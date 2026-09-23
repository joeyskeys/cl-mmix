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

(defun run-forms (forms)
  "Assemble FORMS at address 0, append a halt, and run. Signals if the VM faults."
  (let ((vm (make-vm)))
    (assemble-into vm (list* 'program '(:org 0)
                             (append forms '((trap 0 0 0)))))
    (run-vm vm)
    (when (vm-fault vm)
      (error "unexpected fault: ~A" (vm-fault vm)))
    (unless (vm-halted vm)
      (error "VM stopped without halting at PC=#x~X" (vm-pc vm)))
    vm))

(defun mmo-bytes (bytes)
  (coerce bytes '(vector (unsigned-byte 8))))

(defun mmo-setl-trap-image ()
  '(#x98 #x09 #x01 #x01
    #x00 #x00 #x00 #x00
    #x98 #x01 #x00 #x02
    #x00 #x00 #x00 #x00
    #x00 #x00 #x01 #x00
    #xE3 #x03 #x00 #x2A
    #x00 #x00 #x00 #x00
    #x98 #x0A #x00 #xFF
    #x00 #x00 #x00 #x00
    #x00 #x00 #x00 #x00))

(defun mmo-double-content ()
  '(#x98 #x09 #x01 #x01
    #x00 #x00 #x00 #x00
    #x98 #x01 #x00 #x02
    #x00 #x00 #x00 #x00
    #x00 #x00 #x01 #x00
    #xE3 #x03 #x00 #x2A
    #x98 #x01 #x00 #x02
    #x00 #x00 #x00 #x00
    #x00 #x00 #x01 #x00
    #xE3 #x03 #x00 #x2A
    #x98 #x0A #x00 #xFF
    #x00 #x00 #x00 #x00
    #x00 #x00 #x00 #x00))

(defun mmo-fixo-image ()
  '(#x98 #x09 #x01 #x01
    #x00 #x00 #x00 #x00
    #x98 #x01 #x00 #x01
    #x00 #x00 #x01 #x00
    #x98 #x03 #x00 #x01
    #x00 #x00 #x02 #x00
    #x98 #x0A #x00 #xFF
    #x00 #x00 #x00 #x00
    #x00 #x00 #x00 #x00))

(defun mmo-with-main ()
  (append (mmo-setl-trap-image)
          '(#x98 #x0B #x00 #x00
            #x20 #x4D #x20 #x61
            #x20 #x69 #x02 #x6E
            #x01 #x00 #x81 #x00
            #x98 #x0C #x00 #x00)))

(defun mmo-data-loc-image ()
  ;; lop_loc with Y=#x20 (Data_Segment) and a tetra offset of #x100.
  '(#x98 #x09 #x01 #x01
    #x00 #x00 #x00 #x00
    #x98 #x01 #x20 #x01
    #x00 #x00 #x01 #x00
    #xAA #xBB #xCC #xDD))

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

  ;; --- opcode map (forward vs backward branches) ---
  (check op-bytes
         (list (cl-mmix::op-byte :bnz) (cl-mmix::op-byte :bnb)
               (cl-mmix::op-byte :pbn) (cl-mmix::op-byte :jmpb)
               (cl-mmix::op-byte :getab) (cl-mmix::op-name #x41)
               (cl-mmix::op-name #x4A))
         (list #x4A #x41 #x50 #xF1 #xF5 :bnb :bnz))

  (check branch-encoding
         (multiple-value-bind (segs)
             (cl-mmix::assemble
              '(program (:org 0)
                (label :a)
                (setl $1 1)
                (jmp :a)
                (bz $1 :t)
                (setl $2 0)
                (label :t)
                (trap 0 0 0)))
           (let ((b (coerce (cdr (first segs)) 'list)))
             (list (subseq b 4 8) (subseq b 8 12))))
         (list '(#xF1 #xFF #xFF #xFF) '(#x42 #x01 #x00 #x02)))

  ;; --- arithmetic, shifts, compare ---
  (check sl-overflow
         (let ((vm (run-forms '((setl $1 1) (sli $2 $1 64)))))
           (list (reg vm 2) (special-reg vm +r-a+)))
         (list 0 #x40))

  (check sl-zero-no-v
         (let ((vm (run-forms '((sli $1 $0 64)))))
           (list (reg vm 1) (special-reg vm +r-a+)))
         (list 0 0))

  (check sru-large
         (let ((vm (run-forms '((setl $1 1) (neg $1 0 $1) (srui $2 $1 64)))))
           (list (reg vm 2) (special-reg vm +r-a+)))
         (list 0 0))

  (check sr-sign-fill
         (let ((vm (run-forms '((setl $1 1) (neg $1 0 $1) (sri $2 $1 64)))))
           (list (cl-mmix::i64-from-u64 (reg vm 2)) (special-reg vm +r-a+)))
         (list -1 0))

  (check add-overflow
         (let ((vm (run-forms '((seth $1 #x7fff)
                                (ormh $1 #xffff)
                                (orml $1 #xffff)
                                (orl $1 #xffff)
                                (addi $2 $1 1)))))
           (list (reg vm 2) (special-reg vm +r-a+) (vm-fault vm)))
         (list #x8000000000000000 #x40 nil))

  (check div-floor
         (let ((vm (run-forms '((setl $2 5)
                                (neg $1 0 $2)
                                (setl $3 2)
                                (div $4 $1 $3)
                                (get $5 rr)))))
           (list (cl-mmix::i64-from-u64 (reg vm 4)) (reg vm 5)))
         (list -3 1))

  (check div0
         (let ((vm (run-forms '((setl $1 9) (div $2 $1 $0) (get $3 rr)))))
           (list (reg vm 2) (reg vm 3) (special-reg vm +r-a+)))
         (list 0 9 #x80))

  (check div-minint
         (let ((vm (run-forms '((seth $1 #x8000)
                                (setl $2 1)
                                (neg $2 0 $2)
                                (div $3 $1 $2)
                                (get $4 rr)))))
           (list (reg vm 3) (reg vm 4) (special-reg vm +r-a+)))
         (list #x8000000000000000 0 #x40))

  (check divu-and-mulu
         (let ((vm (run-forms '((setl $1 100)
                                (setl $2 7)
                                (divu $3 $1 $2)
                                (get $4 rr)
                                (seth $5 #xffff)
                                (ormh $5 #xffff)
                                (orml $5 #xffff)
                                (orl $5 #xffff)
                                (setl $6 2)
                                (mulu $7 $5 $6)
                                (get $8 rh)))))
           (list (reg vm 3) (reg vm 4) (reg vm 7) (reg vm 8)))
         (list 14 2 #xfffffffffffffffe 1))

  (check scaled-add-and-lda
         (let ((vm (run-forms '((setl $1 3)
                                (setl $2 1)
                                (2addu $3 $1 $2)
                                (16addu $4 $1 $0)
                                (lda $5 $1 $2)
                                (ldai $6 $0 5)))))
           (list (reg vm 3) (reg vm 4) (reg vm 5) (reg vm 6)))
         (list 7 48 4 5))

  ;; --- register window ---
  (check marginal-widen
         (let ((vm (make-vm)))
           (let ((before (reg vm 5)))
             (set-reg vm 5 9)
             (list before (special-reg vm +r-l+) (reg vm 3) (reg vm 5))))
         (list 0 6 0 9))

  (check put-rl-decreases
         (let ((vm (make-vm)))
           (set-reg vm 5 9)
           (assemble-into vm
             '(program (:org 0) (puti rl 3) (puti rl 10) (trap 0 0 0)))
           (run-vm vm)
           (special-reg vm +r-l+))
         3)

  (check put-rg-and-ra
         (let ((vm (make-vm)))
           (set-reg vm 40 7)
           (assemble-into vm
             '(program (:org 0) (puti rg 32) (trap 0 0 0)))
           (run-vm vm)
           (set-reg vm 32 99)
           (assemble-into vm
             '(program (:org 0)
               (puti rg 40)
               (setl $1 #xffff)
               (orml $1 7)
               (put ra $1)
               (setl $2 5)
               (put rc $2)
               (trap 0 0 0)))
           (run-vm vm)
           (list (special-reg vm +r-g+) (special-reg vm +r-l+)
                 (reg vm 32) (reg vm 40)
                 (special-reg vm +r-a+) (special-reg vm cl-mmix::+r-c+)))
         (list 40 32 0 7 #x3ffff 0))

  (check csz-zsz
         (let ((vm (run-forms '((setl $1 0)
                                (setl $2 5)
                                (setl $3 9)
                                (csz $3 $1 $2)
                                (zsz $4 $1 $2)
                                (setl $1 1)
                                (zsz $5 $1 $2)))))
           (list (reg vm 3) (reg vm 4) (reg vm 5)))
         (list 5 5 0))

  (check stw-align-and-stb-v
         (let ((vm (run-forms '((setl $1 #x1234)
                                (setl $2 1)
                                (stw $1 $2 $0)
                                (setl $3 200)
                                (setl $4 8)
                                (stb $3 $4 $0)))))
           (list (mem-ref-u16 vm 0) (mem-ref-u8 vm 1)
                 (mem-ref-u8 vm 8) (logand (special-reg vm +r-a+) #x40)))
         (list #x1234 #x34 200 #x40))

  (check logic-bitops
         (let ((vm (make-vm)))
           (set-special vm +r-m+ #xF0)
           (assemble-into vm
             '(program (:org 0)
               (setl $1 #xff)
               (setl $2 #x0f)
               (andn $3 $1 $2)
               (sadd $4 $1 $2)
               (mux $5 $1 $0)
               (setl $6 #x0201)
               (setl $7 #x0103)
               (bdif $8 $6 $7)
               (trap 0 0 0)))
           (run-vm vm)
           (list (reg vm 3) (reg vm 4) (reg vm 5) (reg vm 8) (vm-fault vm)))
         (list #xF0 4 #xF0 #x0100 nil))

  (check mor-reverse
         (let ((vm (run-forms '((seth $1 #x0102)
                                (ormh $1 #x0408)
                                (orml $1 #x1020)
                                (orl $1 #x4080)
                                (seth $2 #x0102)
                                (ormh $2 #x0304)
                                (orml $2 #x0506)
                                (orl $2 #x0708)
                                (mor $3 $1 $2)))))
           (reg vm 3))
         #x0807060504030201)

  (check go-no-rj
         (let ((vm (run-forms '((setl $1 0) (goi $2 $1 16) (:org 16)))))
           (list (reg vm 2) (special-reg vm +r-j+) (vm-pc vm) (vm-halted vm)))
         (list 8 0 16 t))

  (check geta-pushj
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org #x100)
               (setl $0 4)
               (setl $2 9)
               (pushj $1 :f)
               (label :back)
               (geta $3 :back)
               (trap 0 0 0)
               (label :f)
               (setl $0 5)
               (pop 1 0)))
           (run-vm vm)
           (list (reg vm 0) (reg vm 1) (vm-fault vm) (vm-halted vm)
                 (= (reg vm 3) (gethash :back (vm-labels vm)))))
         (list 4 5 nil t t))

  (check recursive-fact
         (list (demo-recursive-factorial 0)
               (demo-recursive-factorial 1)
               (demo-recursive-factorial 5)
               (demo-recursive-factorial 10))
         (list 1 1 120 3628800))

  ;; --- memory model ---
  (check page-budget
         (let ((vm (make-vm :memory-size 64)))
           (list (mem-size vm)
                 (hash-table-p (vm-memory vm))
                 (mem-ref-u64 vm #x2000000000000000)
                 (handler-case
                     (progn (mem-set-u8 vm 0 1)
                            (mem-set-u8 vm 4096 1)
                            :grew)
                   (mmix-fault () :limited))))
         (list 4096 t 0 :limited))

  (check kernel-fault
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (seth $1 #x8000)
               (ldbu $2 $1 $0)
               (trap 0 0 0)))
           (run-vm vm)
           (list (vm-halted vm)
                 (and (vm-fault vm) (search "kernel" (vm-fault vm)) t)))
         (list t t))

  (check fp-and-save-fault
         (let ((fp (make-vm))
               (sv (make-vm)))
           (assemble-into fp '(program (:org 0) (fadd $1 $2 $3) (setl $1 1) (trap 0 0 0)))
           (assemble-into sv '(program (:org 0) (save) (setl $1 1) (trap 0 0 0)))
           (run-vm fp)
           (run-vm sv)
           (list (reg fp 1) (and (search "floating point" (vm-fault fp)) t)
                 (reg sv 1) (and (search "SAVE/UNSAVE" (vm-fault sv)) t)
                 (vm-halted fp) (vm-halted sv)))
         (list 0 t 0 t t t))

  (check trip-and-resume
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org #x100)
               (setl $255 7)
               (trip 1 2 3)
               (trap 0 0 0)))
           (step-vm vm)
           (step-vm vm)
           (let ((pc (vm-pc vm))
                 (rb (special-reg vm +r-b+))
                 (rw (special-reg vm +r-w+))
                 (rx (special-reg vm +r-x+))
                 (ry (special-reg vm +r-y+))
                 (rz (special-reg vm +r-z+)))
             (assemble-into vm '(program (:org 0) (resume 0)))
             (set-special vm +r-w+ #x50)
             (step-vm vm)
             (list pc rb rw rx ry rz (vm-pc vm))))
         (list 0 7 #x108 #xFF010203 2 3 #x50))

  (check overflow-trips-when-enabled
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org #x200)
               (setl $1 #x4000)
               (put ra $1)
               (setl $2 1)
               (sli $3 $2 64)
               (trap 0 0 0)))
           (run-vm vm)
           (list (vm-pc vm) (reg vm 3) (logand (special-reg vm +r-a+) #x40)
                 (special-reg vm +r-w+)))
         (list 32 0 #x40 #x210))

  ;; --- MMIX-SIM traps ---
  (check fopen-refuses-stdio
         (let ((vm (run-forms '((trap 0 1 1)))))
           (list (cl-mmix::i64-from-u64 (reg vm 255))
                 (length (vm-output vm))
                 (vm-legacy-putchar vm)))
         (list -1 0 nil))

  (check legacy-putchar
         (let ((vm (make-vm :legacy-putchar t)))
           (assemble-into vm
             '(program (:org 0) (setl $1 65) (trap 0 1 1) (trap 0 0 0)))
           (run-vm vm)
           (coerce (vm-output vm) 'string))
         "A")

  (check fgets-fwrite
         (let ((vm (make-vm :input (format nil "hi~%"))))
           (assemble-into vm
             '(program (:org 0)
               (setl $255 #x300)
               (trap 0 4 0)
               (setl $255 #x320)
               (trap 0 6 1)
               (trap 0 0 0)))
           (mem-set-u64 vm #x300 #x200)
           (mem-set-u64 vm #x308 16)
           (mem-set-u64 vm #x320 #x200)
           (mem-set-u64 vm #x328 3)
           (run-vm vm)
           (list (reg vm 255)
                 (mem-ref-u8 vm #x200) (mem-ref-u8 vm #x201)
                 (mem-ref-u8 vm #x202) (mem-ref-u8 vm #x203)
                 (coerce (vm-output vm) 'string)))
         (list 0 (char-code #\h) (char-code #\i) 10 0
               (format nil "hi~%")))

  (check fgets-eof
         (let ((empty (make-vm :input ""))
               (partial (make-vm :input "xy")))
           (dolist (vm (list empty partial))
             (assemble-into vm
               '(program (:org 0)
                 (setl $255 #x300)
                 (trap 0 4 0)
                 (trap 0 0 0)))
             (mem-set-u64 vm #x300 #x200)
             (mem-set-u64 vm #x308 16)
             (run-vm vm))
           (list (cl-mmix::i64-from-u64 (reg empty 255))
                 (cl-mmix::i64-from-u64 (reg partial 255))
                 (mem-ref-u8 partial #x200)
                 (mem-ref-u8 partial #x201)
                 (mem-ref-u8 partial #x202)))
         (list -1 2 (char-code #\x) (char-code #\y) 0))

  (check hello-exit
         (multiple-value-bind (s vm) (demo-putchar-hello)
           (list s (vm-exit-code vm) (vm-fault vm)))
         (list "HELLO" 5 nil))

  ;; --- debugger ---
  (check breakpoint-exec
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 1)
               (setl $1 2)
               (trap 0 0 0)))
           (breakpoint vm 4 :kind :exec)
           (run-vm vm)
           (let ((at-break (list (reg vm 1) (vm-pc vm) (car (vm-break vm))
                                 (vm-halted vm)))
                 (cycles (vm-cycles vm)))
             (run-vm vm)
             (let ((still (list (= cycles (vm-cycles vm)) (reg vm 1)))
                   (stepped (progn (step-vm vm) (list (reg vm 1) (vm-pc vm)))))
               (continue-vm vm)
               (list at-break still stepped (reg vm 1) (vm-halted vm)))))
         (list (list 1 4 :exec nil)
               (list t 1)
               (list 2 8)
               2 t))

  (check breakpoint-write
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 7)
               (setl $2 #x40)
               (stb $1 $2 $0)
               (trap 0 0 0)))
           (breakpoint vm #x40 :kind :write)
           (run-vm vm)
           (list (mem-ref-u8 vm #x40) (vm-break vm) (vm-pc vm)))
         (list 7 (list :write #x40) 12))

  ;; --- .mmo loader ---
  (check mmo-run
         (let ((vm (make-vm)))
           (load-mmo vm (mmo-bytes (mmo-setl-trap-image)))
           (run-vm vm)
           (list (reg vm 3) (vm-pc vm) (vm-halted vm) (vm-fault vm)))
         (list 42 #x104 t nil))

  (check mmo-xor-and-fixo
         (let ((xor (make-vm))
               (fix (make-vm)))
           (load-mmo xor (mmo-bytes (mmo-double-content)))
           (load-mmo fix (mmo-bytes (mmo-fixo-image)))
           (list (mem-ref-u32 xor #x100) (mem-ref-u64 fix #x200)))
         (list 0 #x100))

  (check mmo-main-symbol
         (let ((vm (make-vm)))
           (load-mmo vm (mmo-bytes (mmo-with-main)))
           (list (vm-pc vm)
                 (mmix-symbol-name (first (vm-symbols vm)))
                 (mmix-symbol-value (first (vm-symbols vm)))
                 (gethash "Main" (vm-labels vm))))
         (list #x100 "Main" #x100 #x100))

  (check mmo-data-segment
         (let ((vm (make-vm)))
           (load-mmo vm (mmo-bytes (mmo-data-loc-image)))
           (mem-ref-u32 vm #x2000000000000100))
         #xAABBCCDD)

  (format t "~%Results: ~D passed, ~D failed~%" *pass* *fail*)
  (when *errors*
    (format t "Failures:~%")
    (dolist (e *errors*) (format t "  ~S~%" e)))
  (zerop *fail*)))
