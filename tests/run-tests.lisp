;;;; Standalone test runner for SBCL (no Quicklisp).
;;;;   sbcl --script tests/run-tests.lisp

(require :asdf)
(let* ((here (directory-namestring *load-truename*))
       (root (truename (merge-pathnames "../" here))))
  (pushnew root asdf:*central-registry* :test #'equal))
(asdf:load-system "cl-mmix/tests")
(let ((ok (cl-mmix/tests:run-tests)))
  (sb-ext:exit :code (if ok 0 1)))
