(in-package #:cl-mmix)

;;; MMIX-SIM system calls. Y field of TRAP, argument/result in $255.
;;; StdIn = 0, StdOut = 1, StdErr = 2 are already open.
;;;
;;;   0 Halt   1 Fopen   2 Fclose  3 Fread   4 Fgets   5 Fgetws
;;;   6 Fwrite 7 Fputs   8 Fputws  9 Fseek  10 Ftell
;;;
;;; Modes: 0 TextRead, 1 TextWrite, 2 BinaryRead, 3 BinaryWrite,
;;; 4 BinaryReadWrite.

(defvar *echo-putchar* t
  "When true, bytes written to StdOut/StdErr are also sent to the Lisp streams.")

(defun mem-cstring (vm addr &optional (limit #x100000))
  (let ((chars (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t)))
    (loop for i from 0 below limit
          for b = (mem-ref-u8 vm (+ addr i) :internal t)
          until (zerop b)
          do (vector-push-extend (code-char b) chars))
    chars))

(defun stream-read-octet (stream)
  (if (subtypep (stream-element-type stream) 'character)
      (let ((c (read-char stream nil nil)))
        (and c (char-code c)))
      (read-byte stream nil nil)))

(defun stream-write-octet (stream byte)
  (if (subtypep (stream-element-type stream) 'character)
      (write-char (code-char (u8 byte)) stream)
      (write-byte (u8 byte) stream)))

(defun ensure-stdin (vm fio)
  (or (fio-stream fio)
      (let ((s (cond
                 ((stringp (vm-input vm))
                  (make-string-input-stream (vm-input vm)))
                 ((streamp (vm-input vm)) (vm-input vm))
                 (t *standard-input*))))
        (setf (fio-stream fio) s))))

(defun fio-can-read (fio)
  (member (fio-mode fio) '(0 2 4)))

(defun fio-can-write (fio)
  (member (fio-mode fio) '(1 3 4)))

(defun capture-byte (vm fio byte)
  (let ((ch (code-char (u8 byte))))
    (case (fio-kind fio)
      (:stdout
       (vector-push-extend ch (vm-output vm))
       (when *echo-putchar*
         (write-char ch *standard-output*)
         (force-output *standard-output*)))
      (:stderr
       (vector-push-extend ch (vm-error-output vm))
       (when *echo-putchar*
         (write-char ch *error-output*)
         (force-output *error-output*)))
      (t (stream-write-octet (fio-stream fio) byte)))))

(defun fio-read-into (vm fio addr size)
  "Read up to SIZE bytes. Returns the count actually stored."
  (let ((n 0))
    (case (fio-kind fio)
      (:stdin
       (let ((s (ensure-stdin vm fio)))
         (loop for i from 0 below size
               for b = (stream-read-octet s)
               while b
               do (mem-set-u8 vm (+ addr i) b :internal t)
                  (incf n))))
      (:file
       (loop for i from 0 below size
             for b = (stream-read-octet (fio-stream fio))
             while b
             do (mem-set-u8 vm (+ addr i) b :internal t)
                (incf n)))
      (t nil))
    n))

(defun fio-write-from (vm fio addr size)
  (let ((n 0))
    (loop for i from 0 below size
          for b = (mem-ref-u8 vm (+ addr i) :internal t)
          do (capture-byte vm fio b)
             (incf n))
    n))

(defun arg-octa (vm index)
  (mem-ref-u64 vm (+ (reg vm 255) (* 8 index)) :internal t))

(defun ret255 (vm value)
  (set-reg vm 255 (u64 value)))

(defun legacy-putchar (vm z)
  (let ((ch (code-char (u8 (reg vm z)))))
    (vector-push-extend ch (vm-output vm))
    (when *echo-putchar*
      (write-char ch)
      (force-output)))
  nil)

(defun sim-fopen (vm z)
  (cond
    ((< z 3)
     (ret255 vm -1))
    (t
     (let* ((name (mem-cstring vm (arg-octa vm 0)))
            (mode (u8 (arg-octa vm 1)))
            (old (aref (vm-files vm) z)))
       (when (and old (eq (fio-kind old) :file) (fio-stream old))
         (close (fio-stream old)))
       (handler-case
           (let ((stream
                  (ecase mode
                    ((0 2) (open name :direction :input
                                 :element-type '(unsigned-byte 8)))
                    ((1 3) (open name :direction :output
                                 :element-type '(unsigned-byte 8)
                                 :if-exists :supersede
                                 :if-does-not-exist :create))
                    (4 (open name :direction :io
                             :element-type '(unsigned-byte 8)
                             :if-exists :supersede
                             :if-does-not-exist :create)))))
             (setf (aref (vm-files vm) z)
                   (make-fio :kind :file :mode mode :stream stream :path name))
             (ret255 vm 0))
         (error ()
           (setf (aref (vm-files vm) z) nil)
           (ret255 vm -1)))))))

(defun sim-fclose (vm z)
  (let ((fio (aref (vm-files vm) z)))
    (cond
      ((null fio) (ret255 vm -1))
      ((member (fio-kind fio) '(:stdin :stdout :stderr))
       (ret255 vm 0))
      (t (when (fio-stream fio) (close (fio-stream fio)))
         (setf (aref (vm-files vm) z) nil)
         (ret255 vm 0)))))

(defun sim-fread (vm z)
  (let ((fio (aref (vm-files vm) z))
        (buf (arg-octa vm 0))
        (size (arg-octa vm 1)))
    (cond
      ((or (null fio) (not (fio-can-read fio)) (> size #x10000000))
       (ret255 vm (- -1 size)))
      (t (let ((n (fio-read-into vm fio buf size)))
           (ret255 vm (- n size)))))))

(defun sim-fwrite (vm z)
  (let ((fio (aref (vm-files vm) z))
        (buf (arg-octa vm 0))
        (size (arg-octa vm 1)))
    (cond
      ((or (null fio) (not (fio-can-write fio)) (> size #x10000000))
       (ret255 vm (- -1 size)))
      (t (let ((n (fio-write-from vm fio buf size)))
           (ret255 vm (- n size)))))))

(defun sim-fgets (vm z)
  (let ((fio (aref (vm-files vm) z))
        (buf (arg-octa vm 0))
        (size (arg-octa vm 1)))
    (cond
      ((or (null fio) (not (fio-can-read fio)) (zerop size))
       (ret255 vm -1))
      (t
       (let ((n 0)
             (limit (1- size)))
         (loop for i from 0 below limit
               for b = (case (fio-kind fio)
                         (:stdin (stream-read-octet (ensure-stdin vm fio)))
                         (:file (stream-read-octet (fio-stream fio)))
                         (t nil))
               while b
               do (mem-set-u8 vm (+ buf i) b :internal t)
                  (incf n)
                  (when (= b 10) (loop-finish)))
         (cond
           ((zerop n) (ret255 vm -1))
           (t (mem-set-u8 vm (+ buf n) 0 :internal t)
              (ret255 vm n))))))))

(defun sim-fputs (vm z)
  (let ((fio (aref (vm-files vm) z))
        (addr (reg vm 255)))
    (cond
      ((or (null fio) (not (fio-can-write fio)))
       (ret255 vm -1))
      (t
       (let ((n 0))
         (loop for i from 0 below #x100000
               for b = (mem-ref-u8 vm (+ addr i) :internal t)
               until (zerop b)
               do (capture-byte vm fio b)
                  (incf n))
         (ret255 vm n))))))

(defun sim-fputws (vm z)
  "Write wyde characters up to a zero wyde. Each value below 256 is one byte."
  (let ((fio (aref (vm-files vm) z))
        (addr (reg vm 255)))
    (cond
      ((or (null fio) (not (fio-can-write fio)))
       (ret255 vm -1))
      (t
       (let ((n 0))
         (loop for i from 0 by 2
               for w = (mem-ref-u16 vm (+ addr i) :internal t)
               until (zerop w)
               do (if (<= w 255)
                      (capture-byte vm fio w)
                      (progn (capture-byte vm fio (ldb (byte 8 8) w))
                             (capture-byte vm fio (ldb (byte 8 0) w))))
                  (incf n))
         (ret255 vm n))))))

(defun sim-fgetws (vm z)
  (let ((fio (aref (vm-files vm) z))
        (buf (arg-octa vm 0))
        (size (arg-octa vm 1)))
    (cond
      ((or (null fio) (not (fio-can-read fio)) (zerop size))
       (ret255 vm -1))
      (t
       (let ((n 0))
         (loop for i from 0 below (1- size)
               for b = (case (fio-kind fio)
                         (:stdin (stream-read-octet (ensure-stdin vm fio)))
                         (:file (stream-read-octet (fio-stream fio)))
                         (t nil))
               while b
               do (mem-set-u16 vm (+ buf (* 2 i)) b :internal t)
                  (incf n)
                  (when (= b 10) (loop-finish)))
         (cond
           ((zerop n) (ret255 vm -1))
           (t (mem-set-u16 vm (+ buf (* 2 n)) 0 :internal t)
              (ret255 vm n))))))))

(defun sim-fseek (vm z)
  (let ((fio (aref (vm-files vm) z)))
    (cond
      ((or (null fio) (not (eq (fio-kind fio) :file)))
       (ret255 vm -1))
      (t (handler-case
             (progn
               (file-position (fio-stream fio) (i64-from-u64 (reg vm 255)))
               (ret255 vm 0))
           (error () (ret255 vm -1)))))))

(defun sim-ftell (vm z)
  (let ((fio (aref (vm-files vm) z)))
    (cond
      ((or (null fio) (not (eq (fio-kind fio) :file)))
       (ret255 vm -1))
      (t (let ((pos (file-position (fio-stream fio))))
           (ret255 vm (if pos pos -1)))))))

(defun exec-trap (vm inst)
  "Perform one TRAP. Returns :STOP when the machine halts."
  (let ((x (inst-x inst))
        (y (inst-y inst))
        (z (inst-z inst)))
    (cond
      ((and (zerop x) (zerop y) (zerop z))
       (halt-vm vm)
       :stop)
      ((and (zerop x) (zerop y) (= z 1))
       (setf (vm-fault vm) "TRAP 0,0,1 (no kernel to service the trip)")
       (halt-vm vm)
       :stop)
      ((and (vm-legacy-putchar vm) (zerop x) (= y 1))
       (legacy-putchar vm z))
      ((zerop y)
       (halt-vm vm)
       :stop)
      (t
       (case y
         (1 (sim-fopen vm z))
         (2 (sim-fclose vm z))
         (3 (sim-fread vm z))
         (4 (sim-fgets vm z))
         (5 (sim-fgetws vm z))
         (6 (sim-fwrite vm z))
         (7 (sim-fputs vm z))
         (8 (sim-fputws vm z))
         (9 (sim-fseek vm z))
         (10 (sim-ftell vm z))
         (t (setf (vm-fault vm) (format nil "unsupported TRAP ~D,~D,~D" x y z))
            (halt-vm vm)
            (return-from exec-trap :stop)))
       nil))))
