(in-package #:cl-mmix)

;;; Tiny s-expression assembler.
;;;
;;; Program form:
;;;   (program
;;;     (:org #x100)            ; optional origin
;;;     (label :start)
;;;     (setl $1 #x0A)          ; $n or bare integer register
;;;     (addi $2 $0 1)
;;;     (bz $1 :done)
;;;     (jmp :start)
;;;     (label :done)
;;;     (trap 0 0 0))
;;;
;;; Immediates may be integers or labels (resolved as PC-relative for
;;; branches/JMP/GETA, absolute address for others when used as data).

(defun parse-reg (r)
  (cond
    ((integerp r)
     (unless (<= 0 r 255) (error "Register out of range: ~S" r))
     r)
    ((and (symbolp r)
          (let ((n (symbol-name r)))
            (and (char= (char n 0) #\$)
                 (every #'digit-char-p (subseq n 1)))))
     (parse-integer (subseq (symbol-name r) 1)))
    (t (error "Bad register: ~S" r))))

(defun wyde-op-p (op)
  (member (op-name-key op)
          '(:seth :setmh :setml :setl :inch :incmh :incml :incl
            :orh :ormh :orml :orl :geta) :test #'eq))

(defun branch-op-p (op)
  (member (op-name-key op)
          '(:bn :bnz :bz :bnn :bp :bnp :bod :bev
            :pbn :pbnz :pbz :pbnn :pbp :pbnp) :test #'eq))

(defun collect-labels (forms origin)
  (let ((labels (make-hash-table :test 'equal))
        (addr origin))
    (dolist (form forms)
      (cond
        ((and (consp form) (eq (first form) :org))
         (setf addr (second form)))
        ((and (consp form) (string-equal (symbol-name (first form)) "LABEL"))
         (setf (gethash (second form) labels) addr))
        ((and (consp form) (eq (first form) :word))
         (incf addr 8))
        ((and (consp form) (eq (first form) :byte))
         (incf addr (length (rest form))))
        ((and (consp form) (keywordp (first form)))
         nil) ; directive
        ((consp form)
         (incf addr 4))
        (t nil)))
    labels))

(defun resolve-imm (imm labels pc &key relative)
  (cond
    ((integerp imm) imm)
    ((or (symbolp imm) (keywordp imm) (stringp imm))
     (let ((target (gethash imm labels)))
       (unless target
         (error "Undefined label: ~S" imm))
       (if relative
           (truncate (- target (+ pc 0)) 4) ; relative in instructions from current PC
           target)))
    (t (error "Bad immediate: ~S" imm))))

(defun encode-form (form labels pc)
  "Return list of bytes (length 4 for instr, or data bytes)."
  (let ((op (first form)))
    (case op
      ((:org label) nil)
      ((:word)
       (let ((v (u64 (second form))))
         (loop for shift from 56 downto 0 by 8
               collect (ldb (byte 8 shift) v))))
      ((:byte)
       (mapcar #'u8 (rest form)))
      (otherwise
       (cond
         ((wyde-op-p op)
          (let* ((x (parse-reg (second form)))
                 (imm (resolve-imm (third form) labels pc
                                   :relative (eq op 'geta)))
                 (yz (if (eq op 'geta)
                         (logand (sign-extend16 (logand imm #xFFFF)) #xFFFF)
                         (u16 imm))))
            ;; For GETA, resolve-imm already returned instruction delta
            (when (eq op 'geta)
              (setf yz (u16 imm)))
            (list (op-byte op) x (ldb (byte 8 8) yz) (ldb (byte 8 0) yz))))
         ((branch-op-p op)
          (let* ((x (parse-reg (second form)))
                 (delta (resolve-imm (third form) labels pc :relative t))
                 (yz (u16 delta)))
            (list (op-byte op) x (ldb (byte 8 8) yz) (ldb (byte 8 0) yz))))
         ((eq op 'jmp)
          (let* ((delta (resolve-imm (second form) labels pc :relative t))
                 (xyz (logand delta #xFFFFFF)))
            (list (op-byte 'jmp)
                  (ldb (byte 8 16) xyz)
                  (ldb (byte 8 8) xyz)
                  (ldb (byte 8 0) xyz))))
         ((eq op 'trap)
          (list (op-byte 'trap)
                (u8 (or (second form) 0))
                (u8 (or (third form) 0))
                (u8 (or (fourth form) 0))))
         ((eq op 'set)
          ;; SET $X,$Y  ≡  ORI $X,$Y,0
          (let ((x (parse-reg (second form)))
                (y (parse-reg (third form))))
            (list (op-byte 'ori) x y 0)))
         ((member op '(addi subi muli divi andi ori xori sli sri srui
                       cmpi cmpui goi) :test #'eq)
          (let ((x (parse-reg (second form)))
                (y (parse-reg (third form)))
                (imm (u8 (resolve-imm (fourth form) labels pc))))
            (list (op-byte op) x y imm)))
         (t
          ;; Register-register: OP $X,$Y,$Z
          (let ((x (parse-reg (second form)))
                (y (parse-reg (third form)))
                (z (parse-reg (fourth form))))
            (list (op-byte op) x y z))))))))

(defun assemble (program &key (origin 0))
  "Assemble PROGRAM (list starting with PROGRAM or bare forms).
Returns (values bytes origin labels)."
  (let* ((forms (if (and (consp program)
                         (symbolp (first program))
                         (string-equal (symbol-name (first program)) "PROGRAM"))
                    (rest program)
                    program))
         (org origin)
         ;; allow leading :org
         (_ (when (and forms (consp (first forms)) (eq (caar forms) :org))
              (setf org (second (first forms)))))
         (labels (collect-labels forms org))
         (out (make-array 64 :element-type '(unsigned-byte 8)
                          :adjustable t :fill-pointer 0))
         (pc org))
    (declare (ignore _))
    (dolist (form forms)
      (cond
        ((and (consp form) (eq (first form) :org))
         (setf pc (second form)))
        ((and (consp form) (string-equal (symbol-name (first form)) "LABEL"))
         nil)
        ((consp form)
         (let ((bytes (encode-form form labels pc)))
           (dolist (b bytes)
             (vector-push-extend b out))
           (incf pc (length bytes))))))
    (values (coerce out '(simple-array (unsigned-byte 8) (*)))
            org
            labels)))

(defun assemble-into (vm program &key (origin 0))
  "Assemble PROGRAM and write bytes into VM memory at ORIGIN (or :org)."
  (multiple-value-bind (bytes org labels) (assemble program :origin origin)
    (loop for i from 0 below (length bytes)
          do (mem-set-u8 vm (+ org i) (aref bytes i)))
    (setf (vm-pc vm) (u64 org)
          (vm-halted vm) nil
          (vm-cycles vm) 0)
    (values vm org labels)))

(defun load-program (vm bytes &key (origin 0))
  "Load a byte vector into VM at ORIGIN and set PC."
  (loop for i from 0 below (length bytes)
        do (mem-set-u8 vm (+ origin i) (aref bytes i)))
  (setf (vm-pc vm) (u64 origin)
        (vm-halted vm) nil
        (vm-cycles vm) 0)
  vm)
