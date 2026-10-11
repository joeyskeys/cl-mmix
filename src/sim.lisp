(in-package #:cl-mmix)

;;; MMIX-SIM session (plan 10). The argv image is an UNSAVE of the §43
;;; layout. On a kernel VM the ROM executes that UNSAVE. The default VM
;;; calls unsave-context directly. sim-command reads one mmix> line.

(defparameter *sim-help*
"empty line    step, then disassemble the instruction just retired
c              continue
q              print the profile
s              print PC, retired instructions, μ, and υ
$N lN gN rA Maddr
               examine. Suffix ! decimal, # hex, . binary64, \" eight characters
same=value     assign, then print. Decimal, # hex, a float, or \"string\"
+N             the next N items in the previous format
@addr          set PC
taddr uaddr    trace on fetch, or trace off
b[rwx]addr     breakpoint. baddr with no letters clears that address
T D P S        later addresses add Text, Data, Pool, or Stack
B              list breakpoints and tracepoints
i file         read commands. A line starting with % or i is skipped
h              print this table
Addresses are decimal unless they start with # or #x.
")

(declaim (ftype (function (t t) t) sim-include))

(defun install-pool-strings (vm args)
  "Pointers at Pool_Segment+8, then NUL-terminated strings, 8-byte aligned.
M8[Pool_Segment] becomes the first free octa after the strings."
  (let* ((args (coerce args 'list))
         (argc (length args))
         (ptr-base (+ +pool-segment+ 8))
         (str-at (+ ptr-base (* 8 (1+ argc)))))
    (loop for arg in args
          for i from 0
          do (mem-set-u64 vm (+ ptr-base (* 8 i)) str-at :internal t)
             (loop for ch across (string arg)
                   for code = (char-code ch)
                   do (unless (<= 0 code 255)
                        (error "argument character ~S does not fit in a byte" ch))
                      (mem-set-u8 vm str-at code :internal t)
                      (incf str-at))
             (mem-set-u8 vm str-at 0 :internal t)
             (incf str-at)
             (setf str-at (logand (+ str-at 7) (lognot 7))))
    (mem-set-u64 vm (+ ptr-base (* 8 argc)) 0 :internal t)
    (mem-set-u64 vm +pool-segment+ str-at :internal t)
    str-at))

(defun push-startup-image (vm argc argv)
  "Push the §43 image whose locals are $0 = ARGC and $1 = ARGV. Returns the
address of the header, which is the current top of the register stack."
  (stack-push-octa vm argc)
  (stack-push-octa vm argv)
  (stack-push-octa vm 2)
  (loop for k from (reg-g vm) to 255
        do (stack-push-octa vm (reg vm k)))
  (loop for s across *save-specials*
        do (stack-push-octa vm (special-reg vm s)))
  (stack-push-octa vm (logior (ash (logand (reg-g vm) #xff) 56)
                              (logand (special-reg vm +r-a+) #xffffffff)))
  (+ +stack-segment+ (* 8 (1- (length (vm-stack vm))))))

(defun rom-unsave (vm top entry)
  "Execute the ROM's UNSAVE $255, then restore rQ and return to ENTRY.
The negative fetch sets the p bit. Leaving that bit set would dynamic-trap
the next user instruction."
  (let ((saved-q (special-reg vm +r-q+)))
    (set-reg vm 255 top)
    (setf (vm-pc vm) (u64 (+ +rom-base+ *startup-unsave-offset*)))
    (step-vm vm)
    (set-special vm +r-q+ saved-q)
    (unless (vm-halted vm)
      (setf (vm-pc vm) (u64 entry))))
  vm)

(defun install-argv (vm args)
  "Build the pool and enter at the PC load-mmo already chose."
  (let* ((args (coerce args 'list))
         (entry (vm-pc vm))
         (argc (length args))
         (argv (+ +pool-segment+ 8)))
    (install-pool-strings vm args)
    (setf (fill-pointer (vm-stack vm)) 0)
    (sync-stack vm)
    (let ((top (push-startup-image vm argc argv)))
      (if (vm-kernel vm)
          (rom-unsave vm top entry)
          (progn
            (unsave-context vm top)
            (setf (vm-pc vm) (u64 entry)))))
    vm))

(defun parse-sim-int (s)
  "A whole token. # or #x is hex. Anything else is decimal, and may be negative."
  (setf s (string-trim '(#\Space #\Tab) s))
  (multiple-value-bind (n pos)
      (cond ((and (>= (length s) 2)
                  (char= (char s 0) #\#)
                  (char-equal (char s 1) #\x))
             (parse-integer s :start 2 :radix 16 :junk-allowed t))
            ((and (plusp (length s)) (char= (char s 0) #\#))
             (parse-integer s :start 1 :radix 16 :junk-allowed t))
            (t (parse-integer s :junk-allowed t)))
    (if (and (integerp n) (integerp pos) (= pos (length s)))
        n
        (error "bad integer: ~A" s))))

(defun take-sim-int (s)
  "Read one integer from the front of S. Returns (values integer remainder)."
  (setf s (string-left-trim '(#\Space #\Tab) s))
  (cond ((and (>= (length s) 2)
              (char= (char s 0) #\#)
              (char-equal (char s 1) #\x))
         (multiple-value-bind (n pos)
             (parse-integer s :start 2 :radix 16 :junk-allowed t)
           (unless n (error "missing hex integer"))
           (values n (subseq s pos))))
        ((and (plusp (length s)) (char= (char s 0) #\#))
         (multiple-value-bind (n pos)
             (parse-integer s :start 1 :radix 16 :junk-allowed t)
           (unless n (error "missing hex integer"))
           (values n (subseq s pos))))
        (t
         (multiple-value-bind (n pos) (parse-integer s :junk-allowed t)
           (unless n (error "missing integer"))
           (values n (subseq s pos))))))

(defun take-decimal (s)
  (setf s (string-left-trim '(#\Space #\Tab) s))
  (multiple-value-bind (n pos) (parse-integer s :junk-allowed t)
    (unless (and n (plusp pos))
      (error "missing register number"))
    (values n (subseq s pos))))

(defun parse-sim-value (s)
  (setf s (string-trim '(#\Space #\Tab) s))
  (when (zerop (length s))
    (error "missing value"))
  (cond ((char= (char s 0) #\")
         (let ((end (position #\" s :start 1)))
           (unless end (error "unterminated string"))
           (chars-to-octa (subseq s 1 end))))
        ((char= (char s 0) #\#)
         (u64 (parse-sim-int s)))
        ((or (find #\. s) (find #\e s) (find #\E s))
         (multiple-value-bind (obj pos)
             (let ((*read-eval* nil))
               (read-from-string s))
           (unless (realp obj)
             (error "not a number: ~A" s))
           (when (< pos (length s))
             (let ((tail (string-trim '(#\Space #\Tab) (subseq s pos))))
               (unless (zerop (length tail))
                 (error "junk after value: ~A" tail))))
           (double-to-octa obj)))
        (t (u64 (parse-sim-int s)))))

(defun parse-suffix (s)
  "Returns (values format remainder). FORMAT is :hex, :dec, :float, or :chars."
  (setf s (string-left-trim '(#\Space #\Tab) s))
  (if (or (zerop (length s)) (char= (char s 0) #\=))
      (values :hex s)
      (case (char s 0)
        (#\! (values :dec (subseq s 1)))
        (#\# (values :hex (subseq s 1)))
        (#\. (values :float (subseq s 1)))
        (#\" (values :chars (subseq s 1)))
        (t (error "bad suffix in ~A" s)))))

(defun format-sim-octa (fmt value)
  (let ((value (u64 value)))
    (ecase fmt
      (:hex (format nil "#x~16,'0X" value))
      (:dec (format nil "~D" value))
      (:float (format nil "~A" (octa-to-double value)))
      (:chars (octa-to-chars value)))))

(defun sim-show-reg (vm index fmt)
  (format nil "$~D=~A~%" index (format-sim-octa fmt (reg vm index))))

(defun sim-show-spec (vm index fmt)
  (format nil "~A=~A~%" (special-name index)
          (format-sim-octa fmt (special-reg vm index))))

(defun sim-show-mem (vm addr fmt)
  (format nil "M#x~16,'0X=~A~%"
          addr
          (format-sim-octa fmt (mem-ref-u64 vm addr :internal t))))

(defun sim-remember (vm kind fmt &key index addr)
  (setf (vm-sim-last vm) (list :kind kind :fmt fmt :index index :addr addr))
  vm)

(defun assign-reg (vm index value)
  "A nonzero write of a marginal register is rejected. Zero widens rL."
  (let ((l (reg-l vm))
        (g (reg-g vm))
        (value (u64 value)))
    (if (and (>= index l) (< index g) (not (zerop value)))
        (format nil "rejected $~D~%" index)
        (progn (set-reg vm index value) nil))))

(defun assign-special (vm index value)
  "PUT rules. A suppress, or a value PUT left unchanged, is a rejection.
Masking rA and clamping rG still count as a successful PUT."
  (let ((before (special-reg vm index))
        (value (u64 value)))
    (handler-case
        (progn
          (put-special vm index value)
          (let ((after (special-reg vm index)))
            (when (and (= after before) (/= after value))
              (format nil "rejected ~A~%" (special-name index)))))
      (mmix-suppress ()
        (format nil "rejected ~A~%" (special-name index))))))

(defun sim-finish-examine (vm show rejected rest)
  (setf rest (string-left-trim '(#\Space #\Tab) rest))
  (cond ((zerop (length rest))
         (or rejected (funcall show)))
        ((char= (char rest 0) #\=)
         (or rejected (funcall show)))
        (t (error "junk after operand: ~A" rest))))

(defun examine-reg (vm index fmt rest)
  (setf rest (string-left-trim '(#\Space #\Tab) rest))
  (let ((rejected
          (when (and (plusp (length rest)) (char= (char rest 0) #\=))
            (assign-reg vm index (parse-sim-value (subseq rest 1))))))
    (sim-remember vm :reg fmt :index index)
    (sim-finish-examine vm (lambda () (sim-show-reg vm index fmt))
                        rejected rest)))

(defun examine-spec (vm index fmt rest)
  (setf rest (string-left-trim '(#\Space #\Tab) rest))
  (let ((rejected
          (when (and (plusp (length rest)) (char= (char rest 0) #\=))
            (assign-special vm index (parse-sim-value (subseq rest 1))))))
    (sim-remember vm :spec fmt :index index)
    (sim-finish-examine vm (lambda () (sim-show-spec vm index fmt))
                        rejected rest)))

(defun examine-mem (vm addr fmt rest)
  (setf rest (string-left-trim '(#\Space #\Tab) rest))
  (when (and (plusp (length rest)) (char= (char rest 0) #\=))
    (mem-set-u64 vm addr (parse-sim-value (subseq rest 1)) :internal t))
  (sim-remember vm :mem fmt :addr addr)
  (sim-finish-examine vm (lambda () (sim-show-mem vm addr fmt)) nil rest))

(defun take-special (s)
  (let ((best nil))
    (dotimes (i 32)
      (let ((name (aref +special-names+ i)))
        (when (and (<= (length name) (length s))
                   (string= name s :end2 (length name))
                   (or (null best) (> (length name) (length (cdr best)))))
          (setf best (cons i name)))))
    (unless best
      (error "unknown special register"))
    (values (car best) (subseq s (length (cdr best))))))

(defun reg-index (vm kind n)
  (unless (<= 0 n 255)
    (error "register ~D is out of range" n))
  (ecase kind
    ((#\$ #\l) n)
    (#\g (if (>= n (reg-g vm))
             n
             (let ((i (+ (reg-g vm) n)))
               (unless (<= i 255)
                 (error "g~D is past $255" n))
               i)))))

(defun sim-addr (vm s)
  (multiple-value-bind (n rest) (take-sim-int s)
    (values (u64 (+ (vm-sim-base vm) n)) rest)))

(defun sim-step-print (vm)
  (cond ((vm-halted vm) (format nil "halted~%"))
        (t
         (let ((pc (logand (vm-pc vm) (lognot 3))))
           (step-vm vm)
           (if (vm-break vm)
               (format nil "break ~S~%" (vm-break vm))
               (format nil "~A~%" (disassemble-at vm pc)))))))

(defun sim-continue-print (vm)
  (continue-vm vm)
  (cond ((vm-break vm) (format nil "break ~S~%" (vm-break vm)))
        ((vm-halted vm) (format nil "halted~%"))
        ((vm-asleep vm) (format nil "asleep~%"))
        (t (format nil "stopped~%"))))

(defun sim-profile-report (vm)
  (let ((table (vm-profile vm)))
    (if (not (hash-table-p table))
        ""
        (with-output-to-string (out)
          (let ((rows nil))
            (maphash (lambda (pc n)
                       (when (plusp n)
                         (push (cons pc n) rows)))
                     table)
            (dolist (row (sort rows #'< :key #'car))
              (let* ((pc (car row))
                     (loc (gethash pc (vm-lines vm))))
                (format out "#x~X  ~D" pc (cdr row))
                (when loc
                  (format out "  ~A:~D" (or (car loc) "?") (cdr loc)))
                (terpri out))))))))

(defun sim-status (vm)
  (format nil "PC=#x~X  retired=~D  μ=~D  υ=~D  pipe=~D~%"
          (vm-pc vm) (vm-cycles vm) (vm-mem-cost vm) (vm-oops vm)
          (vm-pipe-cycles vm)))

(defun sim-show-current (vm)
  (let ((last (vm-sim-last vm)))
    (unless last
      (error "no previous simulator item"))
    (ecase (getf last :kind)
      (:reg (sim-show-reg vm (getf last :index) (getf last :fmt)))
      (:spec (sim-show-spec vm (getf last :index) (getf last :fmt)))
      (:mem (sim-show-mem vm (getf last :addr) (getf last :fmt))))))

(defun sim-advance (vm)
  (let ((last (vm-sim-last vm)))
    (unless last
      (return-from sim-advance nil))
    (ecase (getf last :kind)
      (:reg (when (< (getf last :index) 255)
              (incf (getf last :index))
              t))
      (:spec (when (< (getf last :index) 31)
               (incf (getf last :index))
               t))
      (:mem (incf (getf last :addr) 8)
            t))))

(defun sim-plus (vm n)
  (when (minusp n)
    (error "bad count ~D" n))
  (with-output-to-string (out)
    (dotimes (i n)
      (unless (sim-advance vm)
        (error "no next simulator item"))
      (write-string (sim-show-current vm) out))))

(defun sim-set-base (vm letter)
  (setf (vm-sim-base vm)
        (ecase letter
          (#\T +text-segment+)
          (#\D +data-segment+)
          (#\P +pool-segment+)
          (#\S +stack-segment+)))
  "")

(defun sim-list-breaks (vm)
  (with-output-to-string (out)
    (dolist (w (reverse (vm-watches vm)))
      (format out "break ~(~A~) #x~X~%" (car w) (cdr w)))
    (dolist (addr (reverse (vm-traces vm)))
      (format out "trace #x~X~%" addr))))

(defun sim-break-cmd (vm rest)
  (setf rest (string-left-trim '(#\Space #\Tab) rest))
  (let ((letters nil)
        (i 0))
    (loop while (and (< i (length rest)) (find (char rest i) "rwx"))
          do (push (char rest i) letters)
             (incf i))
    (let ((addr (sim-addr vm (subseq rest i))))
      (setf (vm-watches vm)
            (remove addr (vm-watches vm) :key #'cdr :test #'=))
      (dolist (ch (nreverse letters))
        (breakpoint vm addr
                    :kind (ecase ch
                            (#\r :read)
                            (#\w :write)
                            (#\x :exec))))))
  "")

(defun sim-trace-cmd (vm rest on)
  (let ((addr (logand (sim-addr vm rest) (lognot 3))))
    (if on
        (pushnew addr (vm-traces vm) :test #'=)
        (setf (vm-traces vm) (remove addr (vm-traces vm) :test #'=)))
    ""))

(defun sim-examine (vm line)
  (let ((kind (char line 0)))
    (ecase kind
      ((#\$ #\l #\g)
       (multiple-value-bind (n rest) (take-decimal (subseq line 1))
         (multiple-value-bind (fmt tail) (parse-suffix rest)
           (examine-reg vm (reg-index vm kind n) fmt tail))))
      (#\r
       (multiple-value-bind (index rest) (take-special (subseq line 1))
         (multiple-value-bind (fmt tail) (parse-suffix rest)
           (examine-spec vm index fmt tail))))
      (#\M
       (multiple-value-bind (addr rest) (sim-addr vm (subseq line 1))
         (multiple-value-bind (fmt tail) (parse-suffix rest)
           (examine-mem vm addr fmt tail)))))))

(defun sim-command-string (vm line)
  (let ((line (string-trim '(#\Space #\Tab #\Return #\Newline) (or line ""))))
    (cond ((zerop (length line))
           (sim-step-print vm))
          ((string= line "c") (sim-continue-print vm))
          ((string= line "q") (sim-profile-report vm))
          ((string= line "s") (sim-status vm))
          ((string= line "h") *sim-help*)
          ((string= line "B") (sim-list-breaks vm))
          ((and (= (length line) 1) (find (char line 0) "TDPS"))
           (sim-set-base vm (char line 0)))
          ((char= (char line 0) #\i)
           (let ((path (string-trim '(#\Space #\Tab) (subseq line 1))))
             (when (zerop (length path))
               (error "missing include file"))
             (sim-include vm path)))
          ((char= (char line 0) #\+)
           (sim-plus vm (take-sim-int (subseq line 1))))
          ((char= (char line 0) #\@)
           (setf (vm-pc vm) (sim-addr vm (subseq line 1)))
           "")
          ((char= (char line 0) #\t)
           (sim-trace-cmd vm (subseq line 1) t))
          ((char= (char line 0) #\u)
           (sim-trace-cmd vm (subseq line 1) nil))
          ((char= (char line 0) #\b)
           (sim-break-cmd vm (subseq line 1)))
          ((find (char line 0) "$lgMr")
           (sim-examine vm line))
          (t (error "unknown simulator command: ~A" line)))))

(defun sim-include (vm path)
  (with-output-to-string (out)
    (with-open-file (in path)
      (loop for line = (read-line in nil nil)
            while line
            for trim = (string-trim '(#\Space #\Tab #\Return) line)
            do (when (and (plusp (length trim))
                          (not (member (char trim 0) '(#\% #\i))))
                 (write-string (sim-command-string vm trim) out))))))

(defun sim-command (vm line)
  "Read one MMIX-SIM command. Returns the text the command prints."
  (let ((out (sim-command-string vm line)))
    (when (plusp (length out))
      (write-string out *standard-output*)
      (force-output *standard-output*))
    out))
