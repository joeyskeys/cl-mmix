;;;; Run a tiny MMIX demo without Quicklisp.
;;;; Usage (from project root):
;;;;   sbcl --load scripts/run-demo.lisp
;;;; Or with full path to SBCL on Windows:
;;;;   E:\soft\sbcl\sbcl.exe --load scripts/run-demo.lisp

(require :asdf)
(let* ((root (or (and *load-truename*
                      (truename (merge-pathnames ".." (directory-namestring *load-truename*))))
                 (truename "."))))
  (pushnew root asdf:*central-registry* :test #'equal))
(asdf:load-system "cl-mmix")

(defpackage #:cl-mmix-demo
  (:use #:cl #:cl-mmix))
(in-package #:cl-mmix-demo)

(format t "~%== cl-mmix demo ==~%~%")

(multiple-value-bind (sum vm) (demo-sum-1-to-n 10)
  (format t "sum(1..10) = ~D  (cycles=~D)~%" sum (vm-cycles vm))
  (format t "disasm @#x100: ~A~%" (disassemble-at vm #x100)))

(multiple-value-bind (f vm) (demo-factorial 10)
  (format t "10! = ~D  (cycles=~D)~%" f (vm-cycles vm)))

(multiple-value-bind (f vm) (demo-recursive-factorial 10)
  (format t "10! via PUSHJ/POP = ~D  (cycles=~D)~%" f (vm-cycles vm)))

(format t "~%Registers (nonzero) after factorial:~%")
(multiple-value-bind (_ vm) (demo-factorial 5)
  (declare (ignore _))
  (dump-registers vm))

(format t "~%Fputs demo: ")
(finish-output)
(cl-mmix::demo-putchar-hello)
(format t "~%~%Demo finished successfully.~%")
(sb-ext:exit :code 0)
