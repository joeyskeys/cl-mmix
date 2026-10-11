(in-package #:cl-mmix)

(defun octa-to-double (n)
  "Binary64 bit pattern N as an SBCL double. Used by the session dump."
  (let ((hi (ldb (byte 32 32) (u64 n)))
        (lo (ldb (byte 32 0) (u64 n))))
    (when (logbitp 31 hi)
      (decf hi #x100000000))
    (sb-kernel:make-double-float hi lo)))

(defun double-to-octa (d)
  "Bits of a Lisp real viewed as binary64."
  (let* ((d (coerce d 'double-float))
         (hi (sb-kernel:double-float-high-bits d))
         (lo (sb-kernel:double-float-low-bits d)))
    (when (minusp hi)
      (incf hi #x100000000))
    (logior (ash (logand hi #xffffffff) 32)
            (logand lo #xffffffff))))

(defun octa-to-chars (n)
  "Eight big-endian characters. A non-graphic byte is #\\. "
  (let ((s (make-string 8))
        (n (u64 n)))
    (loop for i from 0 below 8
          for b = (ldb (byte 8 (* 8 (- 7 i))) n)
          for c = (code-char b)
          do (setf (char s i) (if (graphic-char-p c) c #\.)))
    s))

(defun chars-to-octa (s)
  "Pack up to eight characters, high byte first."
  (let ((n 0))
    (loop for i from 0 below (min 8 (length s))
          do (setf n (logior n (ash (char-code (char s i)) (* 8 (- 7 i))))))
    n))

(defun dump-registers (vm &key (stream *standard-output*) (nonzero-only t)
                            float string)
  (let ((l (reg-l vm))
        (g (reg-g vm)))
    (dotimes (i 256)
      (let ((v (reg vm i)))
        (when (or (not nonzero-only) (not (zerop v)))
          (format stream "$~D = #x~16,'0X (~D)~@[ ~A~]~@[ ~S~] ~A~%"
                  i v (i64-from-u64 v)
                  (and string (octa-to-chars v))
                  (and float (octa-to-double v))
                  (cond ((< i l) "local")
                        ((< i g) "marginal")
                        (t "global"))))))
    (format stream "PC=#x~X  cycles=~D  mems=~D  oops=~D  mem-cost=~D  halted=~A~%"
            (vm-pc vm) (vm-cycles vm) (vm-mems vm)
            (vm-oops vm) (vm-mem-cost vm) (vm-halted vm))
    (format stream "rL=~D  rG=~D  rJ=#x~X  rA=#x~X  rR=#x~X  rH=#x~X~%"
            l g
            (special-reg vm +r-j+)
            (special-reg vm +r-a+)
            (special-reg vm +r-r+)
            (special-reg vm +r-h+))
    (dolist (pair `(("rN" ,+r-n+) ("rI" ,+r-i+) ("rU" ,+r-u+)))
      (let ((v (special-reg vm (second pair))))
        (unless (zerop v)
          (format stream "~A=#x~X~%" (first pair) v))))
    (when (vm-fault vm)
      (format stream "fault: ~A~%" (vm-fault vm)))
    (when (vm-break vm)
      (format stream "break: ~S~%" (vm-break vm)))
    (when (vm-exit-code vm)
      (format stream "exit: ~D~%" (i64-from-u64 (vm-exit-code vm))))
    (unless (zerop (length (vm-output vm)))
      (format stream "output: ~S~%" (coerce (vm-output vm) 'string))))
  vm)

(defun dump-memory (vm addr &optional (nbytes 64) &key (stream *standard-output*))
  (let ((addr (u64 addr)))
    (loop for a from addr below (+ addr nbytes) by 16 do
      (format stream "~16,'0X:" a)
      (loop for i from 0 below 16
            for aa = (+ a i)
            do (if (< aa (+ addr nbytes))
                   (format stream " ~2,'0X" (mem-ref-u8 vm aa :internal t))
                   (format stream "   ")))
      (terpri stream)))
  vm)

(defun demo-sum-1-to-n (&optional (n 10))
  "Sum 1..N. Result in $3. Returns (values sum vm)."
  (let ((vm (make-vm))
        (prog
          `(program
            (:org #x100)
            (setl $1 ,n)
            (setl $2 0)
            (setl $3 0)
            (label :loop)
            (cmp  $4 $2 $1)
            (bnn  $4 :done)
            (addi $2 $2 1)
            (add  $3 $3 $2)
            (jmp  :loop)
            (label :done)
            (trap 0 0 0))))
    (assemble-into vm prog)
    (run-vm vm)
    (values (reg vm 3) vm)))

(defun demo-factorial (&optional (n 10))
  "Compute N! with a loop. Result in $3. Returns (values fact vm)."
  (let ((vm (make-vm))
        (prog
          `(program
            (:org #x100)
            (setl $1 ,n)
            (setl $3 1)
            (label :loop)
            (bz   $1 :done)
            (mul  $3 $3 $1)
            (subi $1 $1 1)
            (jmp  :loop)
            (label :done)
            (trap 0 0 0))))
    (assemble-into vm prog)
    (run-vm vm)
    (values (reg vm 3) vm)))

(defun demo-recursive-factorial (&optional (n 10))
  "Compute N! with PUSHJ/POP. Result in $0. Returns (values fact vm)."
  (let ((vm (make-vm))
        (prog
          `(program
            (:org #x100)
            (setl $1 ,n)
            (pushj $0 :fact)
            (trap 0 0 0)
            (label :fact)
            (bz $0 :base)
            (get $1 :rj)
            (setl $4 1)
            (sub $3 $0 $4)
            (pushj $2 :fact)
            (mul $0 $0 $2)
            (put :rj $1)
            (pop 1 0)
            (label :base)
            (setl $0 1)
            (pop 1 0))))
    (assemble-into vm prog)
    (run-vm vm)
    (values (reg vm 0) vm)))

(defun demo-putchar-hello ()
  "Write HELLO with TRAP 0,Fputs,StdOut. The string lives in Data_Segment.
Returns (values output-string vm)."
  (let ((vm (make-vm))
        (prog
          '(program
            (:org #x100)
            (seth $255 #x2000)
            (trap 0 7 1)
            (trap 0 0 0)
            (:org #x2000000000000000)
            (:zstring "HELLO"))))
    (assemble-into vm prog)
    (run-vm vm)
    (values (coerce (vm-output vm) 'string) vm)))

(defun demo-hello ()
  "Same as DEMO-PUTCHAR-HELLO."
  (demo-putchar-hello))
