(in-package #:cl-mmix)

;;; Kernel traps (§36–38). Loaded after the assembler so the ROM is a tetra
;;; image. Default make-vm never calls this file's entry points.
;;;
;;; The ROM lives at +ROM-BASE+. Clearing bit 63 yields physical #x100000000,
;;; which is where plan 06's φ will find it. Until then the fetcher, and only
;;; the fetcher, reads the image; other negative addresses clear bit 63 and
;;; use vm-memory.
;;;
;;; The first instruction is SWYM with XYZ #x485354 ("HST"). That is the host
;;; call. It runs only when the PC is negative on a kernel VM, so a user SWYM
;;; with the same XYZ stays a no-op. The call reads X, Y, and Z from the low
;;; tetra of rXX and performs the MMIX-SIM service. Halt, the trip report, and
;;; an unsupported TRAP stop inside the call. A file service returns, and the
;;; following guest instructions put the result where RESUME 1 expects it:
;;;
;;;   PUT rBB, $255     ; rBB ← the value the service stored in $255
;;;   $255 ← all ones   ; the mask RESUME 1 writes back to rK
;;;   RESUME 1          ; rK ← $255, $255 ← rBB, PC ← rWW
;;;
;;; Only $255 and rBB are written, so the user's local registers survive.

(defconstant +rom-base+ #x8000000100000000)
(defconstant +host-swym-xyz+ #x485354)

(defun kernel-rom-image ()
  (multiple-value-bind (segments origin)
      (assemble '((swym #x485354)
                  (put rbb $255)
                  (seth $255 #xffff)
                  (ormh $255 #xffff)
                  (orml $255 #xffff)
                  (orl $255 #xffff)
                  (resume 1))
                :origin 0)
    (declare (ignore origin))
    (unless (and segments (null (rest segments)))
      (error "kernel ROM assembled into more than one segment"))
    (cdr (first segments))))

(defparameter *kernel-rom* (kernel-rom-image)
  "Byte vector of the trap ROM. Shared by every kernel VM; nothing writes it.")

(defun install-kernel (vm)
  "Point rT and rTT at the ROM and unmask every interrupt for user code."
  (setf (vm-rom vm) *kernel-rom*
        (vm-rom-base vm) +rom-base+)
  (set-special vm +r-t+ +rom-base+)
  (set-special vm +r-tt+ +rom-base+)
  (set-special vm +r-k+ #xffffffffffffffff)
  vm)

(defun rom-tetra (vm addr)
  (let ((rom (vm-rom vm))
        (base (vm-rom-base vm)))
    (if (and rom
             (<= base addr)
             (<= (+ addr 4) (+ base (length rom))))
        (let ((i (- addr base)))
          (values (logior (ash (aref rom i) 24)
                          (ash (aref rom (+ i 1)) 16)
                          (ash (aref rom (+ i 2)) 8)
                          (aref rom (+ i 3)))
                  t))
        (values nil nil))))

(defun host-swym-p (vm inst)
  (and (vm-kernel vm)
       (logbitp 63 (vm-pc vm))
       (= (inst-xyz inst) +host-swym-xyz+)))

(defun host-dispatch (vm)
  "Service the TRAP whose tetra sits in rXX. File calls return to the ROM.
X = 0 and Y = 1…10 are the MMIX-SIM services. Halt and the trip report are
X = Y = 0 with Z = 0 or 1. Every other XYZ halts with the unsupported message."
  (let* ((tetra (logand (special-reg vm +r-xx+) #xffffffff))
         (x (ldb (byte 8 16) tetra))
         (y (ldb (byte 8 8) tetra))
         (z (ldb (byte 8 0) tetra)))
    (cond
      ((and (zerop x) (zerop y) (<= z 1))
       (service-trap vm x y z))
      ((and (zerop x) (<= 1 y 10))
       (service-trap vm x y z))
      (t
       (setf (vm-fault vm) (format nil "unsupported TRAP ~D,~D,~D" x y z))
       (halt-vm vm)
       :stop))))

(defun force-trap (vm dest &key (ww 0) (xx 0) (yy 0) (zz 0))
  "Bootstrap a forced trap. $255 is copied to rBB and otherwise left alone."
  (set-special vm +r-bb+ (reg vm 255))
  (set-special vm +r-k+ 0)
  (set-special vm +r-ww+ ww)
  (set-special vm +r-xx+ xx)
  (set-special vm +r-yy+ yy)
  (set-special vm +r-zz+ zz)
  (setf (vm-pc vm) (special-reg vm dest))
  vm)

(defun enter-forced-trap (vm inst)
  "TRAP. rWW is the next instruction. rXX has high tetra #x80000000."
  (force-trap vm +r-t+
              :ww (u64 (+ (vm-pc vm) 4))
              :xx (logior (ash #x80000000 32) (inst-raw inst))
              :yy (reg vm (inst-y inst))
              :zz (reg vm (inst-z inst)))
  :jump)

(defun deliver-dynamic-trap (vm)
  "At a nonnegative PC, a hole in rK's program mask sets s in rQ and rK.
Then rQ ∧ rK enters rTT with rWW pointing at the instruction not yet run.
Returns true when that instruction must not be fetched."
  (unless (vm-kernel vm)
    (return-from deliver-dynamic-trap nil))
  (let ((pc (vm-pc vm)))
    (when (and (not (logbitp 63 pc))
               (/= (logand (special-reg vm +r-k+) +rq-prog+) +rq-prog+))
      (raise-program-bit vm +rq-s+)
      (set-special vm +r-k+ (logior (special-reg vm +r-k+) +rq-s+)))
    (when (zerop (logand (special-reg vm +r-q+) (special-reg vm +r-k+)))
      (return-from deliver-dynamic-trap nil))
    (let* ((tetra (handler-case
                      (mem-ref-u32 vm (logand pc (lognot 3)) :internal t)
                    (mmix-fault () 0)))
           (inst (decode tetra)))
      (force-trap vm +r-tt+
                  :ww pc
                  :xx (logior #x8000000000000000 (logand tetra #xffffffff))
                  :yy (reg vm (inst-y inst))
                  :zz (reg vm (inst-z inst))))
    t))
