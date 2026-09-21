(defpackage #:cl-mmix
  (:use #:cl)
  (:export
   ;; Machine
   #:vm
   #:make-vm
   #:vm-memory
   #:vm-registers
   #:vm-pc
   #:vm-halted
   #:vm-cycles
   #:vm-special
   #:vm-output
   ;; Memory / registers
   #:mem-size
   #:mem-ref-u8 #:mem-set-u8
   #:mem-ref-u16 #:mem-set-u16
   #:mem-ref-u32 #:mem-set-u32
   #:mem-ref-u64 #:mem-set-u64
   #:reg #:set-reg
   #:u64
   ;; Execution
   #:fetch
   #:decode
   #:step-vm
   #:run-vm
   #:reset-vm
   ;; Assembler / loader
   #:assemble
   #:load-program
   #:assemble-into
   ;; Inspection
   #:disassemble-at
   #:dump-registers
   #:dump-memory
   ;; Demo helpers
   #:demo-sum-1-to-n
   #:demo-factorial
   #:+op+))

(defpackage #:cl-mmix/tests
  (:use #:cl #:cl-mmix)
  (:export #:run-tests))
