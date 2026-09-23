# cl-mmix

A user-mode **MMIX** virtual machine in portable Common Lisp (tested on SBCL).

It runs educational MMIXAL: the integer instruction set, the register stack, the four address segments, MMIX-SIM traps, and `.mmo` object files. It is not an MMIXware replacement: there is no pipeline, no virtual memory, and no IEEE floating point.

## Features

- 256 general registers with the `rL`/`rG` window (`rG` starts at 255, `rL` at 0). Marginal registers read as 0; writing one widens `rL` and zeros the gap.
- `PUSHJ`/`PUSHJB`/`PUSHGO`/`PUSHGOI` and `POP`. `rJ` is written only by the push instructions. `GO`/`GOI` set `$X` to the next address and jump, with the low two bits cleared.
- Special registers. `GET`, `PUT`, and `PUTI` follow the user-mode rules (`rL` only decreases, `rG` stays at least 32, `rA` keeps bits 0–17, privileged registers are unchanged).
- Integer arithmetic, including floor `DIV`, `DIVU` with `rD`, `MULU`/`rH`, scaled `ADDU`, and the `V`/`D` bits in `rA`. A shift count of 64 or more yields 0 (`SR` yields 0 or −1 from the sign).
- Loads and stores of byte, wyde, tetra, and octa, plus the immediate forms. Addresses are aligned by masking low bits. Signed stores that do not fit set `V` and still write the low bytes.
- Bitwise operations: `AND`/`OR`/`XOR` and their complements, `BDIF`/`WDIF`/`TDIF`/`ODIF`, `MUX`, `SADD`, `MOR`/`MXOR`, wyde immediates, `LDHT`/`STHT`/`STCO`, and `CSWAP`.
- `CS*`/`ZS*`, branches (`BN`…`PBV` and the backward opcodes), `JMP`/`JMPB`, `GETA`/`GETAB`.
- `TRIP` and `RESUME` with `XYZ` = 0. Arithmetic trips only when the matching `rA` enable bit is set.
- Four segments, sparse 4096-byte pages, untouched reads are 0. `:memory-size` is a page budget (at least one page), not a flat array length.
- MMIX-SIM `TRAP` services: Halt, Fopen, Fclose, Fread, Fwrite, Fgets, Fgetws, Fputs, Fputws, Fseek, Ftell. Handles 0–2 are StdIn, StdOut, and StdErr.
- S-expression assembler that emits real forward and backward opcodes, and a `.mmo` loader (content is XOR-ed in, as in MMIXware).
- Breakpoints on fetch, read, and write. `step-vm`, `run-vm`, `continue-vm`.

## Layout

```
cl-mmix/
  cl-mmix.asd
  src/          package, util, machine, decode, trap, ops, asm, mmo, api
  tests/        assert-style tests (no FiveAM)
  scripts/run-demo.lisp
  README.md
```

## Requirements

- SBCL
- ASDF (bundled with SBCL)

Quicklisp is not used.

## Load

From the project root:

```sh
sbcl --eval '(require :asdf)' \
     --eval '(push (truename ".") asdf:*central-registry*)' \
     --eval '(asdf:load-system :cl-mmix)' \
     --eval '(cl-mmix:demo-sum-1-to-n 10)'
```

Or:

```sh
sbcl --load scripts/run-demo.lisp
```

```lisp
(require :asdf)
(push (truename ".") asdf:*central-registry*)
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

## Memory

| Segment | Base |
|---------|------|
| Text | `#x0000000000000000` |
| Data | `#x2000000000000000` |
| Pool | `#x4000000000000000` |
| Stack | `#x6000000000000000` |

Bit 63 is a kernel address: the instruction stops, `vm-fault` is set, and the machine halts. Pages are allocated on the first write. `(mem-size vm)` is the budget in bytes, rounded up to a page. `(vm-memory vm)` is the page table, a hash table of 4096-byte vectors, not a flat octet vector.

The hidden register stack is a Lisp vector. `rO` and `rS` stay consistent with `Stack_Segment + 8*tau`, and each push is also written into the stack segment.

## Registers

`$0` … `$(rL−1)` are local, `$rL` … `$(rG−1)` are marginal, and `$rG` … `$255` are global. `PUT rL` ignores a new value that is not smaller. `PUT rG` clamps at 32; if the new `rG` is below `rL`, `rL` drops to match. Raising `rG` zeros registers that become marginal. Lowering `rG` zeros former marginals that become global and keeps former locals that become global.

`rA` event bits, from bit 7 down to bit 0, are `DVWIOUZX`. Enables are bits 15–8 and default to 0, so an overflow records `V` without tripping. Trip vectors are D=16, V=32, W=48, I=64, O=80, U=96, Z=112, X=128. `TRIP` itself enters at 0.

## TRAP (MMIX-SIM)

`$255` is the argument or the result. `Y` selects the operation:

| Y | Operation |
|---|-----------|
| 0 | Halt. `X=Y=Z=0` is a clean halt and `(vm-exit-code vm)` becomes `$255`. `X=Y=0,Z=1` records a fault and halts. Any other `Y=0` halts. |
| 1 | Fopen. Refuses handles 0–2. `$255` points at the name and the mode. |
| 2 | Fclose |
| 3 | Fread |
| 4 | Fgets (partial line at EOF succeeds; immediate EOF returns −1) |
| 5 | Fgetws |
| 6 | Fwrite |
| 7 | Fputs (`$255` is the string address; StdOut is also appended to `vm-output`) |
| 8 | Fputws |
| 9 | Fseek (`$255` is the offset) |
| 10 | Ftell |

Modes: 0 TextRead, 1 TextWrite, 2 BinaryRead, 3 BinaryWrite, 4 BinaryReadWrite. File streams are opened as raw bytes; text and binary differ only in the read/write permission of the mode number.

`TRAP 0,Fputs,StdOut` is the way to print. The old putchar encoding `TRAP 0,1,Z` is Fopen. Set `(make-vm :legacy-putchar t)` or `(setf (vm-legacy-putchar vm) t)` to make `TRAP 0,1,Z` write the low 8 bits of `$Z` instead. `*echo-putchar*` (default true) also copies StdOut and StdErr to the Lisp streams.

## Assembler

```lisp
(program
  (:org #x100)
  (label :start)
  (setl $1 10)
  (lda $2 $1 $0)          ; one ADDU, not a multi-instruction address load
  (bz $1 :done)           ; BN/BZ/… or BNB/BZB; the sign of the delta picks the opcode
  (jmp :start)            ; JMP or JMPB the same way
  (label :done)
  (trap 0 0 0)
  (:org #x2000000000000000)
  (:zstring "hi"))
```

Each `:org` is its own segment. `PC` becomes the first origin, so put code before data. Registers are `$3` or `3`. Branch, `JMP`, `GETA`, and `PUSHJ` targets are labels and must be 4-byte aligned relative to the instruction. Byte immediates are unsigned. `SET $X,$Y` is `ORI`. `NEG`/`NEGU` take an unsigned byte as `Y`.

`(load-mmo vm path-or-octet-vector)` loads an `.mmo` file. `PC` is the absolute symbol `Main` or `:Main` when one is present, otherwise the first tetra in the text segment.

## Debugger

```lisp
(breakpoint vm #x104 :kind :exec)   ; :exec before the instruction; :read / :write after
(run-vm vm)                         ; returns immediately if already stopped
(continue-vm vm)                    ; executes the stopped instruction, then runs
(step-vm vm)                        ; a step while stopped executes that instruction
(clear-breakpoints vm)
(dump-registers vm)                 ; local / marginal / global, rL rG rJ rA rR rH
(dump-memory vm #x2000000000000000 32)
(disassemble-at vm)
```

`run-vm` signals a Lisp error when `:max-cycles` is exhausted without a halt or a breakpoint. A `mmix-fault` (kernel address, page budget, unimplemented opcode) is caught by `step-vm`: `vm-fault` holds the reason and the machine halts.

## API

| Function | Role |
|----------|------|
| `make-vm` | `:memory-size` page budget, `:pc`, `:input`, `:legacy-putchar` |
| `assemble` / `assemble-into` / `load-program` / `load-mmo` | Build and load |
| `step-vm` / `run-vm` / `continue-vm` | Execute |
| `reg` / `set-reg` / `special-reg` / `set-special` | Register window and raw specials |
| `mem-ref-u*` / `mem-set-u*` | Big-endian memory |
| `breakpoint` / `clear-breakpoints` | Breakpoints |
| `disassemble-at` / `dump-registers` / `dump-memory` | Inspect |
| `demo-sum-1-to-n` / `demo-factorial` / `demo-recursive-factorial` / `demo-putchar-hello` | Demos |

## Tests

```sh
sbcl --script tests/run-tests.lisp
```

## Limitations

- Floating-point opcodes `#x01`–`#x17` and `LDSF`/`STSF` halt with `vm-fault` "floating point is not implemented".
- `SAVE`/`UNSAVE` halt with "SAVE/UNSAVE is not implemented".
- No `rV` page tables, no dynamic traps, no pipeline, no `υ`/`μ` counts beyond a simple `mems` counter.
- `RESUME` accepts only `XYZ` = 0 (`PC ← rW`).
- `SWYM` does not halt. `PRE*`/`SYNC*`/`SYNCD`/`SYNCID` are no-ops. `LDUNC`/`STUNC` are ordinary octa accesses. `LDVTS` returns 0.
- `Fopen` text and binary modes are not newline-translated.

## License

[GPL-3.0](LICENSE) — GNU General Public License v3.0.
