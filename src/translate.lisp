(in-package #:cl-mmix)

;;; Virtual addresses (§44–47). Loaded after the kernel so a miss can force
;;; a trap. Default make-vm leaves vm-virtual-memory nil: fetch and mem-ref
;;; keep the identity map, and LDVTS returns 0.
;;;
;;; rV, from the top: b1 b2 b3 b4 (4 bits each), s (8), r (27), n (10), f (3).
;;; b0 is 0. A PTE's low bits are pr pw px in bits 2–0, then a 10-bit n.
;;; A page-table pointer has its sign bit set and the same n.

(defun unpack-rv (rv)
  "Return b1 b2 b3 b4 s r n f."
  (values (ldb (byte 4 60) rv)
          (ldb (byte 4 56) rv)
          (ldb (byte 4 52) rv)
          (ldb (byte 4 48) rv)
          (ldb (byte 8 40) rv)
          (ldb (byte 27 13) rv)
          (ldb (byte 10 3) rv)
          (ldb (byte 3 0) rv)))

(defun pack-rv (b1 b2 b3 b4 s r n f)
  "Build an rV octa from the §44 fields."
  (logior (ash (logand b1 #xf) 60)
          (ash (logand b2 #xf) 56)
          (ash (logand b3 #xf) 52)
          (ash (logand b4 #xf) 48)
          (ash (logand s #xff) 40)
          (ash (logand r #x7ffffff) 13)
          (ash (logand n #x3ff) 3)
          (logand f 7)))

(defun make-pte (phys &key (n 0) (pr nil) (pw nil) (px nil) (s 13))
  "One page-table entry. PHYS is the physical page address, aligned to 2^s."
  (logior (logand (u64 phys) (lognot (1- (ash 1 s))))
          (ash (logand n #x3ff) 3)
          (if pr 4 0)
          (if pw 2 0)
          (if px 1 0)))

(defun make-ptp (phys &key (n 0))
  "A page-table pointer: sign bit set, physical base, n matching rV."
  (logior #x8000000000000000
          (logand (u64 phys) (lognot #x1fff))
          (ash (logand n #x3ff) 3)))

(defun trans-key (va s n)
  "§46 key: the virtual page base with rV's n in bits 12–3."
  (logior (logand (u64 va) (lognot (1- (ash 1 s))))
          (ash (logand n #x3ff) 3)))

(defun accept-ptp (raw n)
  "A pointer whose sign bit is set and whose n matches. Low 13 bits are cleared.
Zero when the octa is not a pointer for this address space."
  (if (and (logbitp 63 raw)
           (= (ldb (byte 10 3) raw) (logand n #x3ff)))
      (logandc2 raw #x1fff)
      0))

(defun accept-pte (raw n s)
  "Normalized translation: physical base in bits 47–s, protection in bits 2–0.
Zero when n does not match rV. Bits above 47 are dropped, so a PTE cannot name I/O."
  (if (= (ldb (byte 10 3) raw) (logand n #x3ff))
      (logand (logior (logandc2 raw (1- (ash 1 s)))
                      (logand raw 7))
              #x0000ffffffffffff)
      0))

(defun page-digits (page)
  "10-bit digits of PAGE, least significant first. The count is 0 when PAGE is 0."
  (let ((digits nil)
        (n 0)
        (q page))
    (loop while (plusp q)
          do (setf digits (nconc digits (list (logand q #x3ff))))
             (setf q (ash q -10))
             (incf n))
    (values digits n)))

(defun walk-pte (vm va s r n b)
  "Walk the page table for nonnegative VA. Return (values translation cachep).
CACHEP is false when the segment cannot hold the page. A zero translation is
cached when the walk ran and the entry did not grant the address."
  (let ((seg (ldb (byte 2 61) va))
        (page (ash (logand va (1- (ash 1 61))) (- s))))
    (multiple-value-bind (digits j) (page-digits page)
      (when (< (aref b (1+ seg)) (+ (aref b seg) j))
        (return-from walk-pte (values 0 nil)))
      (when (zerop j)
        (setf j 1
              digits (list 0)))
      (let ((phys (ash (+ r (aref b seg) (1- j)) 13)))
        (loop for k from (1- j) downto 0
              for digit = (nth k digits)
              for raw = (physical-ref vm (+ phys (* 8 digit)) 8)
              do (if (plusp k)
                     (let ((ptp (accept-ptp raw n)))
                       (when (zerop ptp)
                         (return-from walk-pte (values 0 t)))
                       (setf phys (logand ptp #x7fffffffffffffff)))
                     (return-from walk-pte (values (accept-pte raw n s) t))))))))

(defun protection-ok (trans perm)
  (ecase perm
    (:read (logbitp 2 trans))
    (:write (logbitp 1 trans))
    (:exec (logbitp 0 trans))
    (:cswap (and (logbitp 2 trans) (logbitp 1 trans)))))

(defun fail-bits (trans perm)
  (ecase perm
    (:read +rq-r+)
    (:write +rq-w+)
    (:exec +rq-x+)
    (:cswap (logior (if (logbitp 2 trans) 0 +rq-r+)
                    (if (logbitp 1 trans) 0 +rq-w+)))))

(defun deny-access (vm perm trans)
  "Record the missing permission. An execute failure does not retire the fetch."
  (if (eq perm :exec)
      (error 'mmix-suppress :bit +rq-x+)
      (raise-program-bit vm (fail-bits trans perm))))

(defun software-miss (vm va)
  "f = 1 and the cache missed. rXX's high tetra is #x03000000. rYY is VA.
A fetch has no instruction yet, so the tetra is SWYM and ropcode 3 fills the
instruction cache. Any other opcode fills the data cache."
  (let ((raw (if *exec-inst*
                 (inst-raw *exec-inst*)
                 (encode :swym 0 0 0))))
    (force-trap vm +r-t+
                :ww (vm-pc vm)
                :xx (logior (ash #x03000000 32) raw)
                :yy (u64 va)
                :zz 0))
  (error 'mmix-taken-trap))

(defun finish-trans (vm va trans perm s)
  "Physical address, or NIL NIL when PERM is missing. Execute failure signals."
  (unless (protection-ok trans perm)
    (deny-access vm perm trans)
    (return-from finish-trans (values nil nil)))
  (values (logior (logandc2 trans (1- (ash 1 s)))
                  (logand (u64 va) (1- (ash 1 s))))
          t))

(defun translate (vm va perm)
  "Map VA for PERM, one of :READ :WRITE :EXEC :CSWAP.
Return (values physical t), or (values nil nil) when the access is dropped.
A negative VA from a negative PC clears bit 63. From a nonnegative PC it sets n.
Physical 0 is a successful translation: the second value distinguishes it."
  (setf va (u64 va))
  (when (logbitp 63 va)
    (if (logbitp 63 (vm-pc vm))
        (return-from translate (values (logand va #x7fffffffffffffff) t))
        (progn
          (raise-program-bit vm +rq-n+)
          (return-from translate (values nil nil)))))
  (multiple-value-bind (b1 b2 b3 b4 s r n f) (unpack-rv (special-reg vm +r-v+))
    (when (or (> f 1) (< s 13) (> s 48))
      (deny-access vm perm 0)
      (return-from translate (values nil nil)))
    (let* ((key (trans-key va s n))
           (table (if (eq perm :exec) (vm-itc vm) (vm-dtc vm))))
      (multiple-value-bind (hit present) (gethash key table)
        (when present
          (return-from translate (finish-trans vm va hit perm s))))
      (when (= f 1)
        (software-miss vm va)
        (return-from translate (values nil nil)))
      (multiple-value-bind (trans cachep)
          (walk-pte vm va s r n (vector 0 b1 b2 b3 b4))
        (when cachep
          (setf (gethash key table) trans))
        (finish-trans vm va trans perm s)))))

(defun fetch-tetra (vm addr)
  "The instruction tetra at ADDR. Virtual memory asks for execute permission.
With caches on, a hit comes from the instruction cache."
  (if (vm-virtual-memory vm)
      (multiple-value-bind (phys ok) (translate vm addr :exec)
        (cond ((not ok) 0)
              ((vm-caches vm)
               (cache-read-physical (vm-icache vm) vm phys 4))
              (t (physical-ref vm phys 4))))
      (if (vm-caches vm)
          (multiple-value-bind (phys ok) (resolve-identity-address vm addr)
            (if ok
                (cache-read-physical (vm-icache vm) vm phys 4)
                0))
          (mem-ref-u32 vm addr :internal t))))

(defun guest-load (vm addr nbytes)
  (multiple-value-bind (phys ok) (translate vm addr :read)
    (cond ((not ok) 0)
          ((vm-caches vm)
           (cache-read-physical (vm-dcache vm) vm phys nbytes))
          (t (physical-ref vm phys nbytes)))))

(defun guest-store (vm addr nbytes value)
  (multiple-value-bind (phys ok) (translate vm addr :write)
    (when ok
      (if (vm-caches vm)
          (cache-write-physical (vm-dcache vm) vm phys nbytes value)
          (physical-set vm phys nbytes value)))
    value))

(defun probe-translation (vm va)
  "The cached or walked translation octa, or NIL when the page cannot be written.
Does not set rQ and does not fill the cache. Used by the register spill."
  (setf va (u64 va))
  (when (logbitp 63 va)
    (return-from probe-translation nil))
  (multiple-value-bind (b1 b2 b3 b4 s r n f) (unpack-rv (special-reg vm +r-v+))
    (when (or (> f 1) (< s 13) (> s 48) (= f 1))
      (let ((hit (and (<= 13 s 48)
                      (gethash (trans-key va s n) (vm-dtc vm)))))
        (return-from probe-translation hit)))
    (let ((key (trans-key va s n)))
      (multiple-value-bind (hit present) (gethash key (vm-dtc vm))
        (when present
          (return-from probe-translation hit)))
      (nth-value 0 (walk-pte vm va s r n (vector 0 b1 b2 b3 b4))))))

(defun rc-physical (vm va)
  "Physical byte on the continuation page. rC is a PTE; the offset comes from VA."
  (let* ((s (ldb (byte 8 40) (special-reg vm +r-v+)))
         (s (if (<= 13 s 48) s 13))
         (mask (1- (ash 1 s)))
         (base (logand (logandc2 (special-reg vm +r-c+) mask)
                       #xffffffffffff)))
    (logior base (logand (u64 va) mask))))

(defun stack-spill-target (vm va)
  "Return (values nil nil) when the virtual page has pw.
Return (values physical t) when the spill must use rC instead."
  (let ((trans (probe-translation vm va)))
    (if (and trans (logbitp 1 trans))
        (values nil nil)
        (values (rc-physical vm va) t))))

(defun ldvts (vm sum)
  "Look up $Y+Z in both translation caches. The low three bits replace p,
and p = 0 removes the key. $X is 0, 1 (instruction), 2 (data), or 3 (both)."
  (let* ((sum (u64 sum))
         (p (logand sum 7))
         (key (logandc2 sum 7))
         (result 0))
    (flet ((touch (table bit)
             (multiple-value-bind (trans present) (gethash key table)
               (when present
                 (incf result bit)
                 (if (zerop p)
                     (remhash key table)
                     (setf (gethash key table)
                           (logior (logandc2 trans 7) p)))))))
      (touch (vm-dtc vm) 2)
      (touch (vm-itc vm) 1))
    result))

(defun drop-translation-caches (vm)
  "SYNC 6. Both caches lose every key."
  (clrhash (vm-itc vm))
  (clrhash (vm-dtc vm))
  vm)

(defun installed-pte (pte s)
  "RESUME ropcode 3 keeps the physical base and the low three protection bits.
The handler's n is not re-checked; bits above 47 are dropped."
  (logand (logior (logandc2 (u64 pte) (1- (ash 1 s)))
                  (logand (u64 pte) 7))
          #x0000ffffffffffff))

(defun install-resumed-translation (vm which va pte)
  "Ropcode 3. WHICH is :INST when the trapped tetra is SWYM, otherwise :DATA.
The key is the page of VA under the current rV."
  (when (vm-virtual-memory vm)
    (multiple-value-bind (b1 b2 b3 b4 s r n f)
        (unpack-rv (special-reg vm +r-v+))
      (declare (ignore b1 b2 b3 b4 r f))
      (when (<= 13 s 48)
        (setf (gethash (trans-key va s n)
                       (if (eq which :inst) (vm-itc vm) (vm-dtc vm)))
              (installed-pte pte s)))))
  vm)

(defun install-segment-pages (vm segment ptes &key (s 13) (n 0) (r #x20) (f 0))
  "Write a one-level table and set rV. Each segment has 1024 pages (b[i+1] = b[i]+1).
PTES are the entries for virtual pages 0, 1, … of SEGMENT. Roots sit at
physical 2^13 (r + segment), so the default r keeps them away from a program
at the bottom of memory. Calling this for a second segment keeps the first
segment's entries; both calls must use the same r, s, n, and f."
  (set-special vm +r-v+ (pack-rv 1 2 3 4 s r n f))
  (let ((root (ash (+ r segment) 13)))
    (loop for pte in ptes
          for i from 0
          do (physical-set vm (+ root (* 8 i)) 8 pte)))
  vm)
