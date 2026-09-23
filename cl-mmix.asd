;;;; cl-mmix.asd — user-mode MMIX virtual machine
(defsystem "cl-mmix"
  :description "User-mode MMIX virtual machine for educational MMIXAL programs"
  :author "cl-mmix"
  :license "GPL-3.0"
  :version "0.9.0"
  :depends-on ()
  :serial t
  :components ((:module "src"
                :components
                (                 (:file "package")
                 (:file "util")
                 (:file "machine")
                 (:file "decode")
                 (:file "trap")
                 (:file "ops")
                 (:file "asm")
                 (:file "mmo")
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

