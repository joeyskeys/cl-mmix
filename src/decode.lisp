(in-package #:cl-mmix)

;;; Opcode table for the implemented MVP subset.
;;; Values match Knuth's MMIX opcodes.

(defparameter +op+
  '((:trap  . #x00)
    (:add   . #x20) (:addi  . #x21)
    (:sub   . #x24) (:subi  . #x25)
    (:mul   . #x18) (:muli  . #x19)
    (:div   . #x1C) (:divi  . #x1D)
    (:and   . #xC8) (:andi  . #xC9)
    (:or    . #xC0) (:ori   . #xC1)
    (:xor   . #xC6) (:xori  . #xC7)
    (:sl    . #x38) (:sli   . #x39)
    (:sr    . #x3C) (:sri   . #x3D)
    (:sru   . #x3E) (:srui  . #x3F)
    (:cmp   . #x30) (:cmpi  . #x31)
    (:cmpu  . #x32) (:cmpui . #x33)
    (:ldb   . #x80) (:ldbu  . #x82)
    (:ldw   . #x84) (:ldwu  . #x86)
    (:ldo   . #x8C) (:ldou  . #x8E)
    (:stb   . #xA0)
    (:stw   . #xA4)
    (:sto   . #xAC)
    (:bn    . #x40) (:bnz   . #x41)
    (:bz    . #x42) (:bnn   . #x43)
    (:bp    . #x44) (:bnp   . #x45)
    (:bod   . #x46) (:bev   . #x47)
    (:pbn   . #x48) (:pbnz  . #x49) ; treated like BN/BNZ (no prediction)
    (:pbz   . #x4A) (:pbnn  . #x4B)
    (:pbp   . #x4C) (:pbnp  . #x4D)
    (:jmp   . #xF0)
    (:go    . #x9E) (:goi   . #x9F)
    (:seth  . #xE0) (:setmh . #xE1) (:setml . #xE2) (:setl . #xE3)
    (:inch  . #xE4) (:incmh . #xE5) (:incml . #xE6) (:incl . #xE7)
    (:orh   . #xE8) (:ormh  . #xE9) (:orml  . #xEA) (:orl  . #xEB)
    (:geta  . #xF4)
    (:set   . #xC1) ; assembler expands SET specially
    )
  "Alist of opcode keywords → byte values.")

(defparameter +op-name+
  (let ((tbl (make-hash-table :test 'eql)))
    (dolist (pair +op+)
      (setf (gethash (cdr pair) tbl) (car pair)))
    ;; Prefer primary names for shared opcodes
    (setf (gethash #xC1 tbl) :ori)
    tbl)
  "Hash: opcode byte → keyword.")

(defun op-name-key (name)
  "Normalize opcode designator to a keyword."
  (cond
    ((keywordp name) name)
    ((symbolp name) (intern (symbol-name name) :keyword))
    ((stringp name) (intern (string-upcase name) :keyword))
    (t (error "Bad opcode designator: ~S" name))))

(defun op-byte (name)
  (let ((key (op-name-key name)))
    (or (cdr (assoc key +op+ :test #'eq))
        (error "Unknown opcode name: ~S" name))))

(defun op-name (byte)
  (gethash (u8 byte) +op-name+ :unknown))

(defstruct (instruction (:conc-name inst-))
  (op 0 :type (unsigned-byte 8))
  (x  0 :type (unsigned-byte 8))
  (y  0 :type (unsigned-byte 8))
  (z  0 :type (unsigned-byte 8))
  (raw 0 :type (unsigned-byte 32)))

(defun decode (word)
  "Decode a 32-bit big-endian instruction word into an INSTRUCTION."
  (let ((w (u32 word)))
    (make-instruction
     :op  (ldb (byte 8 24) w)
     :x   (ldb (byte 8 16) w)
     :y   (ldb (byte 8 8) w)
     :z   (ldb (byte 8 0) w)
     :raw w)))

(defun encode (op x y z)
  "Encode OP X Y Z into a 32-bit instruction word."
  (logior (ash (u8 (if (symbolp op) (op-byte op) op)) 24)
          (ash (u8 x) 16)
          (ash (u8 y) 8)
          (u8 z)))

(defun inst-yz (inst)
  "Unsigned 16-bit YZ field."
  (logior (ash (inst-y inst) 8) (inst-z inst)))

(defun inst-xyz (inst)
  "Unsigned 24-bit XYZ field."
  (logior (ash (inst-x inst) 16)
          (ash (inst-y inst) 8)
          (inst-z inst)))

(defun fetch (vm)
  "Fetch the 32-bit instruction at PC (does not advance PC)."
  (mem-ref-u32 vm (vm-pc vm)))

(defun immediate-op-p (op)
  "True if Z is an immediate (xxxI forms) or YZ is immediate (SET*/INC*/OR*/branches)."
  (member (if (integerp op) (op-name op) (op-name-key op))
          '(:addi :subi :muli :divi :andi :ori :xori :sli :sri :srui :cmpi :cmpui
            :goi :seth :setmh :setml :setl :inch :incmh :incml :incl
            :orh :ormh :orml :orl :geta :jmp
            :bn :bnz :bz :bnn :bp :bnp :bod :bev
            :pbn :pbnz :pbz :pbnn :pbp :pbnp)
          :test #'eq))

(defun disassemble-at (vm &optional (addr (vm-pc vm)))
  "Return a human-readable string for the instruction at ADDR."
  (let* ((word (mem-ref-u32 vm addr))
         (inst (decode word))
         (name (op-name (inst-op inst)))
         (x (inst-x inst))
         (y (inst-y inst))
         (z (inst-z inst))
         (yz (inst-yz inst)))
    (case name
      ((:seth :setmh :setml :setl :inch :incmh :incml :incl :orh :ormh :orml :orl :geta)
       (format nil "~A $~D,#~X" name x yz))
      ((:jmp)
       (format nil "~A #~X" name (inst-xyz inst)))
      ((:bn :bnz :bz :bnn :bp :bnp :bod :bev :pbn :pbnz :pbz :pbnn :pbp :pbnp)
       (format nil "~A $~D,#~X" name x yz))
      ((:trap)
       (format nil "TRAP ~D,~D,~D" x y z))
      ((:addi :subi :muli :divi :andi :ori :xori :sli :sri :srui :cmpi :cmpui :goi)
       (format nil "~A $~D,$~D,~D" name x y z))
      ((:unknown unknown)
       (format nil "??? #~8,'0X" word))
      (otherwise
       (format nil "~A $~D,$~D,$~D" name x y z)))))
