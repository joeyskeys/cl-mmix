(in-package #:cl-mmix)

;;; 64-bit helpers for the IEEE port. MMIXware keeps an octa as two
;;; tetrabytes; a masked Lisp integer has the same shift, add, and
;;; multiply results, including bits that fall off the top.

(defvar *fp-exceptions* 0
  "Simulator exception word. Bits match MMIXware: X at bit 8 through W at bit 13.")

(defvar *cur-round* 4
  "Rounding mode for operations that read rA. 1 off, 2 up, 3 down, 4 near.")

(defconstant +round-off+ 1)
(defconstant +round-up+ 2)
(defconstant +round-down+ 3)
(defconstant +round-near+ 4)

(defconstant +x-bit+ (ash 1 8))
(defconstant +z-bit+ (ash 1 9))
(defconstant +u-bit+ (ash 1 10))
(defconstant +o-bit+ (ash 1 11))
(defconstant +i-bit+ (ash 1 12))
(defconstant +w-bit+ (ash 1 13))
(defconstant +e-bit+ (ash 1 18))

(defconstant +fp-sign+ #x8000000000000000)
(defconstant +fp-quiet+ #x0008000000000000)
(defconstant +fp-inf+ #x7ff0000000000000)
(defconstant +standard-nan+ #x7ff8000000000000)
(defconstant +zero-exponent+ -1000)

(defconstant +ft-zro+ 0)
(defconstant +ft-num+ 1)
(defconstant +ft-inf+ 2)
(defconstant +ft-nan+ 3)

(defun fp-raise (bit)
  (setf *fp-exceptions* (logior *fp-exceptions* bit)))

(defun fp-hi (o)
  (ash (u64 o) -32))

(defun fp-lo (o)
  (logand (u64 o) #xffffffff))

(defun fp-shl (y s)
  "Logical left shift by S, with S between 0 and 64 inclusive."
  (cond ((<= s 0) (u64 y))
        ((>= s 64) 0)
        (t (u64 (ash (u64 y) s)))))

(defun fp-shr (y s)
  "Logical right shift by S, with S between 0 and 64 inclusive."
  (cond ((<= s 0) (u64 y))
        ((>= s 64) 0)
        (t (ash (u64 y) (- s)))))

(defun fp-inc-lo (o)
  "Increment the low tetrabyte and do not carry into the high one."
  (logior (ash (fp-hi o) 32)
          (logand (1+ (fp-lo o)) #xffffffff)))

(defun add-hi (o delta)
  "Add DELTA to the high tetrabyte, wrapping inside those 32 bits."
  (logior (ash (logand (+ (fp-hi o) delta) #xffffffff) 32)
          (fp-lo o)))

(defun apply-sign (x s)
  (if (char= s #\-)
      (logior (u64 x) +fp-sign+)
      (u64 x)))

(defun sign-product (ys zs)
  "Character sum MMIXware uses for a product sign. Two minuses yield '+'."
  (code-char (- (+ (char-code ys) (char-code zs)) (char-code #\+))))

(defun quietp (x)
  (logtest (u64 x) +fp-quiet+))

(defun quieten (x)
  "Set the quiet bit. A signaling NaN also raises I."
  (if (quietp x)
      (u64 x)
      (progn
        (fp-raise +i-bit+)
        (logior (u64 x) +fp-quiet+))))

(defun fp-mul128 (a b)
  "Unsigned product. Returns (values low-64 high-64)."
  (let ((p (* (u64 a) (u64 b))))
    (values (logand p +u64-mask+) (ash p -64))))

(defun fp-div128 (x y z)
  "Divide 2^64*X+Y by Z. Returns (values quotient remainder).
When X >= Z the quotient is X and the remainder is Y."
  (setf x (u64 x) y (u64 y) z (u64 z))
  (if (>= x z)
      (values x y)
      (floor (+ (ash x 64) y) z)))
