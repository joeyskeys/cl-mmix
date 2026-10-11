;;;; cl-mmix.asd — user-mode MMIX virtual machine
(defsystem "cl-mmix"
  :description "User-mode MMIX virtual machine for educational MMIXAL programs"
  :author "cl-mmix"
  :license "GPL-3.0"
  :version "0.13.0"
  :depends-on ()
  :serial t
  :components ((:module "src"
                :components
                (                 (:file "package")
                 (:file "util")
                 (:file "machine")
                 (:file "cache")
                 (:file "decode")
                 ;; Later plans add a sibling directory here instead of growing ops.lisp.
                 (:module "float"
                  :serial t
                  :components ((:file "octa")
                               (:file "pack")
                               (:file "arith")
                               (:file "exec")))
                 (:file "trap")
                 (:file "ops")
                 (:file "asm")
                 ;; After the assembler: the trap ROM is an assembled tetra image.
                 (:file "kernel")
                 (:file "translate")
                 (:file "mmo")
                 (:file "api"))))
  :in-order-to ((test-op (test-op "cl-mmix/tests"))))

(defsystem "cl-mmix/tests"
  :description "Tests for cl-mmix"
  :depends-on ("cl-mmix")
  :serial t
  :components ((:module "tests"
                :components
                ((:file "tests")
                 (:file "float"))))
  :perform (test-op (o c) (symbol-call :cl-mmix/tests :run-tests)))

