(in-package #:cl-mmix)

(defconstant +u64-mask+ #xFFFFFFFFFFFFFFFF)
(defconstant +u32-mask+ #xFFFFFFFF)
(defconstant +u16-mask+ #xFFFF)
(defconstant +u8-mask+  #xFF)

(declaim (inline u64 u32 u16 u8 i64-from-u64 sign-extend16 sign-extend24))

(defun u64 (n)
  "Truncate N to an unsigned 64-bit integer."
  (logand (if (integerp n) n (truncate n)) +u64-mask+))

(defun u32 (n) (logand n +u32-mask+))
(defun u16 (n) (logand n +u16-mask+))
(defun u8  (n) (logand n +u8-mask+))

(defun i64-from-u64 (u)
  "Interpret unsigned 64-bit U as signed two's complement."
  (let ((u (u64 u)))
    (if (logbitp 63 u)
        (- u (ash 1 64))
        u)))

(defun sign-extend16 (n)
  (let ((n (logand n #xFFFF)))
    (if (logbitp 15 n) (- n #x10000) n)))

(defun sign-extend24 (n)
  (let ((n (logand n #xFFFFFF)))
    (if (logbitp 23 n) (- n #x1000000) n)))

(defun ashu64 (value count)
  "Logical left shift of 64-bit VALUE by COUNT (0..63 meaningful)."
  (u64 (ash (u64 value) count)))

(defun shru64 (value count)
  "Logical right shift of 64-bit VALUE by COUNT."
  (u64 (ash (u64 value) (- count))))

(defun shar64 (value count)
  "Arithmetic (signed) right shift of 64-bit VALUE by COUNT."
  (u64 (ash (i64-from-u64 value) (- count))))
