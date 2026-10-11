(in-package #:cl-mmix)

;;; Defined in src/translate.lisp.
(declaim (ftype (function (t) t) drop-translation-caches)
         (ftype (function (t t t t) t) install-resumed-translation)
         (ftype (function (t t) (unsigned-byte 64)) ldvts)
         (ftype (function (t t t) (values t t &optional)) translate))

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
  (prog1
      (ecase bytes
        (1 (mem-ref-u8 vm addr))
        (2 (mem-ref-u16 vm addr))
        (4 (mem-ref-u32 vm addr))
        (8 (mem-ref-u64 vm addr)))
    (clear-vm-fence vm)))

(defun write-int (vm addr bytes value)
  (prog1
      (ecase bytes
        (1 (mem-set-u8 vm addr value))
        (2 (mem-set-u16 vm addr value))
        (4 (mem-set-u32 vm addr value))
        (8 (mem-set-u64 vm addr value)))
    (clear-vm-fence vm)))

(defun sign-extend-width (raw bytes)
  (let ((bits (* 8 bytes)))
    (if (logbitp (1- bits) raw)
        (u64 (logior raw (ash -1 bits)))
        raw)))

(defun exec-load (vm inst bytes signed)
  (let* ((addr (aligned-addr vm inst (floor (log bytes 2))))
         (raw (read-int vm addr bytes)))
    (incf (vm-mems vm))
    (set-reg vm (inst-x inst)
             (if (and signed (< bytes 8))
                 (sign-extend-width raw bytes)
                 raw)))
  nil)

(defun exec-store (vm inst bytes signed)
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
    (incf (vm-mems vm))
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
  (let ((addr (aligned-addr vm inst 3)))
    (when (and (vm-virtual-memory vm)
               (not (nth-value 1 (translate vm addr :cswap))))
      (incf (vm-mems vm))
      (clear-vm-fence vm)
      (set-reg vm (inst-x inst) 0)
      (return-from exec-cswap nil)))
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
  (clear-vm-fence vm)
  nil)

(defun exec-ldunc (vm inst)
  "Read memory and do not allocate a cache line."
  (set-reg vm (inst-x inst) (backing-load vm (aligned-addr vm inst 3) 8))
  (clear-vm-fence vm)
  (incf (vm-mems vm))
  nil)

(defun exec-stunc (vm inst)
  "Write memory and drop the matching data-cache line."
  (backing-store vm (aligned-addr vm inst 3) 8 (reg vm (inst-x inst)))
  (clear-vm-fence vm)
  (incf (vm-mems vm))
  nil)

(defun span-count (inst)
  (1+ (inst-x inst)))

(defun exec-prefetch (vm inst which)
  (when (vm-caches vm)
    (cache-prefetch vm which (eff-addr vm inst) (span-count inst)))
  (clear-vm-fence vm)
  nil)

(defun exec-syncd (vm inst)
  (when (vm-caches vm)
    (cache-syncd vm (eff-addr vm inst) (span-count inst)))
  (clear-vm-fence vm)
  nil)

(defun exec-syncid (vm inst)
  (when (vm-caches vm)
    (cache-syncid vm (eff-addr vm inst) (span-count inst)))
  (clear-vm-fence vm)
  nil)

(defun sync-k-enabled-p (vm)
  "XYZ ≥ 4 is privileged while rK's k bit is set at a nonnegative PC."
  (and (vm-kernel vm)
       (logtest (special-reg vm +r-k+) +rq-k+)
       (not (logbitp 63 (vm-pc vm)))))

(defun exec-mem (vm inst)
  (let ((op (logand (inst-op inst) #xFE)))
    (case op
      (#x80 (exec-load vm inst 1 t))
      (#x82 (exec-load vm inst 1 nil))
      (#x84 (exec-load vm inst 2 t))
      (#x86 (exec-load vm inst 2 nil))
      (#x88 (exec-load vm inst 4 t))
      (#x8A (exec-load vm inst 4 nil))
      ((#x8C #x8E) (exec-load vm inst 8 nil))
      (#x96 (if (vm-caches vm)
                (exec-ldunc vm inst)
                (exec-load vm inst 8 nil)))
      (#x90 (exec-ldsf vm inst))
      (#x92 (progn
              (incf (vm-mems vm))
              (set-reg vm (inst-x inst)
                       (ash (mem-ref-u32 vm (aligned-addr vm inst 2)) 32))
              (clear-vm-fence vm)
              nil))
      (#x94 (exec-cswap vm inst))
      (#x98 (progn
              (cond ((not (vm-virtual-memory vm))
                     (set-reg vm (inst-x inst) 0))
                    ((not (logbitp 63 (vm-pc vm)))
                     (error 'mmix-suppress :bit +rq-k+))
                    (t
                     (set-reg vm (inst-x inst) (ldvts vm (eff-addr vm inst)))))
              nil))
      (#x9A (exec-prefetch vm inst :data))
      (#x9C (exec-prefetch vm inst :inst))
      (#x9E (exec-go vm inst))
      (#xA0 (exec-store vm inst 1 t))
      (#xA2 (exec-store vm inst 1 nil))
      (#xA4 (exec-store vm inst 2 t))
      (#xA6 (exec-store vm inst 2 nil))
      (#xA8 (exec-store vm inst 4 t))
      (#xAA (exec-store vm inst 4 nil))
      ((#xAC #xAE) (exec-store vm inst 8 nil))
      (#xB6 (if (vm-caches vm)
                (exec-stunc vm inst)
                (exec-store vm inst 8 nil)))
      (#xB0 (exec-stsf vm inst))
      (#xB2 (progn
              (incf (vm-mems vm))
              (mem-set-u32 vm (aligned-addr vm inst 2)
                           (ldb (byte 32 32) (reg vm (inst-x inst))))
              (clear-vm-fence vm)
              nil))
      (#xB4 (progn
              (incf (vm-mems vm))
              (mem-set-u64 vm (aligned-addr vm inst 3) (inst-x inst))
              (clear-vm-fence vm)
              nil))
      (#xB8 (exec-syncd vm inst))
      (#xBA (exec-prefetch vm inst :data))
      (#xBC (exec-syncid vm inst))
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

(defun exec-inserted (vm tetra rop &optional (w-reg +r-w+) (y-reg +r-y+) (z-reg +r-z+))
  "Execute TETRA as though it occupied the resume address minus 4.
ROP 1 substitutes the Y and Z registers of this resume bank."
  (let ((inst (decode tetra))
        (rw (special-reg vm w-reg)))
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
         (let ((*yz-override* (cons (special-reg vm y-reg)
                                    (special-reg vm z-reg))))
           (execute vm inst))
         (execute vm inst)))))

(defun exec-resume-set (vm rx &optional (w-reg +r-w+) (y-reg +r-y+) (z-reg +r-z+))
  "Ropcode 2: $X ← rZ, then raise the exception bits in bits 47–40 of rX.
$X must not be marginal. An enabled bit trips from the resume address minus 4."
  (let* ((tetra (logand rx #xffffffff))
         (x (ldb (byte 8 16) tetra))
         (bits (suppress-exact-underflow vm (logand (ash rx -40) #xff)))
         (ry (special-reg vm y-reg))
         (rz (special-reg vm z-reg))
         (rw (special-reg vm w-reg)))
    (when (marginal-reg-p vm x)
      (illegal-instruction))
    (set-reg vm x rz)
    (setf (vm-pc vm) (u64 (- rw 4)))
    (if (signal-events vm bits :y ry :z rz :inst tetra)
        :jump
        (progn
          (setf (vm-pc vm) rw)
          :jump))))

(defun apply-resume-rop (vm rx w-reg y-reg z-reg &key allow-rop3)
  "Negative RX jumps to the resume address. Otherwise insert under the ropcode.
Ropcode 3 is the page-table pair, and only RESUME 1 accepts it."
  (if (logbitp 63 rx)
      (progn
        (setf (vm-pc vm) (special-reg vm w-reg))
        :jump)
      (case (ldb (byte 8 56) rx)
        (0 (exec-inserted vm (logand rx #xffffffff) 0 w-reg y-reg z-reg))
        (1 (exec-inserted vm (logand rx #xffffffff) 1 w-reg y-reg z-reg))
        (2 (exec-resume-set vm rx w-reg y-reg z-reg))
        (3 (if allow-rop3
               (let ((which (if (= (ldb (byte 8 24) rx) #xFD) :inst :data)))
                 (setf (vm-trans-cache vm) which
                       (vm-trans-va vm) (special-reg vm y-reg)
                       (vm-trans-pte vm) (special-reg vm z-reg)
                       (vm-pc vm) (special-reg vm w-reg))
                 (install-resumed-translation vm which
                                              (special-reg vm y-reg)
                                              (special-reg vm z-reg))
                 :jump)
               (illegal-instruction)))
        (t (illegal-instruction)))))

(defun finish-resume-1 (vm effect)
  "rK ← $255 and $255 ← rBB. A return to a nonnegative rWW drops the p bit,
which the handler's own fetches recorded."
  (set-special vm +r-k+ (reg vm 255))
  (set-reg vm 255 (special-reg vm +r-bb+))
  (unless (logbitp 63 (special-reg vm +r-ww+))
    (set-special vm +r-q+ (logandc2 (special-reg vm +r-q+) +rq-p+)))
  effect)

(defun exec-resume-1 (vm inst)
  "RESUME from the trap bank. Z = 1 at a negative PC. Z > 1 sets b.
The same instruction at a nonnegative PC sets k and does not resume."
  (cond
    ((or (plusp (inst-x inst))
         (plusp (inst-y inst))
         (> (inst-z inst) 1))
     (illegal-instruction))
    ((not (logbitp 63 (vm-pc vm)))
     (error 'mmix-suppress :bit +rq-k+))
    (t
     (finish-resume-1
      vm
      (apply-resume-rop vm (special-reg vm +r-xx+)
                        +r-ww+ +r-yy+ +r-zz+
                        :allow-rop3 t)))))

(defun exec-resume (vm inst)
  "RESUME. Z = 0 uses rW/rX/rY/rZ. On a kernel VM, Z = 1 uses the trap bank.
User mode still rejects a nonzero Z as unimplemented. A nonzero X or Y field,
a ropcode above 3, and ropcode 3 on RESUME 0 are illegal."
  (cond
    ((and (vm-kernel vm) (plusp (inst-z inst)))
     (exec-resume-1 vm inst))
    ((not (zerop (inst-z inst)))
     (unimplemented "RESUME with a nonzero XYZ"))
    ((or (not (zerop (inst-x inst)))
         (not (zerop (inst-y inst))))
     (illegal-instruction))
    (t
     (apply-resume-rop vm (special-reg vm +r-x+) +r-w+ +r-y+ +r-z+))))

;;; Defined in src/kernel.lisp. The ftypes stay broad so a later definition
;;; may return true; a stub that returned NIL made SBCL reject that.
(declaim (ftype (function (t t) t) host-swym-p)
         (ftype (function (t) t) host-dispatch deliver-dynamic-trap))

(defun branch-mispredicted-p (op taken)
  "Ordinary BN…BEV predict not taken. Probable PBN…PBEV predict taken."
  (if (< op #x50)
      taken
      (not taken)))

(defun instruction-cost (op taken)
  "§50 (υ μ) for one retired opcode. TAKEN matters only for #x40–#x5F.
LDSF and STSF are the floating-point load and store: 4υ and 1μ.
PUSHGO is a GO, so 3υ and no μ. The holes #x98–#x9F and #xB8–#xBF
contribute no μ."
  (cond
    ((or (= op #x94) (= op #x95))
     (values 2 2))
    ((or (= op #xFA) (= op #xFB))
     (values 1 20))
    ((<= #x40 op #x5F)
     (values (if (branch-mispredicted-p op taken) 3 1) 0))
    ((or (= op #xF8) (= op #x9E) (= op #x9F) (= op #xBE) (= op #xBF))
     (values 3 0))
    ((<= #x18 op #x1B)
     (values 10 0))
    ((<= #x1C op #x1F)
     (values 60 0))
    ((or (= op #x00) (= op #xF9) (= op #xFF))
     (values 5 0))
    ((or (= op #x01) (= op #x02) (= op #x03))
     (values 1 0))
    ((or (= op #x14) (= op #x15))
     (values 40 0))
    ((or (<= #x04 op #x17)
         (= op #x90) (= op #x91) (= op #xB0) (= op #xB1))
     (values 4 (if (or (= op #x90) (= op #x91) (= op #xB0) (= op #xB1)) 1 0)))
    ((and (<= #x80 op #xBF)
          (not (<= #x98 op #x9F))
          (not (<= #xB8 op #xBF)))
     (values 1 1))
    (t (values 1 0))))

(defun charge (vm op &key taken)
  "Add the §50 μ and υ of a retired opcode. Does not touch rI or vm-cycles.
Callers that leave EXECUTE by a signal have not retired and must not call this."
  (multiple-value-bind (oops mems) (instruction-cost (logand op #xFF) taken)
    (incf (vm-oops vm) oops)
    (incf (vm-mem-cost vm) mems))
  vm)

(defun execute (vm inst)
  "Execute one instruction. Returns :JUMP, :STOP, or NIL (fall through).
A normal return charges §50. A signal does not: the instruction did not retire."
  (let ((*exec-vm* vm)
        (*exec-inst* inst)
        (op (inst-op inst)))
    (let ((effect
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
      ((= op #xFC)
       (let ((xyz (inst-xyz inst)))
         (cond
           ((and (>= xyz 4) (sync-k-enabled-p vm))
            (error 'mmix-suppress :bit +rq-k+))
           ((> xyz 7)
            (illegal-instruction))
           ((<= xyz 3)
            (record-vm-fence vm xyz))
           ((= xyz 4)
            (setf (vm-asleep vm) t))
           ((= xyz 5)
            (cache-writeback-all vm))
           ((= xyz 6)
            (drop-translation-caches vm))
           ((= xyz 7)
            (cache-discard-all vm))))
       nil)
      ((= op #xFD)
       (if (host-swym-p vm inst)
           (host-dispatch vm)
           nil))
      ((= op #xFE)
       (unless (zerop (inst-y inst)) (illegal-instruction))
       (let ((z (inst-z inst)))
         (when (and (vm-kernel vm) (= z +r-q+))
           (setf (vm-rq-gotten vm) (special-reg vm +r-q+)))
         (set-reg vm (inst-x inst) (special-reg vm z)))
       nil)
      ((= op #xFF)
       (if (do-trip vm 0
                    :y (reg vm (inst-y inst))
                    :z (reg vm (inst-z inst))
                    :inst (inst-raw inst))
           :jump
           nil))
      (t (unimplemented (format nil "opcode #x~2,'0X" op))))))
      (charge vm op :taken (and (<= #x40 op #x5F) (eq effect :jump)))
      effect)))

(defun step-vm (vm)
  "Fetch–decode–execute one instruction. An execute breakpoint stops first.
Calling STEP-VM again while stopped executes that instruction.
SYNC 4 puts the core to sleep: further steps return until WAKE-CORE or a
bit appears in rQ."
  (when (vm-halted vm)
    (return-from step-vm vm))
  (when (vm-asleep vm)
    (if (zerop (special-reg vm +r-q+))
        (return-from step-vm vm)
        (setf (vm-asleep vm) nil)))
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
  ;; A fault does not retire. A dynamic trap does not retire the user
  ;; instruction it diverts. rI stays one tick per retired instruction.
  ;; §50 υ is charged inside EXECUTE and is not added here.
  (incf (vm-cycles vm))
  (when (deliver-dynamic-trap vm)
    (return-from step-vm vm))
  (let* ((retired-pc (vm-pc vm))
         (raise-stack (vm-stack-alert vm)))
    (setf (vm-stack-alert vm) nil)
    (handler-case
        (progn
          (when (and (vm-kernel vm) (logbitp 63 retired-pc))
            (raise-program-bit vm +rq-p+))
          (let* ((word (fetch vm))
                 (inst (decode word))
                 (effect (execute vm inst)))
            (unless (or (eq effect :jump) (eq effect :stop) (vm-halted vm))
              (setf (vm-pc vm) (u64 (+ (vm-pc vm) 4))))
            (note-usage vm (inst-op inst) retired-pc)
            (tick-interval vm)
            (when raise-stack
              (raise-program-bit vm +rq-stack-overflow+))))
      (mmix-suppress (c)
        (raise-program-bit vm (mmix-suppress-bit c))
        (when raise-stack
          (raise-program-bit vm +rq-stack-overflow+)))
      (mmix-taken-trap ()
        (when raise-stack
          (raise-program-bit vm +rq-stack-overflow+)))
      (mmix-fault (e)
        (when raise-stack
          (raise-program-bit vm +rq-stack-overflow+))
        (setf (vm-fault vm) (mmix-fault-reason e)
              (vm-halted vm) t))))
  (when (and (vm-watch-hit vm) (not (vm-halted vm)))
    (setf (vm-break vm) (vm-watch-hit vm)))
  vm)

(defun run-vm (vm &key (max-cycles 100000))
  "Run until halt, breakpoint, power-save, or MAX-CYCLES.
Signals an error if the cycle limit is hit without halt, a breakpoint,
or SYNC 4."
  (loop
    (when (or (vm-halted vm) (vm-break vm) (vm-asleep vm))
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
