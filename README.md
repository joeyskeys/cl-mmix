# cl-mmix

A small **MMIX virtual machine** written in portable Common Lisp (tested on SBCL).

This is an educational MVP: enough of the ISA to assemble a tiny program, run it, and inspect registers/memory — not a full MMIXware replacement.

## Features

- Byte-addressable memory (default 1 MiB), **big-endian** 64-bit helpers
- 256 general registers `$0`–`$255` (unsigned 64-bit)
- Fetch–decode–execute loop with **halt** and **max-cycles** safeguard
- Instruction subset: arithmetic, logic, shifts, compare, loads/stores, branches, `JMP`/`GO`, `SET*`/`INC*`/`OR*` wyde immediates, `TRAP`
- S-expression assembler (no Knuth assembler required)
- Self-contained: **no Quicklisp** required for the core or demo

## Layout

```
cl-mmix/
  cl-mmix.asd
  src/          package, util, machine, decode, ops, asm, api
  tests/        assert-style tests (no FiveAM)
  scripts/run-demo.lisp
  README.md
```

## Requirements

- SBCL (e.g. 2.5.x). On this machine: `E:\soft\sbcl\sbcl.exe`
- ASDF (bundled with SBCL)

Quicklisp is optional and **not** used by the core system.

## Load with SBCL

From the project root (`E:\repo\cl-mmix`):

```bat
E:\soft\sbcl\sbcl.exe --eval "(require :asdf)" --eval "(push (truename \".\") asdf:*central-registry*)" --eval "(asdf:load-system :cl-mmix)" --eval "(cl-mmix:demo-sum-1-to-n 10)"
```

Or run the demo script:

```bat
cd /d E:\repo\cl-mmix
E:\soft\sbcl\sbcl.exe --load scripts\run-demo.lisp
```

REPL session:

```lisp
(require :asdf)
(push (truename "E:/repo/cl-mmix/") asdf:*central-registry*)
(asdf:load-system :cl-mmix)
(use-package :cl-mmix)

(multiple-value-bind (sum vm) (demo-sum-1-to-n 10)
  (format t "sum=~D cycles=~D~%" sum (vm-cycles vm)))

(let ((vm (make-vm)))
  (assemble-into vm
    '(program (:org #x100)
      (setl $1 6)
      (setl $3 1)
      (label :L)
      (bz $1 :done)
      (mul $3 $3 $1)
      (subi $1 $1 1)
      (jmp :L)
      (label :done)
      (trap 0 0 0)))
  (run-vm vm)
  (dump-registers vm))
```

## TRAP convention (this MVP)

| Instruction   | Meaning                                      |
|---------------|----------------------------------------------|
| `TRAP 0,0,0`  | Halt                                         |
| `TRAP 0,1,Z`  | Putchar: write low 8 bits of `$Z` to output  |
| other TRAPs   | Halt (message recorded in `vm-output`)       |

## Assembler sketch

```lisp
(program
  (:org #x100)
  (label :start)
  (setl $1 10)
  (addi $2 $0 1)
  (bz $1 :done)
  (jmp :start)
  (label :done)
  (trap 0 0 0))
```

Registers may be written `$3` or `3`. Labels work for branches, `JMP`, and `GETA`.

## API

| Function | Role |
|----------|------|
| `make-vm` | Create VM (`:memory-size`, `:pc`) |
| `assemble` / `assemble-into` / `load-program` | Build & load |
| `step-vm` / `run-vm` | Execute |
| `reg` / `set-reg` / `mem-ref-u*` / `mem-set-u*` | Inspect |
| `disassemble-at` / `dump-registers` / `dump-memory` | Debug |
| `demo-sum-1-to-n` / `demo-factorial` | Built-in demos |

## Tests

```bat
cd /d E:\repo\cl-mmix
E:\soft\sbcl\sbcl.exe --script tests\run-tests.lisp
```

Or:

```bat
E:\soft\sbcl\sbcl.exe --eval "(require :asdf)" --eval "(push (truename \".\") asdf:*central-registry*)" --eval "(asdf:load-system :cl-mmix/tests)" --eval "(unless (cl-mmix/tests:run-tests) (sb-ext:exit :code 1))" --quit
```

## Limitations vs full MMIX

- Only a coherent **subset** of opcodes (see `src/decode.lisp`)
- No floating-point, no `PUSHJ`/`POP` stack frame model, no trips/interrupts
- Special registers mostly stubs; `rR` (DIV remainder) and `rJ` (GO) are used
- No prediction for `PB*` (same as `B*`)
- No `rL`/`rG` local/global register windowing — all 256 `$` registers are flat
- Immediate forms for loads use register+register addressing in the MVP ops; assemble with `$0` as zero base
- Not binary-compatible with MMIXware OS / `ld` object formats

## License

[GPL-3.0](LICENSE) — GNU General Public License v3.0.

