(in-package #:cl-mmix)

;;; Line caches for one processor (§30–31). Off unless make-vm is passed
;;; :caches t. Translation caches stay in src/translate.lisp.
;;;
;;; A store retires into the data cache and marks the line dirty. Memory keeps
;;; the previous bytes until SYNCD, SYNC 5, or a write-through configuration
;;; writes them back. LDUNC reads memory and does not allocate. STUNC writes
;;; memory and drops the matching data line. Addresses at or above 2^48 are
;;; I/O only after translation; the identity map still caches the data segment.
;;;
;;; The sign bit of a SYNCD, SYNCID, or PRE* address selects the variant.
;;; The low 63 bits select the bytes. Missing permission does not raise rQ.

;;; probe-translation and translate are defined in src/translate.lisp.
(declaim (ftype (function (t t) t) probe-translation)
         (ftype (function (t t t) (values t t &optional)) translate))

(defstruct cache-line
  (tag 0 :type (unsigned-byte 64))
  (valid nil :type boolean)
  (dirty nil :type boolean)
  (stamp 0 :type unsigned-byte)
  (data nil))

(defstruct (line-cache (:constructor %make-line-cache))
  (blocksize 64 :type unsigned-byte)
  (associativity 2 :type unsigned-byte)
  (sets 256 :type unsigned-byte)
  (writeback t :type boolean)
  (writeallocate t :type boolean)
  (accesstime 2 :type unsigned-byte)
  (stamp 0 :type unsigned-byte)
  (table nil))

(defun power-of-two-p (n)
  (and (integerp n) (plusp n) (zerop (logand n (1- n)))))

(defun cache-plist (config key default)
  (if (and (listp config) (member key config))
      (getf config key)
      default))

(defun make-line-cache (config)
  (let ((assoc (cache-plist config :associativity 2))
        (block (cache-plist config :blocksize 64))
        (sets (cache-plist config :sets 256)))
    (unless (and (integerp assoc) (>= assoc 1))
      (error "cache associativity must be a positive integer"))
    (unless (power-of-two-p block)
      (error "cache blocksize must be a power of two"))
    (unless (power-of-two-p sets)
      (error "cache set count must be a power of two"))
    (let ((cache (%make-line-cache
                  :associativity assoc
                  :blocksize block
                  :sets sets
                  :writeback (and (cache-plist config :writeback t) t)
                  :writeallocate (and (cache-plist config :writeallocate t) t)
                  :accesstime (let ((n (cache-plist config :accesstime 2)))
                                (if (and (integerp n) (>= n 0)) n 2))
                  :table (make-array sets))))
      (dotimes (s sets cache)
        (let ((ways (make-array assoc)))
          (dotimes (w assoc)
            (setf (aref ways w) (make-cache-line)))
          (setf (aref (line-cache-table cache) s) ways))))))

(defun install-caches (vm config)
  "Build the instruction and data caches. A secondary cache exists when
the plist contains :SECONDARY true."
  (setf (vm-caches vm) t
        (vm-cache-config vm) config
        (vm-dcache vm) (make-line-cache config)
        (vm-icache vm) (make-line-cache config)
        (vm-scache vm) (when (cache-plist config :secondary nil)
                         (make-line-cache config)))
  vm)

(defun line-tag (cache phys)
  (logand (u64 phys) (lognot (1- (line-cache-blocksize cache)))))

(defun line-set-index (cache phys)
  (logand (floor (u64 phys) (line-cache-blocksize cache))
          (1- (line-cache-sets cache))))

(defun find-line (cache phys)
  (let ((tag (line-tag cache phys))
        (set (aref (line-cache-table cache) (line-set-index cache phys))))
    (loop for line across set
          when (and (cache-line-valid line)
                    (= (cache-line-tag line) tag))
            return line)))

(defun touch-line (cache line)
  (setf (cache-line-stamp line) (incf (line-cache-stamp cache)))
  line)

(defun cache-victim (set)
  (or (find-if (lambda (line) (not (cache-line-valid line))) set)
      (reduce (lambda (a b)
                (if (<= (cache-line-stamp a) (cache-line-stamp b)) a b))
              set)))

(defun io-physical-p (vm addr)
  (and (vm-virtual-memory vm)
       (>= (logand (u64 addr) #x7fffffffffffffff) (ash 1 48))))

(defun hash-load (vm addr nbytes)
  (let ((acc 0))
    (dotimes (i nbytes acc)
      (setf acc (logior (ash acc 8) (%chunk-byte vm (+ addr i)))))))

(defun hash-store (vm addr nbytes value)
  (let ((value (logand (u64 value) (1- (ash 1 (* 8 nbytes))))))
    (loop for i from 0 below nbytes
          for shift from (* 8 (1- nbytes)) downto 0 by 8
          do (%chunk-byte vm (+ addr i) (ldb (byte 8 shift) value)))
    value))

(defun fill-block (vm cache tag)
  (let* ((n (line-cache-blocksize cache))
         (data (make-array n :element-type '(unsigned-byte 8)))
         (scache (vm-scache vm)))
    (loop for i from 0 below n
          for addr = (+ tag i)
          for upper = (and scache
                           (not (eq cache scache))
                           (find-line scache addr))
          do (setf (aref data i)
                   (if upper
                       (aref (cache-line-data upper)
                             (logand addr (1- (line-cache-blocksize scache))))
                       (%chunk-byte vm addr))))
    data))

(defun write-backing-bytes (vm cache addr data start len)
  (if (and (vm-scache vm) (not (eq cache (vm-scache vm))))
      (secondary-deposit vm addr data start len)
      (loop for i from 0 below len
            do (%chunk-byte vm (+ addr i) (aref data (+ start i))))))

(defun commit-line (vm cache line)
  (when (and (cache-line-valid line) (cache-line-dirty line))
    (write-backing-bytes vm cache (cache-line-tag line)
                         (cache-line-data line) 0
                         (length (cache-line-data line)))
    (setf (cache-line-dirty line) nil))
  line)

(defun install-line (vm cache phys)
  (let ((hit (find-line cache phys)))
    (when hit
      (return-from install-line (touch-line cache hit)))
    (let* ((set (aref (line-cache-table cache) (line-set-index cache phys)))
           (line (cache-victim set))
           (tag (line-tag cache phys)))
      (when (cache-line-valid line)
        (commit-line vm cache line)
        (setf (cache-line-valid line) nil))
      (setf (cache-line-tag line) tag
            (cache-line-data line) (fill-block vm cache tag)
            (cache-line-valid line) t
            (cache-line-dirty line) nil)
      (touch-line cache line))))

(defun secondary-deposit (vm addr data start len)
  (let* ((cache (vm-scache vm))
         (bs (line-cache-blocksize cache))
         (line (install-line vm cache addr))
         (off (logand (u64 addr) (1- bs))))
    (loop for i from 0 below len
          do (setf (aref (cache-line-data line) (+ off i))
                   (aref data (+ start i))))
    (setf (cache-line-dirty line) t)
    line))

(defun line-extract (line offset nbytes)
  (let ((acc 0))
    (loop for i from 0 below nbytes
          do (setf acc (logior (ash acc 8)
                               (aref (cache-line-data line) (+ offset i)))))
    acc))

(defun line-deposit (line offset nbytes value)
  (loop for i from 0 below nbytes
        for shift from (* 8 (1- nbytes)) downto 0 by 8
        do (setf (aref (cache-line-data line) (+ offset i))
                 (ldb (byte 8 shift) value))))

(defun cache-read-physical (cache vm phys nbytes)
  "Read NBYTES at physical PHYS through CACHE. I/O skips the cache."
  (setf phys (logand (u64 phys) #x7fffffffffffffff))
  (when (io-physical-p vm phys)
    (return-from cache-read-physical (physical-ref vm phys nbytes)))
  (let ((acc 0)
        (left nbytes)
        (addr phys)
        (bs (line-cache-blocksize cache)))
    (loop while (plusp left)
          for off = (logand addr (1- bs))
          for take = (min left (- bs off))
          for line = (install-line vm cache addr)
          do (setf acc (logior (ash acc (* 8 take))
                               (line-extract line off take)))
             (incf addr take)
             (decf left take))
    acc))

(defun cache-write-physical (cache vm phys nbytes value)
  "Store VALUE at physical PHYS. A write-back miss allocates a dirty line."
  (setf phys (logand (u64 phys) #x7fffffffffffffff))
  (setf value (logand (u64 value) (1- (ash 1 (* 8 nbytes)))))
  (when (io-physical-p vm phys)
    (return-from cache-write-physical (physical-set vm phys nbytes value)))
  (let ((left nbytes)
        (addr phys)
        (bs (line-cache-blocksize cache)))
    (loop while (plusp left)
          for off = (logand addr (1- bs))
          for take = (min left (- bs off))
          for shift = (* 8 (- left take))
          for chunk = (ldb (byte (* 8 take) shift) value)
          do (cond
               ((and (not (line-cache-writeallocate cache))
                     (not (find-line cache addr)))
                (hash-store vm addr take chunk))
               (t
                (let ((line (install-line vm cache addr)))
                  (line-deposit line off take chunk)
                  (if (line-cache-writeback cache)
                      (setf (cache-line-dirty line) t)
                      (hash-store vm addr take chunk)))))
             (incf addr take)
             (decf left take)))
  value)

(defun cache-data-read (vm addr nbytes)
  (multiple-value-bind (phys ok) (resolve-identity-address vm addr)
    (if ok
        (cache-read-physical (vm-dcache vm) vm phys nbytes)
        0)))

(defun cache-data-write (vm addr nbytes value)
  (multiple-value-bind (phys ok) (resolve-identity-address vm addr)
    (if ok
        (cache-write-physical (vm-dcache vm) vm phys nbytes value)
        0)))

(defun cache-note-load-byte (vm phys)
  "The cached data byte at PHYS, when a line already holds it."
  (let ((cache (vm-dcache vm))
        (phys (u64 phys)))
    (let ((line (and cache (find-line cache phys))))
      (if line
          (values (aref (cache-line-data line)
                        (logand phys (1- (line-cache-blocksize cache))))
                  t)
          (values 0 nil)))))

(defun cache-note-store-byte (vm phys value)
  "An identity write updated memory. A resident data line takes the same byte,
and a resident instruction line is dropped so the next fetch reads memory."
  (let ((phys (u64 phys))
        (dcache (vm-dcache vm)))
    (when dcache
      (let ((line (find-line dcache phys)))
        (when line
          (setf (aref (cache-line-data line)
                      (logand phys (1- (line-cache-blocksize dcache))))
                (u8 value)))))
    (invalidate-span (vm-icache vm) phys 1))
  value)

(defun map-valid-lines (cache addr nbytes fn)
  (when cache
    (let ((bs (line-cache-blocksize cache))
          (left nbytes)
          (addr (logand (u64 addr) #x7fffffffffffffff)))
      (loop while (plusp left)
            for off = (logand addr (1- bs))
            for take = (min left (- bs off))
            for line = (find-line cache addr)
            do (when line
                 (funcall fn line off take))
               (incf addr take)
               (decf left take)))))

(defun invalidate-span (cache addr nbytes)
  (map-valid-lines cache addr nbytes
                   (lambda (line offset take)
                     (declare (ignore offset take))
                     (setf (cache-line-valid line) nil
                           (cache-line-dirty line) nil))))

(defun writeback-span (vm cache addr nbytes &key evict)
  (map-valid-lines cache addr nbytes
                   (lambda (line offset take)
                     (when (cache-line-dirty line)
                       (write-backing-bytes vm cache
                                            (+ (cache-line-tag line) offset)
                                            (cache-line-data line)
                                            offset take)
                       (when (>= take (line-cache-blocksize cache))
                         (setf (cache-line-dirty line) nil)))
                     (when evict
                       (setf (cache-line-valid line) nil
                             (cache-line-dirty line) nil)))))

(defun page-size-of (vm)
  (let ((s (ldb (byte 8 40) (special-reg vm +r-v+))))
    (ash 1 (if (<= 13 s 48) s 13))))

(defun maintenance-phys (vm va)
  "Physical address for a cache-maintenance byte, or NIL when the page
does not translate. Does not set rQ."
  (let ((trans (probe-translation vm va)))
    (when (and trans (plusp trans))
      (let ((s (page-size-of vm)))
        (logior (logandc2 trans (1- s))
                (logand (u64 va) (1- s)))))))

(defun each-physical (vm addr nbytes fn)
  "Call FN on each physical piece of the low 63 bits of ADDR."
  (let ((left nbytes)
        (addr (logand (u64 addr) #x7fffffffffffffff)))
    (cond ((not (vm-virtual-memory vm))
           (when (plusp left)
             (funcall fn addr left)))
          (t
           (loop while (plusp left)
                 for ps = (page-size-of vm)
                 for room = (- ps (logand addr (1- ps)))
                 for take = (min left room)
                 for phys = (maintenance-phys vm addr)
                 do (when phys
                      (funcall fn phys take))
                    (incf addr take)
                    (decf left take))))))

(defun prefetch-physical (vm cache addr nbytes)
  (when cache
    (let ((bs (line-cache-blocksize cache))
          (left nbytes)
          (addr (logand (u64 addr) #x7fffffffffffffff)))
      (loop while (plusp left)
            for off = (logand addr (1- bs))
            for take = (min left (- bs off))
            do (unless (or (io-physical-p vm addr)
                           (find-line cache addr))
                 (install-line vm cache addr))
               (incf addr take)
               (decf left take)))))

(defun cache-prefetch (vm which addr nbytes)
  "Bring NBYTES at ADDR into the data cache, or the instruction cache when
WHICH is :INST. The sign bit is not a fault."
  (let ((cache (if (eq which :inst) (vm-icache vm) (vm-dcache vm))))
    (each-physical vm addr nbytes
                   (lambda (phys n)
                     (prefetch-physical vm cache phys n))))
  vm)

(defun cache-syncd (vm addr nbytes)
  "Write dirty data bytes in the span back to the next level. A negative
address also drops those lines."
  (let ((evict (logbitp 63 (u64 addr))))
    (each-physical vm addr nbytes
                   (lambda (phys n)
                     (writeback-span vm (vm-dcache vm) phys n :evict evict))))
  vm)

(defun cache-syncid (vm addr nbytes)
  "A nonnegative address drops the instruction-cache span and writebacks data.
A negative address drops the span from every cache and leaves memory as it is."
  (let ((negative (logbitp 63 (u64 addr))))
    (each-physical vm addr nbytes
                   (lambda (phys n)
                     (invalidate-span (vm-icache vm) phys n)
                     (if negative
                         (progn
                           (invalidate-span (vm-dcache vm) phys n)
                           (invalidate-span (vm-scache vm) phys n))
                         (writeback-span vm (vm-dcache vm) phys n)))))
  vm)

(defun cache-writeback-all (vm)
  "SYNC 5. Dirty data lines are written back and kept."
  (dolist (cache (list (vm-dcache vm) (vm-scache vm)))
    (when cache
      (loop for set across (line-cache-table cache)
            do (loop for line across set
                     do (commit-line vm cache line)))))
  vm)

(defun cache-discard-all (vm)
  "SYNC 7. Instruction and data lines are dropped, dirty bytes included."
  (dolist (cache (list (vm-dcache vm) (vm-icache vm) (vm-scache vm)))
    (when cache
      (loop for set across (line-cache-table cache)
            do (loop for line across set
                     do (setf (cache-line-valid line) nil
                              (cache-line-dirty line) nil)))))
  vm)

(defun reset-line-caches (vm)
  (cache-discard-all vm))

(defun backing-load (vm addr nbytes)
  "Memory value, ignoring a dirty line. LDUNC."
  (if (vm-virtual-memory vm)
      (multiple-value-bind (phys ok) (translate vm addr :read)
        (if ok (physical-ref vm phys nbytes) 0))
      (multiple-value-bind (phys ok) (resolve-identity-address vm addr)
        (if ok (hash-load vm phys nbytes) 0))))

(defun backing-store (vm addr nbytes value)
  "Write memory and drop any data line that covers the bytes. STUNC."
  (if (vm-virtual-memory vm)
      (multiple-value-bind (phys ok) (translate vm addr :write)
        (when ok
          (physical-set vm phys nbytes value)
          (invalidate-span (vm-dcache vm) phys nbytes)
          (invalidate-span (vm-scache vm) phys nbytes)))
      (multiple-value-bind (phys ok) (resolve-identity-address vm addr)
        (when ok
          (hash-store vm phys nbytes value)
          (invalidate-span (vm-dcache vm) phys nbytes)
          (invalidate-span (vm-scache vm) phys nbytes))))
  value)
