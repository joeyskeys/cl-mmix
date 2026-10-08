(in-package #:cl-mmix)

;;; Binary64 and binary32 packing. The fraction that enters fpack sits in
;;; [2^54, 2^55], so the low two bits are the round bit and the sticky bit.
;;; Tininess is decided after rounding. fpack raises U for a tiny result and
;;; X for an inexact one; the caller drops exact U when that enable is off.

(defun round-adjust (o s r)
  "Add the rounding increment for mode R. Sets X when the low two bits are live."
  (when (logtest o 3)
    (fp-raise +x-bit+))
  (case r
    (#.+round-down+ (if (char= s #\-) (u64 (+ o 3)) (u64 o)))
    (#.+round-up+ (if (char/= s #\-) (u64 (+ o 3)) (u64 o)))
    (#.+round-off+ (u64 o))
    (#.+round-near+ (u64 (+ o (if (logtest o 4) 2 1))))
    (t (error "bad rounding mode ~D" r))))

(defun fpack (f e s r)
  "Pack ±2^(E−1076)*F. F should lie in [2^54, 2^55]."
  (let ((o 0))
    (cond ((> e #x7fd)
           (setf e #x7ff o 0))
          ((< e 0)
           (if (< e -54)
               (setf o 1)
               (let ((shifted (fp-shr f (- e))))
                 (setf o shifted)
                 (unless (= (fp-shl shifted (- e)) (u64 f))
                   (setf o (logior o 1)))))
           (setf e 0))
          (t (setf o (u64 f))))
    (setf o (fp-shr (round-adjust o s r) 2))
    (setf o (add-hi o (ash e 20)))
    (cond ((>= (fp-hi o) #x7ff00000)
           (fp-raise (logior +o-bit+ +x-bit+)))
          ((< (fp-hi o) #x100000)
           (fp-raise +u-bit+)))
    (apply-sign o s)))

(defun sfpack (f e s r)
  "Pack a binary32 value from the same fraction convention as fpack."
  (let ((o 0))
    (cond ((> e #x47d)
           (setf e #x47f o 0))
          (t
           (setf o (fp-hi (fp-shl f 3)))
           (when (logtest (fp-lo f) #x1fffffff)
             (setf o (logior o 1)))
           (when (< e #x380)
             (if (< e (- #x380 25))
                 (setf o 1)
                 (let* ((shift (- #x380 e))
                        (o0 o))
                   (setf o (ash o (- shift)))
                   (when (/= (logand (ash o shift) #xffffffff) o0)
                     (setf o (logior o 1)))))
             (setf e #x380))))
    (when (logtest o 3)
      (fp-raise +x-bit+))
    (setf o (case r
              (#.+round-down+ (if (char= s #\-) (+ o 3) o))
              (#.+round-up+ (if (char/= s #\-) (+ o 3) o))
              (#.+round-off+ o)
              (#.+round-near+ (+ o (if (logtest o 4) 2 1)))
              (t (error "bad rounding mode ~D" r))))
    (setf o (logand o #xffffffff))
    (setf o (ash o -2))
    (setf o (logand (+ o (ash (- e #x380) 23)) #xffffffff))
    (cond ((>= o #x7f800000)
           (fp-raise (logior +o-bit+ +x-bit+)))
          ((< o #x800000)
           (fp-raise +u-bit+)))
    (if (char= s #\-) (logior o #x80000000) o)))

(defun funpack (x)
  "Split a binary64 value. Returns (values type fraction exponent sign).
Clears *fp-exceptions*. TYPE is zero, number, infinity, or NaN."
  (setf *fp-exceptions* 0)
  (setf x (u64 x))
  (let* ((s (if (logbitp 63 x) #\- #\+))
         (f (logand (fp-shl x 2) #x3fffffffffffff))
         (ee (logand (ash x -52) #x7ff)))
    (cond ((plusp ee)
           (setf f (logior f (ash #x400000 32)))
           (values (cond ((< ee #x7ff) +ft-num+)
                         ((and (= (fp-hi f) #x400000) (zerop (fp-lo f))) +ft-inf+)
                         (t +ft-nan+))
                   f (1- ee) s))
          ((and (zerop (fp-lo x)) (zerop (fp-hi f)))
           (values +ft-zro+ f +zero-exponent+ s))
          (t
           (loop do (decf ee)
                    (setf f (fp-shl f 1))
                 until (logtest (fp-hi f) #x400000))
           (values +ft-num+ f ee s)))))

(defun sfunpack (x)
  "Split a binary32 tetra into the binary64 fraction convention."
  (setf *fp-exceptions* 0)
  (setf x (logand x #xffffffff))
  (let* ((s (if (logtest x #x80000000) #\- #\+))
         (f (logior (ash (logand (ash x -1) #x3fffff) 32)
                    (logand (ash x 31) #xffffffff)))
         (ee (logand (ash x -23) #xff)))
    (cond ((plusp ee)
           (setf f (logior f (ash #x400000 32)))
           (values (cond ((< ee #xff) +ft-num+)
                         ((= (logand x #x7fffffff) #x7f800000) +ft-inf+)
                         (t +ft-nan+))
                   f (+ ee #x380 -1) s))
          ((zerop (logand x #x7fffffff))
           (values +ft-zro+ f +zero-exponent+ s))
          (t
           (loop do (decf ee)
                    (setf f (fp-shl f 1))
                 until (logtest (fp-hi f) #x400000))
           (values +ft-num+ f (+ ee #x380) s)))))

(defun load-sf (z)
  "Widen a binary32 tetra to binary64."
  (multiple-value-bind (ty f e s) (sfunpack z)
    (case ty
      (#.+ft-num+ (fpack f e s +round-off+))
      (#.+ft-inf+ (apply-sign +fp-inf+ s))
      (#.+ft-nan+ (apply-sign (logior (fp-shr f 2) (ash #x7ff00000 32)) s))
      (t (apply-sign 0 s)))))

(defun store-sf (x)
  "Narrow a binary64 octa to binary32 using *cur-round*."
  (multiple-value-bind (ty f e s) (funpack x)
    (case ty
      (#.+ft-num+ (sfpack f e s *cur-round*))
      (#.+ft-inf+ (if (char= s #\-) #xff800000 #x7f800000))
      (#.+ft-nan+
       (unless (logtest (fp-hi f) #x200000)
         (setf f (logior f (ash #x200000 32)))
         (fp-raise +i-bit+))
       (let ((z (logior #x7f800000
                        (logand (ash (fp-hi f) 1) #xffffffff)
                        (ash (fp-lo f) -31))))
         (if (char= s #\-) (logior z #x80000000) (logand z #xffffffff))))
      (t (if (char= s #\-) #x80000000 0)))))
