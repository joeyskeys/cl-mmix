(in-package #:cl-mmix)

(defun dump-registers (vm &key (stream *standard-output*) (nonzero-only t))
  (dotimes (i 256)
    (let ((v (reg vm i)))
      (when (or (not nonzero-only) (not (zerop v)))
        (format stream "$~D = #x~16,'0X (~D)~%" i v v))))
  (format stream "PC=#x~X  cycles=~D  halted=~A~%"
          (vm-pc vm) (vm-cycles vm) (vm-halted vm))
  (unless (zerop (length (vm-output vm)))
    (format stream "output: ~S~%" (coerce (vm-output vm) 'string)))
  vm)

(defun dump-memory (vm addr &optional (nbytes 64) &key (stream *standard-output*))
  (let* ((addr (u64 addr))
         (end (min (+ addr nbytes) (mem-size vm))))
    (loop for a from addr below end by 16 do
      (format stream "~8,'0X:" a)
      (loop for i from 0 below 16
            for aa = (+ a i)
            do (if (< aa end)
                   (format stream " ~2,'0X" (mem-ref-u8 vm aa))
                   (format stream "   ")))
      (terpri stream)))
  vm)

;;; ---- Demos ---------------------------------------------------------------

(defun demo-sum-1-to-n (&optional (n 10))
  "Sum 1..N in the VM. Result in $3. Returns (values sum vm)."
  (let ((vm (make-vm))
        (prog
          `(program
            (:org #x100)
            (setl $1 ,n)     ; n
            (setl $2 0)      ; i = 0
            (setl $3 0)      ; sum = 0
            (label :loop)
            (cmp  $4 $2 $1)  ; $4 = cmp(i,n): -1 if i<n
            (bnn  $4 :done)  ; branch if i >= n
            (addi $2 $2 1)
            (add  $3 $3 $2)
            (jmp  :loop)
            (label :done)
            (trap 0 0 0))))
    (assemble-into vm prog)
    (run-vm vm)
    (values (reg vm 3) vm)))

(defun demo-factorial (&optional (n 10))
  "Compute N! in the VM. Result in $3. Returns (values fact vm)."
  (let ((vm (make-vm))
        (prog
          `(program
            (:org #x100)
            (setl $1 ,n)      ; n
            (setl $3 1)       ; result = 1
            (label :loop)
            (bz   $1 :done)   ; while n != 0
            (mul  $3 $3 $1)
            (subi $1 $1 1)
            (jmp  :loop)
            (label :done)
            (trap 0 0 0))))
    (assemble-into vm prog)
    (run-vm vm)
    (values (reg vm 3) vm)))

(defun demo-putchar-hello ()
  "Write HELLO via TRAP 0,1,Z putchar convention."
  (let ((vm (make-vm))
        (prog
          '(program
            (:org #x100)
            (setl $1 #x48) (trap 0 1 1) ; H
            (setl $1 #x45) (trap 0 1 1) ; E
            (setl $1 #x4C) (trap 0 1 1) ; L
            (setl $1 #x4C) (trap 0 1 1) ; L
            (setl $1 #x4F) (trap 0 1 1) ; O
            (trap 0 0 0))))
    (assemble-into vm prog)
    (run-vm vm)
    (values (coerce (vm-output vm) 'string) vm)))
