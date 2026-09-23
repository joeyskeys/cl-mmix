(in-package #:cl-mmix)

(defun dump-registers (vm &key (stream *standard-output*) (nonzero-only t))
  (let ((l (reg-l vm))
        (g (reg-g vm)))
    (dotimes (i 256)
      (let ((v (reg vm i)))
        (when (or (not nonzero-only) (not (zerop v)))
          (format stream "$~D = #x~16,'0X (~D) ~A~%"
                  i v (i64-from-u64 v)
                  (cond ((< i l) "local")
                        ((< i g) "marginal")
                        (t "global"))))))
    (format stream "PC=#x~X  cycles=~D  mems=~D  halted=~A~%"
            (vm-pc vm) (vm-cycles vm) (vm-mems vm) (vm-halted vm))
    (format stream "rL=~D  rG=~D  rJ=#x~X  rA=#x~X  rR=#x~X  rH=#x~X~%"
            l g
            (special-reg vm +r-j+)
            (special-reg vm +r-a+)
            (special-reg vm +r-r+)
            (special-reg vm +r-h+))
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
