(in-package #:cl-mmix)

(defun y-operand (vm inst)
  "Register $Y, or rY when RESUME ropcode 1 is inserting this instruction."
  (if *yz-override*
      (car *yz-override*)
      (reg vm (inst-y inst))))

(defun z-operand (vm inst)
  "Register $Z or the immediate Z field. RESUME ropcode 1 substitutes rZ."
  (cond (*yz-override* (cdr *yz-override*))
        ((oddp (inst-op inst)) (inst-z inst))
        (t (reg vm (inst-z inst)))))

(defun eff-addr (vm inst)
  (u64 (+ (y-operand vm inst) (z-operand vm inst))))

(defun aligned-addr (vm inst shift)
  (logand (eff-addr vm inst) (lognot (1- (ash 1 shift)))))

(defun cond-holds (pred value)
  "Branch/CS/ZS predicate. 0 N, 1 Z, 2 P, 3 OD, 4 NN, 5 NZ, 6 NP, 7 EV."
  (ecase pred
    (0 (logbitp 63 value))
    (1 (zerop value))
    (2 (and (not (zerop value)) (not (logbitp 63 value))))
    (3 (logbitp 0 value))
    (4 (not (logbitp 63 value)))
    (5 (not (zerop value)))
    (6 (or (zerop value) (logbitp 63 value)))
    (7 (not (logbitp 0 value)))))

(defun pred-index (op base)
  (- (ash (logand op #xFE) -1) (ash base -1)))

(defun maybe-trip (tripped)
  (if tripped :jump nil))

(defun unimplemented (what)
  (error 'mmix-fault :reason (format nil "~A is not implemented" what)))

(defun marginal-reg-p (vm n)
  "True when $N is neither local nor global."
  (let ((n (u8 n)))
    (and (>= n (reg-l vm)) (< n (reg-g vm)))))

(defun exec-muldiv (vm inst)
  (let* ((op (logand (inst-op inst) #xFE))
         (y (y-operand vm inst))
         (z (z-operand vm inst))
         (x (inst-x inst)))
    (ecase op
      (#x18
       (let ((p (* (i64-from-u64 y) (i64-from-u64 z))))
         (set-reg vm x (u64 p))
         (when (not (<= +i64-min+ p +i64-max+))
           (return-from exec-muldiv
             (maybe-trip (signal-event vm +ev-v+ :y y :z z :inst (inst-raw inst)))))))
      (#x1A
       (let ((p (* y z)))
         (set-reg vm x (u64 p))
         (set-special vm +r-h+ (u64 (ash p -64)))))
      (#x1C
       (multiple-value-bind (q r cond) (div-floor-u64 y z)
         (set-reg vm x q)
         (set-special vm +r-r+ r)
         (when cond
           (return-from exec-muldiv
             (maybe-trip (signal-event vm (if (eq cond :div0) +ev-d+ +ev-v+)
                                        :y y :z z :inst (inst-raw inst)))))))
      (#x1E
       (multiple-value-bind (q r cond)
           (divu-u64 (special-reg vm +r-d+) y z)
         (set-reg vm x q)
         (set-special vm +r-r+ r)
         (when cond
           (return-from exec-muldiv
             (maybe-trip (signal-event vm +ev-d+ :y y :z z :inst (inst-raw inst))))))))
  nil))

(defun exec-add (vm inst)
  (let* ((op (logand (inst-op inst) #xFE))
         (y (y-operand vm inst))
         (z (z-operand vm inst))
         (x (inst-x inst)))
    (cond
      ((or (= op #x20) (= op #x24))
       (multiple-value-bind (result ov)
           (if (= op #x20) (add-u64 y z) (sub-u64 y z))
         (set-reg vm x result)
         (when ov
           (return-from exec-add
             (maybe-trip (signal-event vm +ev-v+ :y y :z z :inst (inst-raw inst)))))))
      ((= op #x22) (set-reg vm x (u64 (+ y z))))
      ((= op #x26) (set-reg vm x (u64 (- y z))))
      (t (let ((shift (1+ (ash (- op #x28) -1))))
           (set-reg vm x (u64 (+ (ash y shift) z)))))))
  nil)

(defun exec-cmp-neg (vm inst)
  (let* ((op (logand (inst-op inst) #xFE))
         (x (inst-x inst)))
    (cond
      ((or (= op #x30) (= op #x32))
       (let ((y (y-operand vm inst))
             (z (z-operand vm inst)))
         (set-reg vm x (if (= op #x30) (cmp-signed y z) (cmp-unsigned y z)))))
      (t
       ;; NEG/NEGU: Y is an unsigned byte even in the register form.
       ;; Ropcode 1 substitutes the full rY octa for that byte.
       (let* ((y (if *yz-override* (car *yz-override*) (inst-y inst)))
              (z (z-operand vm inst))
              (math (- (i64-from-u64 (u64 y)) (i64-from-u64 z))))
         (set-reg vm x (u64 math))
         (when (and (= op #x34)
                    (not (<= +i64-min+ math +i64-max+)))
           (return-from exec-cmp-neg
             (maybe-trip (signal-event vm +ev-v+ :y y :z z :inst (inst-raw inst))))))))
  nil))

(defun cmp-signed (a b)
  (let ((sa (i64-from-u64 a))
        (sb (i64-from-u64 b)))
    (cond ((< sa sb) (u64 -1))
          ((> sa sb) 1)
          (t 0))))

(defun cmp-unsigned (a b)
  (cond ((< a b) (u64 -1))
        ((> a b) 1)
        (t 0)))

(defun exec-shift (vm inst)
  (let* ((op (logand (inst-op inst) #xFE))
         (y (y-operand vm inst))
         (count (z-operand vm inst))
         (x (inst-x inst)))
    (ecase op
      (#x38
       (multiple-value-bind (result ov) (sl-signed y count)
         (set-reg vm x result)
         (when ov
           (return-from exec-shift
             (maybe-trip (signal-event vm +ev-v+ :y y :z count :inst (inst-raw inst)))))))
      (#x3A (set-reg vm x (if (>= count 64) 0 (ashu64 y count))))
      (#x3C (set-reg vm x (sr-signed y count)))
      (#x3E (set-reg vm x (if (>= count 64) 0 (shru64 y count))))))
  nil)

(defun exec-branch (vm inst)
  (let* ((op (inst-op inst))
         (pred (pred-index op (if (>= op #x50) #x50 #x40)))
         (disp (relative-disp (inst-yz inst) 16 (oddp op))))
    (when (cond-holds pred (reg vm (inst-x inst)))
      (setf (vm-pc vm) (u64 (+ (vm-pc vm) (* 4 disp))))
      (return-from exec-branch :jump)))
  nil)

(defun exec-condset (vm inst)
  (let* ((op (inst-op inst))
         (pred (pred-index op (if (>= op #x70) #x70 #x60)))
         (hold (cond-holds pred (y-operand vm inst)))
         (z (z-operand vm inst)))
    (cond
      ((< op #x70)
       (when hold (set-reg vm (inst-x inst) z)))
      (t (set-reg vm (inst-x inst) (if hold z 0)))))
  nil)

(defun exec-logic (vm inst)
  (let* ((op (logand (inst-op inst) #xFE))
         (y (y-operand vm inst))
         (z (z-operand vm inst))
         (notz (logxor z +u64-mask+)))
    (set-reg vm (inst-x inst)
             (ecase op
               (#xC0 (logior y z))
               (#xC2 (logior y notz))
               (#xC4 (logxor (logior y z) +u64-mask+))
               (#xC6 (logxor y z))
               (#xC8 (logand y z))
               (#xCA (logand y notz))
               (#xCC (logxor (logand y z) +u64-mask+))
               (#xCE (logxor (logxor y z) +u64-mask+))
               (#xD0 (dif-slices y z 8))
               (#xD2 (dif-slices y z 16))
               (#xD4 (dif-slices y z 32))
               (#xD6 (dif-slices y z 64))
               (#xD8 (let ((m (special-reg vm +r-m+)))
                       (logior (logand y m)
                               (logand z (logxor m +u64-mask+)))))
               (#xDA (logcount (logand y notz)))
               (#xDC (mor-octa y z))
               (#xDE (mor-octa y z :xor t)))))
  nil)

(defun read-int (vm addr bytes)
  (ecase bytes
    (1 (mem-ref-u8 vm addr))
    (2 (mem-ref-u16 vm addr))
    (4 (mem-ref-u32 vm addr))
    (8 (mem-ref-u64 vm addr))))

(defun write-int (vm addr bytes value)
  (ecase bytes
    (1 (mem-set-u8 vm addr value))
    (2 (mem-set-u16 vm addr value))
    (4 (mem-set-u32 vm addr value))
    (8 (mem-set-u64 vm addr value))))

(defun sign-extend-width (raw bytes)
  (let ((bits (* 8 bytes)))
    (if (logbitp (1- bits) raw)
        (u64 (logior raw (ash -1 bits)))
        raw)))

(defun exec-load (vm inst bytes signed)
  (incf (vm-mems vm))
  (let* ((addr (aligned-addr vm inst (floor (log bytes 2))))
         (raw (read-int vm addr bytes)))
    (set-reg vm (inst-x inst)
             (if (and signed (< bytes 8))
                 (sign-extend-width raw bytes)
                 raw)))
  nil)

(defun exec-store (vm inst bytes signed)
  (incf (vm-mems vm))
  (let* ((val (reg vm (inst-x inst)))
         (addr (aligned-addr vm inst (floor (log bytes 2))))
         (tripped nil))
    (when (and signed (< bytes 8)
               (not (fits-signed-p val (* 8 bytes))))
      (setf tripped (signal-event vm +ev-v+
                                  :y (eff-addr vm inst)
                                  :z val
                                  :inst (inst-raw inst))))
    (write-int vm addr bytes val)
    (maybe-trip tripped)))

(defun exec-go (vm inst)
  (let* ((next (u64 (+ (vm-pc vm) 4)))
         (addr (logand (eff-addr vm inst) (lognot 3))))
    (set-reg vm (inst-x inst) next)
    (setf (vm-pc vm) addr))
  :jump)

(defun exec-pushgo (vm inst)
  (let* ((next (u64 (+ (vm-pc vm) 4)))
         (addr (logand (eff-addr vm inst) (lognot 3))))
    (push-frame vm (inst-x inst))
    (set-special vm +r-j+ next)
    (setf (vm-pc vm) addr))
  :jump)

(defun exec-cswap (vm inst)
  (incf (vm-mems vm))
  (let* ((addr (aligned-addr vm inst 3))
         (mem (mem-ref-u64 vm addr))
         (rp (special-reg vm +r-p+)))
    (if (= mem rp)
        (progn
          (mem-set-u64 vm addr (reg vm (inst-x inst)))
          (set-reg vm (inst-x inst) 1))
        (progn
          (set-special vm +r-p+ mem)
          (set-reg vm (inst-x inst) 0))))
  nil)

(defun exec-mem (vm inst)
  (let ((op (logand (inst-op inst) #xFE)))
    (case op
      (#x80 (exec-load vm inst 1 t))
      (#x82 (exec-load vm inst 1 nil))
      (#x84 (exec-load vm inst 2 t))
      (#x86 (exec-load vm inst 2 nil))
      (#x88 (exec-load vm inst 4 t))
      (#x8A (exec-load vm inst 4 nil))
      ((#x8C #x8E #x96) (exec-load vm inst 8 nil))
      (#x90 (exec-ldsf vm inst))
      (#x92 (progn
              (incf (vm-mems vm))
              (set-reg vm (inst-x inst)
                       (ash (mem-ref-u32 vm (aligned-addr vm inst 2)) 32))
              nil))
      (#x94 (exec-cswap vm inst))
      (#x98 (progn (set-reg vm (inst-x inst) 0) nil))
      ((#x9A #x9C) nil)
      (#x9E (exec-go vm inst))
      (#xA0 (exec-store vm inst 1 t))
      (#xA2 (exec-store vm inst 1 nil))
      (#xA4 (exec-store vm inst 2 t))
      (#xA6 (exec-store vm inst 2 nil))
      (#xA8 (exec-store vm inst 4 t))
      (#xAA (exec-store vm inst 4 nil))
      ((#xAC #xAE #xB6) (exec-store vm inst 8 nil))
      (#xB0 (exec-stsf vm inst))
      (#xB2 (progn
              (incf (vm-mems vm))
              (mem-set-u32 vm (aligned-addr vm inst 2)
                           (ldb (byte 32 32) (reg vm (inst-x inst))))
              nil))
      (#xB4 (progn
              (incf (vm-mems vm))
              (mem-set-u64 vm (aligned-addr vm inst 3) (inst-x inst))
              nil))
      ((#xB8 #xBA #xBC) nil)
      (#xBE (exec-pushgo vm inst))
      (t (unimplemented (symbol-name (op-name (inst-op inst))))))))

(defun wyde-field (op yz)
  (ash (u16 yz)
       (ecase (ldb (byte 2 0) op)
         (0 48) (1 32) (2 16) (3 0))))

(defun exec-wyde (vm inst)
  (let* ((op (inst-op inst))
         (group (ldb (byte 2 2) op))
         (y (if *yz-override* (car *yz-override*) (reg vm (inst-x inst))))
         (z (if *yz-override*
                (cdr *yz-override*)
                (wyde-field op (inst-yz inst)))))
    ;; SET ignores Y. INC/OR/ANDN use the previous $X, unless ropcode 1
    ;; supplied rY in its place.
    (set-reg vm (inst-x inst)
             (ecase group
               (0 z)
               (1 (u64 (+ y z)))
               (2 (logior y z))
               (3 (logand y (logxor z +u64-mask+))))))
  nil)

(defun exec-jump (vm inst)
  (let ((disp (relative-disp (inst-xyz inst) 24 (= (inst-op inst) #xF1))))
    (setf (vm-pc vm) (u64 (+ (vm-pc vm) (* 4 disp)))))
  :jump)

(defun exec-pushj (vm inst)
  (let* ((next (u64 (+ (vm-pc vm) 4)))
         (disp (relative-disp (inst-yz inst) 16 (oddp (inst-op inst))))
         (target (u64 (+ (vm-pc vm) (* 4 disp)))))
    (push-frame vm (inst-x inst))
    (set-special vm +r-j+ next)
    (setf (vm-pc vm) target))
  :jump)

(defun exec-geta (vm inst)
  (let ((disp (relative-disp (inst-yz inst) 16 (oddp (inst-op inst)))))
    (set-reg vm (inst-x inst) (u64 (+ (vm-pc vm) (* 4 disp)))))
  nil)

(defun rop-nybble-ok-p (op)
  "Ropcode 1 allows high nybbles #x0–#x3, #x6, #x7, #xC, #xD, and #xE."
  (member (ash (u8 op) -4) '(0 1 2 3 6 7 12 13 14)))

(defun finish-inserted (vm rw effect)
  "After an inserted instruction: keep a jump or a halt, otherwise go to rW."
  (cond
    ((or (eq effect :jump) (eq effect :stop) (vm-halted vm))
     (or effect :stop))
    (t
     (setf (vm-pc vm) rw)
     :jump)))

(defun exec-inserted (vm tetra rop)
  "Execute TETRA as though it occupied rW−4. ROP 1 substitutes rY and rZ."
  (let ((inst (decode tetra))
        (rw (special-reg vm +r-w+)))
    (when (and (= rop 1)
               (or (not (rop-nybble-ok-p (inst-op inst)))
                   (marginal-reg-p vm (inst-x inst))))
      (illegal-instruction))
    (when (= (inst-op inst) #xF9)
      (illegal-instruction))
    (setf (vm-pc vm) (u64 (- rw 4)))
    (finish-inserted
     vm rw
     (if (= rop 1)
         (let ((*yz-override* (cons (special-reg vm +r-y+)
                                    (special-reg vm +r-z+))))
           (execute vm inst))
         (execute vm inst)))))

(defun exec-resume-set (vm rx)
  "Ropcode 2: $X ← rZ, then raise the exception bits in bits 47–40 of rX.
$X must not be marginal. An enabled bit trips from rW−4."
  (let* ((tetra (logand rx #xffffffff))
         (x (ldb (byte 8 16) tetra))
         (bits (suppress-exact-underflow vm (logand (ash rx -40) #xff)))
         (ry (special-reg vm +r-y+))
         (rz (special-reg vm +r-z+))
         (rw (special-reg vm +r-w+)))
    (when (marginal-reg-p vm x)
      (illegal-instruction))
    (set-reg vm x rz)
    (setf (vm-pc vm) (u64 (- rw 4)))
    (if (signal-events vm bits :y ry :z rz :inst tetra)
        :jump
        (progn
          (setf (vm-pc vm) rw)
          :jump))))

(defun exec-resume (vm inst)
  "RESUME 0. A negative rX returns to rW. Otherwise insert rX under its ropcode.
Z ≠ 0 is still the unimplemented RESUME 1 path. A nonzero X or Y field, a
ropcode above 2, and ropcode 3 are illegal."
  (cond
    ((not (zerop (inst-z inst)))
     (unimplemented "RESUME with a nonzero XYZ"))
    ((or (not (zerop (inst-x inst)))
         (not (zerop (inst-y inst))))
     (illegal-instruction))
    (t
     (let ((rx (special-reg vm +r-x+)))
       (if (logbitp 63 rx)
           (progn
             (setf (vm-pc vm) (special-reg vm +r-w+))
             :jump)
           (case (ldb (byte 8 56) rx)
             (0 (exec-inserted vm (logand rx #xffffffff) 0))
             (1 (exec-inserted vm (logand rx #xffffffff) 1))
             (2 (exec-resume-set vm rx))
             (t (illegal-instruction))))))))

(defun execute (vm inst)
  "Execute one instruction. Returns :JUMP, :STOP, or NIL (fall through)."
  (let ((op (inst-op inst)))
    (cond
      ((= op #x00) (exec-trap vm inst))
      ((<= #x01 op #x17) (exec-float vm inst))
      ((<= #x18 op #x1F) (exec-muldiv vm inst))
      ((<= #x20 op #x2F) (exec-add vm inst))
      ((<= #x30 op #x37) (exec-cmp-neg vm inst))
      ((<= #x38 op #x3F) (exec-shift vm inst))
      ((<= #x40 op #x5F) (exec-branch vm inst))
      ((<= #x60 op #x7F) (exec-condset vm inst))
      ((<= #x80 op #xBF) (exec-mem vm inst))
      ((<= #xC0 op #xDF) (exec-logic vm inst))
      ((<= #xE0 op #xEF) (exec-wyde vm inst))
      ((or (= op #xF0) (= op #xF1)) (exec-jump vm inst))
      ((or (= op #xF2) (= op #xF3)) (exec-pushj vm inst))
      ((or (= op #xF4) (= op #xF5)) (exec-geta vm inst))
      ((= op #xF6)
       (unless (zerop (inst-y inst)) (illegal-instruction))
       (put-special vm (inst-x inst) (reg vm (inst-z inst)))
       nil)
      ((= op #xF7)
       (unless (zerop (inst-y inst)) (illegal-instruction))
       (put-special vm (inst-x inst) (inst-z inst))
       nil)
      ((= op #xF8)
       (pop-frame vm (inst-x inst))
       (setf (vm-pc vm)
             (u64 (+ (special-reg vm +r-j+) (* 4 (inst-yz inst)))))
       :jump)
      ((= op #xF9) (exec-resume vm inst))
      ((= op #xFA)
       (unless (and (zerop (inst-y inst)) (zerop (inst-z inst)))
         (illegal-instruction))
       (save-context vm (inst-x inst))
       nil)
      ((= op #xFB)
       (unless (and (zerop (inst-x inst)) (zerop (inst-y inst)))
         (illegal-instruction))
       (unsave-context vm (reg vm (inst-z inst)))
       nil)
      ((or (= op #xFC) (= op #xFD)) nil)
      ((= op #xFE)
       (unless (zerop (inst-y inst)) (illegal-instruction))
       (set-reg vm (inst-x inst) (special-reg vm (inst-z inst)))
       nil)
      ((= op #xFF)
       (if (do-trip vm 0
                    :y (reg vm (inst-y inst))
                    :z (reg vm (inst-z inst))
                    :inst (inst-raw inst))
           :jump
           nil))
      (t (unimplemented (format nil "opcode #x~2,'0X" op))))))

(defun step-vm (vm)
  "Fetch–decode–execute one instruction. An execute breakpoint stops first.
Calling STEP-VM again while stopped executes that instruction."
  (when (vm-halted vm)
    (return-from step-vm vm))
  (let ((skip (or (vm-break-skip vm) (not (null (vm-break vm))))))
    (setf (vm-break vm) nil
          (vm-break-skip vm) nil)
    (when (and (not skip) (vm-watches vm))
      (dolist (w (vm-watches vm))
        (when (and (eq (car w) :exec) (= (cdr w) (logand (vm-pc vm) (lognot 3))))
          (setf (vm-break vm) (list :exec (vm-pc vm)))
          (return-from step-vm vm)))))
  (setf (vm-watch-hit vm) nil)
  ;; An execute breakpoint returned above and did not retire. rI and rU
  ;; advance only after a successful execute, beside this cycle count.
  ;; A fault does not retire. One rI tick is one instruction until plan 08.
  (incf (vm-cycles vm))
  (let ((retired-pc (vm-pc vm)))
    (handler-case
        (let* ((word (fetch vm))
               (inst (decode word))
               (effect (execute vm inst)))
          (unless (or (eq effect :jump) (eq effect :stop) (vm-halted vm))
            (setf (vm-pc vm) (u64 (+ (vm-pc vm) 4))))
          (note-usage vm (inst-op inst) retired-pc)
          (tick-interval vm))
      (mmix-fault (e)
        (setf (vm-fault vm) (mmix-fault-reason e)
              (vm-halted vm) t))))
  (when (and (vm-watch-hit vm) (not (vm-halted vm)))
    (setf (vm-break vm) (vm-watch-hit vm)))
  vm)

(defun run-vm (vm &key (max-cycles 100000))
  "Run until halt, breakpoint, or MAX-CYCLES.
Signals an error if the cycle limit is hit without halt or a breakpoint."
  (loop
    (when (or (vm-halted vm) (vm-break vm))
      (return vm))
    (when (>= (vm-cycles vm) max-cycles)
      (error "VM exceeded max-cycles (~D) at PC=#x~X" max-cycles (vm-pc vm)))
    (step-vm vm))
  vm)

(defun continue-vm (vm &rest keys &key &allow-other-keys)
  "Resume after a breakpoint, then run like RUN-VM."
  (when (vm-break vm)
    (setf (vm-break-skip vm) t
          (vm-break vm) nil))
  (apply #'run-vm vm keys))
