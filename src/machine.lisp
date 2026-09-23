(in-package #:cl-mmix)

;;; Special-register numbers (Knuth opcode chart).
(defconstant +r-b+  0)
(defconstant +r-d+  1)
(defconstant +r-e+  2)
(defconstant +r-h+  3)
(defconstant +r-j+  4)
(defconstant +r-m+  5)
(defconstant +r-r+  6)
(defconstant +r-bb+ 7)
(defconstant +r-c+  8)
(defconstant +r-n+  9)
(defconstant +r-o+  10)
(defconstant +r-s+  11)
(defconstant +r-i+  12)
(defconstant +r-t+  13)
(defconstant +r-tt+ 14)
(defconstant +r-k+  15)
(defconstant +r-q+  16)
(defconstant +r-u+  17)
(defconstant +r-v+  18)
(defconstant +r-g+  19)
(defconstant +r-l+  20)
(defconstant +r-a+  21)
(defconstant +r-f+  22)
(defconstant +r-p+  23)
(defconstant +r-w+  24)
(defconstant +r-x+  25)
(defconstant +r-y+  26)
(defconstant +r-z+  27)
(defconstant +r-ww+ 28)
(defconstant +r-xx+ 29)
(defconstant +r-yy+ 30)
(defconstant +r-zz+ 31)

;;; rA event bits, DVWIOUZX from bit 7 down to bit 0. Enables are bits 15–8.
(defconstant +ev-d+ #x80)
(defconstant +ev-v+ #x40)
(defconstant +ev-w+ #x20)
(defconstant +ev-i+ #x10)
(defconstant +ev-o+ #x08)
(defconstant +ev-u+ #x04)
(defconstant +ev-z+ #x02)
(defconstant +ev-x+ #x01)

(defconstant +text-segment+  #x0000000000000000)
(defconstant +data-segment+  #x2000000000000000)
(defconstant +pool-segment+  #x4000000000000000)
(defconstant +stack-segment+ #x6000000000000000)

(defconstant +page-size+ 4096)

(defconstant +special-names+
  (if (boundp '+special-names+)
      (symbol-value '+special-names+)
      #("B" "D" "E" "H" "J" "M" "R" "BB"
        "C" "N" "O" "S" "I" "T" "TT" "K"
        "Q" "U" "V" "G" "L" "A" "F" "P"
        "W" "X" "Y" "Z" "WW" "XX" "YY" "ZZ")))

(define-condition mmix-fault (error)
  ((reason :initarg :reason :reader mmix-fault-reason))
  (:report (lambda (c s) (format s "MMIX fault: ~A" (mmix-fault-reason c)))))

(defstruct fio
  kind
  mode
  stream
  path)

(defstruct mmix-symbol
  name
  value
  kind
  serial)

(defstruct (vm (:constructor %make-vm))
  (memory (make-hash-table :test 'eql) :type hash-table)
  (mem-bytes 0 :type unsigned-byte)
  (mem-limit #x2000000 :type unsigned-byte)
  (registers (make-array 256 :element-type '(unsigned-byte 64) :initial-element 0)
             :type (simple-array (unsigned-byte 64) (256)))
  (special (make-array 32 :element-type '(unsigned-byte 64) :initial-element 0)
           :type (simple-array (unsigned-byte 64) (32)))
  (stack (make-array 64 :element-type '(unsigned-byte 64) :adjustable t :fill-pointer 0)
         :type vector)
  (pc 0 :type (unsigned-byte 64))
  (halted nil :type boolean)
  (cycles 0 :type unsigned-byte)
  (mems 0 :type unsigned-byte)
  (output (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t)
          :type (vector character))
  (error-output (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t)
                :type (vector character))
  (input nil)
  (files nil)
  (fault nil)
  (exit-code nil)
  (break nil)
  (break-skip nil)
  (watch-hit nil)
  (watches nil)
  (labels (make-hash-table :test 'equal) :type hash-table)
  (symbols nil)
  (lines (make-hash-table :test 'eql) :type hash-table)
  (legacy-putchar nil :type boolean))

(defun make-vm (&key (memory-size #x2000000) (pc 0) input legacy-putchar)
  "Create a user-mode MMIX VM.
MEMORY-SIZE is the grow-on-touch page budget in bytes (at least one page).
General registers use the rL/rG window; rG starts at 255 and rL at 0.
The register stack is rooted at Stack_Segment."
  (unless (and (integerp memory-size) (plusp memory-size))
    (error "memory-size must be a positive integer"))
  (let ((vm (%make-vm
             :mem-limit (max memory-size +page-size+)
             :pc (u64 pc)
             :input input
             :legacy-putchar (and legacy-putchar t))))
    (set-special vm +r-g+ 255)
    (sync-stack vm)
    (init-files vm)
    vm))

(defun init-files (vm)
  (let ((v (make-array 256 :initial-element nil)))
    (setf (aref v 0) (make-fio :kind :stdin :mode 0)
          (aref v 1) (make-fio :kind :stdout :mode 1)
          (aref v 2) (make-fio :kind :stderr :mode 1)
          (vm-files vm) v))
  vm)

(defun reset-vm (vm &key (pc 0) clear-memory clear-registers)
  (setf (vm-pc vm) (u64 pc)
        (vm-halted vm) nil
        (vm-cycles vm) 0
        (vm-mems vm) 0
        (vm-fault vm) nil
        (vm-exit-code vm) nil
        (vm-break vm) nil
        (vm-break-skip vm) nil
        (vm-watch-hit vm) nil
        (fill-pointer (vm-output vm)) 0
        (fill-pointer (vm-error-output vm)) 0
        (fill-pointer (vm-stack vm)) 0)
  (when clear-registers
    (fill (vm-registers vm) 0)
    (fill (vm-special vm) 0)
    (set-special vm +r-g+ 255)
    (init-files vm))
  (when clear-memory
    (clrhash (vm-memory vm))
    (setf (vm-mem-bytes vm) 0))
  (sync-stack vm)
  vm)

(defun mem-size (vm)
  "Page budget in bytes. Untouched addresses read as zero until this is exhausted."
  (vm-mem-limit vm))

(defun sync-stack (vm)
  "Keep rO/rS matched to the hidden register stack and rL."
  (let* ((tau (length (vm-stack vm)))
         (l (special-reg vm +r-l+))
         (base +stack-segment+))
    (set-special vm +r-o+ (u64 (+ base (* 8 tau))))
    (set-special vm +r-s+ (u64 (+ base (* 8 (+ tau l))))))
  vm)

(defun special-reg (vm n)
  (aref (vm-special vm) n))

(defun set-special (vm n value)
  "Raw write of special register N. The PUT instruction applies restrictions separately."
  (setf (aref (vm-special vm) n) (u64 value)))

(defun reg-l (vm) (special-reg vm +r-l+))
(defun reg-g (vm) (special-reg vm +r-g+))

(defun reg (vm n)
  "Read general register N under the rL/rG window. Marginal registers read as 0."
  (let ((n (u8 n))
        (l (reg-l vm))
        (g (reg-g vm)))
    (cond ((< n l) (aref (vm-registers vm) n))
          ((< n g) 0)
          (t (aref (vm-registers vm) n)))))

(defun set-reg (vm n value)
  "Write general register N. Writing a marginal register widens rL and zeros the gap."
  (let ((n (u8 n))
        (l (reg-l vm))
        (g (reg-g vm))
        (value (u64 value))
        (regs (vm-registers vm)))
    (cond ((< n l)
           (setf (aref regs n) value))
          ((< n g)
           (loop for k from l below n do (setf (aref regs k) 0))
           (setf (aref regs n) value)
           (set-special vm +r-l+ (1+ n))
           (sync-stack vm))
          (t (setf (aref regs n) value))))
  value)

(defun user-addr (addr)
  (let ((addr (u64 addr)))
    (when (logbitp 63 addr)
      (error 'mmix-fault :reason (format nil "kernel address #x~X" addr)))
    addr))

(defun ensure-page (vm page write-p)
  (or (gethash page (vm-memory vm))
      (when write-p
        (when (> (+ (vm-mem-bytes vm) +page-size+) (vm-mem-limit vm))
          (error 'mmix-fault
                 :reason (format nil "memory limit exceeded (~D bytes) at #x~X"
                                 (vm-mem-limit vm) (* page +page-size+))))
        (incf (vm-mem-bytes vm) +page-size+)
        (setf (gethash page (vm-memory vm))
              (make-array +page-size+
                          :element-type '(unsigned-byte 8)
                          :initial-element 0)))))

(defun %byte (vm addr &optional (value nil write-p))
  (let ((addr (user-addr addr)))
    (multiple-value-bind (page off) (floor addr +page-size+)
      (let ((arr (ensure-page vm page write-p)))
        (cond (write-p (setf (aref arr off) (u8 value)))
              (arr (aref arr off))
              (t 0))))))

(defun note-watch (vm addr kind)
  (dolist (w (vm-watches vm))
    (when (and (eq (car w) kind) (= (the (unsigned-byte 64) (cdr w)) (u64 addr)))
      (setf (vm-watch-hit vm) (list kind (u64 addr)))
      (return))))

(defun mem-ref-u8 (vm addr &key internal)
  (let ((b (%byte vm addr)))
    (unless internal (note-watch vm addr :read))
    b))

(defun mem-set-u8 (vm addr value &key internal)
  (let ((v (%byte vm addr value)))
    (unless internal (note-watch vm addr :write))
    v))

(defun %ref-sized (vm addr nbytes)
  (let ((acc 0))
    (dotimes (i nbytes acc)
      (setf acc (logior (ash acc 8) (%byte vm (+ addr i)))))))

(defun %set-sized (vm addr nbytes value)
  (let ((value (logand value (1- (ash 1 (* 8 nbytes))))))
    (loop for i from 0 below nbytes
          for shift from (* 8 (1- nbytes)) downto 0 by 8
          do (%byte vm (+ addr i) (ldb (byte 8 shift) value)))
    value))

(defun mem-ref-u16 (vm addr &key internal)
  (let ((v (%ref-sized vm addr 2)))
    (unless internal (note-watch vm addr :read))
    v))

(defun mem-set-u16 (vm addr value &key internal)
  (let ((v (%set-sized vm addr 2 value)))
    (unless internal (note-watch vm addr :write))
    v))

(defun mem-ref-u32 (vm addr &key internal)
  (let ((v (%ref-sized vm addr 4)))
    (unless internal (note-watch vm addr :read))
    v))

(defun mem-set-u32 (vm addr value &key internal)
  (let ((v (%set-sized vm addr 4 value)))
    (unless internal (note-watch vm addr :write))
    v))

(defun mem-ref-u64 (vm addr &key internal)
  (let ((v (%ref-sized vm addr 8)))
    (unless internal (note-watch vm addr :read))
    v))

(defun mem-set-u64 (vm addr value &key internal)
  (let ((v (%set-sized vm addr 8 value)))
    (unless internal (note-watch vm addr :write))
    v))

(defun mem-xor (vm addr value nbytes)
  "XOR VALUE (big-endian, NBYTES wide) into ADDR. Used by the .mmo loader."
  (let ((cur (%ref-sized vm addr nbytes)))
    (%set-sized vm addr nbytes (logxor cur (logand value (1- (ash 1 (* 8 nbytes))))))))

(defun event-vector (bit)
  "Trip-vector address for one rA event bit (D at 16 … X at 128)."
  (ecase bit
    (#x80 16) (#x40 32) (#x20 48) (#x10 64)
    (#x08 80) (#x04 96) (#x02 112) (#x01 128)))

(defun do-trip (vm vector &key y z inst)
  "Enter a trip handler at VECTOR. rW is the instruction after the one at PC."
  (set-special vm +r-b+ (reg vm 255))
  (set-special vm +r-w+ (u64 (+ (vm-pc vm) 4)))
  (set-special vm +r-x+ (u64 (or inst 0)))
  (set-special vm +r-y+ (u64 (or y 0)))
  (set-special vm +r-z+ (u64 (or z 0)))
  (setf (vm-pc vm) (u64 vector))
  t)

(defun signal-event (vm bit &key y z inst)
  "Set an rA event bit. If the matching enable is set, trip. Returns true on trip."
  (let ((a (logior (special-reg vm +r-a+) bit)))
    (set-special vm +r-a+ a)
    (when (logtest (ash bit 8) a)
      (do-trip vm (event-vector bit) :y y :z z :inst inst))))

(defun halt-vm (vm)
  (setf (vm-exit-code vm) (reg vm 255)
        (vm-halted vm) t)
  vm)

(defun stack-push-octa (vm value)
  (let ((tau (length (vm-stack vm))))
    (vector-push-extend (u64 value) (vm-stack vm))
    (mem-set-u64 vm (+ +stack-segment+ (* 8 tau)) value :internal t))
  value)

(defun widen-locals (vm x)
  "Make marginal $X local, zeroing $L … $(X−1). rL ← X+1."
  (let ((regs (vm-registers vm))
        (l (reg-l vm)))
    (loop for k from l to x do (setf (aref regs k) 0))
    (set-special vm +r-l+ (1+ x))
    (sync-stack vm)))

(defun push-frame (vm x)
  "PUSHJ/PUSHGO window slide. See mmix-doc §29."
  (let ((regs (vm-registers vm))
        (g (reg-g vm)))
    (cond ((>= x g)
           (let ((l (reg-l vm)))
             (dotimes (k l) (stack-push-octa vm (aref regs k)))
             (stack-push-octa vm l)
             (set-special vm +r-l+ 0)))
          (t
           (when (>= x (reg-l vm))
             (widen-locals vm x))
           (let ((l (reg-l vm)))
             (dotimes (k x) (stack-push-octa vm (aref regs k)))
             (stack-push-octa vm x)
             (let ((new-l (- l x 1)))
               (loop for k from 0 below new-l
                     do (setf (aref regs k) (aref regs (+ k x 1))))
               (set-special vm +r-l+ new-l))))))
  (sync-stack vm))

(defun pop-frame (vm n)
  "POP window slide. N is the number of return values in $0 … $(N−1).
The last of them (the main value) lands in the caller's hole; the earlier
ones land just after the hole, in order."
  (let* ((stack (vm-stack vm))
         (tau (length stack)))
    (when (zerop tau)
      (error 'mmix-fault :reason "POP with an empty register stack"))
    (let ((l (reg-l vm)))
      (when (> n l)
        (setf n (1+ l)))
      (let* ((x (mod (aref stack (1- tau)) 256))
             (rvs (make-array (max n 1) :element-type '(unsigned-byte 64) :initial-element 0)))
        (dotimes (i n)
          (setf (aref rvs i) (reg vm i)))
        (when (plusp n)
          (setf (aref stack (1- tau)) (aref rvs (1- n))))
        (let* ((new-l (min (+ x n) (reg-g vm)))
               (base (- tau x 1)))
          (when (minusp base)
            (error 'mmix-fault :reason "POP frame is larger than the register stack"))
          (let ((regs (vm-registers vm)))
            (dotimes (k (min new-l (+ x (if (plusp n) 1 0))))
              (setf (aref regs k) (aref stack (+ base k))))
            (loop for i from 0 below (max 0 (1- n))
                  for dest = (+ x 1 i)
                  while (< dest new-l)
                  do (setf (aref regs dest) (aref rvs i)))
            (setf (fill-pointer stack) base)
            (set-special vm +r-l+ new-l)
            (sync-stack vm)))))))

(defun privileged-special-p (n)
  (member n '(8 9 10 11 12 13 14 15 16 17 18 22 7 28 29 30 31)))

(defun put-special (vm n value)
  "PUT rules from mmix-doc §43. Privileged registers are left unchanged."
  (cond
    ((privileged-special-p n) nil)
    ((= n +r-a+)
     (set-special vm +r-a+ (logand (u64 value) #x3ffff)))
    ((= n +r-l+)
     (let ((z (logand (u64 value) 255))
           (l (reg-l vm)))
       (when (< z l)
         (set-special vm +r-l+ z)
         (sync-stack vm))))
    ((= n +r-g+)
     (let* ((old-g (reg-g vm))
            (old-l (reg-l vm))
            (g (logand (u64 value) 255))
            (regs (vm-registers vm)))
       (when (< g 32) (setf g 32))
       (when (> g old-g)
         (loop for k from old-g below g do (setf (aref regs k) 0)))
       (when (< g old-g)
         (loop for k from (max g old-l) below old-g
               do (setf (aref regs k) 0)))
       (when (< g old-l)
         (set-special vm +r-l+ g))
       (set-special vm +r-g+ g)
       (sync-stack vm)))
    (t (set-special vm n (u64 value)))))

(defun special-name (n)
  (let ((n (u8 n)))
    (if (<= n 31)
        (format nil "r~A" (aref +special-names+ n))
        (format nil "r?~D" n))))

(defun breakpoint (vm addr &key (kind :exec))
  "Stop when ADDR is fetched (:EXEC), read, or written."
  (push (cons kind (u64 addr)) (vm-watches vm))
  vm)

(defun clear-breakpoints (vm)
  (setf (vm-watches vm) nil
        (vm-break vm) nil
        (vm-break-skip vm) nil)
  vm)
