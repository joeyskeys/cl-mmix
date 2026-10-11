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

(defun resume-at (rx &key (rw #x40) (ry 0) (rz 0) (ra 0) regs)
  "Plant RESUME 0 at address 0 and step it once. RX is the full rX octa."
  (let ((vm (make-vm)))
    (dolist (pair regs)
      (set-reg vm (car pair) (cdr pair)))
    (set-special vm +r-x+ rx)
    (set-special vm +r-w+ rw)
    (set-special vm +r-y+ ry)
    (set-special vm +r-z+ rz)
    (set-special vm +r-a+ ra)
    (assemble-into vm '(program (:org 0) (resume 0)))
    (step-vm vm)
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

(defun mapped-vm (&key (text-px t) (text-pw t) (text-pr t)
                     segment ptes forms (origin #x100))
  "Kernel VM with virtual memory, a one-level text page at physical 0, and FORMS."
  (let ((vm (make-vm :kernel t :virtual-memory t)))
    (cl-mmix::install-segment-pages
     vm 0 (list (cl-mmix::make-pte 0 :pr text-pr :pw text-pw :px text-px)))
    (when segment
      (cl-mmix::install-segment-pages vm segment ptes))
    (when forms
      (assemble-into vm (list* 'program (list :org origin) forms)))
    vm))

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

  (check serial-rn
         (let* ((vm (make-vm))
                (rn (special-reg vm cl-mmix::+r-n+))
                (now (- (get-universal-time) cl-mmix::+unix-epoch+)))
           (assemble-into vm
             '(program (:org 0) (setl $1 1) (put rn $1) (trap 0 0 0)))
           (run-vm vm)
           (let ((after-put (special-reg vm cl-mmix::+r-n+)))
             (reset-vm vm)
             (let ((after-reset (special-reg vm cl-mmix::+r-n+)))
               (reset-vm vm :clear-registers t)
               (list (plusp rn)
                     (= (ldb (byte 24 40) rn) cl-mmix::+arch-version+)
                   (let ((unix (logand rn #xffffffffff)))
                     (and (>= now unix) (<= (- now unix) 5)))
                   (= rn after-put)
                     (= rn after-reset)
                     (= rn (special-reg vm cl-mmix::+r-n+))))))
         (list t t t t t t))

  (check interval-ri
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 1)
               (setl $2 2)
               (setl $3 3)
               (get $4 rq)
               (setl $5 0)
               (put rq $5)
               (get $6 rq)
               (trap 0 0 0)))
           (set-special vm cl-mmix::+r-i+ 3)
           (step-vm vm)
           (step-vm vm)
           (let ((before (list (special-reg vm cl-mmix::+r-i+)
                               (logbitp 6 (special-reg vm cl-mmix::+r-q+)))))
             (step-vm vm)
             (let ((on-third (list (special-reg vm cl-mmix::+r-i+)
                                   (logbitp 6 (special-reg vm cl-mmix::+r-q+)))))
               (run-vm vm)
               (list before on-third
                     (logbitp 6 (reg vm 4))
                     (logbitp 6 (reg vm 6))
                     (special-reg vm cl-mmix::+r-q+)
                     (special-reg vm cl-mmix::+r-i+)))))
         (list (list 1 nil) (list 0 t) t t #x40 0))

  (check breakpoint-does-not-retire
         (let ((vm (make-vm)))
           (assemble-into vm '(program (:org 0) (setl $1 1) (trap 0 0 0)))
           (set-special vm cl-mmix::+r-i+ 4)
           (breakpoint vm 0 :kind :exec)
           (step-vm vm)
           (list (vm-break vm) (vm-cycles vm)
                 (special-reg vm cl-mmix::+r-i+)
                 (special-reg vm cl-mmix::+r-u+)
                 (special-reg vm cl-mmix::+r-q+)))
         (list (list :exec 0) 0 4 0 0))

  (check usage-counts-all
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0) (setl $1 1) (setl $2 2) (setl $3 3) (trap 0 0 0)))
           (run-vm vm)
           (list (logand (special-reg vm cl-mmix::+r-u+) #x7fffffffffff)
                 (vm-cycles vm)))
         (list 4 4))

  (check usage-counts-pop
         (let ((vm (make-vm)))
           (set-special vm cl-mmix::+r-u+ (logior (ash #xF8 56) (ash #xFF 48)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 1)
               (pushj $0 :leaf)
               (trap 0 0 0)
               (label :leaf)
               (setl $2 2)
               (pop 0)))
           (run-vm vm)
           (list (logand (special-reg vm cl-mmix::+r-u+) #x7fffffffffff)
                 (vm-fault vm)))
         (list 1 nil))

  (check page-budget-sets-rf
         (let ((vm (make-vm :memory-size 64)))
           (assemble-into vm
             '(program (:org 0)
               (setl $1 1)
               (stb $1 $0 0)
               (setl $2 4096)
               (stb $1 $2 0)
               (trap 0 0 0)))
           (run-vm vm)
           (list (special-reg vm cl-mmix::+r-f+)
                 (and (vm-fault vm)
                      (search "memory limit exceeded" (vm-fault vm))
                      (search "#x1000" (vm-fault vm))
                      t)
                 (vm-halted vm)))
         (list 4096 t t))

  (check dump-machine-specials
         (let ((vm (make-vm)))
           (set-special vm cl-mmix::+r-i+ 3)
           (set-special vm cl-mmix::+r-u+ 1)
           (let ((shown (with-output-to-string (s)
                          (dump-registers vm :stream s)))
                 (quiet (with-output-to-string (s)
                          (dump-registers (make-vm) :stream s))))
             (list (and (search "rN=#x" shown) t)
                   (and (search "rI=#x" shown) t)
                   (and (search "rU=#x" shown) t)
                   (and (search "rN=#x" quiet) t)
                   (search "rI=" quiet)
                   (search "rU=" quiet))))
         (list t t t t nil nil))

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
           (list (reg fp 1) (vm-fault fp)
                 (reg sv 1) (and (search "illegal" (vm-fault sv)) t)
                 (vm-halted fp) (vm-halted sv)))
         (list 1 nil 0 t t t))

  (check save-unsave-roundtrip
         (let ((vm (make-vm)))
           (cl-mmix::put-special vm cl-mmix::+r-g+ 32)
           (set-reg vm 0 11)
           (set-reg vm 1 22)
           (set-reg vm 2 33)
           (set-reg vm 32 #x111)
           (set-reg vm 40 #x222)
           (cl-mmix::put-special vm +r-j+ #x1000)
           (cl-mmix::put-special vm +r-a+ #x155)
           (cl-mmix::put-special vm +r-z+ #x99)
           (let ((before (list (special-reg vm +r-l+)
                               (special-reg vm +r-g+)
                               (special-reg vm +r-a+)
                               (special-reg vm +r-j+)
                               (reg vm 0) (reg vm 1) (reg vm 2)
                               (reg vm 32) (reg vm 40)
                               (length (cl-mmix::vm-stack vm))
                               (special-reg vm cl-mmix::+r-o+)
                               (special-reg vm cl-mmix::+r-s+))))
             (assemble-into vm '(program (:org 0) (save #x280000)))
             (step-vm vm)
             (let* ((ptr (reg vm 40))
                    (header (mem-ref-u64 vm ptr))
                    (mid (list (special-reg vm +r-l+)
                               (= (special-reg vm cl-mmix::+r-o+)
                                  (special-reg vm cl-mmix::+r-s+))
                               (ldb (byte 8 56) header)
                               (logand header #xffffffff)
                               (mem-ref-u64 vm (- ptr 8))
                               (vm-fault vm))))
               (assemble-into vm '(program (:org 4) (unsave 40)))
               (step-vm vm)
               (list before mid
                     (list (special-reg vm +r-l+)
                           (special-reg vm +r-g+)
                           (special-reg vm +r-a+)
                           (special-reg vm +r-j+)
                           (reg vm 0) (reg vm 1) (reg vm 2)
                           (reg vm 32) (reg vm 40)
                           (length (cl-mmix::vm-stack vm))
                           (special-reg vm cl-mmix::+r-o+)
                           (special-reg vm cl-mmix::+r-s+))
                     (vm-fault vm)
                     (vm-halted vm)))))
         (list (list 3 32 #x155 #x1000 11 22 33 #x111 #x222
                     0 +stack-segment+ (+ +stack-segment+ 24))
               (list 0 t 32 #x155 #x99 nil)
               (list 3 32 #x155 #x1000 11 22 33 #x111 #x222
                     0 +stack-segment+ (+ +stack-segment+ 24))
               nil nil))

  (check pop-after-save
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0) (save #xFF0000) (pop 0) (trap 0 0 0)))
           (run-vm vm)
           (list (and (vm-fault vm) (search "empty register stack" (vm-fault vm)) t)
                 (vm-halted vm)
                 (special-reg vm +r-l+)
                 (= (special-reg vm cl-mmix::+r-o+)
                    (special-reg vm cl-mmix::+r-s+))))
         (list t t 0 t))

  (check save-nonzero-y
         (let ((sy (make-vm))
               (ux (make-vm)))
           (assemble-into sy
             '(program (:org 0) (save #xFF0100) (setl $1 1) (trap 0 0 0)))
           (assemble-into ux
             '(program (:org 0) (unsave #x010000) (setl $1 1) (trap 0 0 0)))
           (run-vm sy)
           (run-vm ux)
           (list (reg sy 1)
                 (and (vm-fault sy) (search "illegal" (vm-fault sy)) t)
                 (length (cl-mmix::vm-stack sy))
                 (reg ux 1)
                 (and (vm-fault ux) (search "illegal" (vm-fault ux)) t)
                 (vm-halted sy) (vm-halted ux)))
         (list 0 t 0 0 t t t))

  (check unsave-moved-image
         (let ((vm (make-vm)))
           (cl-mmix::put-special vm cl-mmix::+r-g+ 32)
           (set-reg vm 0 11)
           (set-reg vm 1 22)
           (set-reg vm 2 33)
           (set-reg vm 32 #x111)
           (set-reg vm 40 #x222)
           (cl-mmix::put-special vm +r-j+ #x1000)
           (assemble-into vm '(program (:org 0) (save #x280000)))
           (step-vm vm)
           (let* ((src (reg vm 40))
                  (count (+ 3 14 (- 256 32)))
                  (base (- src (* 8 (1- count))))
                  (dest-base (+ +stack-segment+ (* 8 1000)))
                  (dest (+ dest-base (* 8 (1- count)))))
             (loop for i from 0 below count
                   do (mem-set-u64 vm (+ dest-base (* 8 i))
                                   (mem-ref-u64 vm (+ base (* 8 i)))))
             (set-reg vm 50 dest)
             (assemble-into vm '(program (:org 4) (unsave 50)))
             (step-vm vm)
             (list (reg vm 0) (reg vm 1) (reg vm 2)
                   (reg vm 32) (reg vm 40)
                   (special-reg vm +r-l+)
                   (special-reg vm +r-g+)
                   (special-reg vm +r-j+)
                   (special-reg vm cl-mmix::+r-o+)
                   (length (cl-mmix::vm-stack vm))
                   (vm-fault vm))))
         (list 11 22 33 #x111 #x222 3 32 #x1000
               (+ +stack-segment+ (* 8 1000))
               1000 nil))

  (check trip-and-resume
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org #x100)
               (setl $2 #x11)
               (setl $3 #x22)
               (setl $4 #x99)
               (put rj $4)
               (setl $255 7)
               (trip 1 2 3)
               (setl $1 5)
               (trap 0 0 0)))
           (dotimes (i 6) (step-vm vm))
           (let ((image (list (vm-pc vm)
                              (special-reg vm +r-b+)
                              (reg vm 255)
                              (special-reg vm +r-w+)
                              (special-reg vm +r-x+)
                              (special-reg vm +r-y+)
                              (special-reg vm +r-z+))))
             (assemble-into vm '(program (:org 0) (resume 0)))
             (step-vm vm)
             (let ((after (vm-pc vm)))
               (step-vm vm)
               (step-vm vm)
               (list image after (reg vm 1) (special-reg vm +r-b+)
                     (vm-pc vm) (vm-halted vm) (vm-fault vm)))))
         (list (list 0 7 #x99 #x118 #x80000000FF010203 #x11 #x22)
               #x118 5 7 #x11c t nil))

  (check overflow-trips-when-enabled
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org #x200)
               (seth $2 #x7fff)
               (ormh $2 #xffff)
               (orml $2 #xffff)
               (orl $2 #xffff)
               (setl $1 #x4000)
               (put ra $1)
               (addi $3 $2 1)
               (trap 0 0 0)))
           (run-vm vm)
           (list (vm-pc vm) (reg vm 3)
                 (logand (special-reg vm +r-a+) #xff)
                 (special-reg vm +r-w+)
                 (special-reg vm +r-y+)
                 (special-reg vm +r-z+)
                 (logbitp 63 (special-reg vm +r-x+))
                 (vm-fault vm)))
         (list 32 #x8000000000000000 0 #x21c
               #x7fffffffffffffff 1 t nil))

  (check overflow-disabled-falls-through
         (let ((vm (run-forms '((seth $1 #x7fff)
                                (ormh $1 #xffff)
                                (orml $1 #xffff)
                                (orl $1 #xffff)
                                (addi $2 $1 1)))))
           (list (reg vm 2) (special-reg vm +r-a+) (vm-pc vm) (vm-fault vm)))
         (list #x8000000000000000 #x40 20 nil))

  (check store-trip-operands
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org #x100)
               (setl $1 #x4000)
               (put ra $1)
               (setl $3 200)
               (setl $4 8)
               (stb $3 $4 $0)
               (trap 0 0 0)))
           (run-vm vm)
           (list (vm-pc vm)
                 (special-reg vm +r-y+)
                 (special-reg vm +r-z+)
                 (logand (special-reg vm +r-a+) #xff)
                 (mem-ref-u8 vm 8)
                 (logbitp 63 (special-reg vm +r-x+))))
         (list 32 8 200 0 200 t))

  (check resume-ropcode-0
         (let ((added (resume-at (cl-mmix::encode :add 1 2 3)
                                 :regs '((2 . 10) (3 . 20))))
               (taken (resume-at #x42010002 :regs '((1 . 0))))
               (skipped (resume-at #x42010002 :regs '((1 . 1)))))
           (list (reg added 1) (vm-pc added) (vm-fault added)
                 (vm-pc taken) (vm-pc skipped)))
         (list 30 #x40 nil #x44 #x40))

  (check resume-ropcode-1
         (let ((sum (resume-at (logior (ash 1 56) (cl-mmix::encode :add 1 2 3))
                               :ry 100 :rz 3
                               :regs '((1 . 0) (2 . 10) (3 . 20))))
               (wide (resume-at (logior (ash 1 56) (cl-mmix::encode :addi 1 2 1))
                                :ry 5 :rz 1000
                                :regs '((1 . 0))))
               (wyde (resume-at (logior (ash 1 56) (cl-mmix::encode :setl 1 0 #xab))
                                :rz #x123456789
                                :regs '((1 . 0))))
               (incl (resume-at (logior (ash 1 56) (cl-mmix::encode :incl 1 0 1))
                                :ry 10 :rz 3
                                :regs '((1 . 99))))
               (bad (resume-at (logior (ash 1 56) (cl-mmix::encode :ldo 1 2 3))))
               (marg (resume-at (logior (ash 1 56) (cl-mmix::encode :add 5 0 0))
                                :ry 1 :rz 2)))
           (list (reg sum 1) (reg wide 1) (reg wyde 1) (reg incl 1)
                 (and (search "illegal" (vm-fault bad)) t)
                 (and (search "illegal" (vm-fault marg)) t)
                 (special-reg marg cl-mmix::+r-l+)))
         (list 103 1005 #x123456789 13 t t 0))

  (check resume-ropcode-2
         (let ((plain (resume-at (logior (ash 2 56) (cl-mmix::encode :add 3 0 0))
                                 :rz #x42
                                 :regs '((3 . 1))))
               (trip (resume-at (logior (ash 2 56)
                                        (ash #x41 40)
                                        (cl-mmix::encode :add 3 1 2))
                                :ry 7 :rz #x99 :ra #x4000 :rw #x80
                                :regs '((3 . 1))))
               (exact-u (resume-at (logior (ash 2 56)
                                           (ash #x04 40)
                                           (cl-mmix::encode :add 3 0 0))
                                   :rz 8
                                   :regs '((3 . 1))))
               (marg (resume-at (logior (ash 2 56) (cl-mmix::encode :add 5 0 0))
                                :rz 9)))
           (list (reg plain 3) (vm-pc plain) (special-reg plain +r-a+)
                 (reg trip 3) (vm-pc trip)
                 (logand (special-reg trip +r-a+) #xffff)
                 (special-reg trip +r-w+)
                 (special-reg trip +r-y+)
                 (special-reg trip +r-z+)
                 (logbitp 63 (special-reg trip +r-x+))
                 (vm-fault trip)
                 (reg exact-u 3) (special-reg exact-u +r-a+) (vm-pc exact-u)
                 (and (search "illegal" (vm-fault marg)) t)
                 (reg marg 5)))
         (list #x42 #x40 0
               #x99 32 #x4001 #x80 7 #x99 t nil
               8 0 #x40
               t 0))

  (check resume-illegal
         (let ((rop3 (resume-at (ash 3 56)))
               (again (resume-at (cl-mmix::encode :resume 0 0 0)))
               (xy (make-vm))
               (z1 (make-vm)))
           (assemble-into xy '(program (:org 0) (resume #x10000)))
           (assemble-into z1 '(program (:org 0) (resume 1)))
           (step-vm xy)
           (step-vm z1)
           (list (and (search "illegal" (vm-fault rop3)) t)
                 (and (search "illegal" (vm-fault again)) t)
                 (and (search "illegal" (vm-fault xy)) t)
                 (and (search "nonzero XYZ" (vm-fault z1)) t)))
         (list t t t t))

  (check put-get-nonzero-y
         (let ((put (make-vm))
               (get (make-vm)))
           (set-reg put 3 #x40)
           (mem-set-u32 put 0 #xF6150103)
           (step-vm put)
           (set-special get +r-a+ #x40)
           (mem-set-u32 get 0 #xFE010115)
           (step-vm get)
           (list (and (search "illegal" (vm-fault put)) t)
                 (special-reg put +r-a+)
                 (vm-halted put)
                 (and (search "illegal" (vm-fault get)) t)
                 (reg get 1)))
         (list t 0 t t 0))

  (check negative-address-does-not-trip
         (let* ((vm (make-vm))
                (pc (logior #x8000000000000000 32)))
           (setf (vm-pc vm) pc)
           (set-special vm +r-a+ #x4000)
           (list (cl-mmix::signal-event vm #x40 :y 1 :z 2 :inst #x21030201)
                 (vm-pc vm)
                 (logand (special-reg vm +r-a+) #xffff)
                 (cl-mmix::do-trip vm 0 :inst #xff000000)
                 (vm-pc vm)))
         (list nil (logior #x8000000000000000 32) #x4040
               nil (logior #x8000000000000000 32)))

  ;; --- Kernel traps (plan 05). Default make-vm stays on the Lisp path. ---
  (check user-trap-skips-kernel
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org #x100)
               (seth $255 #x2000)
               (trap 0 7 1)
               (trap 0 0 0)
               (:org #x2000000000000000)
               (:zstring "HI")))
           (run-vm vm)
           (list (coerce (vm-output vm) 'string)
                 (reg vm 255)
                 (special-reg vm cl-mmix::+r-t+)
                 (special-reg vm cl-mmix::+r-k+)
                 (vm-halted vm)
                 (vm-fault vm)
                 (vm-exit-code vm)))
         (list "HI" 2 0 0 t nil 2))

  (check user-kernel-address-faults
         (let ((vm (make-vm)))
           (assemble-into vm '(program (:org 0) (ldou $1 $2 $3) (trap 0 0 0)))
           (set-reg vm 2 #x8000000000000000)
           (run-vm vm)
           (list (and (search "kernel address" (or (vm-fault vm) "")) t)
                 (vm-halted vm)
                 (reg vm 1)))
         (list t t 0))

  (check kernel-fputs
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm
             '(program (:org #x100)
               (seth $255 #x2000)
               (trap 0 7 1)
               (trap 0 0 0)
               (:org #x2000000000000000)
               (:zstring "HI")))
           (breakpoint vm #x108)
           (run-vm vm)
           (list (coerce (vm-output vm) 'string)
                 (reg vm 255)
                 (special-reg vm cl-mmix::+r-k+)
                 (vm-pc vm)
                 (and (vm-break vm) t)
                 (vm-halted vm)
                 (vm-fault vm)))
         (list "HI" 2 #xFFFFFFFFFFFFFFFF #x108 t nil nil))

  (check kernel-fputs-halts
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm
             '(program (:org #x100)
               (seth $255 #x2000)
               (trap 0 7 1)
               (trap 0 0 0)
               (:org #x2000000000000000)
               (:zstring "HI")))
           (run-vm vm)
           (list (coerce (vm-output vm) 'string)
                 (vm-exit-code vm)
                 (vm-halted vm)
                 (vm-fault vm)
                 (special-reg vm cl-mmix::+r-t+)))
         (list "HI" 2 t nil #x8000000100000000))

  (check kernel-halt
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x100) (trap 0 0 0)))
           (set-reg vm 255 42)
           (run-vm vm)
           (list (vm-exit-code vm) (vm-halted vm) (vm-fault vm)))
         (list 42 t nil))

  (check kernel-trip-trap
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x100) (trap 0 0 1)))
           (run-vm vm)
           (list (vm-halted vm) (vm-fault vm)))
         (list t "TRAP 0,0,1 (no kernel to service the trip)"))

  (check kernel-unsupported-trap
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x100) (trap 1 2 3)))
           (run-vm vm)
           (list (vm-halted vm) (vm-fault vm)))
         (list t "unsupported TRAP 1,2,3"))

  (check kernel-put-rk-user
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x100) (put rk $1)))
           (set-reg vm 1 #x11)
           (step-vm vm)
           (list (special-reg vm cl-mmix::+r-k+)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-k+)
                 (vm-pc vm)
                 (vm-halted vm)
                 (vm-fault vm)))
         (list #xFFFFFFFFFFFFFFFF cl-mmix::+rq-k+ #x100 nil nil))

  (check kernel-put-rk-rom
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x200) (put rk $1)))
           (set-reg vm 1 #xABC)
           (setf (vm-pc vm) (logior #x8000000000000000 #x200))
           (step-vm vm)
           (list (special-reg vm cl-mmix::+r-k+)
                 (vm-halted vm)
                 (vm-fault vm)))
         (list #xABC nil nil))

  (check kernel-dynamic-trap
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x100) (setl $1 1)))
           (set-special vm cl-mmix::+r-q+ cl-mmix::+rq-k+)
           (step-vm vm)
           (list (vm-pc vm)
                 (reg vm 1)
                 (special-reg vm cl-mmix::+r-k+)
                 (special-reg vm cl-mmix::+r-ww+)))
         (list #x8000000100000000 0 0 #x100))

  (check kernel-resume-user-pc
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x100) (resume 1)))
           (set-special vm cl-mmix::+r-ww+ #x40)
           (step-vm vm)
           (list (vm-pc vm)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-k+)
                 (vm-halted vm)
                 (vm-fault vm)))
         (list #x100 cl-mmix::+rq-k+ nil nil))

  (check kernel-negative-load
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x100) (ldou $1 $2 $3)))
           (set-reg vm 2 #x8000000000000300)
           (mem-set-u64 vm #x300 #x1111)
           (step-vm vm)
           (list (reg vm 1)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-n+)
                 (vm-pc vm)
                 (vm-halted vm)))
         (list 0 cl-mmix::+rq-n+ #x104 nil))

  (check kernel-negative-store
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x100) (stou $4 $5 $6)))
           (set-reg vm 4 #x99)
           (set-reg vm 5 #x8000000000000300)
           (mem-set-u64 vm #x300 #x1111)
           (step-vm vm)
           (list (mem-ref-u64 vm #x300)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-n+)
                 (vm-pc vm)))
         (list #x1111 cl-mmix::+rq-n+ #x104))

  (check kernel-ropcode-3
         (let ((inst (make-vm :kernel t))
               (data (make-vm :kernel t)))
           (flet ((arm (vm xx)
                    (assemble-into vm '(program (:org #x400) (resume 1)))
                    (setf (vm-pc vm) (logior #x8000000000000000 #x400))
                    (set-special vm cl-mmix::+r-ww+ #x80)
                    (set-special vm cl-mmix::+r-xx+ xx)
                    (set-special vm cl-mmix::+r-yy+ #x2000)
                    (set-special vm cl-mmix::+r-zz+ #x55)
                    (set-reg vm 255 #xFFFFFFFFFFFFFFFF)
                    (set-special vm cl-mmix::+r-bb+ 7)
                    (step-vm vm)))
             (arm inst (logior (ash 3 56) (cl-mmix::encode :swym 0 0 0)))
             (arm data (logior (ash 3 56) (cl-mmix::encode :add 0 0 0)))
             (list (cl-mmix::vm-trans-cache inst)
                   (cl-mmix::vm-trans-va inst)
                   (cl-mmix::vm-trans-pte inst)
                   (vm-pc inst)
                   (special-reg inst cl-mmix::+r-k+)
                   (reg inst 255)
                   (cl-mmix::vm-trans-cache data)
                   (logand (special-reg inst cl-mmix::+r-q+) cl-mmix::+rq-p+))))
         (list :inst #x2000 #x55 #x80 #xFFFFFFFFFFFFFFFF 7 :data 0))

  (check kernel-resume-bad-z
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm '(program (:org #x400) (resume 2)))
           (setf (vm-pc vm) (logior #x8000000000000000 #x400))
           (set-special vm cl-mmix::+r-ww+ #x80)
           (step-vm vm)
           (list (vm-pc vm)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-b+)
                 (special-reg vm cl-mmix::+r-k+)
                 (vm-fault vm)))
         (list (logior #x8000000000000000 #x400)
               cl-mmix::+rq-b+
               #xFFFFFFFFFFFFFFFF
               nil))

  (check kernel-put-rq-sticky
         (let ((vm (make-vm :kernel t)))
           (assemble-into vm
             '(program (:org #x500)
               (get $1 rq)
               (put rq $2)))
           (setf (vm-pc vm) (logior #x8000000000000000 #x500))
           ;; rK is 0 while the kernel itself runs, so the preset rQ bit
           ;; does not take a dynamic trap before the GET.
           (set-special vm cl-mmix::+r-k+ 0)
           (set-special vm cl-mmix::+r-q+ cl-mmix::+rq-k+)
           (step-vm vm)
           (set-special vm cl-mmix::+r-q+
                        (logior cl-mmix::+rq-k+ cl-mmix::+rq-n+))
           (set-reg vm 2 0)
           (step-vm vm)
           (list (reg vm 1)
                 (special-reg vm cl-mmix::+r-q+)))
         (list (logior cl-mmix::+rq-k+ cl-mmix::+rq-p+)
               cl-mmix::+rq-n+))

  (check kernel-sync-k
         (let ((hi (make-vm :kernel t))
               (lo (make-vm :kernel t)))
           (assemble-into hi '(program (:org #x100) (sync 4)))
           (assemble-into lo '(program (:org #x100) (sync 3)))
           (step-vm hi)
           (step-vm lo)
           (list (logand (special-reg hi cl-mmix::+r-q+) cl-mmix::+rq-k+)
                 (vm-pc hi)
                 (logand (special-reg lo cl-mmix::+r-q+) cl-mmix::+rq-k+)
                 (vm-pc lo)
                 (vm-fault hi)))
         (list cl-mmix::+rq-k+ #x100 0 #x104 nil))

  ;; --- Virtual memory (plan 06). Default make-vm stays an identity map. ---
  (check vm-requires-kernel
         (handler-case (progn (make-vm :virtual-memory t) :made)
           (error () :rejected))
         :rejected)

  (check vm-ldvts-identity
         (let ((vm (make-vm)))
           (assemble-into vm '(program (:org #x100) (ldvts $1 $2 $3)))
           (set-reg vm 2 #x2000)
           (set-reg vm 3 7)
           (step-vm vm)
           (list (reg vm 1) (vm-pc vm) (vm-halted vm)))
         (list 0 #x104 nil))

  (check vm-hardware-walk
         (let* ((data (cl-mmix::make-pte #x8000 :pr t :pw t))
                (locked (cl-mmix::make-pte #xA000 :pr t :pw nil))
                (vm (mapped-vm :segment 1 :ptes (list data locked)
                               :forms '((stou $1 $2 0)
                                        (stou $1 $3 0)))))
           (set-reg vm 1 #x99)
           (set-reg vm 2 +data-segment+)
           (set-reg vm 3 (+ +data-segment+ 8192))
           (step-vm vm)
           (step-vm vm)
           (list (mem-ref-u64 vm #x8000 :physical t)
                 (mem-ref-u64 vm #xA000 :physical t)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-w+)
                 (vm-pc vm)
                 (null (gethash (floor +data-segment+ 4096) (vm-memory vm)))))
         (list #x99 0 cl-mmix::+rq-w+ #x108 t))

  (check vm-fetch-no-px
         (let ((vm (mapped-vm :text-px nil
                              :forms '((setl $1 7)))))
           (step-vm vm)
           (list (reg vm 1)
                 (vm-pc vm)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-x+)
                 (special-reg vm cl-mmix::+r-u+)
                 (vm-halted vm)))
         (list 0 #x100 cl-mmix::+rq-x+ 0 nil))

  (check vm-negative-address
         (let ((vm (mapped-vm :forms '((ldou $1 $2 $3)))))
           (set-reg vm 2 #x8000000000000300)
           (mem-set-u64 vm #x300 #x1111 :physical t)
           (step-vm vm)
           (let ((user (list (reg vm 1)
                             (logand (special-reg vm cl-mmix::+r-q+)
                                     cl-mmix::+rq-n+)
                             (vm-pc vm))))
            ;; rK = 0 so the n bit just recorded does not divert this fetch.
            (set-special vm cl-mmix::+r-k+ 0)
            (setf (vm-pc vm) #x8000000000000100)
            (step-vm vm)
            (list user (reg vm 1))))
         (list (list 0 cl-mmix::+rq-n+ #x104) #x1111))

  (check vm-software-translate
         (let* ((pte (cl-mmix::make-pte #x8000 :pr t :pw t))
                (vm (mapped-vm :segment 1 :ptes (list pte)
                              :forms '((setl $1 1)
                                       (ldou $2 $3 0)))))
           (set-reg vm 3 +data-segment+)
           (mem-set-u64 vm #x8000 #x42 :physical t)
           (step-vm vm)
           (set-special vm cl-mmix::+r-v+
                        (logior (logand (special-reg vm cl-mmix::+r-v+)
                                        (lognot 7))
                                1))
           (step-vm vm)
           (let ((trapped (list (ldb (byte 32 32) (special-reg vm cl-mmix::+r-xx+))
                                (special-reg vm cl-mmix::+r-yy+)
                                (reg vm 2)
                                (vm-pc vm)
                                (special-reg vm cl-mmix::+r-k+))))
             (set-special vm cl-mmix::+r-zz+ pte)
             (set-reg vm 255 #xFFFFFFFFFFFFFFFF)
             (assemble-into vm '(program (:org #x500) (resume 1)))
             (setf (vm-pc vm) #x8000000000000500)
             (step-vm vm)
             (step-vm vm)
             (list trapped (reg vm 2) (vm-pc vm))))
         (list (list #x03000000 +data-segment+ 0
                     cl-mmix::+rom-base+ 0)
               #x42 #x108))

  (check vm-ldvts
         (let* ((pte (cl-mmix::make-pte #x8000 :pr t :pw t))
                (vm (mapped-vm :segment 1 :ptes (list pte)
                              :forms '((stou $1 $2 0)))))
           (set-reg vm 1 #x99)
           (set-reg vm 2 +data-segment+)
           (step-vm vm)
           (assemble-into vm '(program (:org #x400) (ldvts $7 $8 $9)))
           ;; rK = 0 so the p bit recorded by a negative PC does not trap
           ;; between the LDVTS instructions. The user store restores the mask.
           (set-special vm cl-mmix::+r-k+ 0)
           (setf (vm-pc vm) #x8000000000000400)
           (set-reg vm 8 +data-segment+)
           (set-reg vm 9 7)
           (step-vm vm)
           (let ((hit (reg vm 7)))
             (set-reg vm 8 +pool-segment+)
             (set-reg vm 9 1)
             (setf (vm-pc vm) #x8000000000000400)
             (step-vm vm)
             (let ((miss (reg vm 7)))
               (set-reg vm 8 +data-segment+)
               (set-reg vm 9 0)
               (setf (vm-pc vm) #x8000000000000400)
               (step-vm vm)
               (let ((dropped (reg vm 7)))
                 (mem-set-u64 vm #x42000 0 :physical t)
                 (set-reg vm 1 #x77)
                 (set-special vm cl-mmix::+r-k+ #xFFFFFFFFFFFFFFFF)
                 (set-special vm cl-mmix::+r-q+
                              (logandc2 (special-reg vm cl-mmix::+r-q+)
                                        cl-mmix::+rq-p+))
                 (setf (vm-pc vm) #x100)
                 (step-vm vm)
                 (list hit miss dropped
                       (mem-ref-u64 vm #x8000 :physical t)
                       (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-w+))))))
         (list 2 0 2 #x99 cl-mmix::+rq-w+))

  (check vm-sync-6
         (let* ((pte (cl-mmix::make-pte #x8000 :pr t :pw t))
                (vm (mapped-vm :segment 1 :ptes (list pte)
                              :forms '((ldou $1 $2 0)))))
           (set-reg vm 2 +data-segment+)
           (step-vm vm)
           (assemble-into vm '(program (:org #x400)
                               (sync 6)
                               (ldvts $7 $8 $0)))
           (set-special vm cl-mmix::+r-k+ 0)
           (setf (vm-pc vm) #x8000000000000400)
           (set-reg vm 8 +data-segment+)
           (step-vm vm)
          (step-vm vm)
          (reg vm 7))
        0)

  (check vm-mmio
         (let ((vm (make-vm :kernel t :virtual-memory t))
               (seen nil))
           (assemble-into vm '(program (:org #x400) (ldou $1 $2 0)))
           (set-special vm cl-mmix::+r-k+ 0)
           (setf (vm-pc vm) #x8000000000000400)
           (set-reg vm 2 #x8001000000000000)
           (let ((bytes (cl-mmix::vm-mem-bytes vm)))
             (step-vm vm)
             (let ((default (list (reg vm 1)
                                  (special-reg vm cl-mmix::+r-f+)
                                  (= (cl-mmix::vm-mem-bytes vm) bytes)
                                  (null (gethash (floor #x1000000000000 4096)
                                                 (vm-memory vm)))
                                  (zerop (hash-table-count (cl-mmix::vm-dtc vm))))))
               (setf (cl-mmix::vm-mmio vm)
                     (lambda (vm addr size value write-p)
                       (declare (ignore vm value write-p))
                       (setf seen (list addr size))
                       #xAB))
               (set-reg vm 1 0)
               (setf (vm-pc vm) #x8000000000000400)
               (step-vm vm)
               (list default (reg vm 1) seen
                     (= (cl-mmix::vm-mem-bytes vm) bytes)))))
         (list (list 0 #x1000000000000 t t t)
               #xAB (list #x1000000000000 8) t))

  (check vm-stack-overflow
         (let ((vm (mapped-vm :forms '((pushj 1 :cont)
                                       (label :cont)
                                       (setl $2 1)))))
           (set-special vm cl-mmix::+r-c+ (cl-mmix::make-pte #xA000 :pw t))
           (set-special vm cl-mmix::+r-l+ 1)
           (set-reg vm 0 #xABC)
           (step-vm vm)
           (step-vm vm)
           (list (mem-ref-u64 vm #xA000 :physical t)
                 (mem-ref-u64 vm +stack-segment+ :internal t)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-stack-overflow+)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-w+)
                 (reg vm 2)
                 (vm-pc vm)))
         (list #xABC 0 cl-mmix::+rq-stack-overflow+ 0 1 #x108))

  (check vm-auxiliary-page
         (let ((vm (make-vm :kernel t :virtual-memory t)))
           (set-special vm cl-mmix::+r-v+ (cl-mmix::pack-rv 2 2 2 2 13 8 0 0))
           (mem-set-u64 vm #x10000 (cl-mmix::make-pte 0 :pr t :pw t :px t) :physical t)
           (mem-set-u64 vm #x12008 (cl-mmix::make-ptp #x30000) :physical t)
           (mem-set-u64 vm #x30000 (cl-mmix::make-pte #x40000 :pr t :pw t) :physical t)
           (assemble-into vm '(program (:org #x100) (stou $1 $2 0)))
           (set-reg vm 1 #x55)
           (set-reg vm 2 #x800000)
           (step-vm vm)
           (list (mem-ref-u64 vm #x40000 :physical t)
                 (vm-pc vm)
                 (vm-fault vm)))
         (list #x55 #x104 nil))

  (check vm-n-mismatch
         (let ((vm (mapped-vm :segment 1
                              :ptes (list (cl-mmix::make-pte #x8000 :n 1 :pr t :pw t))
                              :forms '((stou $1 $2 0)))))
           (set-reg vm 1 #x99)
           (set-reg vm 2 +data-segment+)
           (step-vm vm)
           (list (mem-ref-u64 vm #x8000 :physical t)
                 (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-w+)
                 (vm-pc vm)))
         (list 0 cl-mmix::+rq-w+ #x104))

  ;; --- Caches and SYNC (plan 07). Default make-vm leaves caches off. ---
  (check cache-dirty-until-syncd
         (let ((vm (make-vm :caches t)))
           (mem-set-u64 vm #x200 #x1111 :physical t)
           (assemble-into vm '(program (:org #x100)
                               (stou $1 $2 $0)
                               (ldou $3 $2 $0)
                               (syncd 7 $2 $0)))
           (set-reg vm 1 #x2222)
           (set-reg vm 2 #x200)
           (step-vm vm)
           (step-vm vm)
           (let ((mid (list (reg vm 3)
                            (mem-ref-u64 vm #x200 :physical t))))
             (step-vm vm)
             (list mid (mem-ref-u64 vm #x200 :physical t) (reg vm 3)
                   (vm-fault vm))))
         (list (list #x2222 #x1111) #x2222 #x2222 nil))

  (check cache-sync-5
         (let ((vm (make-vm :caches t)))
           (mem-set-u64 vm #x200 #x1111 :physical t)
           (assemble-into vm '(program (:org #x100)
                               (stou $1 $2 $0)
                               (sync 5)))
           (set-reg vm 1 #x2222)
           (set-reg vm 2 #x200)
           (step-vm vm)
           (let ((dirty (mem-ref-u64 vm #x200 :physical t)))
             (step-vm vm)
             (list dirty (mem-ref-u64 vm #x200 :physical t)
                   (mem-ref-u64 vm #x200) (vm-fault vm))))
         (list #x1111 #x2222 #x2222 nil))

  (check cache-ldunc
         (let ((vm (make-vm :caches t)))
           (mem-set-u64 vm #x200 #x1111 :physical t)
           (assemble-into vm '(program (:org #x100)
                               (stou $1 $2 $0)
                               (ldunc $3 $2 $0)
                               (ldou $4 $2 $0)))
           (set-reg vm 1 #x2222)
           (set-reg vm 2 #x200)
           (step-vm vm)
           (step-vm vm)
           (step-vm vm)
           (list (reg vm 3) (reg vm 4)
                 (mem-ref-u64 vm #x200 :physical t)
                 (vm-fault vm)))
         (list #x1111 #x2222 #x1111 nil))

  (check cache-stunc
         (let ((vm (make-vm :caches t)))
           (mem-set-u64 vm #x200 #x1111 :physical t)
           (assemble-into vm '(program (:org #x100)
                               (stou $1 $2 $0)
                               (stunc $3 $2 $0)
                               (ldou $4 $2 $0)))
           (set-reg vm 1 #x2222)
           (set-reg vm 3 #x3333)
           (set-reg vm 2 #x200)
           (step-vm vm)
           (step-vm vm)
           (step-vm vm)
           (list (reg vm 4) (mem-ref-u64 vm #x200 :physical t) (vm-fault vm)))
         (list #x3333 #x3333 nil))

  (check cache-data-segment
         (let ((vm (make-vm :caches t)))
           (assemble-into vm '(program (:org #x100)
                               (stou $1 $2 $0)
                               (ldou $3 $2 $0)))
           (set-reg vm 1 #x55)
           (set-reg vm 2 +data-segment+)
           (step-vm vm)
           (step-vm vm)
           (list (reg vm 3)
                 (null (gethash (floor +data-segment+ 4096) (vm-memory vm)))
                 (vm-fault vm)))
         (list #x55 t nil))

  (check cache-syncid
         (let ((vm (make-vm :caches t))
               (new (cl-mmix::encode :setl 3 0 9)))
           (assemble-into vm '(program (:org #x100)
                               (sttu $1 $2 $0)
                               (syncid 3 $2 $0)
                               (setl $3 1)
                               (trap 0 0 0)))
           (set-reg vm 1 new)
           (set-reg vm 2 #x108)
           (setf (vm-pc vm) #x108)
           (let ((warm (fetch vm)))
             (setf (vm-pc vm) #x100)
             (step-vm vm)
             (setf (vm-pc vm) #x108)
             (let ((stale (fetch vm)))
               (setf (vm-pc vm) #x104)
               (step-vm vm)
               (setf (vm-pc vm) #x108)
               (list warm stale
                     (mem-ref-u32 vm #x108 :physical t)
                     (fetch vm)
                     (vm-fault vm)))))
         (list (cl-mmix::encode :setl 3 0 1)
               (cl-mmix::encode :setl 3 0 1)
               (cl-mmix::encode :setl 3 0 9)
               (cl-mmix::encode :setl 3 0 9)
               nil))

  (check cache-syncid-negative
         (let ((vm (make-vm :caches t)))
           (mem-set-u64 vm #x200 #x1111 :physical t)
           (assemble-into vm '(program (:org #x100)
                               (stou $1 $2 $0)
                               (syncid 7 $5 $0)
                               (ldou $3 $2 $0)))
           (set-reg vm 1 #x2222)
           (set-reg vm 2 #x200)
           (set-reg vm 5 (logior #x8000000000000000 #x200))
           (step-vm vm)
           (step-vm vm)
           (step-vm vm)
           (list (reg vm 3)
                 (mem-ref-u64 vm #x200 :physical t)
                 (vm-fault vm)
                 (vm-halted vm)))
         (list #x1111 #x1111 nil nil))

  (check cache-sync7-privileged
         (let ((kept (make-vm :kernel t :caches t))
               (dropped (make-vm :caches t)))
           (mem-set-u64 kept #x200 #x1111 :physical t)
           (mem-set-u64 dropped #x200 #x1111 :physical t)
           (assemble-into kept '(program (:org #x100)
                                 (stou $1 $2 $0)
                                 (sync 7)
                                 (ldou $3 $2 $0)))
           (assemble-into dropped '(program (:org #x100)
                                    (stou $1 $2 $0)
                                    (sync 7)
                                    (ldou $3 $2 $0)))
           (set-reg kept 1 #x2222)
           (set-reg kept 2 #x200)
           (set-reg dropped 1 #x2222)
           (set-reg dropped 2 #x200)
           (step-vm kept)
           (step-vm kept)
           (step-vm dropped)
           (step-vm dropped)
           (step-vm dropped)
           (list (mem-ref-u64 kept #x200)
                 (mem-ref-u64 kept #x200 :physical t)
                 (logand (special-reg kept cl-mmix::+r-q+) cl-mmix::+rq-k+)
                 (vm-pc kept)
                 (reg dropped 3)
                 (mem-ref-u64 dropped #x200 :physical t)
                 (vm-fault dropped)))
         (list #x2222 #x1111 cl-mmix::+rq-k+ #x104
               #x1111 #x1111 nil))

  (check cache-sync8-sets-b
         (let ((vm (make-vm :kernel t :caches t)))
           (assemble-into vm '(program (:org #x100) (sync 8)))
           (set-special vm cl-mmix::+r-k+ 0)
           (setf (vm-pc vm) #x8000000000000100)
           (step-vm vm)
           (list (logand (special-reg vm cl-mmix::+r-q+) cl-mmix::+rq-b+)
                 (vm-pc vm)
                 (vm-halted vm)
                 (vm-fault vm)))
         (list cl-mmix::+rq-b+ #x8000000000000100 nil nil))

  (check cache-fence
         (let ((vm (make-vm :caches t)))
           (assemble-into vm '(program (:org #x100)
                               (sync 0)
                               (sync 2)
                               (sync 3)
                               (sync 1)
                               (ldou $1 $2 $0)))
           (set-reg vm 2 #x200)
           (step-vm vm)
           (let ((a (cl-mmix::vm-fence vm)))
             (step-vm vm)
             (let ((b (cl-mmix::vm-fence vm)))
               (step-vm vm)
               (let ((c (cl-mmix::vm-fence vm)))
                 (step-vm vm)
                 (let ((d (cl-mmix::vm-fence vm)))
                   (step-vm vm)
                   (list a b c d (cl-mmix::vm-fence vm) (vm-pc vm)))))))
         (list :all :load :memory :store nil #x114))

  (check cache-power-save
         (let ((vm (make-vm :caches t))
               (woken (make-vm :caches t)))
           (assemble-into vm '(program (:org #x100)
                               (sync 4)
                               (setl $1 5)))
           (assemble-into woken '(program (:org #x100)
                                  (sync 4)
                                  (setl $1 6)))
           (step-vm vm)
           (let ((slept (list (cl-mmix::vm-asleep vm) (vm-pc vm) (reg vm 1))))
             (step-vm vm)
             (let ((held (list (vm-pc vm) (reg vm 1))))
               (wake-core vm)
               (step-vm vm)
               (step-vm woken)
               (set-special woken cl-mmix::+r-q+ 1)
               (step-vm woken)
               (list slept held
                     (reg vm 1) (vm-pc vm) (cl-mmix::vm-asleep vm)
                     (reg woken 1) (cl-mmix::vm-asleep woken)))))
         (list (list t #x104 0) (list #x104 0)
               5 #x108 nil
               6 nil))

  (check cache-prefetch
         (let ((vm (make-vm :caches t)))
           (assemble-into vm '(program (:org #x100)
                               (preld 255 $2 $0)
                               (trap 0 0 0)))
           (set-reg vm 2 #x5000)
           (let ((bytes (cl-mmix::vm-mem-bytes vm)))
             (step-vm vm)
             (list (vm-fault vm)
                   (vm-halted vm)
                   (= (cl-mmix::vm-mem-bytes vm) bytes)
                   (vm-pc vm))))
         (list nil nil t #x104))

  ;; --- §50 μ and υ ---
  (check cost-ten-addu
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (addu $1 $1 $1)
               (addu $1 $1 $1)
               (addu $1 $1 $1)
               (addu $1 $1 $1)
               (addu $1 $1 $1)
               (addu $1 $1 $1)
               (addu $1 $1 $1)
               (addu $1 $1 $1)
               (addu $1 $1 $1)
               (addu $1 $1 $1)
               (trap 0 0 0)))
           (dotimes (i 10) (step-vm vm))
           (let ((dump (with-output-to-string (s)
                         (dump-registers vm :stream s))))
             (list (vm-oops vm) (vm-mem-cost vm) (vm-cycles vm) (vm-mems vm)
                   (and (search "oops=10" dump)
                        (search "mem-cost=0" dump)
                        t))))
         (list 10 0 10 0 t))

  (check cost-taken-bz
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (label :back)
               (swym 0)
               (bz $1 :back)))
           (set-reg vm 1 0)
           (setf (vm-pc vm) 4)
           (let ((op (ldb (byte 8 24) (mem-ref-u32 vm 4))))
             (step-vm vm)
             (list op (vm-oops vm) (vm-mem-cost vm) (vm-pc vm) (vm-cycles vm))))
         (list #x43 3 0 0 1))

  (check cost-taken-pbz
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (label :back)
               (swym 0)
               (pbz $1 :back)))
           (set-reg vm 1 0)
           (setf (vm-pc vm) 4)
           (let ((op (ldb (byte 8 24) (mem-ref-u32 vm 4))))
             (step-vm vm)
             (list op (vm-oops vm) (vm-mem-cost vm) (vm-pc vm))))
         (list #x53 1 0 0))

  (check cost-mul-div
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (mul $1 $2 $3)
               (div $1 $2 $3)
               (trap 0 0 0)))
           (set-reg vm 2 20)
           (set-reg vm 3 4)
           (set-special vm cl-mmix::+r-i+ 10)
           (step-vm vm)
           (step-vm vm)
           (list (vm-oops vm) (vm-mem-cost vm) (vm-cycles vm)
                 (special-reg vm cl-mmix::+r-i+)
                 (logand (special-reg vm cl-mmix::+r-q+) #x40)
                 (reg vm 1)))
         (list 70 0 2 8 0 5))

  (check cost-ldo
         (let ((vm (make-vm)))
           (assemble-into vm '(program (:org 0) (ldo $1 $2 $0) (trap 0 0 0)))
           (set-reg vm 2 #x200)
           (mem-set-u64 vm #x200 99)
           (step-vm vm)
           (list (vm-oops vm) (vm-mem-cost vm) (vm-mems vm) (vm-cycles vm)
                 (reg vm 1)))
         (list 1 1 1 1 99))

  (check cost-go
         (let ((vm (make-vm)))
           (assemble-into vm '(program (:org 0) (go $1 $2 $0)))
           (set-reg vm 2 #x100)
           (step-vm vm)
           (list (vm-oops vm) (vm-mem-cost vm) (vm-mems vm) (vm-cycles vm)
                 (vm-pc vm) (reg vm 1)))
         (list 3 0 0 1 #x100 4))

  (check cost-cswap
         (let ((vm (make-vm)))
           (assemble-into vm '(program (:org 0) (cswap $1 $2 $0) (trap 0 0 0)))
           (set-reg vm 1 9)
           (set-reg vm 2 #x200)
           (set-special vm +r-p+ 5)
           (mem-set-u64 vm #x200 5)
           (step-vm vm)
           (list (vm-oops vm) (vm-mem-cost vm) (vm-mems vm)
                 (reg vm 1) (mem-ref-u64 vm #x200)))
         (list 2 2 1 1 9))

  (check cost-demo-sum
         (multiple-value-bind (sum vm) (demo-sum-1-to-n 10)
           (list sum (vm-cycles vm) (vm-oops vm) (vm-mem-cost vm)))
         (list 55 56 62 0))

  (check cost-fault-adds-nothing
         (let ((vm (make-vm)))
           (assemble-into vm
             '(program (:org 0)
               (seth $1 #x8000)
               (ldbu $2 $1 $0)
               (trap 0 0 0)))
           (step-vm vm)
           (let ((after-seth (list (vm-oops vm) (vm-cycles vm))))
             (step-vm vm)
             (list after-seth
                   (vm-oops vm) (vm-mem-cost vm) (vm-cycles vm)
                   (vm-halted vm)
                   (and (vm-fault vm) t))))
         (list (list 1 1) 1 0 2 t t))

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

  ;; --- MMIXAL ---
  (let ((fact (format nil "% factorial~%        LOC     #100~%        SETL    $1,10          % n~%        SETL    $3,1~%1H      BZ      $1,1F~%        MUL     $3,$3,$1~%        SUB     $1,$1,1~%        JMP     1B~%1H      TRAP    0,Halt,0~%")))
    (check mmixal-factorial
           (let ((vm (make-vm)))
             (load-mms vm fact)
             (run-vm vm)
             (reg vm 3))
           3628800)
    (check mmixal-write-mmo
           (let ((vm (make-vm)))
             (load-mmo vm (write-mmo fact))
             (run-vm vm)
             (reg vm 3))
           3628800))

  (check mmixal-greg
         (let* ((text (format nil "        LOC     Data_Segment~%base    GREG    @~%"))
                (image (nth-value 3 (assemble-mms text)))
                (vm (make-vm)))
           (load-mms vm text)
           (list (mmixal-image-rg image)
                 (gethash ":base" (mmixal-image-regs image))
                 (special-reg vm +r-g+)
                 (reg vm 254)))
         (list 254 254 254 #x2000000000000000))

  (check mmixal-local-branches
         (let* ((text (format nil "        LOC     #100~%1H      JMP     1F~%        SWYM~%1H      JMP     1B~%"))
                (bytes (cdr (first (assemble-mms text))))
                (word (lambda (i)
                        (logior (ash (aref bytes i) 24)
                                (ash (aref bytes (+ i 1)) 16)
                                (ash (aref bytes (+ i 2)) 8)
                                (aref bytes (+ i 3))))))
           (list (funcall word 0) (funcall word 4) (funcall word 8)))
         (list #xF0000002 #xFD000000 #xF1FFFFFE))

  (check mmixal-bspec
         (let* ((text (format nil "        LOC     #100~%        BSPEC   2~%        TETRA   #AABBCCDD~%        ESPEC~%        SETL    $1,7~%        TRAP    0,Halt,0~%"))
                (image (nth-value 3 (assemble-mms text)))
                (vm (make-vm)))
           (load-mms vm text)
           (run-vm vm)
           (list (reg vm 1)
                 (mem-ref-u32 vm #x100)
                 (mmixal-image-specs image)))
         (list 7 #xE3010007 '((:mode 2 :tetras (#xAABBCCDD)))))

  (check mmixal-expr
         (let ((vm (make-vm)))
           (load-mms vm (format nil "        LOC     #100~%        SETL    $1,(1<<4)|(4>>2)~%        SETL    $2,5%2~%        TRAP    0,Halt,0~%"))
           (run-vm vm)
           (list (reg vm 1) (reg vm 2)))
         (list 17 1))

  (check mmixal-byte-base
         (let ((vm (make-vm)))
           (load-mms vm (format nil "        LOC     Data_Segment~%base    GREG    @~%        BYTE    \"Hi\",0~%        LOC     #100~%        LDB     $1,Data_Segment~%        TRAP    0,Halt,0~%"))
           (run-vm vm)
           (reg vm 1))
         72)

  (check mmixal-prefix
         (let ((vm (make-vm)))
           (load-mms vm (format nil "        PREFIX  Foo:~%x       IS      7~%        PREFIX  :~%        LOC     #100~%        SETL    $1,Foo:x~%        TRAP    0,Halt,0~%"))
           (run-vm vm)
           (reg vm 1))
         7)

  (check mmixal-main
         (let ((vm (make-vm)))
           (load-mmo vm (write-mmo (format nil "        LOC     #100~%        SETL    $1,1~%Main    SETL    $3,42~%        TRAP    0,Halt,0~%")))
           (run-vm vm)
           (list (reg vm 1) (reg vm 3)))
         (list 0 42))

  (check mmixal-local-exceeds-rg
         (handler-case
             (assemble-mms (format nil "        LOCAL   $255~%"))
           (error () t))
         t)

  (check mmixal-bad-mnemonic
         (handler-case
             (assemble-mms (format nil "        LOC     #100~%        ADDI    $1,$2,1~%"))
           (error () t))
         t)

  (run-float-tests)

  (format t "~%Results: ~D passed, ~D failed~%" *pass* *fail*)
  (when *errors*
    (format t "Failures:~%")
    (dolist (e *errors*) (format t "  ~S~%" e)))
  (zerop *fail*)))
