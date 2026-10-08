(in-package #:cl-mmix)

;;; Opcode glue. Arithmetic stays in this directory; ops.lisp only dispatches.
;;; Enabled exceptions trip through signal-events: the bit that trips stays
;;; clear, and an earlier bit of DVWIOUZX wins when two enables are set.

(defun current-round (vm)
  "rA bits 17–16. 00 is round-to-nearest; 01, 10, and 11 are off, up, and down."
  (let ((a (logand (special-reg vm +r-a+) #x3ffff)))
    (if (>= a #x10000)
        (ash a -16)
        +round-near+)))

(defun commit-fp-exceptions (vm exc inst y z)
  "Merge simulator exception bits into rA and maybe trip.
Exact underflow is dropped when the U enable is clear. The destination
register or the stored tetra has already been written."
  (let ((a (special-reg vm +r-a+)))
    (when (and (logtest exc +u-bit+)
               (not (logtest exc +x-bit+))
               (not (logtest a (ash +ev-u+ 8))))
      (setf exc (logandc2 exc +u-bit+)))
    (let ((bits (ash (logand exc #x3f00) -8)))
      (when (signal-events vm bits :y y :z z :inst inst)
        :jump))))

(defun %fcmp (y z)
  (let ((k (fcomp y z)))
    (cond ((< k 0) (values (u64 -1) 0))
          ((= k 1) (values 1 0))
          ((= k 2) (values 0 +i-bit+))
          (t (values 0 0)))))

(defun %fcmpe (y z e)
  (let ((k (fepscomp y z e t)))
    (if (zerop k)
        (%fcmp y z)
        (values 0 (if (= k 2) +i-bit+ 0)))))

(defun %feql (y z)
  (values (if (zerop (fcomp y z)) 1 0) 0))

(defun %feqle (y z e)
  (let ((k (fepscomp y z e nil)))
    (cond ((= k 1) (values 1 0))
          ((= k 2) (values 0 +i-bit+))
          (t (values 0 0)))))

(defun %fun (y z)
  (values (if (= (fcomp y z) 2) 1 0) 0))

(defun %fune (y z e)
  (values (if (= (fepscomp y z e t) 2) 1 0) 0))

(defun float-unary-p (op)
  (member op '(#x05 #x07 #x08 #x09 #x0A #x0B #x0C #x0D #x0E #x0F #x15 #x17)))

(defun exec-float-unary (vm inst op)
  (let ((y (if *yz-override* (car *yz-override*) (inst-y inst))))
    (when (> y 4)
      (error 'mmix-fault :reason "illegal rounding mode"))
    (let* ((z (if *yz-override*
                  (cdr *yz-override*)
                  (if (member op '(#x09 #x0B #x0D #x0F))
                      (inst-z inst)
                      (reg vm (inst-z inst)))))
           (result (ecase op
                     (#x05 (fixit z y))
                     (#x07 (prog1 (fixit z y)
                             (setf *fp-exceptions*
                                   (logandc2 *fp-exceptions* +w-bit+))))
                     ((#x08 #x09) (floatit z y 0 0))
                     ((#x0A #x0B) (floatit z y 2 0))
                     ((#x0C #x0D) (floatit z y 0 4))
                     ((#x0E #x0F) (floatit z y 2 4))
                     (#x15 (froot z y))
                     (#x17 (fintegerize z y)))))
      (set-reg vm (inst-x inst) result)
      (commit-fp-exceptions vm *fp-exceptions* (inst-raw inst) y z))))

(defun exec-float-binary (vm inst op)
  (let* ((y (if *yz-override* (car *yz-override*) (reg vm (inst-y inst))))
         (z (if *yz-override* (cdr *yz-override*) (reg vm (inst-z inst))))
         (e (special-reg vm +r-e+))
         (result 0)
         (exc 0))
    (ecase op
      (#x01 (multiple-value-setq (result exc) (%fcmp y z)))
      (#x02 (multiple-value-setq (result exc) (%fun y z)))
      (#x03 (multiple-value-setq (result exc) (%feql y z)))
      (#x04 (setf result (fplus y z) exc *fp-exceptions*))
      (#x06 (setf result (fsub y z) exc *fp-exceptions*))
      (#x10 (setf result (fmult y z) exc *fp-exceptions*))
      (#x11 (multiple-value-setq (result exc) (%fcmpe y z e)))
      (#x12 (multiple-value-setq (result exc) (%fune y z e)))
      (#x13 (multiple-value-setq (result exc) (%feqle y z e)))
      (#x14 (setf result (fdivide y z) exc *fp-exceptions*))
      (#x16 (setf result (fremstep y z 2500) exc *fp-exceptions*)))
    (set-reg vm (inst-x inst) result)
    (commit-fp-exceptions vm exc (inst-raw inst) y z)))

(defun exec-float (vm inst)
  (let ((*fp-exceptions* 0)
        (*cur-round* (current-round vm))
        (op (inst-op inst)))
    (if (float-unary-p op)
        (exec-float-unary vm inst op)
        (exec-float-binary vm inst op))))

(defun exec-ldsf (vm inst)
  (incf (vm-mems vm))
  (set-reg vm (inst-x inst)
           (let ((*fp-exceptions* 0))
             (load-sf (mem-ref-u32 vm (aligned-addr vm inst 2)))))
  nil)

(defun exec-stsf (vm inst)
  (incf (vm-mems vm))
  (let* ((*fp-exceptions* 0)
         (*cur-round* (current-round vm))
         (addr (eff-addr vm inst))
         (value (reg vm (inst-x inst)))
         (tetra (store-sf value)))
    (mem-set-u32 vm (logand addr (lognot 3)) tetra)
    (commit-fp-exceptions vm *fp-exceptions* (inst-raw inst) addr value)))
