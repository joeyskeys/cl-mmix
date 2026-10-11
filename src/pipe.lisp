(in-package #:cl-mmix)

;;; One in-order pipeline (plan 11). Functional results still come from EXECUTE
;;; at write-back, so a younger instruction cannot commit a store or a register
;;; ahead of an older one. :pipeline nil never builds this struct and run-vm
;;; keeps calling step-vm.
;;;
;;; A destination is busy while its writer occupies X. Once that writer leaves
;;; X, D may read the register in the same cycle: M and W both forward. That
;;; is the bypass. A load-use dependency therefore waits one cycle (the writer
;;; still in X) and does not wait an extra cycle for W. Memory itself still
;;; spends its access time in M; the scoreboard does not add that on top of X,
;;; which is what keeps the locked load-use gap at one pipeline cycle.
;;;
;;; Ordinary branches predict not taken. Probable branches predict taken. A
;;; miss flushes F and D. GO, PUSHGO, POP, JMP, PUSHJ, TRAP, TRIP, RESUME, and
;;; UNSAVE flush F and D when they leave X and do not fetch again until
;;; write-back knows the target. SYNC XYZ = 0, and XYZ ≥ 4, hold fetch until
;;; that SYNC retires. XYZ 1–3 stay in order because M holds one instruction.

;;; Defined in src/kernel.lisp. A speculative fetch must not require the ROM
;;; helper to be loaded first; the call happens only after the system is up.
(declaim (ftype (function (t t) (values t t &optional)) rom-tetra))

(defstruct (pipe (:conc-name pipe-))
  f d x m w
  (fetch-pc 0)
  (hold-pc nil)
  (drains 0)
  (add 1)
  (mul 10)
  (div 60)
  (fadd 4)
  (fmul 4)
  (fdiv 40)
  (mem-latency 1))

(defstruct (iru (:conc-name iru-))
  pc inst reads writes
  (x-left 1)
  (m-left 1)
  predicted
  steered
  drain
  kind)

(defun pipe-latency (config key default)
  (let ((n (and (listp config) (getf config key))))
    (if (and (integerp n) (plusp n)) n default)))

(defun install-pipe (vm config)
  "Build the five-stage pipe. Latencies come from CACHE-CONFIG when present.
M uses accesstime only when caches are on; otherwise a memory op spends one
cycle in M so the load-use test stays at one extra cycle."
  (setf (vm-pipe vm)
        (make-pipe
         :fetch-pc (logand (vm-pc vm) (lognot 3))
         :add (pipe-latency config :add 1)
         :mul (pipe-latency config :multiply 10)
         :div (pipe-latency config :divide 60)
         :fadd (pipe-latency config :fadd 4)
         :fmul (pipe-latency config :fmul 4)
         :fdiv (pipe-latency config :fdiv 40)
         :mem-latency (if (vm-caches vm)
                          (pipe-latency config :accesstime 2)
                          1)))
  vm)

(defun reset-pipe (vm)
  (let ((pipe (vm-pipe vm)))
    (when pipe
      (setf (pipe-f pipe) nil
            (pipe-d pipe) nil
            (pipe-x pipe) nil
            (pipe-m pipe) nil
            (pipe-w pipe) nil
            (pipe-hold-pc pipe) nil
            (pipe-drains pipe) 0
            (pipe-fetch-pc pipe) (logand (vm-pc vm) (lognot 3)))))
  (setf (vm-pipe-cycles vm) 0)
  vm)

(defun pipe-drain-count (vm)
  "Cycles in which SYNC 0 or SYNC ≥ 4 kept the fetcher idle."
  (let ((pipe (vm-pipe vm)))
    (if pipe (pipe-drains pipe) 0)))

(defun pipe-stage-pc (vm stage)
  "PC occupying STAGE, or NIL. STAGE is :F, :D, :X, :M, or :W."
  (let ((pipe (vm-pipe vm)))
    (unless pipe
      (return-from pipe-stage-pc nil))
    (let ((iru (ecase stage
                 (:f (pipe-f pipe))
                 (:d (pipe-d pipe))
                 (:x (pipe-x pipe))
                 (:m (pipe-m pipe))
                 (:w (pipe-w pipe)))))
      (and iru (iru-pc iru)))))

(defun pipe-empty-p (pipe)
  (not (or (pipe-f pipe) (pipe-d pipe) (pipe-x pipe)
           (pipe-m pipe) (pipe-w pipe))))

(defun pipe-flush (pipe)
  (setf (pipe-f pipe) nil
        (pipe-d pipe) nil
        (pipe-x pipe) nil
        (pipe-m pipe) nil
        (pipe-w pipe) nil
        (pipe-hold-pc pipe) nil)
  pipe)

(defun pipe-holds-pc-p (pipe pc)
  (dolist (iru (list (pipe-f pipe) (pipe-d pipe) (pipe-x pipe)
                     (pipe-m pipe) (pipe-w pipe)))
    (when (and iru pc (= (iru-pc iru) pc))
      (return-from pipe-holds-pc-p t)))
  nil)

(defun pipe-drop-hold (pipe &optional keep)
  (let ((pc (pipe-hold-pc pipe)))
    (when (and pc
               (not (and keep (= (iru-pc keep) pc)))
               (not (pipe-holds-pc-p pipe pc)))
      (setf (pipe-hold-pc pipe) nil)))
  pipe)

(defun pipe-control-op-p (op)
  (or (= op #x00)
      (= op #x9E) (= op #x9F)
      (= op #xBE) (= op #xBF)
      (<= #xF0 op #xF3)
      (= op #xF8) (= op #xF9)
      (= op #xFB)
      (= op #xFF)))

(defun pipe-sync-drain-p (inst)
  (and (= (inst-op inst) #xFC)
       (let ((xyz (inst-xyz inst)))
         (or (zerop xyz) (>= xyz 4)))))

(defun pipe-mem-op-p (op)
  (and (<= #x80 op #xBF)
       (not (or (= op #x9E) (= op #x9F)
                (= op #xBE) (= op #xBF)))))

(defun pipe-x-cycles (pipe op)
  (cond
    ((<= #x18 op #x1B) (pipe-mul pipe))
    ((<= #x1C op #x1F) (pipe-div pipe))
    ((or (= op #x14) (= op #x15)) (pipe-fdiv pipe))
    ((= op #x10) (pipe-fmul pipe))
    ((or (<= #x04 op #x0F)
         (<= #x11 op #x13)
         (= op #x16) (= op #x17))
     (pipe-fadd pipe))
    (t (pipe-add pipe))))

(defun pipe-m-cycles (pipe op)
  (if (pipe-mem-op-p op)
      (pipe-mem-latency pipe)
      1))

(defun pipe-reg-hit-p (need have)
  (dolist (reg need nil)
    (when (member reg have :test #'=)
      (return t))))

(defun inst-general-reads (inst)
  "General registers this instruction reads. Specials are not scoreboarded.
A missed read only skips a stall; EXECUTE at W still sees the retired value."
  (let* ((op (inst-op inst))
         (x (inst-x inst))
         (y (inst-y inst))
         (z (inst-z inst))
         (imm (oddp op)))
    (cond
      ((<= #x40 op #x5F) (list x))
      ((<= #xE0 op #xE3) nil)
      ((<= #xE4 op #xEF) (list x))
      ((or (= op #xF0) (= op #xF1) (= op #xF4) (= op #xF5)
           (= op #xF7) (= op #xF8) (= op #xF9)
           (= op #xFA) (= op #xFC) (= op #xFD) (= op #xFE))
       nil)
      ((= op #xF2) nil)
      ((= op #xF3) nil)
      ((= op #xF6) (list z))
      ((= op #xFB) (list z))
      ((= op #xFF) (list y z))
      ((= op #x00) (list 255))
      ((or (= op #x34) (= op #x35) (= op #x36) (= op #x37))
       (if imm nil (list z)))
      ((and (<= #x9A op #x9D))
       (if imm (list y) (list y z)))
      ((and (<= #xB8 op #xBD))
       (if imm (list y) (list y z)))
      ((<= #xA0 op #xB7)
       (if imm (list x y) (list x y z)))
      ((or (= op #x94) (= op #x95))
       (if imm (list x y) (list x y z)))
      ((<= #x80 op #x9D)
       (if imm (list y) (list y z)))
      ((<= #x01 op #xDF)
       (if imm (list y) (list y z)))
      (t nil))))

(defun inst-general-writes (inst)
  (let ((op (inst-op inst))
        (x (inst-x inst)))
    (cond
      ((<= #x40 op #x5F) nil)
      ((or (<= #x9A op #x9D) (<= #xB8 op #xBD)) nil)
      ((<= #xA0 op #xBF) nil)
      ((or (= op #xF0) (= op #xF1) (= op #xF6) (= op #xF7)
           (= op #xF8) (= op #xF9) (= op #xFA)
           (= op #xFC) (= op #xFD))
       nil)
      ((or (= op #x00) (= op #xFF) (= op #xFB)) (list 255))
      (t (list x)))))

(defun pipe-predict-next (pc inst)
  (let ((op (inst-op inst)))
    (if (<= #x50 op #x5F)
        (u64 (+ pc (* 4 (relative-disp (inst-yz inst) 16 (oddp op)))))
        (u64 (+ pc 4)))))

(defun pipe-branch-next (vm iru)
  (let* ((inst (iru-inst iru))
         (op (inst-op inst))
         (pred (pred-index op (if (>= op #x50) #x50 #x40)))
         (disp (relative-disp (inst-yz inst) 16 (oddp op))))
    (if (cond-holds pred (reg vm (inst-x inst)))
        (u64 (+ (iru-pc iru) (* 4 disp)))
        (u64 (+ (iru-pc iru) 4)))))

(defun pipe-word (vm addr)
  "Instruction tetra for a speculative fetch. A fault stays on the iru until
that instruction retires and the real FETCH runs."
  (let ((addr (logand (u64 addr) (lognot 3))))
    (handler-case
        (multiple-value-bind (word hit) (rom-tetra vm addr)
          (if hit
              word
              (mem-ref-u32 vm addr :internal t)))
      (mmix-fault () 0))))

(defun pipe-hold-is-drain-p (pipe)
  "True when the instruction that stopped fetch is a draining SYNC."
  (let ((pc (pipe-hold-pc pipe)))
    (dolist (iru (list (pipe-f pipe) (pipe-d pipe) (pipe-x pipe)
                       (pipe-m pipe) (pipe-w pipe)))
      (when (and iru pc (= (iru-pc iru) pc) (iru-drain iru))
        (return-from pipe-hold-is-drain-p t))))
  nil)

(defun pipe-fetch (vm pipe)
  (cond
    ((or (pipe-f pipe) (vm-halted vm) (vm-break vm) (vm-asleep vm))
     nil)
    ((pipe-hold-pc pipe)
     (when (pipe-hold-is-drain-p pipe)
       (incf (pipe-drains pipe)))
     nil)
    (t
     (let* ((pc (logand (pipe-fetch-pc pipe) (lognot 3)))
            (inst (decode (pipe-word vm pc)))
            (iru (make-iru :pc pc
                           :inst inst
                           :reads (inst-general-reads inst)
                           :writes (inst-general-writes inst)
                           :predicted (pipe-predict-next pc inst)
                           :drain (pipe-sync-drain-p inst)
                           :kind (cond
                                   ((<= #x40 (inst-op inst) #x5F) :branch)
                                   ((pipe-control-op-p (inst-op inst)) :control)
                                   (t :op)))))
       (note-sim-fetch vm pc)
       (setf (pipe-fetch-pc pipe) (iru-predicted iru)
             (pipe-f pipe) iru)
       (when (iru-drain iru)
         (setf (pipe-hold-pc pipe) pc))
       iru))))

(defun pipe-finish-x (vm pipe iru)
  (cond
    ((eq (iru-kind iru) :branch)
     (let ((next (pipe-branch-next vm iru)))
       (setf (iru-steered iru) t)
       (unless (= next (iru-predicted iru))
         (setf (pipe-f pipe) nil
               (pipe-d pipe) nil)
         (pipe-drop-hold pipe iru)
         (setf (pipe-fetch-pc pipe) next))))
    ((eq (iru-kind iru) :control)
     (setf (pipe-f pipe) nil
           (pipe-d pipe) nil
           (pipe-hold-pc pipe) (iru-pc iru))))
  iru)

(defun pipe-advance (vm pipe)
  (when (pipe-m pipe)
    (if (<= (iru-m-left (pipe-m pipe)) 1)
        (setf (pipe-w pipe) (pipe-m pipe)
              (pipe-m pipe) nil)
        (decf (iru-m-left (pipe-m pipe)))))
  (when (pipe-x pipe)
    (cond
      ((and (<= (iru-x-left (pipe-x pipe)) 1)
            (not (pipe-m pipe)))
       (let ((iru (pipe-x pipe)))
         (setf (pipe-x pipe) nil)
         (pipe-finish-x vm pipe iru)
         (setf (iru-m-left iru) (pipe-m-cycles pipe (inst-op (iru-inst iru)))
               (pipe-m pipe) iru)))
      ((> (iru-x-left (pipe-x pipe)) 1)
       (decf (iru-x-left (pipe-x pipe))))))
  (when (and (pipe-d pipe) (not (pipe-x pipe)))
    (let ((iru (pipe-d pipe)))
      (setf (iru-x-left iru) (pipe-x-cycles pipe (inst-op (iru-inst iru)))
            (pipe-d pipe) nil
            (pipe-x pipe) iru)))
  (when (and (pipe-f pipe)
             (not (pipe-d pipe))
             (not (and (pipe-x pipe)
                       (pipe-reg-hit-p (iru-reads (pipe-f pipe))
                                       (iru-writes (pipe-x pipe))))))
    (setf (pipe-d pipe) (pipe-f pipe)
          (pipe-f pipe) nil))
  (pipe-fetch vm pipe)
  pipe)

(defun pipe-redirect (pipe vm)
  (pipe-flush pipe)
  (setf (pipe-fetch-pc pipe) (logand (vm-pc vm) (lognot 3)))
  pipe)

(defun pipe-retire (vm pipe)
  (let ((iru (pipe-w pipe))
        (pc 0))
    (setf pc (iru-pc iru)
          (pipe-w pipe) nil
          (vm-watch-hit vm) nil
          (vm-pc vm) pc)
    (incf (vm-cycles vm))
    (when (deliver-dynamic-trap vm)
      (pipe-redirect pipe vm)
      (return-from pipe-retire vm))
    (let ((raise-stack (vm-stack-alert vm)))
      (setf (vm-stack-alert vm) nil)
      (handler-case
          (progn
            (when (and (vm-kernel vm) (logbitp 63 pc))
              (raise-program-bit vm +rq-p+))
            (let* ((inst (decode (fetch vm)))
                   (effect (execute vm inst)))
              (unless (or (eq effect :jump) (eq effect :stop) (vm-halted vm))
                (setf (vm-pc vm) (u64 (+ (vm-pc vm) 4))))
              (note-usage vm (inst-op inst) pc)
              (tick-interval vm)
              (note-profile vm pc)
              (cond
                ((or (eq effect :stop) (vm-halted vm))
                 (pipe-flush pipe))
                ((not (iru-steered iru))
                 (when (or (eq effect :jump)
                           (eq (iru-kind iru) :control)
                           (iru-drain iru))
                   (pipe-redirect pipe vm))))))
        (mmix-suppress (c)
          (raise-program-bit vm (mmix-suppress-bit c))
          (pipe-redirect pipe vm))
        (mmix-taken-trap ()
          (pipe-redirect pipe vm))
        (mmix-fault (e)
          (pipe-flush pipe)
          (setf (vm-fault vm) (mmix-fault-reason e)
                (vm-halted vm) t)))
      (when raise-stack
        (raise-program-bit vm +rq-stack-overflow+)))
    (when (and (vm-watch-hit vm) (not (vm-halted vm)))
      (setf (vm-break vm) (vm-watch-hit vm)))
    vm))

(defun pipe-exec-break-p (vm pc)
  (dolist (w (vm-watches vm) nil)
    (when (and (eq (car w) :exec)
               (= (cdr w) (logand (u64 pc) (lognot 3))))
      (return t))))

(defun step-cycle (vm)
  "Advance every pipeline stage once. An :exec watch stops before the
instruction in W retires, so continue-vm still runs that instruction.
vm-pipe-cycles counts this call. vm-cycles still counts a retirement."
  (let ((pipe (vm-pipe vm)))
    (unless pipe
      (error "step-cycle requires :pipeline t"))
    (when (vm-halted vm)
      (return-from step-cycle vm))
    (when (vm-asleep vm)
      (if (zerop (special-reg vm +r-q+))
          (return-from step-cycle vm)
          (setf (vm-asleep vm) nil)))
    (when (and (not (pipe-hold-pc pipe)) (pipe-empty-p pipe))
      (setf (pipe-fetch-pc pipe) (logand (vm-pc vm) (lognot 3))))
    (let ((skip (or (vm-break-skip vm) (not (null (vm-break vm))))))
      (setf (vm-break vm) nil
            (vm-break-skip vm) nil)
      (when (and (not skip)
                 (pipe-w pipe)
                 (pipe-exec-break-p vm (iru-pc (pipe-w pipe))))
        (setf (vm-break vm) (list :exec (iru-pc (pipe-w pipe))))
        (return-from step-cycle vm)))
    (incf (vm-pipe-cycles vm))
    (when (pipe-w pipe)
      (pipe-retire vm pipe))
    (unless (or (vm-halted vm) (vm-break vm) (vm-asleep vm))
      (pipe-advance vm pipe))
    vm))
