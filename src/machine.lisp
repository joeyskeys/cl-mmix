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

;;; High three bytes of rN (§41). mmix-doc version 1.0.0.
(defconstant +arch-version+ #x010000)

;;; Common Lisp universal time is seconds since 1900-01-01 UTC.
;;; rN's low five bytes are seconds since 1970-01-01 UTC.
(defconstant +unix-epoch+ 2208988800)

;;; rC holds a continuation-page PTE. PUT rC stays ignored on the user-mode path.
;;; With virtual memory on, a register spill into a page without pw writes the
;;; physical page named here. The PTE is: ignored high bits, a physical page
;;; number in a (48−s)-bit field, ignored (s−13) bits, a 10-bit address-space
;;; number, and the protection bits pr pw px.
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

;;; rQ program byte rwxnkbsp, bits 39–32. Machine bit 6 (interval) stays #x40.
(defconstant +rq-r+ (ash #x80 32))
(defconstant +rq-w+ (ash #x40 32))
(defconstant +rq-x+ (ash #x20 32))
(defconstant +rq-n+ (ash #x10 32))
(defconstant +rq-k+ (ash #x08 32))
(defconstant +rq-b+ (ash #x04 32))
(defconstant +rq-s+ (ash #x02 32))
(defconstant +rq-p+ (ash #x01 32))
(defconstant +rq-prog+ (ash #xFF 32))

;;; §45 raises a stack-overflow interrupt after a spill onto the continuation
;;; page and does not assign it a program bit. This is the leftmost
;;; high-priority I/O bit of rQ (bit 31).
(defconstant +rq-stack-overflow+ (ash 1 31))

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

(define-condition mmix-suppress (error)
  ((bit :initarg :bit :reader mmix-suppress-bit))
  (:report (lambda (c s)
             (format s "MMIX suppress: program bit #x~X" (mmix-suppress-bit c)))))

(define-condition mmix-taken-trap (condition) ()
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "MMIX trap taken"))))

(defvar *exec-vm* nil
  "VM bound by EXECUTE. Illegal fields consult it to choose a halt or the b bit.")

(defvar *exec-inst* nil
  "Instruction bound by EXECUTE. A fetch translation sees NIL and records SWYM.")

(defun illegal-instruction ()
  "The b condition. User mode halts. A kernel VM records b and suppresses the instruction."
  (let ((vm *exec-vm*))
    (if (and vm (vm-kernel vm))
        (error 'mmix-suppress :bit +rq-b+)
        (error 'mmix-fault :reason "illegal instruction"))))

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
  (legacy-putchar nil :type boolean)
  (kernel nil :type boolean)
  (rom nil)
  (rom-base 0 :type (unsigned-byte 64))
  (rq-gotten 0 :type (unsigned-byte 64))
  (trans-cache nil)
  (trans-va 0 :type (unsigned-byte 64))
  (trans-pte 0 :type (unsigned-byte 64))
  (virtual-memory nil :type boolean)
  (mmio nil)
  (itc (make-hash-table :test 'eql) :type hash-table)
  (dtc (make-hash-table :test 'eql) :type hash-table)
  (stack-alert nil :type boolean))

;;; Defined in src/translate.lisp. Guest loads and stores call them when
;;; virtual memory is on. A spill asks whether the stack page has pw.
(declaim (ftype (function (t t (integer 1 8)) (unsigned-byte 64)) guest-load)
         (ftype (function (t t (integer 1 8) t) t) guest-store)
         (ftype (function (t t) (values t t &optional)) stack-spill-target))

;;; Defined in src/kernel.lisp.
(declaim (ftype (function (t) t) install-kernel))

(defun make-vm (&key (memory-size #x2000000) (pc 0) input legacy-putchar kernel
                   virtual-memory)
  "Create an MMIX VM. Without :KERNEL this is the user-mode interpreter.
MEMORY-SIZE is the grow-on-touch page budget in bytes (at least one page).
General registers use the rL/rG window; rG starts at 255 and rL at 0.
The register stack is rooted at Stack_Segment.
:KERNEL installs the trap ROM, sets rT and rTT to its entry, and sets rK to all ones.
:VIRTUAL-MEMORY requires :KERNEL and translates nonnegative addresses through rV.
The default leaves the four segments as an identity map, and LDVTS returns 0."
  (unless (and (integerp memory-size) (plusp memory-size))
    (error "memory-size must be a positive integer"))
  (when (and virtual-memory (not kernel))
    (error ":virtual-memory requires :kernel t"))
  (let ((vm (%make-vm
             :mem-limit (max memory-size +page-size+)
             :pc (u64 pc)
             :input input
             :legacy-putchar (and legacy-putchar t)
             :kernel (and kernel t)
             :virtual-memory (and virtual-memory t))))
    (set-special vm +r-g+ 255)
    (stamp-serial vm)
    (sync-stack vm)
    (init-files vm)
    (when kernel
      (install-kernel vm))
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
        (fill-pointer (vm-stack vm)) 0
        (vm-stack-alert vm) nil)
  (clrhash (vm-itc vm))
  (clrhash (vm-dtc vm))
  (when clear-registers
    (let ((serial (special-reg vm +r-n+)))
      (fill (vm-registers vm) 0)
      (fill (vm-special vm) 0)
      (set-special vm +r-g+ 255)
      (set-special vm +r-n+ serial)
      (setf (vm-rq-gotten vm) 0
            (vm-trans-cache vm) nil
            (vm-trans-va vm) 0
            (vm-trans-pte vm) 0)
      (when (vm-kernel vm)
        (set-special vm +r-t+ (vm-rom-base vm))
        (set-special vm +r-tt+ (vm-rom-base vm))
        (set-special vm +r-k+ #xffffffffffffffff))
      (init-files vm)))
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

(defun stamp-serial (vm)
  "Freeze rN. High three bytes are +ARCH-VERSION+. Low five bytes are the
Unix time at which this VM was created. Later PUT and reset-vm leave it."
  (set-special vm +r-n+
               (logior (ash +arch-version+ 40)
                       (logand (- (get-universal-time) +unix-epoch+)
                               #xffffffffff)))
  vm)

(defun tick-interval (vm)
  "One retired instruction. rI counts down; the step from 1 to 0 sets rQ bit 6.
Until plan 08 a tick is one instruction, not one υ. A kernel VM whose rK
unmasks that bit takes a dynamic trap on the following step-vm."
  (let ((ri (special-reg vm +r-i+)))
    (when (plusp ri)
      (let ((next (1- ri)))
        (set-special vm +r-i+ next)
        (when (zerop next)
          (set-special vm +r-q+ (logior (special-reg vm +r-q+) (ash 1 6)))))))
  vm)

(defun note-usage (vm op pc)
  "Count a retired opcode in rU. up is bits 63–56, um is bits 55–48, bit 47
is the kernel-counting flag, and uc is bits 46–0, incremented modulo 2^47.
A negative PC counts only when bit 47 is set. The fetched opcode is the one
that retires; an instruction inserted by RESUME is part of that RESUME."
  (let* ((ru (special-reg vm +r-u+))
         (up (ldb (byte 8 56) ru))
         (um (ldb (byte 8 48) ru)))
    (when (and (= (logand (logand op #xff) um) up)
               (or (not (logbitp 63 (u64 pc)))
                   (logbitp 47 ru)))
      (let ((uc (logand (1+ (logand ru #x7fffffffffff)) #x7fffffffffff)))
        (set-special vm +r-u+
                     (logior (logand ru (lognot #x7fffffffffff)) uc)))))
  vm)

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
          (let ((addr (* page +page-size+)))
            ;; rF records the refused physical address. It is not rW.
            (set-special vm +r-f+ addr)
            (error 'mmix-fault
                   :reason (format nil "memory limit exceeded (~D bytes) at #x~X"
                                   (vm-mem-limit vm) addr))))
        (incf (vm-mem-bytes vm) +page-size+)
        (setf (gethash page (vm-memory vm))
              (make-array +page-size+
                          :element-type '(unsigned-byte 8)
                          :initial-element 0)))))

(defun raise-program-bit (vm bit)
  (set-special vm +r-q+ (logior (special-reg vm +r-q+) bit)))

(defun %chunk-byte (vm addr &optional (value nil write-p))
  "One byte of the physical hash. ADDR is below 2^48. A missing read is 0."
  (multiple-value-bind (page off) (floor addr +page-size+)
    (let ((arr (ensure-page vm page write-p)))
      (cond (write-p (setf (aref arr off) (u8 value)))
            (arr (aref arr off))
            (t 0)))))

(defun default-mmio (vm addr nbytes value write-p)
  "Unmapped I/O. A read returns 0, a write is ignored, and rF receives ADDR."
  (declare (ignore nbytes value write-p))
  (set-special vm +r-f+ (u64 addr))
  0)

(defun call-mmio (vm addr nbytes value write-p)
  (let ((hook (vm-mmio vm)))
    (if hook
        (funcall hook vm addr nbytes value write-p)
        (default-mmio vm addr nbytes value write-p))))

(defun physical-ref (vm addr nbytes)
  "Read NBYTES at a physical address. Addresses at and above 2^48 are I/O."
  (let ((addr (logand (u64 addr) #x7fffffffffffffff)))
    (if (>= addr (ash 1 48))
        (logand (u64 (call-mmio vm addr nbytes nil nil))
                (1- (ash 1 (* 8 nbytes))))
        (let ((acc 0))
          (dotimes (i nbytes acc)
            (setf acc (logior (ash acc 8) (%chunk-byte vm (+ addr i)))))))))

(defun physical-set (vm addr nbytes value)
  "Write NBYTES at a physical address. I/O at and above 2^48 is not stored."
  (let ((addr (logand (u64 addr) #x7fffffffffffffff))
        (value (logand (u64 value) (1- (ash 1 (* 8 nbytes))))))
    (if (>= addr (ash 1 48))
        (call-mmio vm addr nbytes value t)
        (loop for i from 0 below nbytes
              for shift from (* 8 (1- nbytes)) downto 0 by 8
              do (%chunk-byte vm (+ addr i) (ldb (byte 8 shift) value))))
    value))

(defun %byte (vm addr &optional (value nil write-p))
  (let ((addr (u64 addr)))
    ;; A nonnegative instruction that names a negative address sets n.
    ;; The load yields 0 and the store writes nothing. Kernel instructions
    ;; (negative PC) map by clearing bit 63. User mode still faults.
    (when (and (vm-kernel vm)
               (logbitp 63 addr)
               (not (logbitp 63 (vm-pc vm))))
      (raise-program-bit vm +rq-n+)
      (return-from %byte 0))
    (let ((addr (if (and (vm-kernel vm) (logbitp 63 addr))
                    (logand addr #x7fffffffffffffff)
                    (user-addr addr))))
      (if write-p
          (%chunk-byte vm addr value)
          (%chunk-byte vm addr)))))

(defun %guest-access (vm addr nbytes value write-p internal physical)
  (cond (physical
         (if write-p
             (physical-set vm addr nbytes value)
             (physical-ref vm addr nbytes)))
        ((and (vm-virtual-memory vm) (not internal))
         (if write-p
             (guest-store vm addr nbytes value)
             (guest-load vm addr nbytes)))
        (write-p
         (if (= nbytes 1)
             (%byte vm addr value)
             (%set-sized vm addr nbytes value)))
        (t
         (if (= nbytes 1)
             (%byte vm addr)
             (%ref-sized vm addr nbytes)))))

(defun note-watch (vm addr kind)
  (dolist (w (vm-watches vm))
    (when (and (eq (car w) kind) (= (the (unsigned-byte 64) (cdr w)) (u64 addr)))
      (setf (vm-watch-hit vm) (list kind (u64 addr)))
      (return))))

(defun mem-ref-u8 (vm addr &key internal physical)
  (let ((b (%guest-access vm addr 1 nil nil internal physical)))
    (unless (or internal physical) (note-watch vm addr :read))
    b))

(defun mem-set-u8 (vm addr value &key internal physical)
  (let ((v (%guest-access vm addr 1 value t internal physical)))
    (unless (or internal physical) (note-watch vm addr :write))
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

(defun mem-ref-u16 (vm addr &key internal physical)
  (let ((v (%guest-access vm addr 2 nil nil internal physical)))
    (unless (or internal physical) (note-watch vm addr :read))
    v))

(defun mem-set-u16 (vm addr value &key internal physical)
  (let ((v (%guest-access vm addr 2 value t internal physical)))
    (unless (or internal physical) (note-watch vm addr :write))
    v))

(defun mem-ref-u32 (vm addr &key internal physical)
  (let ((v (%guest-access vm addr 4 nil nil internal physical)))
    (unless (or internal physical) (note-watch vm addr :read))
    v))

(defun mem-set-u32 (vm addr value &key internal physical)
  (let ((v (%guest-access vm addr 4 value t internal physical)))
    (unless (or internal physical) (note-watch vm addr :write))
    v))

(defun mem-ref-u64 (vm addr &key internal physical)
  (let ((v (%guest-access vm addr 8 nil nil internal physical)))
    (unless (or internal physical) (note-watch vm addr :read))
    v))

(defun mem-set-u64 (vm addr value &key internal physical)
  (let ((v (%guest-access vm addr 8 value t internal physical)))
    (unless (or internal physical) (note-watch vm addr :write))
    v))

(defun mem-xor (vm addr value nbytes)
  "XOR VALUE (big-endian, NBYTES wide) into ADDR. Used by the .mmo loader."
  (let ((cur (%ref-sized vm addr nbytes)))
    (%set-sized vm addr nbytes (logxor cur (logand value (1- (ash 1 (* 8 nbytes))))))))

(defvar *yz-override* nil
  "During RESUME ropcode 1, a cons (Y . Z) replacing the instruction's operands.")

(defun event-vector (bit)
  "Trip-vector address for one rA event bit (D at 16 … X at 128)."
  (ecase bit
    (#x80 16) (#x40 32) (#x20 48) (#x10 64)
    (#x08 80) (#x04 96) (#x02 112) (#x01 128)))

(defun trip-suppressed-p (vm)
  "Instructions fetched from a negative address do not trip."
  (logbitp 63 (vm-pc vm)))

(defun do-trip (vm vector &key y z inst)
  "Enter a trip handler at VECTOR (§35). Returns true when the trip is taken.
rB saves the previous $255, $255 receives rJ, and rX is the raw tetra with
bit 63 set. rW is the instruction after the one at PC. A negative PC does
not trip."
  (when (trip-suppressed-p vm)
    (return-from do-trip nil))
  (let ((saved-255 (reg vm 255)))
    (set-special vm +r-b+ saved-255)
    (set-reg vm 255 (special-reg vm +r-j+))
    (set-special vm +r-w+ (u64 (+ (vm-pc vm) 4)))
    (set-special vm +r-x+ (logior #x8000000000000000
                                  (logand (u64 (or inst 0)) #xffffffff)))
    (set-special vm +r-y+ (u64 (or y 0)))
    (set-special vm +r-z+ (u64 (or z 0)))
    (setf (vm-pc vm) (u64 vector)))
  t)

(defun highest-event-bit (bits)
  "Earliest bit of DVWIOUZX present in BITS."
  (loop for bit in '(#x80 #x40 #x20 #x10 #x08 #x04 #x02 #x01)
        when (logtest bits bit)
          return bit))

(defun record-event-bits (vm bits)
  (when (plusp bits)
    (set-special vm +r-a+ (logior (special-reg vm +r-a+) (logand bits #xff)))))

(defun signal-events (vm bits &key y z inst)
  "BITS is a mask of rA event bits. The earliest enabled bit trips and stays
clear; every other bit is recorded. Nothing trips at a negative PC, and in
that case every bit is recorded. Returns true when a trip is taken."
  (setf bits (logand (or bits 0) #xff))
  (when (zerop bits)
    (return-from signal-events nil))
  (let* ((enabled (logand bits (logand (ash (special-reg vm +r-a+) -8) #xff)))
         (winner (and (plusp enabled)
                      (not (trip-suppressed-p vm))
                      (highest-event-bit enabled))))
    (record-event-bits vm (if winner (logandc2 bits winner) bits))
    (when winner
      (do-trip vm (event-vector winner) :y y :z z :inst inst))))

(defun signal-event (vm bit &key y z inst)
  "Record one rA event bit, or trip when its enable is set. Returns true on trip."
  (signal-events vm bit :y y :z z :inst inst))

(defun suppress-exact-underflow (vm bits)
  "Drop an exact U (U set, X clear, U enable clear), including for RESUME ropcode 2."
  (if (and (logtest bits +ev-u+)
           (not (logtest bits +ev-x+))
           (not (logtest (special-reg vm +r-a+) (ash +ev-u+ 8))))
      (logandc2 bits +ev-u+)
      bits))

(defun halt-vm (vm)
  (setf (vm-exit-code vm) (reg vm 255)
        (vm-halted vm) t)
  vm)

(defun stack-push-octa (vm value)
  (let* ((tau (length (vm-stack vm)))
         (addr (+ +stack-segment+ (* 8 tau))))
    (vector-push-extend (u64 value) (vm-stack vm))
    ;; The mirror is an identity store so a push does not need a page table.
    ;; A virtual page without pw is the one case that diverts to rC.
    (if (vm-virtual-memory vm)
        (multiple-value-bind (phys divert) (stack-spill-target vm addr)
          (if divert
              (progn
                (physical-set vm phys 8 value)
                (setf (vm-stack-alert vm) t))
              (mem-set-u64 vm addr value :internal t)))
        (mem-set-u64 vm addr value :internal t)))
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
    (let ((top (aref stack (1- tau))))
      ;; A return hole is at most 255. The SAVE header has rG in its top
      ;; byte, so POP immediately after SAVE sees an empty register stack.
      (unless (<= top 255)
        (error 'mmix-fault :reason "POP with an empty register stack"))
      (let ((l (reg-l vm)))
        (when (> n l)
          (setf n (1+ l)))
        (let* ((x top)
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
              (sync-stack vm))))))))

(defvar *save-specials*
  (vector +r-b+ +r-d+ +r-e+ +r-h+ +r-j+ +r-m+
          +r-r+ +r-p+ +r-w+ +r-x+ +r-y+ +r-z+)
  "Specials pushed by SAVE, low address to high: rB first, rZ last.")

(defun set-hidden-tau (vm tau)
  "Make the hidden stack TAU octas long, filling a gap from the stack segment."
  (when (or (minusp tau) (> tau #x100000))
    (error 'mmix-fault :reason "UNSAVE image is not on the register stack"))
  (let ((stack (vm-stack vm)))
    (cond ((< tau (length stack))
           (setf (fill-pointer stack) tau))
          ((> tau (length stack))
           (loop for k from (length stack) below tau
                 do (vector-push-extend
                     (mem-ref-u64 vm (+ +stack-segment+ (* 8 k)) :internal t)
                     stack)))))
  (sync-stack vm))

(defun save-context (vm x)
  "SAVE $X. Writes the §43 process image and leaves $X holding its top address.
The whole image is one step-vm. Plan 05 will poll a phase and a count in rX
when a trip arrives mid-save (α = β = γ, rO = rS, rL = 0, so the handler
sees a fresh stack on a partial image). This function does not return
mid-instruction."
  (let ((g (reg-g vm))
        (x (u8 x)))
    (unless (>= x g)
      (illegal-instruction))
    ;; push-frame of register 255 uses the X ≥ rG arm: locals, then the old
    ;; rL as the hole, then rL ← 0. The hole is that saved rL, not 255.
    (push-frame vm 255)
    (loop for k from g to 255
          do (stack-push-octa vm (reg vm k)))
    (loop for s across *save-specials*
          do (stack-push-octa vm (special-reg vm s)))
    (stack-push-octa vm (logior (ash (logand g #xff) 56)
                                (logand (special-reg vm +r-a+) #xffffffff)))
    (set-reg vm x (+ +stack-segment+ (* 8 (1- (length (vm-stack vm))))))
    (sync-stack vm))
  vm)

(defun unsave-context (vm addr)
  "UNSAVE 0,$Z. Reverses save-context. Reads vm-stack when ADDR is the current
top octa (rO − 8), and memory when the image was moved. Restores rO to the
address of the first saved local. One step-vm, same plan 05 hook as SAVE."
  (let* ((addr (u64 addr))
         (stack (vm-stack vm))
         (tau (length stack))
         (top (and (plusp tau)
                   (+ +stack-segment+ (* 8 (1- tau)))))
         (from-stack (and top (= addr top)))
         (cursor addr))
    (labels ((peek ()
               (cond (from-stack
                      (when (zerop (length stack))
                        (error 'mmix-fault :reason "UNSAVE ran off the register stack"))
                      (aref stack (1- (length stack))))
                     ((minusp cursor)
                      (error 'mmix-fault :reason "UNSAVE ran off the bottom of memory"))
                     (t (mem-ref-u64 vm cursor :internal t))))
             (next-octa ()
               (prog1 (peek)
                 (when from-stack
                   (vector-pop stack))
                 (decf cursor 8))))
      (let* ((header (peek))
             (g (ldb (byte 8 56) header))
             (mid (ldb (byte 24 32) header))
             (ra (logand header #xffffffff)))
        (unless (and (>= g 32)
                     (zerop mid)
                     (zerop (ash ra -18)))
          (illegal-instruction))
        (next-octa)
        (set-special vm +r-l+ 0)
        (set-special vm +r-g+ g)
        (set-special vm +r-a+ ra)
        (loop for i from (1- (length *save-specials*)) downto 0
              do (set-special vm (aref *save-specials* i) (next-octa)))
        (loop for k from 255 downto g
              do (set-reg vm k (next-octa)))
        (let ((hole (next-octa)))
          (unless (and (< hole 256) (<= hole g))
            (illegal-instruction))
          (set-special vm +r-l+ hole)
          (loop for k from (1- hole) downto 0
                do (set-reg vm k (next-octa))))
        (if from-stack
            (sync-stack vm)
            (let ((base (+ cursor 8)))
              (unless (and (>= base +stack-segment+)
                           (zerop (mod (- base +stack-segment+) 8)))
                (error 'mmix-fault :reason "UNSAVE image is not on the register stack"))
              (set-hidden-tau vm (floor (- base +stack-segment+) 8)))))))
  vm)

(defun privileged-special-p (n)
  (member n '(8 9 10 11 12 13 14 15 16 17 18 22 7 28 29 30 31)))

(defun k-special-p (n)
  "PUT of these from user space sets k while rK's k bit is set."
  (member n '(8 12 13 14 15 16 17 18)))

(defun b-special-p (n)
  "rN, rO, and rS are never writable."
  (member n '(9 10 11)))

(defun put-rq (vm value)
  "PUT rQ. Bits that came on since the last GET rQ stay set."
  (let* ((cur (special-reg vm +r-q+))
         (sticky (logandc2 cur (vm-rq-gotten vm))))
    (set-special vm +r-q+
                 (logior (logand (u64 value) (lognot sticky)) sticky))))

(defun put-special (vm n value)
  "PUT rules from mmix-doc §43. User mode leaves privileged registers unchanged.
A kernel VM raises b for rN/rO/rS, raises k for the privileged group while
the k bit of rK is set at a nonnegative PC, and writes the bootstrap
registers from a negative PC."
  (cond
    ((and (vm-kernel vm) (b-special-p n))
     (error 'mmix-suppress :bit +rq-b+))
    ((and (vm-kernel vm) (k-special-p n))
     (if (and (logtest (special-reg vm +r-k+) +rq-k+)
              (not (logbitp 63 (vm-pc vm))))
         (error 'mmix-suppress :bit +rq-k+)
         (if (= n +r-q+)
             (put-rq vm value)
             (set-special vm n (u64 value)))))
    ((and (vm-kernel vm)
          (logbitp 63 (vm-pc vm))
          (member n '(7 22 28 29 30 31)))
     (set-special vm n (u64 value)))
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
