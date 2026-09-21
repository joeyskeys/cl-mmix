(in-package #:cl-mmix)

;;; Special-register indices (subset; stubs documented in README)
(defconstant +r-a+ 21)   ; arithmetic status
(defconstant +r-r+ 6)    ; remainder (DIV)
(defconstant +r-j+ 4)    ; return-jump (GO)
(defconstant +r-g+ 19)   ; global threshold (stub)
(defconstant +r-l+ 20)   ; local registers (stub)

(defstruct (vm (:constructor %make-vm))
  (memory   (make-array 0 :element-type '(unsigned-byte 8))
            :type (simple-array (unsigned-byte 8) (*)))
  (registers (make-array 256 :element-type '(unsigned-byte 64) :initial-element 0)
             :type (simple-array (unsigned-byte 64) (256)))
  (special   (make-array 32 :element-type '(unsigned-byte 64) :initial-element 0)
             :type (simple-array (unsigned-byte 64) (32)))
  (pc 0 :type (unsigned-byte 64))
  (halted nil :type boolean)
  (cycles 0 :type unsigned-byte)
  (output (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t)
          :type (vector character)))

(defun make-vm (&key (memory-size #x100000) (pc 0))
  "Create a fresh MMIX VM. MEMORY-SIZE defaults to 1 MiB."
  (unless (and (integerp memory-size) (plusp memory-size))
    (error "memory-size must be a positive integer"))
  (%make-vm
   :memory (make-array memory-size :element-type '(unsigned-byte 8) :initial-element 0)
   :pc (u64 pc)))

(defun reset-vm (vm &key (pc 0) clear-memory clear-registers)
  (setf (vm-pc vm) (u64 pc)
        (vm-halted vm) nil
        (vm-cycles vm) 0
        (fill-pointer (vm-output vm)) 0)
  (when clear-registers
    (fill (vm-registers vm) 0)
    (fill (vm-special vm) 0))
  (when clear-memory
    (fill (vm-memory vm) 0))
  vm)

(defun mem-size (vm) (length (vm-memory vm)))

(defun check-addr (vm addr size)
  (let ((addr (u64 addr)))
    (unless (<= 0 addr (- (mem-size vm) size))
      (error "Memory access out of bounds: addr=#x~X size=~D mem=~D"
             addr size (mem-size vm)))
    addr))

;;; Big-endian accessors matching MMIX

(defun mem-ref-u8 (vm addr)
  (aref (vm-memory vm) (check-addr vm addr 1)))

(defun mem-set-u8 (vm addr value)
  (setf (aref (vm-memory vm) (check-addr vm addr 1)) (u8 value)))

(defun mem-ref-u16 (vm addr)
  (let* ((a (check-addr vm addr 2))
         (m (vm-memory vm)))
    (logior (ash (aref m a) 8) (aref m (1+ a)))))

(defun mem-set-u16 (vm addr value)
  (let* ((a (check-addr vm addr 2))
         (m (vm-memory vm))
         (v (u16 value)))
    (setf (aref m a) (ldb (byte 8 8) v)
          (aref m (1+ a)) (ldb (byte 8 0) v))
    v))

(defun mem-ref-u32 (vm addr)
  (let* ((a (check-addr vm addr 4))
         (m (vm-memory vm)))
    (logior (ash (aref m a) 24)
            (ash (aref m (+ a 1)) 16)
            (ash (aref m (+ a 2)) 8)
            (aref m (+ a 3)))))

(defun mem-set-u32 (vm addr value)
  (let* ((a (check-addr vm addr 4))
         (m (vm-memory vm))
         (v (u32 value)))
    (setf (aref m a)       (ldb (byte 8 24) v)
          (aref m (+ a 1)) (ldb (byte 8 16) v)
          (aref m (+ a 2)) (ldb (byte 8 8) v)
          (aref m (+ a 3)) (ldb (byte 8 0) v))
    v))

(defun mem-ref-u64 (vm addr)
  (let* ((a (check-addr vm addr 8))
         (m (vm-memory vm))
         (hi (logior (ash (aref m a) 24)
                     (ash (aref m (+ a 1)) 16)
                     (ash (aref m (+ a 2)) 8)
                     (aref m (+ a 3))))
         (lo (logior (ash (aref m (+ a 4)) 24)
                     (ash (aref m (+ a 5)) 16)
                     (ash (aref m (+ a 6)) 8)
                     (aref m (+ a 7)))))
    (u64 (logior (ash hi 32) lo))))

(defun mem-set-u64 (vm addr value)
  (let* ((a (check-addr vm addr 8))
         (m (vm-memory vm))
         (v (u64 value)))
    (loop for i from 0 below 8
          for shift from 56 downto 0 by 8
          do (setf (aref m (+ a i)) (ldb (byte 8 shift) v)))
    v))

(defun reg (vm n)
  (aref (vm-registers vm) (u8 n)))

(defun set-reg (vm n value)
  (setf (aref (vm-registers vm) (u8 n)) (u64 value)))

(defun special-reg (vm n)
  (aref (vm-special vm) n))

(defun set-special (vm n value)
  (setf (aref (vm-special vm) n) (u64 value)))
