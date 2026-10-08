# Current implementation

This document describes this tree (ASDF system `cl-mmix`, version 0.10.0). It is what the sources do today. The distance from this tree to a full machine — kernel mode, the remaining opcodes, virtual memory, a pipeline, and shared-memory multi-core — is [TAOCP-GAP-ANALYSIS.md](TAOCP-GAP-ANALYSIS.md). The order of work is [plans/00-roadmap.md](plans/00-roadmap.md).

The VM is a **user-mode functional interpreter** for educational MMIXAL. Every one of the 256 opcode bytes has a name in the decoder. The integer, bitwise, floating-point, load/store, branch, wyde, register-stack, and MMIX-SIM `TRAP` instructions are executed. `SAVE`/`UNSAVE` are recognized and stop the machine with `vm-fault`. There is no pipeline, no page-table `rV`, and no dynamic trap entry into a kernel.

## Source map

ASDF loads `src/` serially, in this order:

| File | Responsibility |
|------|----------------|
| `package.lisp` | Packages `cl-mmix` and `cl-mmix/tests`, and the public exports |
| `util.lisp` | 64-bit wrap, signed views, overflow, floor division, shifts, `BDIF` slices, `MOR`/`MXOR` |
| `machine.lisp` | VM struct, special registers, the `rL`/`rG` window, sparse memory, the register stack, `PUT` rules, breakpoints, trips |
| `decode.lisp` | The 256-opcode name table, encode/decode, fetch, disassembly |
| `float/` | IEEE binary64 and binary32. `octa.lisp` holds the bit helpers, `pack.lisp` packs and unpacks, `arith.lisp` is the operations, `exec.lisp` dispatches opcodes and commits `rA` |
| `trap.lisp` | MMIX-SIM `TRAP` services and the legacy putchar switch |
| `ops.lisp` | Instruction execution and `step-vm` / `run-vm` / `continue-vm`. Floating-point opcodes call into `float/` |
| `asm.lisp` | S-expression assembler |
| `mmo.lisp` | `.mmo` loader |
| `api.lisp` | `dump-registers`, `dump-memory`, and the demos |

`tests/tests.lisp` is a small `check` runner (no FiveAM, no Quicklisp). `scripts/run-demo.lisp` loads the system and prints the demos.

## Instruction word

An instruction is a big-endian tetrabyte:

```
OP (8) | X (8) | Y (8) | Z (8)
```

`decode` splits that into an `instruction` struct (`inst-op`, `inst-x`, `inst-y`, `inst-z`, `inst-raw`). `fetch` reads the tetra at `PC` with the low two bits cleared and does not advance `PC`.

Operand rule used by `z-operand`:

- An **even** opcode in a register/immediate pair reads `$Z`.
- The **odd** opcode reads `Z` as an unsigned byte. The byte is never sign-extended.

`FIX`, `FIXU`, `FSQRT`, and `FINT` do not follow that rule either: the opcode is odd and `$Z` is still a register. `Y` is a rounding byte. Only `FLOTI`, `FLOTUI`, `SFLOTI`, and `SFLOTUI` take `Z` as an unsigned byte.

Branch opcodes do not follow that rule. In `#x40`–`#x5F`, `#xF0`–`#xF1`, `#xF2`–`#xF3`, and `#xF4`–`#xF5`, the odd opcode is the **backward** form. The unsigned field is `YZ` (16 bits) or `XYZ` (24 bits for `JMP`/`JMPB`). A backward displacement is `field − 2^bits`. The target is `PC + 4 * displacement`, relative to the instruction itself, not to `PC+4`.

`execute` returns `:jump` when it has already set `PC`, `:stop` when a `TRAP` halted, or `nil` to fall through by 4 bytes.

## Opcode map

`src/decode.lisp` fills `*op-name*` and `*op-byte*`. `+op+` is the resulting alist. Names match Knuth’s opcode chart. A trailing `I` is the immediate form (`ADD`/`ADDI`). A trailing `B` on a branch, `JMP`, `PUSHJ`, or `GETA` is the backward form.

Status in the table means what `execute` does today.

| Bytes | Names | Status |
|-------|--------|--------|
| `#x00` | `TRAP` | Executed. See [Traps](#traps). |
| `#x01`–`#x17` | `FCMP` `FUN` `FEQL` `FADD` `FIX` `FSUB` `FIXU` `FLOT`/`FLOTI` `FLOTU`/`FLOTUI` `SFLOT`/`SFLOTI` `SFLOTU`/`SFLOTUI` `FMUL` `FCMPE` `FUNE` `FEQLE` `FDIV` `FSQRT` `FREM` `FINT` | Executed. Binary64 bit patterns, four rounding modes, events `W I O U Z X`. See [Floating point](#floating-point). |
| `#x18`–`#x1F` | `MUL`/`MULI` `MULU`/`MULUI` `DIV`/`DIVI` `DIVU`/`DIVUI` | Executed. See [Arithmetic](#arithmetic). |
| `#x20`–`#x2F` | `ADD`/`ADDI` `ADDU`/`ADDUI` `SUB`/`SUBI` `SUBU`/`SUBUI` `2ADDU` `4ADDU` `8ADDU` `16ADDU` and the `I` forms | Executed. Scaled `nADDU` is `($Y << k) + Z` for `k` in {1,2,3,4}. |
| `#x30`–`#x37` | `CMP`/`CMPI` `CMPU`/`CMPUI` `NEG`/`NEGI` `NEGU`/`NEGUI` | Executed. Compare writes 0, 1, or the unsigned bit pattern of −1. For `NEG`/`NEGU`, `Y` is an unsigned byte in **both** the register form and the immediate form; `Z` is `$Z` or the unsigned byte. |
| `#x38`–`#x3F` | `SL`/`SLI` `SLU`/`SLUI` `SR`/`SRI` `SRU`/`SRUI` | Executed. The count is the full operand, not `count mod 64`. |
| `#x40`–`#x4F` | `BN` `BZ` `BP` `BOD` `BNN` `BNZ` `BNP` `BEV` and each backward `…B` | Executed. `BNZ` is `#x4A`, not `#x41`. `#x41` is `BNB`. |
| `#x50`–`#x5F` | `PBN` `PBZ` `PBP` `PBOD` `PBNN` `PBNZ` `PBNP` `PBEV` and the backward forms | Executed with the same predicates as the non-probable branches. There is no branch prediction and no penalty. |
| `#x60`–`#x6F` | `CSN` `CSZ` `CSP` `CSOD` `CSNN` `CSNZ` `CSNP` `CSEV` and `I` forms | Executed. If the predicate on `$Y` holds, `$X ← Z`; otherwise `$X` is left alone. |
| `#x70`–`#x7F` | `ZSN` `ZSZ` `ZSP` `ZSOD` `ZSNN` `ZSNZ` `ZSNP` `ZSEV` and `I` forms | Executed. `$X ← Z` when the predicate holds, else `$X ← 0`. |
| `#x80`–`#x8F` | `LDB` `LDBU` `LDW` `LDWU` `LDT` `LDTU` `LDO` `LDOU` and `I` forms | Executed. Signed loads sign-extend. Widths are 1, 2, 4, and 8 bytes. |
| `#x90`–`#x91` | `LDSF`/`LDSFI` | Executed. Aligned tetra load, widened from binary32 to binary64. Increments `vm-mems`. |
| `#x92`–`#x93` | `LDHT`/`LDHTI` | Executed. The aligned tetra is shifted left by 32. |
| `#x94`–`#x95` | `CSWAP`/`CSWAPI` | Executed. Compare the octa at the aligned address with `rP`. On a match, store `$X` and set `$X ← 1`. Otherwise set `rP` from memory and `$X ← 0`. |
| `#x96`–`#x97` | `LDUNC`/`LDUNCI` | Executed as `LDOU`. There is no cache. |
| `#x98`–`#x99` | `LDVTS`/`LDVTSI` | Executed as "return 0". There are no page tables. |
| `#x9A`–`#x9D` | `PRELD`/`PRELDI` `PREGO`/`PREGOI` | No-ops. |
| `#x9E`–`#x9F` | `GO`/`GOI` | Executed. `$X ← PC+4`, then `PC ← ($Y + Z)` with the low two bits cleared. `rJ` is not written. |
| `#xA0`–`#xAF` | `STB` `STBU` `STW` `STWU` `STT` `STTU` `STO` `STOU` and `I` forms | Executed. A signed store that does not fit the width sets `V` in `rA` and still writes the low bytes. |
| `#xB0`–`#xB1` | `STSF`/`STSFI` | Executed. Narrows binary64 to binary32 with the current rounding mode, then writes the tetra. Overflow sets `O` and `X`, not `V`. |
| `#xB2`–`#xB3` | `STHT`/`STHTI` | Executed. Stores bits 63–32 of `$X` as a tetra. |
| `#xB4`–`#xB5` | `STCO`/`STCOI` | Executed. Stores the unsigned byte `X` (the instruction field, not `$X`) as an octa. |
| `#xB6`–`#xB7` | `STUNC`/`STUNCI` | Executed as `STOU`. |
| `#xB8`–`#xBD` | `SYNCD` `PREST` `SYNCID` and `I` forms | No-ops. |
| `#xBE`–`#xBF` | `PUSHGO`/`PUSHGOI` | Executed. Register-stack push, then `rJ ← PC+4`, then the same jump as `GO`. |
| `#xC0`–`#xCF` | `OR` `ORN` `NOR` `XOR` `AND` `ANDN` `NAND` `NXOR` and `I` forms | Executed across the full 64 bits. |
| `#xD0`–`#xD7` | `BDIF` `WDIF` `TDIF` `ODIF` and `I` forms | Executed. Saturated unsigned difference of 8, 16, 32, or 64-bit slices. |
| `#xD8`–`#xD9` | `MUX`/`MUXI` | Executed. Bit `i` comes from `$Y` where `rM` has a 1, otherwise from `Z`. |
| `#xDA`–`#xDB` | `SADD`/`SADDI` | Executed. Population count of `$Y` AND NOT `Z`. |
| `#xDC`–`#xDF` | `MOR`/`MORI` `MXOR`/`MXORI` | Executed. 8×8 boolean matrix product. The leftmost bit of byte `i` of `$Y` selects the leftmost byte of `Z`. `MXOR` combines the selected bytes with XOR instead of OR. |
| `#xE0`–`#xEF` | `SETH` `SETMH` `SETML` `SETL`, `INCH` `INCMH` `INCML` `INCL`, `ORH` `ORMH` `ORML` `ORL`, `ANDNH` `ANDNMH` `ANDNML` `ANDNL` | Executed. The 16-bit `YZ` field is placed at bit shift 48, 32, 16, or 0. The four groups replace, add, OR, or AND-NOT that field into `$X`. |
| `#xF0`–`#xF1` | `JMP`/`JMPB` | Executed. 24-bit relative branch. `XYZ = 0` jumps to itself. |
| `#xF2`–`#xF3` | `PUSHJ`/`PUSHJB` | Executed. Register-stack push, `rJ ← PC+4`, then a 16-bit relative branch. |
| `#xF4`–`#xF5` | `GETA`/`GETAB` | Executed. `$X ←` the target address. Control does not branch. |
| `#xF6`–`#xF7` | `PUT`/`PUTI` | Executed. `PUT` writes `$Z` into special register `X`. `PUTI` writes the unsigned byte `Z`. A nonzero `Y` field is an illegal instruction. See [PUT](#put). |
| `#xF8` | `POP` | Executed. `X` is the number of return values. `PC ← rJ + 4*YZ`. |
| `#xF9` | `RESUME` | `Z ≠ 0` faults with "RESUME with a nonzero XYZ is not implemented". A nonzero `X` or `Y` field is an illegal instruction. `RESUME 0` returns to `rW` when `rX` is negative, and otherwise inserts the low tetra of `rX`. See [Trips](#trips). |
| `#xFA`–`#xFB` | `SAVE`/`UNSAVE` | Not executed. Fault: "SAVE/UNSAVE is not implemented". |
| `#xFC`–`#xFD` | `SYNC`/`SWYM` | No-ops. `SWYM` does not halt. |
| `#xFE` | `GET` | Executed. `$X ←` special register `Z`, with no permission check. A nonzero `Y` field is an illegal instruction. |
| `#xFF` | `TRIP` | Executed. Enters the trip handler at address 0 with the §35 register image. See [Trips](#trips). |

Load and store addresses are aligned by clearing the low bits (`1`, `2`, `4`, or `8` bytes), not by trapping. An unaligned `STW` at address 1 therefore writes at address 0. Each load or store increments `vm-mems`. Prefetches, `SYNC*`, `SWYM`, and `LDVTS` do not.

## Arithmetic

All general-register values are stored as unsigned 64-bit patterns. Signed operations view that pattern as two’s complement.

| Operation | Result | `rA` |
|-----------|--------|------|
| `ADD`/`SUB`/`MUL`/`SL` | Wrapped 64-bit result | `V` (`#x40`) when the mathematical signed result does not fit in −2^63 … 2^63−1 |
| `SL` with count ≥ 64 | 0 | `V` unless the source is 0 |
| `SLU`/`SRU` with count ≥ 64 | 0 | no event |
| `SR` with count ≥ 64 | 0, or the bit pattern of −1 when the source is negative | no event |
| `ADDU`/`SUBU`/`MULU`/`2ADDU`… | Wrapped unsigned result | `MULU` also writes the high 64 bits of the product to `rH` |
| `DIV` | Floor quotient. The remainder has the sign of the divisor and is written to `rR` | Divisor 0: `$X ← 0`, `rR ←` dividend, `D` (`#x80`). −2^63 / −1: `$X` stays −2^63, `rR ← 0`, `V` |
| `DIVU` | Unsigned division of the 128-bit value `rD·2^64 + $Y` by `Z` | Failure (`Z = 0` or `rD ≥ Z`): `$X ← rD`, `rR ← $Y`, `D` |
| `NEG` | `Y − $Z` as a signed value, `Y` an unsigned byte | `V` when the result does not fit |
| `NEGU` | Same subtraction modulo 2^64 | no event |

An event bit is recorded when its enable is clear. When the enable is set, the instruction trips and that bit stays clear. Enables are `rA` bits 15–8, the event bit shifted up by 8. They default to 0, so overflow does not leave the instruction stream unless the program turned the enable on. An instruction at a negative address records the bit and does not trip. User mode still faults on a negative address before that instruction can run.

## Floating point

`src/float/` executes the floating-point opcodes. A general register holds a binary64 bit pattern. The implementation does not call `float` or `coerce`.

`rA` bits 17–16 select the rounding mode: 00 nearest, ties to even; 01 toward zero; 10 toward +∞; 11 toward −∞. `FIX`, `FIXU`, `FLOT`, `FLOTU`, `SFLOT`, `SFLOTU`, their immediate forms, `FSQRT`, and `FINT` read `Y` as an override: 0 uses `rA`, 1 is toward zero, 2 toward +∞, 3 toward −∞, 4 nearest/even. Any other `Y` faults with "illegal rounding mode" before the operation. `FADD`, `FSUB`, `FMUL`, `FDIV`, and `FSQRT` round the exact result. `FREM` is the IEEE remainder and ignores the mode.

Comparisons write the integer −1, 0, or +1. `FCMP` of a NaN writes 0 and sets `I`. `FEQL` and `FUN` do not set `I`. `FCMPE`, `FUNE`, and `FEQLE` consult `rE`.

`LDSF` loads an aligned tetra and widens it. `STSF` narrows with the current mode and stores that tetra. A binary64 value that does not fit binary32 sets `O` and `X` and still writes the short encoding. A signaling NaN is quieted and sets `I`. `STSF` does not set `V`.

`W I O U Z X` are merged into `rA` after the result is written. Overflow always also sets `X`. Exact underflow sets `U` only when the `U` enable is on. When several enables are on, one trip is taken, at the earliest enabled bit of `D V W I O U Z X`. The bit that trips stays clear. Every other exception bit from that instruction is recorded, including one whose enable was also set. Disabled exceptions deliver the IEEE default and do not leave the instruction stream.

## Register window

`rG` starts at 255 and `rL` at 0.

| Register | Class | `reg` / `set-reg` |
|----------|--------|-------------------|
| `$0` … `$(rL−1)` | local | Read and write the physical register |
| `$rL` … `$(rG−1)` | marginal | Read returns 0. A write zeros `$rL` … `$(x−1)`, stores the value, and sets `rL ← x+1` |
| `$rG` … `$255` | global | Read and write the physical register. `rL` does not change |

`set-reg` of a fresh `$5` therefore yields `rL = 6` and zeros `$0`–`$4` except `$5` itself. Programs that use `$0` as a zero base still work: widening a higher register zeros the gap, so `$0` becomes a real local 0.

### Push

`PUSHJ` and `PUSHGO` call `push-frame` with `X`, then set `rJ` to the address of the next instruction.

- If `X < rG` and `X ≥ rL`, marginal registers up through `$X` are widened first (so the new `rL` is `X+1` and the callee will see `rL = 0` if nothing was passed above the hole).
- If `X < rG`: push `$0`…`$(X−1)` and then the hole number `X`. Slide `$(X+1)`…`$(old rL − 1)` down to `$0`. New `rL = old rL − X − 1`. Arguments that the caller placed in `$(X+1)`, `$(X+2)`, … become the callee’s `$0`, `$1`, ….
- If `X ≥ rG`: push every current local, then push the old `rL` as the hole, and set `rL ← 0`.

`rJ` is written only by these push instructions. `GO` does not touch it.

### Pop

`POP X,YZ` calls `pop-frame` with `N = X`.

- An empty hidden stack is a fault.
- If `N > rL`, `N` becomes `rL+1`, which pulls one marginal zero into the returned values.
- The hole index `x` is the last stacked octa modulo 256.
- Callee `$(N−1)` is written into that hole. Callee `$0`…`$(N−2)` land at caller `$(x+1)` onward. The caller’s saved `$0`…`$(x−1)` are restored.
- New `rL = min(x+N, rG)`. `POP 0` leaves the hole marginal (`rL = x`). `POP 1` puts the callee’s `$0` in the hole, which is the usual single return value.
- `PC ← rJ + 4*YZ`.

The hidden stack is a growable vector of octas (`vm-stack`). Its length is `tau`. Each push is also stored at `Stack_Segment + 8*tau`. Locals are not mirrored on every write; they are copied when they are pushed. After every window change:

```
rO = Stack_Segment + 8*tau
rS = rO + 8*rL
```

`PUSH`/`POP` with `X < rG` leave `rS` unchanged, which is the usual MMIX invariant. `demo-recursive-factorial` is a complete `PUSHJ`/`POP` factorial and is checked for `0!`, `1!`, `5!`, and `10!`.

## Special registers

| Number | Name | `PUT` |
|--------|------|--------|
| 0 | `rB` | writable |
| 1 | `rD` | writable. High half of the `DIVU` dividend |
| 2 | `rE` | writable |
| 3 | `rH` | writable. Also written by `MULU` |
| 4 | `rJ` | writable. Also written by `PUSHJ`/`PUSHGO` |
| 5 | `rM` | writable. `MUX` mask |
| 6 | `rR` | writable. Also written by `DIV`/`DIVU` |
| 7 | `rBB` | ignored |
| 8–18 | `rC` `rN` `rO` `rS` `rI` `rT` `rTT` `rK` `rQ` `rU` `rV` | ignored. `rO` and `rS` are maintained by the VM, not by `PUT` |
| 19 | `rG` | clamped to at least 32. Raising it zeros registers that become marginal. Lowering it zeros former marginals that become global and keeps former locals that become global. If the new `rG` is below `rL`, `rL` drops to the new `rG` |
| 20 | `rL` | only a smaller value (modulo 256) is accepted |
| 21 | `rA` | bits 18 and above are discarded (`#x3FFFF` mask) |
| 22 | `rF` | ignored |
| 23 | `rP` | writable. Also written by a failing `CSWAP` |
| 24–27 | `rW` `rX` `rY` `rZ` | writable. Also written by a trip |
| 28–31 | `rWW` `rXX` `rYY` `rZZ` | ignored |

`rA` layout:

| Bits | Meaning |
|------|---------|
| 7…0 | Events `D V W I O U Z X`, values `#x80` `#x40` `#x20` `#x10` `#x08` `#x04` `#x02` `#x01` |
| 15…8 | Enables for those events |
| 17…16 | Rounding mode for floating point: 00 nearest/even, 01 toward 0, 10 toward +∞, 11 toward −∞ |

`GET` can read any special, including the ones `PUT` refuses.

Assembler specials accept `rJ`, `J`, or the number `4`. One leading `R` is stripped, so `rR` is the remainder register.

## Memory

| Segment | Base |
|---------|------|
| Text | `#x0000000000000000` |
| Data | `#x2000000000000000` |
| Pool | `#x4000000000000000` |
| Stack | `#x6000000000000000` |

`vm-memory` is a hash table of 4096-byte pages, keyed by the page number, not a flat vector. A read of a missing page returns 0 and allocates nothing. The first write of a page allocates it, filled with zeros. `(mem-size vm)` is the budget in bytes, which is `:memory-size` rounded up to at least one page (the default budget is `#x2000000`, 32 MiB). Exceeding the budget, or touching an address with bit 63 set, signals `mmix-fault`. `step-vm` catches that condition, stores the reason in `vm-fault`, and halts. It does not escape `run-vm` as a raw Lisp error.

`mem-ref-u*` / `mem-set-u*` are big-endian. Multi-byte accesses are done a byte at a time, so a value that crosses a page boundary still works. `:internal t` suppresses watchpoints; fetch and the `.mmo` loader use it.

`mem-xor` is the `.mmo` content operation: loading the same tetra twice clears it, which is how fixups patch a field that was emitted as zero.

## Trips

`signal-events` takes a mask of `rA` event bits. A bit whose enable is clear is ORed into `rA`. The earliest enabled bit trips, and that bit stays clear. Every other bit in the mask is recorded. At a negative `PC` nothing trips and every bit is recorded.

`do-trip` enters the handler:

- `rB ←` the previous `$255`
- `$255 ← rJ`
- `rW ← PC+4` (the instruction after the one that tripped)
- `rX ← #x8000000000000000` OR the raw tetra
- `rY`, `rZ ←` the operands passed by the operation
- `PC ←` the vector

| Event | Bit | Vector |
|-------|-----|--------|
| D | `#x80` | 16 |
| V | `#x40` | 32 |
| W | `#x20` | 48 |
| I | `#x10` | 64 |
| O | `#x08` | 80 |
| U | `#x04` | 96 |
| Z | `#x02` | 112 |
| X | `#x01` | 128 |

`TRIP X,Y,Z` trips to address 0, with `rY ← $Y` and `rZ ← $Z`. A `TRIP` fetched from a negative address does nothing. The arithmetic result is written before the trip. For a store, `rY` is the virtual address `$Y+Z` and `rZ` is the octa that would have been written. The store still completes.

`RESUME` with `Z ≠ 0` faults with "RESUME with a nonzero XYZ is not implemented". A nonzero `X` or `Y` field is an illegal instruction and halts with `vm-fault`. There is no kernel, so `TRAP 0,0,1` still records a fault and halts.

`RESUME 0` reads `rX`:

- Bit 63 set: `PC ← rW`. The tetra in the low half of `rX` is not executed. This is the return from `TRIP` and from an arithmetic trip.
- Otherwise the high byte is the ropcode and the low tetra is inserted as though it occupied `rW−4`. Relative branches and a new trip see that address. A fall-through then sets `PC ← rW`. A jump keeps the target the inserted instruction wrote.
  - Ropcode 0 executes the tetra. An inserted `RESUME` is illegal.
  - Ropcode 1 executes it with the operands replaced by `rY` and `rZ`. The opcode’s high nybble must be `#x0`–`#x3`, `#x6`, `#x7`, `#xC`, `#xD`, or `#xE`, and `$X` must not be marginal.
  - Ropcode 2 sets `$X ← rZ`, where `X` is the second byte of the low tetra, and raises the exception bits in bits 47–40 of `rX`. `$X` must not be marginal. Exact underflow (`U` set, `X` clear, `U` enable clear) is dropped. An enabled bit trips.
  - Ropcode 3 and above are illegal. Ropcode 3 belongs to `RESUME 1`.

## Traps

`TRAP` is the MMIX-SIM system call, not a private putchar instruction. `$255` is the argument or the result. Handles 0, 1, and 2 are opened at `make-vm` as StdIn, StdOut, and StdErr.

| `Y` | Service | Arguments |
|-----|---------|-----------|
| 0 | Halt | `X = Y = Z = 0` is a clean halt. `vm-exit-code` becomes `$255`. `X = Y = 0` and `Z = 1` faults and halts. Any other `Y = 0` halts |
| 1 | `Fopen` | `Z` is the handle and must be ≥ 3. `$255` points at two octas: the address of the path, then the mode. Failure returns −1 |
| 2 | `Fclose` | Closing 0–2 succeeds and leaves them open. Closing a real file closes the Lisp stream |
| 3 | `Fread` | `$255` points at buffer address and size. Result is `n − size`, or `−1 − size` on error. Size above `#x10000000` is an error |
| 4 | `Fgets` | Same argument block. A partial line at EOF is a success and is terminated with a zero byte. Immediate EOF returns −1 |
| 5 | `Fgetws` | Same idea, storing each byte as a wyde |
| 6 | `Fwrite` | Same argument block as `Fread`. Result is `n − size` |
| 7 | `Fputs` | `$255` is the address of a zero-terminated byte string, not a pointer to an argument block. StdOut is appended to `vm-output` |
| 8 | `Fputws` | Zero-terminated wydes. A wyde below 256 is one byte; a larger wyde is written as two bytes |
| 9 | `Fseek` | `$255` is the signed offset. Only real files seek |
| 10 | `Ftell` | `$255` receives the position. Standard handles return −1 |
| other | — | Fault "unsupported TRAP …" and halt |

Modes: 0 TextRead, 1 TextWrite, 2 BinaryRead, 3 BinaryWrite, 4 BinaryReadWrite. The numbers control read versus write permission. Files are opened as raw `(unsigned-byte 8)` streams. Text mode does not translate newlines.

StdOut and StdErr bytes are captured in `vm-output` and `vm-error-output`. When `cl-mmix::*echo-putchar*` is true (the default), they are also written to the Lisp standard streams. Tests bind it to `nil`.

`make-vm` accepts `:input` as a string or a stream; that becomes StdIn. `:legacy-putchar t` (or `setf` of `vm-legacy-putchar`) makes `TRAP 0,1,Z` write the low 8 bits of `$Z` instead of calling `Fopen`. The default is off, because `Y = 1` is `Fopen` in MMIX-SIM. `demo-putchar-hello` uses `Fputs` of a `Data_Segment` string and returns `"HELLO"`.

Any other `Y = 0` halt still stores `$255` as the exit code. `Fputs` of five characters therefore leaves exit code 5, because the call’s result overwrites `$255` before `TRAP 0,0,0`.

## Assembler

`assemble` reads a list of forms, optionally wrapped in `(program …)`. It returns `(values segments origin labels)`.

- `(:org address)` starts a new segment. `PC` after `assemble-into` is the first origin, so code must come before a data `:org` or execution starts in the data.
- `(label name)` records `name →` current address in an `equal` hash table. The name may be a keyword.
- Registers are `$3` or `3`.
- `(lda $X $Y $Z)` is one `ADDU`. `(ldai $X $Y byte)` is `ADDUI`. `LDA` is not expanded into four instructions.
- `(set $X $Y)` is `ORI $X,$Y,0`.
- Branch, `JMP`, `GETA`, and `PUSHJ` targets are labels. The sign of `(target − pc) / 4` selects the forward or backward opcode. The delta must be a multiple of 4 and must fit: branches, `GETA`, and `PUSHJ` cover −2^16 … 2^16−1 instructions; `JMP` covers −2^24 … 2^24−1. A zero delta is the forward opcode with displacement 0, which jumps to itself.
- Wyde immediates (`SETL`, `ORL`, …) must fit in 16 bits. Byte immediates, recognized by a mnemonic that ends in `I` (except `PUTI`, `NEGI`, `NEGUI`), must fit in 8 bits and are unsigned.
- `(neg $X Y $Z)` and `(negu $X Y $Z)` take `Y` as an unsigned byte. The `I` forms take `Z` as an unsigned byte too.
- Data: `:byte`, `:wyde`, `:tetra`, `:octa` (and `:word` as an octa alias), `:string`, `:zstring`.
- `(trap X Y Z)`, `(trip X Y Z)`, `(pop X YZ)`, `(get $X special)`, `(put special $Z)`, `(puti special byte)`, `(swym)`, `(sync xyz)`, `(resume xyz)`, `(save)`, `(unsave)`.

`assemble-into` writes each segment with `mem-set-u8`, clears halt/cycle/fault state, stores the label table on the VM, and does not clear registers. `load-program` writes one byte vector at one origin.

## `.mmo` loader

`load-mmo` accepts a pathname or an octet vector. The file must start with the escape tetrabyte `#x98` and `lop_pre`. The low byte `Z` of that tetra is how many following tetras belong to the preamble (the usual file is `#x98090101`, so one timestamp tetra is skipped).

| Lopcode | Byte | Effect |
|---------|------|--------|
| `lop_quote` | 0 | `YZ` must be 1. The next tetra is ordinary content even if it looks like an escape. This is required for an instruction whose opcode is `#x98` (`LDVTS`) |
| `lop_loc` | 1 | Sets the location to `Y·2^56` plus a tetra (`Z = 1`) or an octa (`Z = 2`). Data segment is `Y = #x20`, not `Y = 2` |
| `lop_skip` | 2 | Adds `YZ` to the location |
| `lop_fixo` | 3 | XORs the current location, as an octa, into the address that follows |
| `lop_fixr` | 4 | XORs the 16-bit `YZ` into the two bytes at `loc + 2 − 4*YZ` |
| `lop_fixrx` | 5 | `Y = 0` and `Z` is 16 or 24. The next tetra is a relative fixup; it is XORed into the instruction it describes |
| `lop_file` | 6 | Records a file name for line notes |
| `lop_line` | 7 | Current source line |
| `lop_spec` | 8 | Skips tetras until the next real loader opcode |
| `lop_post` | 10 | `Y` must be 0. `Z` is the new `rG` and must be ≥ 32. The next `256−Z` octas initialize `$Z`…`$255` |
| `lop_stab` | 11 | Ternary-trie symbol table, padded with zeros to a tetra, then `lop_end` |
| `lop_end` | 12 | Closes the symbol table |

Content tetras are XOR-ed into memory, 4-byte aligned. The first such tetra below `Data_Segment` is the fallback entry point.

Symbols are `mmix-symbol` values (`name`, `value`, `kind`, `serial`). Absolute values of 1–8 bytes are stored big-endian. A value length above 8 is a `Data_Segment` address with the high bytes implied. Length 15 is a register. The serial is a 7-bit continuation; the last byte has its high bit set, and the serial is that accumulated value minus 128. `PC` becomes the absolute symbol `Main`, `:Main`, or the same names with the first character dropped (mmotype’s print convention), otherwise the first text tetra, otherwise 0. Symbol names are also entered in `vm-labels`. Line notes land in `vm-lines` as `(filename . line)`.

## Execution and the debugger

`step-vm`:

1. Returns immediately if the VM has halted.
2. An `:exec` watch on the aligned `PC` sets `vm-break` to `(:exec address)` and returns **before** the instruction. Calling `step-vm` again while `vm-break` is set executes that instruction (`break-skip`). `run-vm` also returns immediately when `vm-break` is already set, so a second `run-vm` does not consume cycles.
3. Increments `vm-cycles`, fetches, decodes, and executes.
4. A `mmix-fault` becomes `vm-fault` plus halt.
5. A `:read` or `:write` watch that fired during the instruction sets `vm-break` **after** the access. `PC` has already moved to the next instruction unless the instruction itself jumped or halted.

`run-vm` loops until halt or a breakpoint. If `vm-cycles` reaches `:max-cycles` (default 100000) with neither, it signals a Lisp error. That error is intentional; the tests still expect it for a jump-to-self.

`continue-vm` clears a breakpoint, marks it skipped so the stopped instruction runs once, then calls `run-vm`.

`breakpoint` pushes `(kind . address)` onto `vm-watches`. `clear-breakpoints` drops the watches and the current stop. Fetch does not trip a `:read` watch.

`dump-registers` prints non-zero general registers with the class local, marginal, or global, then `PC`, cycles, mems, halt, `rL`, `rG`, `rJ`, `rA`, `rR`, `rH`, and any fault, breakpoint, exit code, or captured output. `dump-memory` prints 16-byte rows and does not clamp the address to the page budget, so a dump of `Data_Segment` works. `disassemble-at` prints a name, registers, and the computed target of a branch, `JMP`, `GETA`, or `PUSHJ`. `PUT` and `GET` print special-register names.

`reset-vm` clears halt, cycles, mems, fault, exit, breakpoints, captured output, and the hidden stack. `:clear-registers` also zeros both register files, restores `rG = 255`, and reopens the standard handles. `:clear-memory` drops the page table. `rO`/`rS` are recomputed.

## Public API

Exported from `cl-mmix` (see `src/package.lisp`):

- Construction and slots: `vm`, `make-vm`, `vm-memory`, `vm-registers`, `vm-pc`, `vm-halted`, `vm-cycles`, `vm-special`, `vm-output`, `vm-error-output`, `vm-mems`, `vm-fault`, `vm-exit-code`, `vm-break`, `vm-input`, `vm-labels`, `vm-symbols`, `vm-legacy-putchar`
- Memory and registers: `mem-size`, `mem-ref-u8` through `mem-set-u64`, `reg`, `set-reg`, `special-reg`, `set-special`, `u64`
- Execution: `fetch`, `decode`, `step-vm`, `run-vm`, `continue-vm`, `reset-vm`, `breakpoint`, `clear-breakpoints`
- Loading: `assemble`, `assemble-into`, `load-program`, `load-mmo`
- Inspection: `disassemble-at`, `dump-registers`, `dump-memory`
- Demos: `demo-sum-1-to-n`, `demo-factorial`, `demo-recursive-factorial`, `demo-putchar-hello`, `demo-hello`
- Constants: `+op+`, the four segment bases, and `+r-a+` `+r-b+` `+r-d+` `+r-e+` `+r-g+` `+r-h+` `+r-j+` `+r-l+` `+r-m+` `+r-p+` `+r-r+` `+r-w+` `+r-x+` `+r-y+` `+r-z+`
- Conditions and symbols: `mmix-fault`, `mmix-fault-reason`, `mmix-symbol`, `mmix-symbol-name`, `mmix-symbol-value`, `mmix-symbol-kind`

`set-special` is a raw write. The `PUT` instruction is the one that applies the restrictions above. `special-reg` is a raw read.

`make-vm` keywords are `:memory-size`, `:pc`, `:input`, and `:legacy-putchar`.

## What the tests lock down

`sbcl --script tests/run-tests.lisp` runs 81 checks. `tests/tests.lisp` covers decode, big-endian memory, the original sum/factorial/hello demos, the cycle limit, branch opcode bytes (`JMPB` is `#xF1FFFFFF` for a one-instruction backward jump; a forward `BZ` with displacement 2 is `#x42010002`), shift and divide edge cases, `MULU`’s high half, `LDA`/`2ADDU`/`16ADDU`, the register window and `PUT`, conditional sets, alignment and the `V` bit on `STB`, `MOR` byte reversal, `GO` leaving `rJ` alone, `PUSHJ`/`GETA`, recursive factorial, the page budget, kernel-address faults, `FADD` of zeros followed by the `SAVE` fault, `TRIP`/`RESUME 0` (including ropcodes 0–2 and a nonzero `Y` on `PUT`), an enabled `V` trip, `Fopen` refusing handles 0–2, legacy putchar, `Fgets`/`Fwrite`, breakpoints, and a hand-built `.mmo` image (including XOR, `lop_fixo`, a `Main` symbol, and a data-segment location). `tests/float.lisp` covers binary64 arithmetic, signed zero, ties to even, overflow with and without the `O` enable, `FDIV` by zero, `FSQRT` of −1, `FREM`, `FCMPE`/`FEQLE`, `LDSF`/`STSF`, and `FIX` of 2^63.

## What is still not MMIX

The full catalog, including kernel mode and multi-core, is [TAOCP-GAP-ANALYSIS.md](TAOCP-GAP-ANALYSIS.md). The short list:

- `SAVE` and `UNSAVE`.
- `RESUME 1` (`Z ≠ 0`). `RESUME 0` inserts ropcodes 0–2.
- Virtual memory: no `rV`, no page tables, `LDVTS` returns 0, bit 63 is a hard fault rather than a kernel mapping.
- Dynamic traps and the privileged specials that a kernel would update (`rT`, `rTT`, `rK`, `rQ`, `rC`, and the bootstrap copies).
- A pipeline, prediction for `PB*`, and separate υ/μ counts. `vm-cycles` counts instructions. `vm-mems` counts loads and stores.
- Cache semantics. `LDUNC`, `STUNC`, `PRE*`, `SYNC`, `SYNCD`, and `SYNCID` do not change memory ordering.
- Newline translation on text-mode `Fopen`.
- An MMIXAL (`.mms`) assembler. The s-expression assembler emits the same opcode bytes; `mmixal` output is consumed by `load-mmo`.
