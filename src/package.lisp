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
   #:vm-error-output
   #:vm-mems
   #:vm-fault
   #:vm-exit-code
   #:vm-break
   #:vm-input
   #:vm-labels
   #:vm-symbols
   #:vm-legacy-putchar
   ;; Memory / registers
   #:mem-size
   #:mem-ref-u8 #:mem-set-u8
   #:mem-ref-u16 #:mem-set-u16
   #:mem-ref-u32 #:mem-set-u32
   #:mem-ref-u64 #:mem-set-u64
   #:reg #:set-reg
   #:special-reg #:set-special
   #:u64
   ;; Execution
   #:fetch
   #:decode
   #:step-vm
   #:run-vm
   #:continue-vm
   #:reset-vm
   #:breakpoint
   #:clear-breakpoints
   ;; Assembler / loader
   #:assemble
   #:load-program
   #:assemble-into
   #:load-mmo
   ;; Inspection
   #:disassemble-at
   #:dump-registers
   #:dump-memory
   ;; Demo helpers
   #:demo-sum-1-to-n
   #:demo-factorial
   #:demo-recursive-factorial
   #:demo-putchar-hello
   #:demo-hello
   #:+op+
   #:+text-segment+
   #:+data-segment+
   #:+pool-segment+
   #:+stack-segment+
   #:+r-a+ #:+r-b+ #:+r-d+ #:+r-e+ #:+r-g+ #:+r-h+
   #:+r-j+ #:+r-l+ #:+r-m+ #:+r-p+ #:+r-r+
   #:+r-w+ #:+r-x+ #:+r-y+ #:+r-z+
   #:mmix-fault
   #:mmix-fault-reason
   #:mmix-symbol
   #:mmix-symbol-name
   #:mmix-symbol-value
   #:mmix-symbol-kind))

(defpackage #:cl-mmix/tests
  (:use #:cl #:cl-mmix)
  (:export #:run-tests))
