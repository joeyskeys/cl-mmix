(in-package #:cl-mmix/tests)

;;; Minimal self-contained test runner (no FiveAM / Quicklisp required).

(defparameter *pass* 0)
(defparameter *fail* 0)
(defparameter *errors* nil)

(defmacro check (name form expected)
  `(let* ((signaled nil)
          (got (handler-case ,form
                 (error (e)
                   (setf signaled t)
                   e))))
     (cond
       (signaled
        (incf *fail*)
        (push (list ',name :error got) *errors*)
        (format t "FAIL  ~A: signaled ~A~%" ',name got))
       ((equal got ,expected)
        (incf *pass*)
        (format t "ok    ~A~%" ',name))
       (t
        (incf *fail*)
        (push (list ',name got ,expected) *errors*)
        (format t "FAIL  ~A: got ~S expected ~S~%"
                ',name got ,expected)))))

(defun run-tests ()
  (setf *pass* 0 *fail* 0 *errors* nil)
  (let ((cl-mmix::*echo-putchar* nil))
  (format t "~%=== cl-mmix tests ===~%")

  ;; Decode
  (check decode-add
         (let ((i (cl-mmix::decode (cl-mmix::encode :add 1 2 3))))
           (list (cl-mmix::inst-op i) (cl-mmix::inst-x i)
                 (cl-mmix::inst-y i) (cl-mmix::inst-z i)))
         (list #x20 1 2 3))

  (check decode-setl
         (let ((i (cl-mmix::decode (cl-mmix::encode :setl 5 #x12 #x34))))
           (list (cl-mmix::op-name (cl-mmix::inst-op i))
                 (cl-mmix::inst-x i)
                 (cl-mmix::inst-yz i)))
         (list :setl 5 #x1234))

  ;; Memory endianness
  (check mem-be-u64
         (let ((vm (make-vm :memory-size 64)))
           (mem-set-u64 vm 0 #x0102030405060708)
           (list (mem-ref-u8 vm 0) (mem-ref-u8 vm 7) (mem-ref-u64 vm 0)))
         (list 1 8 #x0102030405060708))

  ;; ADD
  (check op-add
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 10)
               (setl $2 32)
               (add $3 $1 $2)
               (trap 0 0 0)))
           (run-vm vm)
           (reg vm 3))
         42)

  ;; SUB / AND / OR / XOR
  (check op-logic
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 #xFF)
               (setl $2 #x0F)
               (and $3 $1 $2)
               (or  $4 $1 $2)
               (xor $5 $1 $2)
               (subi $6 $1 1)
               (trap 0 0 0)))
           (run-vm vm)
           (list (reg vm 3) (reg vm 4) (reg vm 5) (reg vm 6)))
         (list #x0F #xFF #xF0 #xFE))

  ;; Shifts
  (check op-shift
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 1)
               (sli $2 $1 3)
               (srui $3 $2 1)
               (trap 0 0 0)))
           (run-vm vm)
           (list (reg vm 2) (reg vm 3)))
         (list 8 4))

  ;; CMP
  (check op-cmp
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 5)
               (setl $2 7)
               (cmp $3 $1 $2)
               (cmp $4 $2 $1)
               (cmp $5 $1 $1)
               (trap 0 0 0)))
           (run-vm vm)
           (list (cl-mmix::i64-from-u64 (reg vm 3))
                 (cl-mmix::i64-from-u64 (reg vm 4))
                 (reg vm 5)))
         (list -1 1 0))

  ;; Load/store
  (check op-ld-st
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 #xAB)
               (setl $2 #x200)
               (stb $1 $2 $0)   ; mem[0x200] = $1
               (ldbu $3 $2 $0)
               (setl $4 #x1234)
               (setl $5 #x210)
               (stw $4 $5 $0)
               (ldwu $6 $5 $0)
               (trap 0 0 0)))
           (run-vm vm)
           (list (reg vm 3) (reg vm 6) (mem-ref-u8 vm #x200)))
         (list #xAB #x1234 #xAB))

  ;; Branch + sum demo
  (check e2e-sum
         (multiple-value-bind (sum vm) (demo-sum-1-to-n 10)
           (declare (ignore vm))
           sum)
         55)

  (check e2e-fact
         (multiple-value-bind (f vm) (demo-factorial 10)
           (declare (ignore vm))
           f)
         3628800)

  (check e2e-hello
         (multiple-value-bind (s vm) (cl-mmix::demo-putchar-hello)
           (declare (ignore vm))
           s)
         "HELLO")

  ;; max-cycles safeguard
  (check max-cycles
         (handler-case
             (let ((vm (make-vm)))
               (assemble-into vm
                 '(program (:org 0)
                   (label :L)
                   (jmp :L)))
               (run-vm vm :max-cycles 50)
               :no-error)
           (error () :error))
         :error)

  (format t "~%Results: ~D passed, ~D failed~%" *pass* *fail*)
  (when *errors*
    (format t "Failures:~%")
    (dolist (e *errors*) (format t "  ~S~%" e)))
  (zerop *fail*)))
