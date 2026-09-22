# cl-mmix vs MMIX: gap analysis for TAOCP practice

Analysis only. This document records what the current code implements and what is still missing for a virtual machine that can be used to practice exercises from Knuth’s *The Art of Computer Programming* (TAOCP) with MMIX. It does not change the ISA.

## Executive summary

cl-mmix is a portable Common Lisp **educational MVP**: a flat 256-register file, a 1 MiB big-endian memory, a fetch–decode–execute loop, and about 64 opcodes covering straight-line integer arithmetic, a few loads and stores, branches, wyde immediates, and a private `TRAP` halt/putchar convention. That is enough to run the in-repo demos (`demo-sum-1-to-n`, `demo-factorial`). It is not enough to assemble or run the programs printed in Volume 1, Fascicle 1, or in Martin Ruckert’s *The MMIX Supplement*, which are ordinary MMIXAL (`.mms`) programs. Those programs depend on the register stack (`PUSHJ`/`POP`, `rL`/`rG`), `GET`/`PUT`, tetra and immediate loads and stores, the standard four address segments, and the MMIX-SIM system calls (`TRAP 0,Halt,0`, `TRAP 0,Fputs,StdOut`, and file I/O). Several opcodes that *are* implemented do not match Knuth’s encoding or semantics (branch map, shift counts, signed `DIV`, `GO` writing `rJ`). Calling the present VM “full MMIX” would be false.

**Recommended compatibility target:** a **user-mode functional VM for educational MMIXAL programs**. Assemble with the external `mmixal` from MMIXware, load the resulting `.mmo`, and execute with correct integer instructions, the hardware register stack, the four standard segments, and the small MMIX-SIM `TRAP` I/O set (`Halt`, `Fputs`, `Fgets`, `Fopen`/`Fclose`/`Fread`/`Fwrite`). Keep the s-expression assembler as a test tool, but make it emit the same opcodes `mmixal` emits. Do **not** target “run MMIXware kernel / BIOS binaries,” cycle-accurate MMMIX, or virtual memory. IEEE floating point is the milestone after integer textbook programs run; Fascicle 1 introduces it, and Volume 2 needs it, but the first programming exercises do not. Pipeline timing is not required for practice: TAOCP asks students to count υ and μ by hand, and a functional instruction count is enough to check results.

## Sources

Code (ground truth for “what we have”):

- `cl-mmix.asd`, `README.md`
- `src/machine.lisp`, `src/decode.lisp`, `src/ops.lisp`, `src/asm.lisp`, `src/api.lisp`, `src/util.lisp`, `src/package.lisp`
- `tests/tests.lisp`, `scripts/run-demo.lisp`

Specification (ground truth for “what MMIX is”):

- Donald E. Knuth, *MMIXware* / “MMIX: A RISC Computer for the New Millennium” (the architecture definition; quotes below are from the public `mmix-doc` text, sections cited inline). Stanford copies: [MMIX](https://cs.stanford.edu/~knuth/mmix.html), [opcode chart](https://cs.stanford.edu/~knuth/mmop.html), [MMIXware](https://cs.stanford.edu/~knuth/mmixware.html).
- Donald E. Knuth, *The Art of Computer Programming*, Volume 1, Fascicle 1 (*MMIX*). The programmer-facing subset of the same machine. The architecture document is explicit that Fascicle 1 is the tutorial and that the full write-up also covers OS-only features.
- MMIXware simulator documentation (`mmix-sim`): the rudimentary OS and interactive debugger that textbook programs assume. Public PDF mirror used here: [mmix-sim](https://mmix.cs.hm.edu/doc/mmix-sim.pdf). Hello-world trace confirming `Fputs`/`StdOut`: [MMIX Hello World](https://mmix.cs.hm.edu/examples/hello.html).
- Opcode cross-check: [Knuth’s opcode page](https://cs.stanford.edu/~knuth/mmop.html) and the Munich MMIX register summary [registers.html](https://mmix.cs.hm.edu/doc/registers.html).

Where the README and the code disagree with those documents, the documents win for “spec” and the code wins for “implemented.”

## Status of the ten areas

| # | Area | Status | One-line evidence |
| --- | --- | --- | --- |
| 1 | General and special registers | **partial** | 256 flat `$` registers; 32 special slots exist; only `rR` and `rJ` are written, and `rJ` is written by the wrong instruction |
| 2 | Instruction set | **partial** | 64 opcodes in `+op+`; branch numbers and several arithmetic rules do not match the opcode chart |
| 3 | Memory model | **partial** | Big-endian byte memory, no alignment rule, no segments, OOB is a Lisp error |
| 4 | Pipeline / timing | **partial** (enough for practice) | `vm-cycles` counts instructions; `run-vm` has `:max-cycles`. No υ/μ, no pipeline |
| 5 | Floating point | **missing** | No FP opcodes, no rounding mode in `rA` |
| 6 | Trips / traps / `TRAP` | **partial** | `TRAP 0,0,0` halts, which matches the architecture; every other `TRAP` is a private convention |
| 7 | Calling convention / register stack | **missing** | No `PUSHJ`/`POP`, no `rL`/`rG` window, no `rO`/`rS` |
| 8 | Assembler / loader | **partial** | S-expression assembler only; no MMIXAL, no `.mmo` |
| 9 | Debugging / learner UX | **partial** | `step-vm`, `disassemble-at`, `dump-registers`, `dump-memory`; no breakpoints or special-register dump |
| 10 | Compatibility target | **not MMIXAL, not MMIXware** | In-repo programs only. Recommendation is in the summary above |

## What’s already solid

These pieces match the architecture and are worth keeping.

**Machine shape.** Instructions are 32-bit `OP X Y Z` (`decode`, `encode` in `src/decode.lisp`). General registers are an array of 256 unsigned 64-bit values (`vm-registers` in `src/machine.lisp`). There is no wired-zero register, which is correct: MMIX `$0` is an ordinary local. Special-register *numbers* that the code does define match Knuth: `rJ` = 4, `rR` = 6, `rG` = 19, `rL` = 20, `rA` = 21 (`src/machine.lisp`). The special file is 32 slots, one per architectural register `rB` through `rZZ`.

**Big-endian memory.** `mem-ref-u*` / `mem-set-u*` are big-endian (`src/machine.lisp`). `mmix-doc` §6 requires big-endian. `tests/tests.lisp` (`mem-be-u64`) locks this in. Byte, wyde, and octa load/store of *aligned* data in the low megabyte work (`:ldb`/`:ldbu`, `:ldw`/`:ldwu`, `:ldo`/`:ldou`, `:stb`, `:stw`, `:sto` in `execute`).

**Integer ops that match on the values the tests use.**

- `ADD`/`SUB`/`MUL` low 64 bits wrap the way two’s-complement low halves do (`u64` in `src/util.lisp`). The low half of a product is the same for signed and unsigned multiply, so `MUL`’s destination register is right when the product fits.
- `AND`/`OR`/`XOR` and their immediate forms.
- `CMP`/`CMPU` return −1, 0, or +1 (`cmp-signed`, `cmp-unsigned`). Immediate `Z` is an unsigned byte, which matches `mmix-doc` §5 (“immediate constants are always nonnegative”).
- Wyde `SETH`/`SETMH`/`SETML`/`SETL` replace the whole register (other wydes cleared). `INC*` adds a shifted wyde. `OR*` ors a shifted wyde. That is `mmix-doc` §13, including the idiom `SETH; INCMH; INCML; INCL` for a 64-bit constant.
- `SET $X,$Y` in the assembler is `ORI $X,$Y,0` (`src/asm.lisp`), which copies `$Y` without depending on `$0`. That is the right expansion.
- Branch *conditions* (sign bit, zero, odd bit) match the eight predicates in `mmix-doc` §17. Treating a probable branch as the same predicate is also correct for a functional machine; `P*` is only a timing hint. The opcode *numbers* are a different story (see P0).

**Control loop.** `fetch` reads a tetra at `PC`. `step-vm` increments `vm-cycles`. `run-vm` stops on halt or signals if `:max-cycles` is exceeded (default 100000). `reset-vm` clears PC, halt, cycles, and the output buffer. Demos and tests show loops, factorial, and a character-output trap working *under the in-repo convention*.

**Debugger seeds.** `disassemble-at`, `dump-registers` (nonzero `$` registers, PC, cycles, halt, output), and `dump-memory` (16-byte hex rows) are the right kinds of tools. They are not yet a practice session.

## Correctness bugs inside the implemented subset

These are not “missing features.” Code that claims to be MMIX already disagrees with the spec. Fixing them is part of P0 because textbook listings and `mmixal` output will otherwise do the wrong thing, and because our own branch opcodes are not Knuth’s.

1. **Branch and jump encoding.** `mmix-doc` §17–19 and the [opcode chart](https://cs.stanford.edu/~knuth/mmop.html): a forward branch adds `4 * YZ` (YZ unsigned); the backward opcode (mnemonic ending in `B`) adds `4 * (YZ − 2^16)`. The same split applies to `JMP`/`JMPB` (24-bit) and `GETA`/`GETAB`. Probable branches start at `#50`, not `#48`.

   `+op+` in `src/decode.lisp` assigns `#41` to `:bnz`, `#43` to `:bnn`, `#45` to `:bnp`, `#47` to `:bev`, and `#48`–`#4D` to probable branches. On the real map those bytes are `BNB`, `BZB`, `BPB`, `BODB`, `BNN`, `BNNB`, `BNZ`, `BNZB`, `BNP`, `BNPB`. Real `BNZ` is `#4A`, real `BEV` is `#4E`, real `PBN` is `#50`. `PBOD`/`PBEV` (`#56`/`#5E`) are absent. `take-branch` and the assembler sign-extend YZ (`sign-extend16`, `branch-offset` in `src/ops.lisp` and `src/asm.lisp`). That happens to agree with MMIX only for a forward opcode and a displacement in −32768 … 32767, and only if the program was assembled *by this assembler*. A `.mmo` file uses the backward opcode instead.

   `JMP` (`#F0`) sign-extends a 24-bit field (`sign-extend24`). Real backward jumps are `JMPB` (`#F1`). `GETAB` (`#F5`) is missing; `GETA` sign-extends.

2. **`GO` writes `rJ`.** `mmix-doc` §19: `GO` sets `$X ← λ+4` and jumps to `$Y+$Z` (low two bits of the target are ignored). It does **not** write `rJ`. `rJ` is written by `PUSHJ`/`PUSHGO` (`mmix-doc` §29). `execute` for `:go` and `:goi` does `(set-special vm +r-j+ next-pc)`. The two low bits of the target are not cleared.

3. **Shifts use `mod 64`.** `mmix-doc` §14: a count ≥ 64 yields 0, except `SR` of a negative value, which yields −1. `SL` also raises integer overflow unless the source was 0. `execute` uses `(mod count 64)` for `SL`/`SR`/`SRU` and never touches `rA`. `SLU` (`#3A`/`#3B`) is not implemented.

4. **`DIV` is not MMIX `DIV`.** `mmix-doc` §20: signed quotient is floor(y/z) (remainder has the sign of the divisor); `rR` receives the remainder; division by zero sets `$X ← 0` and `rR ← $Y` and raises integer divide check; `−2^63 / −1` overflows. `execute` runs Common Lisp `truncate` on the raw unsigned register values (toward zero, unsigned). On a zero divisor it sets `$X` to the dividend and `rR` to 0 — the opposite assignment. `DIVU` (128-bit dividend in `rD`) is missing. `MULU` does not write `rH`.

5. **`ADD`/`SUB`/`MUL`/`SL` never report overflow.** The implemented opcodes are the signed ones (`ADD` is `#20`, which must signal V in `rA` when the mathematical result is outside `[−2^63, 2^63)`). The code wraps modulo `2^64` and leaves `rA` at 0, so it behaves like `ADDU` under the `ADD` opcode. `ADDU` itself (`#22`) is missing, and MMIXAL emits `ADDU` for `LDA` and for address arithmetic (`mmix-doc` §7).

6. **Loads and stores do not force alignment.** `mmix-doc` §6–8: a `2^t`-byte access uses address `k` with the low `t` bits cleared (rounded down), not a trap and not a split access. `mem-ref-u16` and friends use the address as given. Signed stores (`STB`/`STW`, and the missing `STT`) must raise integer overflow when the register value does not fit the signed width; the unsigned variants (`STBU`, …) skip that check. Our `STB`/`STW` store the low bytes and never set `rA`, so they implement the unsigned variant under the signed opcode.

7. **`TRAP 0,1,…` is not `Fopen`.** See area 6. Halt is the one compatible case.

The tests in `tests/tests.lisp` pass for the in-repo encoding (small positive immediates, no backward MMIXAL branches, no `DIV`, no shift by ≥ 64). They do not detect the mismatches above.

## Area notes

### 1. General and special registers — partial

Spec (`mmix-doc` §29, §40–43; opcode-page special-register table):

- `$0`–`$255`. With counters `L = rL` and `G = rG` (`0 ≤ L ≤ G ≤ 255`, and `G ≥ 32`): `$0`…`$(L−1)` local, `$L`…`$(G−1)` marginal, `$G`…`$255` global.
- A marginal register reads as 0. Writing marginal `$x` sets `rL ← x+1` and zeros the registers in between.
- `PUT rL` can only decrease `rL`. `G` is fixed at load time from the program’s `GREG`s and may be changed later with `PUT`.
- 32 specials: `rB rD rE rH rJ rM rR rBB rC rN rO rS rI rT rTT rK rQ rU rV rG rL rA rF rP rW rX rY rZ rWW rXX rYY rZZ` (numbers 0–31 as on the opcode page).
- `rA` layout (`mmix-doc` §32): bits 17–16 are the rounding mode (00 nearest/even, 01 toward 0, 10 toward +∞, 11 toward −∞). Bits 8–15 are enable bits and bits 0–7 are event bits, each the eight flags `DVWIOUZX` (integer divide check, integer overflow, float-to-fix, invalid, float overflow, float underflow, float divide by zero, inexact).
- `rO` and `rS` are the register-stack offset and pointer (`mmix-doc` §42), usually aimed at `Stack_Segment`.

Code: `reg`/`set-reg` index a flat vector. Nothing consults `rL` or `rG`. `make-vm` zeros every special, so `rG` is 0 rather than a legal threshold (≥ 32, and 255 when the program allocated no globals). `special-reg`/`set-special` exist but are not exported. `execute` writes `rR` on `DIV` and `rJ` on `GO` only. There is no `GET` (`#FE`) or `PUT` (`#F6`/`#F7`), so a program cannot even move `rR` into a general register after division.

### 2. Instruction set — partial

Knuth’s chart has 256 opcodes (`mmop.html`). `+op+` lists 64 distinct bytes plus the `SET` pseudo, which shares `ORI` (`#C1`). Roughly a quarter of the map has a handler; several of those handlers are semantically wrong (previous section).

**Implemented (mnemonic as coded, not as in the chart when they differ):**

| Group | Opcodes in `+op+` / `execute` |
| --- | --- |
| Trap | `TRAP` `#00` |
| Multiply / divide | `MUL` `#18`, `MULI` `#19`, `DIV` `#1C`, `DIVI` `#1D` |
| Add / sub | `ADD` `#20`, `ADDI` `#21`, `SUB` `#24`, `SUBI` `#25` |
| Compare | `CMP` `#30`, `CMPI` `#31`, `CMPU` `#32`, `CMPUI` `#33` |
| Shift | `SL` `#38`, `SLI` `#39`, `SR` `#3C`, `SRI` `#3D`, `SRU` `#3E`, `SRUI` `#3F` |
| Branch | `#40`–`#47` as `BN BNZ BZ BNN BP BNP BOD BEV`; `#48`–`#4D` as `PBN PBNZ PBZ PBNN PBP PBNP`. No `#4E`/`#4F` |
| Load | `LDB` `#80`, `LDBU` `#82`, `LDW` `#84`, `LDWU` `#86`, `LDO` `#8C`, `LDOU` `#8E` (register+register address only) |
| Go | `GO` `#9E`, `GOI` `#9F` |
| Store | `STB` `#A0`, `STW` `#A4`, `STO` `#AC` |
| Logic | `OR` `#C0`, `ORI` `#C1`, `XOR` `#C6`, `XORI` `#C7`, `AND` `#C8`, `ANDI` `#C9` |
| Wyde | `SETH`…`SETL` `#E0`–`#E3`, `INCH`…`INCL` `#E4`–`#E7`, `ORH`…`ORL` `#E8`–`#EB` |
| Jump / address | `JMP` `#F0`, `GETA` `#F4` |

**Major missing groups** (names from the opcode chart):

- Floating point: `FCMP FUN FEQL FADD FIX FSUB FIXU FLOT* SFLOT* FMUL FCMPE FUNE FEQLE FDIV FSQRT FREM FINT` (`#01`–`#17`).
- Unsigned and scaled arithmetic: `MULU DIVU ADDU SUBU 2ADDU 4ADDU 8ADDU 16ADDU NEG NEGU SLU` and their immediate forms. `LDA` is `ADDU` (`mmix-doc` §7).
- Conditional assignment, the usual branchless idiom in Fascicle 1: `CSN CSZ CSP CSOD CSNN CSNZ CSNP CSEV` and `ZSN`…`ZSEV`, plus immediates (`#60`–`#7F`).
- Tetra (32-bit) memory, which MMIX programs use constantly: `LDT LDTU STT STTU` and immediates. Also `LDHT STHT STCO LDSF STSF`.
- The immediate memory opcodes (`LDBI`, `LDOI`, `STOI`, …). MMIXAL turns `LDO $X,base,8` into an immediate form. The README already warns that the MVP expects a zero register as the offset.
- Bitwise completeness: `ANDN ORN NOR NAND NXOR`, the wyde `ANDN*`, `BDIF WDIF TDIF ODIF`, `MUX` (`rM`), `SADD`, `MOR`, `MXOR`.
- Register stack and specials: `PUSHJ PUSHJB PUSHGO PUSHGOI POP SAVE UNSAVE GET PUT PUTI`.
- Jumps: `JMPB`, `GETAB`, all backward `B*`/`PB*`.
- System and synchronization: `TRIP RESUME SYNC SWYM SYNCD SYNCID`, plus `CSWAP` (`rP`), `LDVTS`, `LDUNC STUNC PRELD PREGO PREST`.

`SWYM` is a no-op (and `SYNC` with `XYZ ≤ 3` is a functional no-op on a single-threaded VM). They are trivial once the decoder stops raising “unimplemented opcode,” but they are not what blocks textbook programs.

### 3. Memory model — partial

Spec (`mmix-doc` §6, §44; `mmix-sim` loader):

- Virtual memory is `2^64` bytes, big-endian, naturally aligned by masking.
- User addresses fall in four `2^61`-byte segments. The simulator’s names (`mmix-sim` § on interactive commands, and the hello-world programs) are:
  - `Text_Segment` = `#0` (user code conventionally at `#100`, because `#00`, `#10`, … `#80` are trip vectors; `mmix-doc` §35)
  - `Data_Segment` = `#2000000000000000`
  - `Pool_Segment` = `#4000000000000000`
  - `Stack_Segment` = `#6000000000000000` (register-stack spill and the software stack)
- Negative virtual addresses are kernel-only and map by clearing the sign bit. Physical addresses ≥ `2^48` are reserved for memory-mapped I/O.
- Page protections (`r`, `w`, `x`, …) and `rV` translation are OS machinery.

Code: `make-vm` allocates one zero-filled byte array, default `#x100000` (1 MiB). `check-addr` signals a Lisp error on an out-of-range access. There is no sparse map, so a `LOC Data_Segment` address cannot be represented. No permission bits, no `rV`, no MMIO. Endianness and the byte/wyde/octa helpers are the part that should stay.

A practice VM does **not** need the page-table hardware. It does need the four segments, because every MMIXAL program in the books uses `LOC Data_Segment` and `GREG @`.

### 4. Pipeline / timing — partial, and functional is the right goal

`mmix-doc` §45 assigns costs in υ (oops) and μ (mems): most arithmetic is 1υ, `MUL` is 10υ, `DIV` is 60υ, loads and stores add memory references, taken branches cost more than untaken ones, and `PB*` reverses that guess. Fascicle 1 exercises ask the student to compute those costs by hand. The meta-simulator MMMIX (pipelines, caches, branch prediction) is a research tool in MMIXware, not something a reader needs in order to check an exercise.

What we have: `vm-cycles` increments once per retired instruction (`step-vm`), and `run-vm` aborts at `:max-cycles`. That is a runaway guard, not a timing model. For TAOCP practice, keep the instruction count, and later add a separate memory-reference count if you want output comparable to `mmix`’s “instructions, mems, oops” line. Do not build a pipeline for the practice target.

### 5. Floating point — missing

`mmix-doc` §21–28 specifies IEEE-754 binary64 (sign, 11-bit exponent, 52-bit fraction) with the MMIX choices for NaNs, signed zeros, and overflow (O always also raises X). Operations: `FADD FSUB FMUL FDIV FREM FSQRT FINT FCMP FEQL FUN` and the epsilon forms `FCMPE FEQLE FUNE` (`rE`), plus conversions `FLOT FIX FIXU SFLOT` and short-float load/store `LDSF`/`STSF`. Rounding comes from `rA` bits 17–16, with per-instruction overrides in the `Y` field of the single-operand conversions (`ROUND_OFF/UP/DOWN/NEAR`). Exceptions update `rA` and, if enabled, trip to fixed handlers at 16, 32, …, 128.

None of this is in `src/`. Common Lisp floats are not a substitute: MMIX requires the IEEE bit patterns, the four rounding modes, and the exact NaN quieting rule in `mmix-doc` §22. Implement this after the integer machine can run book programs. It becomes mandatory for the floating-point section of Fascicle 1 and for Volume 2.

### 6. Interruptions, trips, and `TRAP` — partial

Three mechanisms (`mmix-doc` §32–37):

- **Trip** (user handler): `TRIP` (`#FF`) and enabled arithmetic exceptions. State goes to `rB`, `rW`, `rX`, `rY`, `rZ`; control goes to address 0 for `TRIP`, or to `16 * bitindex` for `D V W I O U Z X`. Return with `RESUME` (`#F9`).
- **Forced trap** (kernel): `TRAP` (`#00`) clears `rK`, saves `rBB rWW rXX rYY rZZ`, and jumps to `rT`. `mmix-doc` §33 predefines only two architecturally: `XYZ = 0` terminates the user process, `XYZ = 1` is the default trip handler’s way of asking the OS for help.
- **Dynamic trap**: bits in `rQ` masked by `rK` (the `rwxnkbsp` program bits plus I/O and machine bits) jump through `rTT`.

The program a student actually writes does **not** install that kernel path. MMIXware’s user-mode simulator intercepts `TRAP` and performs the call itself (`mmix-sim`). The Y-field opcodes, from the simulator’s `Halt, Fopen, Fclose, Fread, Fgets, Fgetws, Fwrite, Fputs, Fputws, Fseek, Ftell` table, are:

| Y | Call | Notes |
| --- | --- | --- |
| 0 | `Halt` | `TRAP 0,Halt,0`. Also the architectural “terminate” case |
| 1 | `Fopen` | handle in Z; name and mode are octas at the address in `$255` |
| 2 | `Fclose` | |
| 3 | `Fread` | buffer and size at `$255` |
| 4 | `Fgets` | |
| 5 | `Fgetws` | wyde characters |
| 6 | `Fwrite` | |
| 7 | `Fputs` | `$255` is the string address; Z is the handle; result returned in `$255` |
| 8 | `Fputws` | |
| 9 | `Fseek` | |
| 10 | `Ftell` | |

`StdIn = 0`, `StdOut = 1`, `StdErr = 2`, already open. Modes are `TextRead`, `TextWrite`, `BinaryRead`, `BinaryWrite`, `BinaryReadWrite`. The hello-world encoding `TRAP 0,Fputs,StdOut` is the tetra `#00000701` ([example trace](https://mmix.cs.hm.edu/examples/hello.html)).

Code (`exec-trap` in `src/ops.lisp`, table in `README.md`):

| Instruction | This VM | MMIX-SIM |
| --- | --- | --- |
| `TRAP 0,0,0` | Halt | Halt |
| `TRAP 0,1,Z` | Putchar: low 8 bits of `$Z` | `Fopen` |
| anything else | Append a note and halt | The corresponding call, or an error |

`demo-putchar-hello` and the test `e2e-hello` depend on the putchar convention. It cannot coexist with `Fopen` = 1. A practice VM should implement the simulator calls and retire putchar (or hide it behind an explicit non-default flag).

Also missing: `TRIP`, `RESUME`, trip vectors, `rA` enable bits, `rT`/`rTT`/`rK`/`rQ`. For the practice target, emulate syscalls directly the way `mmix` does. Full trip/trap delivery is P2 unless you are teaching the exception chapter itself (then a minimal `TRIP` + `RESUME` is P1).

### 7. Calling convention / register stack — missing

This is the feature that separates a toy ISA from programs in the books. `mmix-doc` §29, abbreviated:

- `PUSHJ $X,RA` / `PUSHGO $X,$Y,$Z`: if `X` is marginal, widen `rL` first. Push `$0`…`$X` (the last of these is the count `X` itself, the “hole”) onto the register stack, rename `$(X+1)`… to `$0`…, set `rL ← rL−X−1`, set `rJ ← λ+4`, and branch (forward/backward wyde, or absolute for `PUSHGO`).
- `POP X,YZ` undoes the matching push, plants the return values around the hole (the last return value drops into the hole; the others keep their order), and jumps to `rJ + 4*YZ`.
- A subroutine that calls further routines must `GET` `rJ` to a local and `PUT` it back before `POP`.
- `SAVE`/`UNSAVE` snapshot locals, globals, and a defined set of specials. The official loader starts a process with `UNSAVE` (`mmix-sim`). A user-mode loader may apply that postamble directly instead of executing BIOS.

`GREG` in MMIXAL allocates globals from 254 downward and sets `rG`. `$255` stays global; it is the syscall argument/result register. None of `PUSHJ`, `POP`, `PUSHGO`, `SAVE`, `UNSAVE`, `GET`, or `PUT` is in `+op+`.

An internal Lisp stack is an acceptable first implementation of `S[τ]`, as long as `PUSHJ`/`POP`/`rL`/`rG` match the spec. Spilling through `rO`/`rS` into `Stack_Segment` can follow once segmented memory exists. `SAVE`/`UNSAVE` matter for the loader and for coroutines; they are not needed to run a first `PUSHJ` example.

### 8. Assembler / loader — partial

What students type is MMIXAL, not s-expressions: `LOC`, `GREG`, `IS`, `BYTE`/`WYDE`/`TETRA`/`OCTA`, local labels `1H`/`1B`/`1F`, expressions, `PREFIX`, and `Main`. `mmixal` writes a `.mmo` object file (the format specified with the assembler in MMIXware). The simulator loads `.mmo`, relocates segments, applies the `GREG`/stack postamble, and starts at `Main`.

What we have (`src/asm.lisp`):

- Forms `(program (:org addr) (label :name) (setl $1 10) …)`.
- Registers as `$3` or `3`. Labels as branch/`JMP`/`GETA` targets.
- `:byte` and `:word` (the latter is an octa, despite the name). No wyde or tetra directives.
- A second `:org` updates label addresses but `assemble-into` writes the byte vector as one contiguous image at the first origin. A gap or a data segment is not placed at the address `collect-labels` recorded.
- No `GREG`, no expressions, no local labels, no `.mmo` reader, no symbol table retained on the VM (`assemble` returns a label hash only to the caller).

**Practical format for TAOCP practice:** keep writing small tests in s-expressions, but treat **`.mmo` from external `mmixal`** as the program format. Reimplementing MMIXAL inside Lisp is a large project (expressions, local labels, `GREG`, fixups) that duplicates a tool Knuth already ships. A loader is smaller and unlocks the printed programs unchanged. The s-expression assembler should still be fixed to emit real opcodes, so tests and `.mmo` programs agree.

### 9. Debugging / learner UX — partial

`mmix -i` (documented in `mmix-sim`) is the session students copy: single step, continue, breakpoints on read/write/execute, dump local vs global registers and specials, dump memory in decimal/hex/float/string, jump to an address, switch the current segment (`T`/`D`/`P`/`S`).

We have `step-vm`, `run-vm`, `disassemble-at`, `dump-registers`, `dump-memory`. Gaps that matter once programs are longer than the demos:

- No breakpoints, so `run-vm` is all-or-nothing aside from `:max-cycles`.
- `dump-registers` skips specials, `rL`/`rG`, and the local/marginal/global distinction.
- `disassemble-at` prints our mnemonic for the opcode byte, which will misname `#41` as `BNZ` until the map is fixed.
- Labels from `assemble` are not stored on the VM, so a dump cannot show symbols.
- No memory-reference count next to the instruction count.

Step and dump are the right foundation. Breakpoints and a special-register view are the next UX work, after the ISA can run a real subroutine.

### 10. Compatibility target — recommendation

Three targets, and only one is realistic for this codebase:

| Target | What it means | Verdict |
| --- | --- | --- |
| Run MMIXware binaries / NNIX | `.mmo` plus BIOS at `#8000000000000000`, `rV` page tables, privileged `TRAP` delivery, dynamic traps, `SAVE`/`UNSAVE` process switch, pipeline | **Not the goal.** Years of OS surface for no gain on exercise answers |
| Run educational programs assembled in-repo | Today’s s-expressions only | **Too small.** Readers would translate every listing by hand, including `PUSHJ` and `LOC Data_Segment` |
| Run MMIXAL via the external toolchain | `mmixal foo.mms` → `foo.mmo` → this VM, user mode, integer ISA, register stack, four segments, MMIX-SIM I/O | **Yes.** This is what Fascicle 1 and the MMIX supplement assume, minus the official `mmix` simulator |

The third target still allows pure-Lisp experiments: the s-expression assembler stays, and it must target the same ISA. Shipping a private dialect (current branch opcodes, putchar trap, flat `$0` as a base register) will teach habits that fail as soon as a student opens a `.mms` file.

## Gaps by priority

### P0 — must-have for TAOCP practice

Without these, a reader cannot type a program from the book and check it.

1. **Spec-correct control transfers.** Forward/backward branch opcodes `#40`–`#5F` per the chart; unsigned displacements; `JMP`/`JMPB`; `GETA`/`GETAB`. `GO`/`GOI` set only `$X`, ignore the low two target bits, and do not write `rJ`. Update `disassemble-at` to match.
2. **Register window and subroutine linkage.** `rL`/`rG` with marginal-read and auto-widen rules (`G ≥ 32`, initial `rG` from the program, default 255). `PUSHJ`/`PUSHJB`/`PUSHGO`/`PUSHGOI` and `POP`. `rJ` saved and restored the way §29 describes. A Lisp-side register stack is acceptable until spill exists.
3. **`GET`/`PUT`.** At least the user-visible specials programs actually touch: `rA rB rD rE rG rH rJ rL rM rR rP`, readable and writable under the §43 restrictions (`rN`/`rO`/`rS` not writable; `PUT rL` only decreases). Until this exists, `DIV`’s remainder is invisible to MMIX code.
4. **Integer ISA that MMIXAL actually emits.**
   - `ADDU`/`SUBU`/`NEG`/`NEGU`/`2ADDU`/`4ADDU`/`8ADDU`/`16ADDU` and immediates (`LDA` = `ADDU`).
   - Signed `DIV` (floor quotient, remainder sign of divisor, div0 and `−2^63/−1` cases, `rR`) and `DIVU` (`rD`). `MULU` writes `rH`.
   - `SLU`. Shift counts ≥ 64 follow §14. Signed `ADD`/`SUB`/`MUL`/`SL` set the V event bit in `rA`; `DIV` by zero sets D. Enabling the trip can wait.
   - Tetra `LDT`/`LDTU`/`STT`/`STTU` and the immediate forms of every load and store we claim to support (`LDBI`, `LDWI`, `LDTI`, `LDOI`, `STBI`, `STWI`, `STTI`, `STOI`, and the unsigned twins).
   - Alignment by masking, as in §6.
   - Conditional sets `CS*` and `ZS*` (`#60`–`#7F`). Fascicle 1 treats them as basic, and generated code uses them instead of branches.
5. **Four segments.** Sparse or paged memory so `#0`, `#2000000000000000`, `#4000000000000000`, and `#6000000000000000` can all hold data. Text programs load at `#100`, leaving room for trip vectors. Out-of-range access should be a clean VM fault, not an uncaught Lisp error, once programs are expected to run.
6. **MMIX-SIM `TRAP` subset, not putchar.** `Halt` (Y=0), `Fputs` (Y=7) and `Fgets` (Y=4) on `StdIn`/`StdOut`/`StdErr`, plus `Fopen`/`Fclose`/`Fread`/`Fwrite` so file-based exercises work. `$255` is the argument and the result, as in `mmix-sim`. Remove or strictly opt-in the current `TRAP 0,1,Z` putchar (it occupies `Fopen`).
7. **A way to load book programs.** A `.mmo` loader (relocations, segment images, `rG` / entry point from the postamble). The s-expression assembler remains for tests but must emit the opcodes from item 1. Fix the multi-`:org` bug in `assemble-into` (bytes are packed contiguously, so a second origin is not honored).

### P1 — important, not required to check the first integer exercises

- **Floating point** to `mmix-doc` §21–28, including `rA` rounding and the event bits `WIOUZX`. Needed for the FP part of Fascicle 1 and for Volume 2. Short-float `LDSF`/`STSF` can trail the scalar operations.
- **Bitwise ops used by real listings:** `ANDN` and the other Boolean completions, `BDIF`/`WDIF`/`TDIF`/`ODIF`, `MUX` (`rM`), `SADD`, and the `ANDNH`…`ANDNL` wydes. `MOR`/`MXOR` show up in later bit-fiddling programs.
- **`LDHT`/`STHT`/`STCO`.** High-tetra arithmetic is a taught idiom (§7–8).
- **Register-stack spill** via `rO`/`rS` into `Stack_Segment`, once deep recursion no longer fits in a Lisp vector.
- **`SAVE`/`UNSAVE`**, if the loader should execute the official startup image instead of decoding it.
- **Minimal trips:** `TRIP`, the eight arithmetic entry points, and `RESUME`, so exception exercises can be run. Default handlers can be `TRAP 1` behavior (report and stop) without a kernel.
- **Learner session:** breakpoints, dump of specials and of local vs global, symbols from the object file, instruction count plus memory-reference count. `SWYM` as a no-op (the simulator uses it as a stopping point).
- **Assembler comfort if `.mmo` is inconvenient on some machines:** a *subset* of MMIXAL (`LOC`, `GREG`, `IS`, data directives, local labels, integer expressions) is enough. Full macro MMIXAL is not.

### P2 — nice-to-have / full MMIXware parity

Not needed to practice TAOCP, and not part of the recommended target.

- Virtual translation `rV`, page tables, protection bits, negative kernel addresses, MMIO above `2^48`.
- Dynamic traps, `rK`/`rQ`, privileged `PUT`, trap entry at `rT` with a real BIOS (`#8000000000000000` in the extended examples).
- Cycle-accurate υ/μ, branch prediction, caches, the MMMIX pipeline.
- `CSWAP`, `LDVTS`, `LDUNC`/`STUNC`, `PRELD`/`PREGO`/`PREST`, `SYNCD`/`SYNCID`, `SYNC` beyond “nop on one CPU.”
- `Fgetws`/`Fputws`, `Fseek`/`Ftell`, argv setup in `Pool_Segment`, the full interactive command language of `mmix -i`.
- Object-file symbol types, line numbers, and profile counts.
- Hardware register-ring details (the 512-deep local ring in §42). Observable behavior of `PUSH`/`POP` is what matters; the ring is an implementation technique.

## Suggested implementation order

Each phase should leave the existing demos runnable (update them when the `TRAP` convention changes) and should add tests that compare against the spec, not only against the previous assembler.

1. **Phase A — stop disagreeing with the opcode chart.** Re-encode branches, `JMP`/`JMPB`, `GETA`/`GETAB`. Fix `GO`. Fix shifts, signed `DIV`/`rR`, and `rA` event bits for V and D. Add `ADDU`/`SUBU`/`NEG*`/`SLU`/`nADDU`, tetra and immediate memory ops, alignment masking, and `CS*`/`ZS*`. Still a flat register file and the s-expression assembler. This phase is pure Lisp and unblocks honest tests.
2. **Phase B — subroutines.** `rL`/`rG`, `PUSHJ`/`POP`/`PUSHGO`, `GET`/`PUT`, `rJ` discipline. Port a two-page Fascicle 1 subroutine (call, nested call that saves `rJ`, `POP` with a result) as the acceptance test.
3. **Phase C — book programs load and print.** Segmented memory. `.mmo` loader and `rG` initialization. Replace putchar with `Halt` + `Fputs`/`Fgets`/`Fopen`/`Fread`/`Fwrite`. Acceptance test: the standard hello world (`LOC Data_Segment`, `GREG`, `LDA $255`, `TRAP 0,Fputs,StdOut`, `TRAP 0,Halt,0`) and one subroutine-heavy program from Fascicle 1 or the MMIX supplement.
4. **Phase D — practice session.** Breakpoints, special-register and segment dumps, symbol names, mems alongside instructions. Optional `SWYM` nop.
5. **Phase E — floating point.** Binary64 operations and `rA` rounding, with tests for the signed-zero and NaN rules in §22. This is when Volume 2 exercises become possible.
6. **Phase F — only if a later goal says so.** Trips and `RESUME`, `SAVE`/`UNSAVE` spill, then anything in the P2 list. Do not start here.

## Open questions

1. **Confirm the target.** External `mmixal` + `.mmo` loader, as recommended, or must the project stay free of any non-Lisp tool and therefore grow an MMIXAL subset?
2. **Putchar compatibility.** Drop `TRAP 0,1,Z` putchar (breaks `demo-putchar-hello` and `e2e-hello`) in favor of `Fputs`, or keep putchar only when a VM flag is set?
3. **When is floating point in scope?** Deferred to Phase E (recommended), or required in the first “practice-ready” milestone because Fascicle 1 documents it up front?
4. **Timing.** Agree that instruction count plus an optional memory-reference count is enough, and that υ/μ pipeline costs stay a manual exercise?
5. **Loader startup.** Interpret the `.mmo` postamble into `rG`, memory, and PC directly, or emulate the official `UNSAVE` prelude? The first is less code; the second is easier to compare against `mmix -i` traces.
6. **How big are the segments?** A few megabytes each, grow-on-touch pages, or a single sparse map with a hard cap?
7. **`rG` default for s-expression programs** that do not mention globals: 255 (everything local until used) is the usual stand-alone default. Confirm before Phase B changes today’s flat file.
