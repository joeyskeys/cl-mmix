(in-package #:cl-mmix)

;;; .mmo loader (MMIXware object format).
;;; Loader opcodes live in tetrabytes whose high byte is #x98.
;;; Content tetrabytes are XOR-ed into memory, which is how fixups patch
;;; fields that were emitted as zero.

(defconstant +mmo-esc+ #x98)
(defconstant +lop-quote+ 0)
(defconstant +lop-loc+ 1)
(defconstant +lop-skip+ 2)
(defconstant +lop-fixo+ 3)
(defconstant +lop-fixr+ 4)
(defconstant +lop-fixrx+ 5)
(defconstant +lop-file+ 6)
(defconstant +lop-line+ 7)
(defconstant +lop-spec+ 8)
(defconstant +lop-pre+ 9)
(defconstant +lop-post+ 10)
(defconstant +lop-stab+ 11)
(defconstant +lop-end+ 12)

(defstruct mmo-in
  (data #() :type vector)
  (pos 0 :type unsigned-byte)
  (buf (make-array 4 :element-type '(unsigned-byte 8))
       :type (simple-array (unsigned-byte 8) (4)))
  (byte-index 4 :type unsigned-byte))

(defun mmo-eof-p (in)
  (>= (mmo-in-pos in) (length (mmo-in-data in))))

(defun mmo-read-tetra (in &optional (eof-error-p t) eof-value)
  (when (> (+ (mmo-in-pos in) 4) (length (mmo-in-data in)))
    (if eof-error-p
        (error 'mmix-fault :reason "unexpected end of .mmo file")
        (return-from mmo-read-tetra eof-value)))
  (let ((w 0)
        (data (mmo-in-data in)))
    (dotimes (i 4)
      (let ((b (aref data (mmo-in-pos in))))
        (setf (aref (mmo-in-buf in) i) b)
        (setf w (logior (ash w 8) b))
        (incf (mmo-in-pos in))))
    (setf (mmo-in-byte-index in) 4)
    w))

(defun mmo-read-byte (in)
  (when (= (mmo-in-byte-index in) 4)
    (mmo-read-tetra in)
    (setf (mmo-in-byte-index in) 0))
  (prog1 (aref (mmo-in-buf in) (mmo-in-byte-index in))
    (incf (mmo-in-byte-index in))))

(defun mmo-read-octa (in)
  (let ((hi (mmo-read-tetra in)))
    (logior (ash hi 32) (mmo-read-tetra in))))

(defun mmo-read-addr (in y z)
  "Address encoded like lop_loc: Y·2^56 plus a tetra (Z=1) or an octa (Z=2)."
  (cond ((= z 1) (+ (ash y 56) (mmo-read-tetra in)))
        ((= z 2) (+ (ash y 56) (mmo-read-octa in)))
        (t (error 'mmix-fault
                  :reason (format nil "Z field of a location lopcode must be 1 or 2, not ~D" z)))))

(defun mmo-yz (tetra)
  (ldb (byte 16 0) tetra))

(defun mmo-lop (tetra)
  (ldb (byte 8 16) tetra))

(defun mmo-quoted-p (tetra)
  (and (= (ldb (byte 8 24) tetra) +mmo-esc+)
       (= (mmo-lop tetra) +lop-quote+)
       (= (mmo-yz tetra) 1)))

(defun symbol-is-main (name)
  (or (string-equal name "Main")
      (string-equal name ":Main")
      (and (> (length name) 1)
           (or (string-equal (subseq name 1) "Main")
               (string-equal (subseq name 1) ":Main")))))

(defun mmo-read-serial (in)
  (let ((j (mmo-read-byte in)))
    (loop while (< j 128)
          for k = (mmo-read-byte in)
          do (setf j (+ (ash j 7) k)))
    (- j 128)))

(defun mmo-read-symbol-value (in m)
  (let ((j (logand m #x0F)))
    (cond
      ((= j 15)
       (values (mmo-read-byte in) :register))
      ((<= j 8)
       (let ((v 0))
         (dotimes (i j)
           (setf v (logior (ash v 8) (mmo-read-byte in))))
         (values v :absolute)))
      (t
       (let ((v (ash +data-segment+ (- (* 8 (- j 8))))))
         (loop repeat (- j 8)
               do (setf v (logior (ash v 8) (mmo-read-byte in))))
         (values v :absolute))))))

(defun mmo-parse-stab (in prefix symbols)
  (let ((m (mmo-read-byte in)))
    (when (logtest m #x40)
      (mmo-parse-stab in prefix symbols))
    (when (logtest m #x2F)
      (let* ((ch (if (logtest m #x80)
                     (code-char (logior (ash (mmo-read-byte in) 8)
                                        (mmo-read-byte in)))
                     (code-char (mmo-read-byte in))))
             (here (concatenate 'string prefix (string ch))))
        (when (logtest m #x0F)
          (multiple-value-bind (value kind) (mmo-read-symbol-value in m)
            (let ((serial (mmo-read-serial in)))
              (push (make-mmix-symbol :name here :value value
                                      :kind kind :serial serial)
                    (cdr symbols)))))
        (when (logtest m #x20)
          (mmo-parse-stab in here symbols))))
    (when (logtest m #x10)
      (mmo-parse-stab in prefix symbols))))

(defun mmo-skip-spec (in)
  "Skip special-data tetrabytes. Returns the terminating tetra, or NIL at EOF."
  (loop
    (let ((w (mmo-read-tetra in nil nil)))
      (cond
        ((null w) (return nil))
        ((mmo-quoted-p w)
         (mmo-read-tetra in))
        ((= (ldb (byte 8 24) w) +mmo-esc+)
         (return w))))))

(defun load-mmo-bytes (vm bytes)
  "Load an .mmo image from an octet vector. Sets rG, globals, symbols, and PC."
  (let ((in (make-mmo-in :data bytes))
        (loc 0)
        (text-entry nil)
        (cur-file nil)
        (cur-line 0)
        (files (make-array 256 :initial-element nil)))
    (let ((pre (mmo-read-tetra in)))
      (unless (and (= (ldb (byte 8 24) pre) +mmo-esc+)
                   (= (mmo-lop pre) +lop-pre+))
        (error 'mmix-fault :reason "file does not start with an .mmo preamble"))
      ;; #x98090101: Y is the format version, Z is how many tetras follow
      ;; (today, one timestamp tetra). YZ as a 16-bit count would skip 257.
      (dotimes (i (ldb (byte 8 0) pre))
        (mmo-read-tetra in)))
    (loop
      (when (mmo-eof-p in) (return))
      (let ((w (mmo-read-tetra in nil nil)))
        (unless w (return))
        (cond
          ((mmo-quoted-p w)
           (setf w (mmo-read-tetra in))
           (setf loc (logand loc (lognot 3)))
           (mem-xor vm loc w 4)
           (unless text-entry
             (when (< loc +data-segment+) (setf text-entry loc)))
           (incf loc 4))
          ((= (ldb (byte 8 24) w) +mmo-esc+)
           (let ((lop (mmo-lop w))
                 (y (ldb (byte 8 8) w))
                 (z (ldb (byte 8 0) w)))
             (case lop
               (#.+lop-loc+ (setf loc (mmo-read-addr in y z)))
               (#.+lop-skip+ (incf loc (mmo-yz w)))
               (#.+lop-fixo+
                (mem-xor vm (mmo-read-addr in y z) loc 8))
               (#.+lop-fixr+
                (let ((yz (mmo-yz w)))
                  (mem-xor vm (+ loc 2 (- (* 4 yz))) yz 2)))
               (#.+lop-fixrx+
                (unless (and (zerop y) (member z '(16 24)))
                  (error 'mmix-fault :reason "bad lop_fixrx"))
                (let* ((delta (mmo-read-tetra in))
                       (lead (ldb (byte 8 24) delta))
                       (p (if (zerop lead)
                              (- loc (* 4 delta))
                              (- loc (* 4 (- (logand delta #xffffff)
                                             (ash 1 z)))))))
                  (mem-xor vm p delta 4)))
               (#.+lop-file+
                (if (plusp z)
                    (let ((name (make-string (* 4 z))))
                      (dotimes (i (* 4 z))
                        (setf (char name i) (code-char (mmo-read-byte in))))
                      (setf (aref files y) (string-right-trim '(#\Null) name)
                            cur-file y
                            cur-line 0))
                    (setf cur-file y cur-line 0)))
               (#.+lop-line+ (setf cur-line (mmo-yz w)))
               (#.+lop-spec+
                (let ((next (mmo-skip-spec in)))
                  (when next
                    ;; Reprocess the terminating lopcode by stepping back.
                    (decf (mmo-in-pos in) 4))))
               (#.+lop-post+
                (unless (zerop y)
                  (error 'mmix-fault :reason "Y field of lop_post must be 0"))
                (unless (>= z 32)
                  (error 'mmix-fault :reason "rG in lop_post must be at least 32"))
                (set-special vm +r-g+ z)
                (loop for g from z below 256
                      do (setf (aref (vm-registers vm) g) (mmo-read-octa in)))
                (return))
               (#.+lop-pre+
                (error 'mmix-fault :reason "duplicate .mmo preamble"))
               (#.+lop-quote+
                (error 'mmix-fault :reason "lop_quote must have YZ=1"))
               (t (error 'mmix-fault
                         :reason (format nil "unknown lopcode #x~2,'0X" lop))))))
          (t
           (setf loc (logand loc (lognot 3)))
           (mem-xor vm loc w 4)
           (when (and (plusp cur-line) (< loc +data-segment+))
             (setf (gethash loc (vm-lines vm))
                   (cons (and cur-file (aref files cur-file)) cur-line))
             (incf cur-line))
           (unless text-entry
             (when (< loc +data-segment+) (setf text-entry loc)))
           (incf loc 4)))))
    (let ((symbols (cons nil nil))
          (main nil))
      (let ((w (mmo-read-tetra in nil nil)))
        (when (and w (= (ldb (byte 8 24) w) +mmo-esc+)
                   (= (mmo-lop w) +lop-stab+))
          (mmo-parse-stab in "" symbols)
          (loop while (< (mmo-in-byte-index in) 4)
                do (let ((b (mmo-read-byte in)))
                     (unless (zerop b)
                       (error 'mmix-fault :reason "nonzero padding after the symbol table"))))
          (let ((end (mmo-read-tetra in nil nil)))
            (when (and end (/= (mmo-lop end) +lop-end+))
              (error 'mmix-fault :reason "symbol table is not closed by lop_end")))))
      (dolist (sym (cdr symbols))
        (when (and (eq (mmix-symbol-kind sym) :absolute)
                   (symbol-is-main (mmix-symbol-name sym)))
          (setf main (mmix-symbol-value sym))))
      (setf (vm-symbols vm) (nreverse (cdr symbols)))
      (dolist (sym (vm-symbols vm))
        (setf (gethash (mmix-symbol-name sym) (vm-labels vm))
              (mmix-symbol-value sym)))
      (setf (vm-pc vm) (u64 (or main text-entry 0))
            (vm-halted vm) nil
            (vm-cycles vm) 0
            (vm-fault vm) nil))
    (sync-stack vm)
    vm))

(defun read-binary-file (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((a (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence a s)
      a)))

(defun load-mmo (vm source)
  "Load an .mmo program into VM. SOURCE is a pathname, a filename, or an octet vector."
  (load-mmo-bytes vm
                  (if (vectorp source)
                      source
                      (read-binary-file source))))
