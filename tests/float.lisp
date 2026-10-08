(in-package #:cl-mmix/tests)

;;; IEEE cases for plan 01. Bit patterns only: no Lisp float is involved.
;;; +1, +2, +3, −1, 1.5, 2.5, −0, max finite, +inf, canonical NaN,
;;; 2^53, 2^63, 2^128.

(defun fp-run (forms &key (org 0) regs specials)
  (let ((vm (make-vm)))
    (assemble-into vm (list* 'program (list :org org)
                             (append forms '((trap 0 0 0)))))
    (set-special vm +r-l+ 16)
    (dolist (pair regs)
      (set-reg vm (car pair) (cdr pair)))
    (dolist (pair specials)
      (set-special vm (car pair) (cdr pair)))
    (run-vm vm)
    vm))

(defun fp-reg (forms &key (org 0) regs specials (dest 1))
  (let ((vm (fp-run forms :org org :regs regs :specials specials)))
    (unless (and (vm-halted vm) (null (vm-fault vm)))
      (error "fp program fault ~S pc #x~X" (vm-fault vm) (vm-pc vm)))
    (reg vm dest)))

(defun run-float-tests ()
  (format t "~%--- floating point ---~%")

  (check fpack-one
         (let ((cl-mmix::*fp-exceptions* 0))
           (cl-mmix::fpack (ash 1 54) #x3fe #\+ 4))
         #x3ff0000000000000)

  (check fadd-1-plus-2
         (fp-reg '((fadd $1 $2 $3))
                 :regs '((2 . #x3ff0000000000000)
                         (3 . #x4000000000000000)))
         #x4008000000000000)

  (check fsub-fmul-fdiv
         (list (fp-reg '((fsub $1 $2 $3))
                       :regs '((2 . #x4008000000000000)
                               (3 . #x3ff0000000000000)))
               (fp-reg '((fmul $1 $2 $3))
                       :regs '((2 . #x3ff8000000000000)
                               (3 . #x4000000000000000)))
               (fp-reg '((fdiv $1 $2 $3))
                       :regs '((2 . #x4008000000000000)
                               (3 . #x4000000000000000))))
         (list #x4000000000000000
               #x4008000000000000
               #x3ff8000000000000))

  (check fadd-cancel-rounding
         (loop for ra in '(0 #x10000 #x20000 #x30000)
               collect (fp-reg '((fadd $1 $2 $3))
                               :regs '((2 . #x3ff0000000000000)
                                       (3 . #xbff0000000000000))
                               :specials `((21 . ,ra))))
         (list 0 0 0 #x8000000000000000))

  (check fadd-zero-signs
         (loop for ra in '(0 #x10000 #x20000 #x30000)
               collect (fp-reg '((fadd $1 $2 $3))
                               :regs '((2 . 0)
                                       (3 . #x8000000000000000))
                               :specials `((21 . ,ra))))
         (list 0 0 0 #x8000000000000000))

  (check fint-ties-and-override
         (list (fp-reg '((fint $1 0 $2))
                       :regs '((2 . #x3ff8000000000000)))
               (fp-reg '((fint $1 0 $2))
                       :regs '((2 . #x4004000000000000)))
               (fp-reg '((fint $1 0 $2))
                       :regs '((2 . #x3ff8000000000000))
                       :specials '((21 . #x10000)))
               (fp-reg '((fint $1 4 $2))
                       :regs '((2 . #x3ff8000000000000))
                       :specials '((21 . #x10000))))
         (list #x4000000000000000
               #x4000000000000000
               #x3ff0000000000000
               #x4000000000000000))

  (check fadd-overflow-flags
         (let ((vm (fp-run '((fadd $1 $2 $3))
                           :regs '((2 . #x7fefffffffffffff)
                                   (3 . #x7fefffffffffffff)))))
           (list (reg vm 1)
                 (logand (special-reg vm +r-a+) #xff)
                 (vm-pc vm)
                 (vm-fault vm)
                 (vm-halted vm)))
         (list #x7ff0000000000000 #x09 4 nil t))

  (check fadd-overflow-trips-on-o
         (let ((vm (fp-run '((fadd $1 $2 $3))
                           :org #x200
                           :regs '((2 . #x7fefffffffffffff)
                                   (3 . #x7fefffffffffffff))
                           :specials '((21 . #x800)))))
           (list (vm-pc vm)
                 (reg vm 1)
                 (logand (special-reg vm +r-a+) #xffff)
                 (special-reg vm +r-w+)
                 (vm-fault vm)))
         (list 80 #x7ff0000000000000 #x809 #x204 nil))

  (check fadd-overflow-o-beats-x
         (let ((vm (fp-run '((fadd $1 $2 $3))
                           :org #x200
                           :regs '((2 . #x7fefffffffffffff)
                                   (3 . #x7fefffffffffffff))
                           :specials '((21 . #x900)))))
           (vm-pc vm))
         80)

  (check fdiv-by-zero
         (let ((pos (fp-run '((fdiv $1 $2 $3))
                            :regs '((2 . #x3ff0000000000000) (3 . 0))))
               (neg (fp-run '((fdiv $1 $2 $3))
                            :regs '((2 . #xbff0000000000000) (3 . 0))))
               (nan (fp-run '((fdiv $1 $2 $3))
                            :regs '((2 . 0) (3 . 0)))))
           (list (reg pos 1) (logand (special-reg pos +r-a+) #xff)
                 (reg neg 1) (logand (special-reg neg +r-a+) #xff)
                 (reg nan 1) (logand (special-reg nan +r-a+) #xff)))
         (list #x7ff0000000000000 #x02
               #xfff0000000000000 #x02
               #x7ff8000000000000 #x10))

  (check fsqrt-negative
         (let ((vm (fp-run '((fsqrt $1 0 $2))
                           :regs '((2 . #xbff0000000000000))))
               (neg0 (fp-run '((fsqrt $1 0 $2))
                             :regs '((2 . #x8000000000000000)))))
           (list (reg vm 1) (logand (special-reg vm +r-a+) #xff)
                 (reg neg0 1) (logand (special-reg neg0 +r-a+) #xff)))
         (list #xfff8000000000000 #x10
               #x8000000000000000 0))

  (check frem-large
         (fp-reg '((frem $1 $2 $3))
                 :regs '((2 . #x4340000000000000)
                         (3 . #x4008000000000000)))
         #xbff0000000000000)

  (check fcmp-family
         (let ((nan #x7ff8000000000000)
               (one #x3ff0000000000000)
               (three #x4008000000000000))
           (list (fp-reg '((fcmp $1 $2 $3)) :regs `((2 . ,one) (3 . ,three)))
                 (let ((vm (fp-run '((fcmp $1 $2 $3)) :regs `((2 . ,nan) (3 . ,one)))))
                   (list (reg vm 1) (logand (special-reg vm +r-a+) #xff)))
                 (let ((vm (fp-run '((feql $1 $2 $3)) :regs `((2 . ,nan) (3 . ,nan)))))
                   (list (reg vm 1) (logand (special-reg vm +r-a+) #xff)))
                 (let ((vm (fp-run '((fun $1 $2 $3)) :regs `((2 . ,nan) (3 . ,one)))))
                   (list (reg vm 1) (logand (special-reg vm +r-a+) #xff)))
                 (fp-reg '((fcmp $1 $2 $3))
                         :regs '((2 . #x8000000000000000) (3 . 0)))))
         (list (u64 -1)
               (list 0 #x10)
               (list 0 0)
               (list 1 0)
               0))

  (check fcmpe-and-feqle
         (let ((one #x3ff0000000000000)
               (three #x4008000000000000)
               (two #x4000000000000000))
           (list (fp-reg '((fcmpe $1 $2 $3))
                         :regs `((2 . ,one) (3 . ,three))
                         :specials `((2 . ,two)))
                 (fp-reg '((fcmpe $1 $2 $3))
                         :regs `((2 . ,one) (3 . ,three)))
                 (fp-reg '((feqle $1 $2 $3))
                         :regs `((2 . ,one) (3 . ,three))
                         :specials `((2 . ,two)))
                 (fp-reg '((feqle $1 $2 $3))
                         :regs `((2 . ,one) (3 . ,three)))
                 (let ((vm (fp-run '((fune $1 $2 $3))
                                   :regs `((2 . #x7ff8000000000000) (3 . ,one)))))
                   (list (reg vm 1) (logand (special-reg vm +r-a+) #xff)))))
         (list 0 (u64 -1) 1 0 (list 1 0)))

  (check ldsf-stsf-roundtrip
         (let ((vm (fp-run '((stsf $1 $0 $0) (ldsf $2 $0 $0))
                           :regs '((1 . #x3ff0000000000000)))))
           (list (mem-ref-u32 vm 0) (reg vm 2) (vm-mems vm)
                 (logand (special-reg vm +r-a+) #xff)))
         (list #x3f800000 #x3ff0000000000000 2 0))

  (check stsf-overflow-sets-ox
         (let ((vm (fp-run '((stsf $1 $2 $3))
                           :regs '((1 . #x47f0000000000000)
                                   (2 . 2)
                                   (3 . 0)))))
           (list (mem-ref-u32 vm 0)
                 (logand (special-reg vm +r-a+) #xff)
                 (reg vm 1)))
         (list #x7f800000 #x09 #x47f0000000000000))

  (check fix-and-fixu-2-63
         (list (let ((vm (fp-run '((fix $1 0 $2))
                                 :regs '((2 . #x43e0000000000000)))))
                 (list (reg vm 1) (logand (special-reg vm +r-a+) #xff)))
               (let ((vm (fp-run '((fixu $1 0 $2))
                                 :regs '((2 . #x43e0000000000000)))))
                 (list (reg vm 1) (logand (special-reg vm +r-a+) #xff))))
         (list (list #x8000000000000000 #x20)
               (list #x8000000000000000 0)))

  (check flot-and-sflot
         (list (fp-reg '((flot $1 0 $2)) :regs '((2 . 3)))
               (fp-reg '((floti $1 0 3)))
               (fp-reg '((flot $1 0 $2)) :regs '((2 . #xfffffffffffffffd)))
               (fp-reg '((flotu $1 0 $2))
                       :regs '((2 . #x8000000000000000)))
               (let ((vm (fp-run '((sflot $1 0 $2))
                                 :regs '((2 . 16777217)))))
                 (list (reg vm 1) (logand (special-reg vm +r-a+) #xff))))
         (list #x4008000000000000
               #x4008000000000000
               #xc008000000000000
               #x43e0000000000000
               (list #x4170000000000000 #x01)))

  (check exact-tiny-suppresses-u
         (let ((vm (fp-run '((fadd $1 $2 $3))
                           :regs '((2 . 0) (3 . 1)))))
           (list (reg vm 1) (special-reg vm +r-a+)))
         (list 1 0))

  (check exact-tiny-trips-when-u-enabled
         (let ((vm (fp-run '((fadd $1 $2 $3))
                           :org #x200
                           :regs '((2 . 0) (3 . 1))
                           :specials '((21 . #x400)))))
           (list (vm-pc vm) (reg vm 1) (logand (special-reg vm +r-a+) #xffff)))
         (list 96 1 #x404))

  (check illegal-rounding-mode
         (let ((vm (make-vm)))
           (assemble-into vm '(program (:org 0) (fsqrt $1 5 $2) (trap 0 0 0)))
           (set-reg vm 2 #x3ff0000000000000)
           (run-vm vm)
           (list (vm-halted vm)
                 (and (vm-fault vm) (search "rounding" (vm-fault vm)) t)
                 (reg vm 1)))
         (list t t 0))

  (check integer-add-leaves-ra
         (let ((vm (fp-run '((add $1 $2 $3))
                           :regs '((2 . 4) (3 . 5)))))
           (list (reg vm 1) (special-reg vm +r-a+)))
         (list 9 0))

  (check signaling-nan-is-quieted
         (let ((vm (fp-run '((fadd $1 $2 $3))
                           :regs '((2 . #x7ff0000000000001)
                                   (3 . #x3ff0000000000000)))))
           (list (reg vm 1) (logand (special-reg vm +r-a+) #xff)))
         (list #x7ff8000000000001 #x10)))
