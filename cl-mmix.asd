;;;; cl-mmix.asd — ASDF system for a Common Lisp MMIX virtual machine (MVP)
(defsystem "cl-mmix"
  :description "MMIX virtual machine (subset) for SBCL"
  :author "cl-mmix"
  :license "GPL-3.0"
  :version "0.1.0"
  :depends-on ()
  :serial t
  :components ((:module "src"
                :components
                ((:file "package")
                 (:file "util")
                 (:file "machine")
                 (:file "decode")
                 (:file "ops")
                 (:file "asm")
                 (:file "api"))))
  :in-order-to ((test-op (test-op "cl-mmix/tests"))))

(defsystem "cl-mmix/tests"
  :description "Tests for cl-mmix"
  :depends-on ("cl-mmix")
  :serial t
  :components ((:module "tests"
                :components
                ((:file "tests"))))
  :perform (test-op (o c) (symbol-call :cl-mmix/tests :run-tests)))

