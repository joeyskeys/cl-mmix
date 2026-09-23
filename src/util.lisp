(in-package #:cl-mmix)

(defconstant +u64-mask+ #xFFFFFFFFFFFFFFFF)
(defconstant +u32-mask+ #xFFFFFFFF)
(defconstant +u16-mask+ #xFFFF)
(defconstant +u8-mask+  #xFF)
(defconstant +i64-min+ (- (ash 1 63)))
(defconstant +i64-max+ (1- (ash 1 63)))

(declaim (inline u64 u32 u16 u8 i64-from-u64))

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

(defun fits-signed-p (value bits)
  "True when unsigned 64-bit VALUE fits in a signed BITS-wide field."
  (let ((s (i64-from-u64 value))
        (lim (ash 1 (1- bits))))
    (<= (- lim) s (1- lim))))

(defun add-u64 (a b)
  "Signed 64-bit sum. Returns (values wrapped overflow-p)."
  (let* ((sum (u64 (+ a b)))
         (sa (logbitp 63 a))
         (sb (logbitp 63 b))
         (ss (logbitp 63 sum)))
    (values sum (and (eq sa sb) (not (eq sa ss))))))

(defun sub-u64 (a b)
  "Signed 64-bit difference A−B. Returns (values wrapped overflow-p)."
  (let* ((diff (u64 (- a b)))
         (sa (logbitp 63 a))
         (sb (logbitp 63 b))
         (sd (logbitp 63 diff)))
    (values diff (and (not (eq sa sb)) (not (eq sa sd))))))

(defun mul-overflow-p (a b)
  "True when the signed product of the two unsigned-64 bit patterns does not fit."
  (let ((p (* (i64-from-u64 a) (i64-from-u64 b))))
    (not (<= +i64-min+ p +i64-max+))))

(defun div-floor-u64 (a b)
  "Signed floor division of two unsigned-64 patterns.
Returns (values quotient remainder condition) where CONDITION is
NIL, :DIV0, or :OVERFLOW. Remainder has the sign of the divisor."
  (let ((sa (i64-from-u64 a))
        (sb (i64-from-u64 b)))
    (cond ((zerop sb) (values 0 a :div0))
          ((and (= sa +i64-min+) (= sb -1))
           (values a 0 :overflow))
          (t (multiple-value-bind (q r) (floor sa sb)
               (values (u64 q) (u64 r) nil))))))

(defun divu-u64 (high low divisor)
  "Unsigned division of the 128-bit value HIGH·2^64+LOW.
Returns (values quotient remainder condition). On failure the
architectural results are quotient=HIGH and remainder=LOW."
  (cond ((or (zerop divisor) (>= high divisor))
         (values high low :div0))
        (t (multiple-value-bind (q r)
               (floor (+ (ash high 64) low) divisor)
             (values (u64 q) (u64 r) nil)))))

(defun ashu64 (value count)
  "Logical left shift of 64-bit VALUE by COUNT."
  (u64 (ash (u64 value) count)))

(defun shru64 (value count)
  "Logical right shift of 64-bit VALUE by COUNT."
  (u64 (ash (u64 value) (- count))))

(defun shar64 (value count)
  "Arithmetic right shift of 64-bit VALUE by COUNT."
  (u64 (ash (i64-from-u64 value) (- count))))

(defun sl-signed (y count)
  "SL result. Returns (values wrapped overflow-p). A count ≥ 64 yields 0
and overflows unless Y is 0."
  (cond ((>= count 64)
         (values 0 (not (zerop y))))
        (t (let ((math (ash (i64-from-u64 y) count)))
             (values (u64 math)
                     (not (<= +i64-min+ math +i64-max+)))))))

(defun sr-signed (y count)
  "SR result. A count ≥ 64 yields 0 or −1 according to the sign of Y."
  (cond ((>= count 64)
         (if (logbitp 63 y) (u64 -1) 0))
        (t (shar64 y count))))

(defun dif-slices (y z width)
  "Saturated unsigned difference of WIDTH-bit slices (BDIF/WDIF/TDIF/ODIF)."
  (let ((acc 0))
    (loop for shift from 0 below 64 by width
          for yb = (ldb (byte width shift) y)
          for zb = (ldb (byte width shift) z)
          do (setf acc (logior acc
                               (ash (if (>= yb zb) (- yb zb) 0) shift))))
    acc))

(defun mor-octa (y z &key xor)
  "8×8 boolean matrix product. Byte i of the result ORs (or XORs) the
bytes of Z selected by the bits of byte i of Y. The leftmost bit of a
byte selects the leftmost byte."
  (let ((acc 0))
    (loop for i from 0 below 8
          for yb = (ldb (byte 8 (- 56 (* i 8))) y)
          for rb = 0
          do (loop for j from 0 below 8
                   when (logbitp (- 7 j) yb)
                     do (let ((zb (ldb (byte 8 (- 56 (* j 8))) z)))
                          (setf rb (if xor (logxor rb zb) (logior rb zb)))))
             (setf acc (logior acc (ash rb (- 56 (* i 8))))))
    acc))
