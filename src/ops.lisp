(in-package #:cl-mmix)

(defun yz-operand (vm inst immediate)
  "Return $Y+$Z or $Y+Z depending on IMMEDIATE."
  (u64 (+ (reg vm (inst-y inst))
          (if immediate (inst-z inst) (reg vm (inst-z inst))))))

(defun z-operand (vm inst immediate)
  (if immediate (u64 (inst-z inst)) (reg vm (inst-z inst))))

(defun cmp-signed (a b)
  (let ((sa (i64-from-u64 a))
        (sb (i64-from-u64 b)))
    (cond ((< sa sb) (u64 -1))
          ((> sa sb) 1)
          (t 0))))

(defun cmp-unsigned (a b)
  (let ((a (u64 a)) (b (u64 b)))
    (cond ((< a b) (u64 -1))
          ((> a b) 1)
          (t 0))))

(defun branch-offset (inst)
  "Instruction-relative signed offset from YZ (in instructions)."
  (sign-extend16 (inst-yz inst)))

(defun take-branch (vm inst)
  (setf (vm-pc vm)
        (u64 (+ (vm-pc vm) (* 4 (branch-offset inst))))))

(defun reg-wyde-set (old yz shift)
  "SET*: replace the wyde at SHIFT bits with YZ, clear other bits (Knuth SET*)."
  (u64 (ash (u16 yz) shift)))

(defun reg-wyde-or (old yz shift)
  (u64 (logior (u64 old) (ash (u16 yz) shift))))

(defun reg-wyde-inc (old yz shift)
  (u64 (+ (u64 old) (ash (u16 yz) shift))))

(defparameter *echo-putchar* t
  "When true, TRAP putchar also writes to *standard-output*.")

(defun exec-trap (vm inst)
  "TRAP convention for this MVP:
   TRAP 0,0,0  — halt
   TRAP 0,1,Z  — putchar: emit low 8 bits of $Z (or Z if we used immediate; we use $Z)
   Other TRAPs halt with a note in output."
  (let ((x (inst-x inst))
        (y (inst-y inst))
        (z (inst-z inst)))
    (cond
      ((and (zerop x) (zerop y) (zerop z))
       (setf (vm-halted vm) t))
      ((and (zerop x) (= y 1))
       (let ((ch (code-char (u8 (reg vm z)))))
         (vector-push-extend ch (vm-output vm))
         (when *echo-putchar*
           (princ ch)
           (force-output))))
      (t
       (format (vm-output vm) "[TRAP ~D,~D,~D]" x y z)
       (setf (vm-halted vm) t)))))

(defun execute (vm inst)
  "Execute one decoded instruction. Advances or redirects PC."
  (let* ((op (inst-op inst))
         (name (op-name op))
         (x (inst-x inst))
         (y (inst-y inst))
         (z (inst-z inst))
         (yz (inst-yz inst))
         (next-pc (u64 (+ (vm-pc vm) 4)))
         (branched nil))
    (flet ((setx (v) (set-reg vm x v))
           (rx () (reg vm x))
           (ry () (reg vm y))
           (rz () (reg vm z)))
      (case name
        ((:trap)
         (exec-trap vm inst))

        ;; Arithmetic
        ((:add)  (setx (u64 (+ (ry) (rz)))))
        ((:addi) (setx (u64 (+ (ry) z))))
        ((:sub)  (setx (u64 (- (ry) (rz)))))
        ((:subi) (setx (u64 (- (ry) z))))
        ((:mul)  (setx (u64 (* (ry) (rz)))))
        ((:muli) (setx (u64 (* (ry) z))))
        ((:div)
         (let* ((a (ry)) (b (rz)))
           (if (zerop b)
               (progn (setx a) (set-special vm +r-r+ 0))
               (multiple-value-bind (q r) (truncate a b)
                 (setx (u64 q))
                 (set-special vm +r-r+ (u64 r))))))
        ((:divi)
         (let* ((a (ry)) (b (u64 z)))
           (if (zerop b)
               (progn (setx a) (set-special vm +r-r+ 0))
               (multiple-value-bind (q r) (truncate a b)
                 (setx (u64 q))
                 (set-special vm +r-r+ (u64 r))))))

        ;; Logic
        ((:and)  (setx (logand (ry) (rz))))
        ((:andi) (setx (logand (ry) z)))
        ((:or)   (setx (logior (ry) (rz))))
        ((:ori)  (setx (logior (ry) z)))
        ((:xor)  (setx (logxor (ry) (rz))))
        ((:xori) (setx (logxor (ry) z)))

        ;; Shifts (count mod 64 for MVP simplicity when using register)
        ((:sl)   (setx (ashu64 (ry) (mod (rz) 64))))
        ((:sli)  (setx (ashu64 (ry) (mod z 64))))
        ((:sr)   (setx (shar64 (ry) (mod (rz) 64))))
        ((:sri)  (setx (shar64 (ry) (mod z 64))))
        ((:sru)  (setx (shru64 (ry) (mod (rz) 64))))
        ((:srui) (setx (shru64 (ry) (mod z 64))))

        ;; Compare → -1 / 0 / 1
        ((:cmp)   (setx (cmp-signed (ry) (rz))))
        ((:cmpi)  (setx (cmp-signed (ry) z)))
        ((:cmpu)  (setx (cmp-unsigned (ry) (rz))))
        ((:cmpui) (setx (cmp-unsigned (ry) z)))

        ;; Loads: address = $Y + $Z or $Y + Z (unsigned immediate forms use Z)
        ;; Using register forms with addr = $Y+$Z; immediate load variants: $Y+Z
        ((:ldb)
         (let* ((addr (u64 (+ (ry) (rz))))
                (b (mem-ref-u8 vm addr)))
           (setx (if (logbitp 7 b) (u64 (logior b #xFFFFFFFFFFFFFF00)) b))))
        ((:ldbu)
         (setx (mem-ref-u8 vm (u64 (+ (ry) (rz))))))
        ((:ldw)
         (let* ((addr (u64 (+ (ry) (rz))))
                (w (mem-ref-u16 vm addr)))
           (setx (if (logbitp 15 w) (u64 (logior w #xFFFFFFFFFFFF0000)) w))))
        ((:ldwu)
         (setx (mem-ref-u16 vm (u64 (+ (ry) (rz))))))
        ((:ldo :ldou)
         (setx (mem-ref-u64 vm (u64 (+ (ry) (rz))))))

        ((:stb) (mem-set-u8  vm (u64 (+ (ry) (rz))) (rx)))
        ((:stw) (mem-set-u16 vm (u64 (+ (ry) (rz))) (rx)))
        ((:sto) (mem-set-u64 vm (u64 (+ (ry) (rz))) (rx)))

        ;; Branches
        ((:bn :pbn)
         (when (logbitp 63 (rx)) (take-branch vm inst) (setf branched t)))
        ((:bnz :pbnz)
         (when (not (zerop (rx))) (take-branch vm inst) (setf branched t)))
        ((:bz :pbz)
         (when (zerop (rx)) (take-branch vm inst) (setf branched t)))
        ((:bnn :pbnn)
         (when (not (logbitp 63 (rx))) (take-branch vm inst) (setf branched t)))
        ((:bp :pbp)
         (when (and (not (zerop (rx))) (not (logbitp 63 (rx))))
           (take-branch vm inst) (setf branched t)))
        ((:bnp :pbnp)
         (when (or (zerop (rx)) (logbitp 63 (rx)))
           (take-branch vm inst) (setf branched t)))
        ((:bod)
         (when (logbitp 0 (rx)) (take-branch vm inst) (setf branched t)))
        ((:bev)
         (when (not (logbitp 0 (rx))) (take-branch vm inst) (setf branched t)))

        ((:jmp)
         (setf (vm-pc vm) (u64 (+ (vm-pc vm) (* 4 (sign-extend24 (inst-xyz inst)))))
               branched t))

        ((:go)
         (set-special vm +r-j+ next-pc)
         (setx next-pc)
         (setf (vm-pc vm) (u64 (+ (ry) (rz)))
               branched t))
        ((:goi)
         (set-special vm +r-j+ next-pc)
         (setx next-pc)
         (setf (vm-pc vm) (u64 (+ (ry) z))
               branched t))

        ;; Wyde immediates
        ((:seth)  (setx (reg-wyde-set (rx) yz 48)))
        ((:setmh) (setx (reg-wyde-set (rx) yz 32)))
        ((:setml) (setx (reg-wyde-set (rx) yz 16)))
        ((:setl)  (setx (reg-wyde-set (rx) yz 0)))
        ((:inch)  (setx (reg-wyde-inc (rx) yz 48)))
        ((:incmh) (setx (reg-wyde-inc (rx) yz 32)))
        ((:incml) (setx (reg-wyde-inc (rx) yz 16)))
        ((:incl)  (setx (reg-wyde-inc (rx) yz 0)))
        ((:orh)   (setx (reg-wyde-or  (rx) yz 48)))
        ((:ormh)  (setx (reg-wyde-or  (rx) yz 32)))
        ((:orml)  (setx (reg-wyde-or  (rx) yz 16)))
        ((:orl)   (setx (reg-wyde-or  (rx) yz 0)))

        ((:geta)
         (setx (u64 (+ (vm-pc vm) (* 4 (sign-extend16 yz))))))

        (otherwise
         (error "Unimplemented opcode ~A (#x~2,'0X) at PC=#x~X"
                name op (vm-pc vm)))))
    (unless (or branched (vm-halted vm))
      (setf (vm-pc vm) next-pc))
    vm))

(defun step-vm (vm)
  "Fetch–decode–execute one instruction. Returns VM."
  (when (vm-halted vm)
    (return-from step-vm vm))
  (let* ((word (fetch vm))
         (inst (decode word)))
    (incf (vm-cycles vm))
    (execute vm inst)))

(defun run-vm (vm &key (max-cycles 100000))
  "Run until halt or MAX-CYCLES. Returns VM.
Signals an error if the cycle limit is hit without halt."
  (loop while (not (vm-halted vm))
        do (when (>= (vm-cycles vm) max-cycles)
             (error "VM exceeded max-cycles (~D) at PC=#x~X"
                    max-cycles (vm-pc vm)))
           (step-vm vm))
  vm)
