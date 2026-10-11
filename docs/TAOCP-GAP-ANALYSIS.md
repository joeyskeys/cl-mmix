# cl-mmix vs a full MMIX machine

This document is the gap between the sources described in [IMPLEMENTATION.md](IMPLEMENTATION.md) (ASDF system `cl-mmix` 0.17.0) and a complete MMIX. It replaces the older write-up, which compared an early MVP (flat registers, about 64 opcodes, a private putchar `TRAP`) with a user-mode practice target. That user-mode target is what the tree implements now. The paragraphs below describe what is still missing after it.

The work that closes each gap is a separate plan under [plans/](plans/00-roadmap.md).

Analysis only. This file does not change the ISA.

## What “full” means

Three layers, all in scope:

1. **The architecture** in Donald Knuth’s *MMIX: A RISC Computer for the New Millennium* (`mmix-doc`, version 1.0.0). Every opcode has its specified result, `rA` event, and trip. Special registers do what §39–43 say. Trips, forced traps, and dynamic traps follow §32–38. Virtual addresses follow §44–47. `SAVE`/`UNSAVE` follow §43. Running time can be reported in μ and υ as in §50.
2. **The MMIXware simulators.** `mmix` is the user-mode functional simulator (MMIX-SIM): MMIX-SIM `TRAP` services, command-line arguments in `Pool_Segment`, an interactive session, and a startup `UNSAVE`. `mmmix` is the configurable pipeline (fetch, decode, execute, memory, write-back, caches, branch prediction). Its own introduction leaves out multiprocessing and the low-level details of memory-mapped I/O.
3. **Several processors on one memory.** `mmix-doc` §31 says MMIX is designed for that case. `CSWAP` is the atomic primitive. `SYNC` is the ordering and cache-maintenance instruction. Neither shipped simulator runs more than one processor. A full machine in this repository includes a shared-memory multiprocessor, with the coherence protocol and the inter-processor interrupt bit chosen here, because the architecture leaves both to the implementation.

Out of scope, and absent from the plans: proposals that change version 1.0.0 (a different `rV` layout, an `rKK` register, virtualization of negative addresses). Also out of scope: a general-purpose operating system beyond a kernel ROM that implements the MMIX-SIM services and the page-fault path. The hardware plans leave room for that ROM. They do not include a Unix.

## Sources

Current behavior: [IMPLEMENTATION.md](IMPLEMENTATION.md), then `src/machine.lisp`, `src/cache.lisp`, `src/decode.lisp`, `src/ops.lisp`, `src/pipe.lisp`, `src/trap.lisp`, `src/kernel.lisp`, `src/translate.lisp`, `src/asm.lisp`, `src/mmo.lisp`, `src/mmixal.lisp`, `src/api.lisp`, `src/sim.lisp`, `tests/tests.lisp`.

Specification:

- [mmix-doc](https://mmix.cs.hm.edu/doc/mmix-doc.pdf) and the [opcode chart](https://cs.stanford.edu/~knuth/mmop.html). Section numbers below are that document’s.
- [MMIX-SIM](https://mmix.cs.hm.edu/doc/mmix-sim.pdf), the user-mode simulator and its interactive commands.
- [MMMIX](https://mmix.cs.hm.edu/doc/mmmix.pdf), [mmix-pipe](https://mmix.cs.hm.edu/doc/mmix-pipe.pdf), and [mmix-config](https://mmix.cs.hm.edu/doc/mmix-config.pdf) for the pipeline and caches.
- Special-register numbers: [registers.html](https://mmix.cs.hm.edu/doc/registers.html).

Where this file and the code disagree, the code wins for “implemented” and `mmix-doc` wins for “specified.”

## Baseline already in the tree

These are done. The plans must keep `sbcl --script tests/run-tests.lisp` green (182 checks) and must keep `make-vm` usable as a user-mode interpreter.

- All 256 opcode bytes are named in `src/decode.lisp`.
- Integer arithmetic, shifts, compares, bitwise ops, wyde immediates, conditional sets, branches (including backward and probable forms), `JMP`/`GETA`/`GO`/`PUSHJ`/`PUSHGO`/`POP`, tetra and immediate loads and stores, `LDHT`/`STHT`/`STCO`/`CSWAP`/`MOR`/`MXOR`.
- The `rL`/`rG` window, a Lisp register stack, and `rO`/`rS` kept consistent with `Stack_Segment + 8*tau`.
- `GET`/`PUT`/`PUTI` with the user-mode restrictions, including a nonzero `Y` field as an illegal instruction. `rA` event and enable bits. `TRIP` and `RESUME 0` with the §35 image and ropcodes 0–2 (plan 02).
- `SAVE` and `UNSAVE` of the §43 register image (plan 03). The instruction runs to completion inside one `step-vm`.
- `rN`, `rI`, `rU`, and `rF` (plan 04). `rN` is frozen at creation. `rI` and `rU` advance once per retired instruction. A refused page is stored in `rF`. `PUT` of these registers stays ignored. `rQ` bit 6 does not trap yet.
- Four segments, sparse 4096-byte grow-on-touch chunks, a page budget (`:memory-size`, default `#x2000000`). Those chunks are an allocator granule. They are not architectural pages (`2^s` with `s ≥ 13`).
- MMIX-SIM `TRAP` services Y = 0…10, intercepted in Lisp. Handles 0–2 are StdIn, StdOut, StdErr. Legacy putchar is opt-in.
- S-expression assembler, an MMIXAL subset (`assemble-mms`, `load-mms`, `write-mmo`), `.mmo` loader, breakpoints, `step-vm` / `run-vm` / `continue-vm`, dumps.

`vm-cycles` counts one retirement. `vm-pipe-cycles` counts one `step-cycle` when `:pipeline t` is set, and stays 0 on the default VM. `vm-mems` counts loads and stores, including operations §50 leaves out of μ. `vm-oops` and `vm-mem-cost` are the §50 υ and μ totals.

## Catalog

| Plan | Gap | Current | Full target |
|------|-----|---------|-------------|
| [01](plans/01-floating-point.md) | Floating point | Opcodes execute in `src/float/`. Enabled exceptions use the plan 02 trip image | Same arithmetic |
| [02](plans/02-trips-and-resume.md) | Trips and `RESUME 0` | Implemented. §35 image, event bit clear on the trip that is taken, ropcodes 0–2 | §35 and §38: negative `rX`, `$255 ← rJ`, ropcodes 0–2 |
| [03](plans/03-save-unsave.md) | `SAVE` / `UNSAVE` | Implemented. §43 image in one step; `POP` after `SAVE` faults | Interruptible spill once traps exist |
| [04](plans/04-machine-specials.md) | `rC` `rF` `rI` `rN` `rU` | Implemented. `rN` frozen, `rI` sets `rQ` bit 6, `rU` counts retired opcodes, `rF` records a refused page. `rC` is consulted on a stack spill when virtual memory is on | Interval delivery through `rTT` is plan 05 |
| [05](plans/05-kernel-traps.md) | Forced and dynamic traps | Implemented behind `:kernel`. Default `make-vm` still uses Lisp `exec-trap`, faults on bit 63, and ignores privileged `PUT` | `rT` / `rTT`, `rK`/`rQ`, `rwxnkbsp`, `RESUME 1`, kernel ROM for MMIX-SIM |
| [06](plans/06-virtual-memory.md) | `rV` translation | Implemented behind `:virtual-memory` (requires `:kernel`). Default `make-vm` keeps the identity map and `LDVTS` returns 0 | Same walk; line caches landed in plan 07 |
| [07](plans/07-cache-and-sync.md) | Caches and `SYNC` | Implemented behind `:caches`. Default `make-vm` still stores straight to memory. `SYNC` 0–3 records a fence tag. With the pipe and caches, M uses `accesstime` for a hit and a miss alike | A split hit/miss delay and a write buffer |
| [08](plans/08-timing-costs.md) | μ and υ | Implemented. `vm-oops` and `vm-mem-cost` follow §50, including mispredicted branches. `vm-cycles`, `vm-mems`, and `rI` keep their old meanings. `:pipeline t` adds `vm-pipe-cycles` | The §50 totals stay available beside the pipe |
| [09](plans/09-mmixal.md) | MMIXAL | Implemented. `.mms` text through `assemble-mms` / `load-mms` / `write-mmo`: `LOC`, `IS`, `GREG`, `PREFIX`, `LOCAL`, data, expressions, local labels, `BSPEC` | The `mmixal` macro language |
| [10](plans/10-simulator-session.md) | MMIX-SIM session | Implemented. `:argv` enters through `UNSAVE` with `$0` = argc, `$1` = argv, and `rL` = 2. Text modes translate newlines. `sim-command` reads one line. `:profile t` counts retired tetras. `s` prints `pipe=` | Same session |
| [11](plans/11-pipeline.md) | Pipeline | Implemented behind `:pipeline`. F–D–X–M–W, X scoreboard, M/W bypass into D, probable branches predict taken. Default `make-vm` still retires one instruction before the next fetch | No reorder buffer and no speculative store. Each core can carry this pipe |
| [12](plans/12-multicore.md) | Several processors | Implemented. `make-machine` shares physical memory. `CSWAP` locks the octa. `SYNC` 5 and 7 are per core. IPI is `rQ` bit 1 at physical `2^48+8` | No silent cache invalidation and no operating system |

Dependency order is in the [roadmap](plans/00-roadmap.md). Plans 01, 02, 03, 08, and 09 can start from today’s tree. Plans 05–07, 11, and 12 stack.

## Opcodes that still fault

`execute` in `src/ops.lisp` sends these to `unimplemented`, which signals `mmix-fault`. `step-vm` stores the reason in `vm-fault` and halts. `run-vm` does not resignal it as a Lisp error.

| Bytes | Names | Fault string |
|-------|--------|----------------|
| `#xF9` with `Z ≠ 0` | `RESUME 1` on the default VM | "RESUME with a nonzero XYZ is not implemented" |

Everything else has a handler. Several handlers are the functional single-processor approximation of an instruction whose real effect is a cache, a pipe drain, a translation cache, or a kernel entry. Those are gaps of meaning, listed below, and they are not missing names in `*op-name*`.

### Floating point (§21–28, plan 01)

The arithmetic is in `src/float/`. Registers hold binary64 patterns, `LDSF`/`STSF` widen and narrow binary32, and `rA` bits 17–16 select the rounding mode. An enabled exception uses the plan 02 trip: the bit that trips stays clear, `$255` is loaded from `rJ`, and `rX` has bit 63 set. The handler is the earliest enabled bit of `D V W I O U Z X`.

### `SAVE` / `UNSAVE` (§43, plan 03)

Landed as a complete image inside one `step-vm`. `SAVE $X,0` pushes locals as `push-frame` with `X ≥ rG` would, sets `rL ← 0`, pushes `$G`…`$255`, then `rB rD rE rH rJ rM rR rP rW rX rY rZ`, then one octa packing `rG` in the top byte and `rA` in the low tetra. `$X` (a global) receives the address of that top octa. Afterwards `rO = rS`. `POP` faults because the top octa is the header, not a return hole.

`UNSAVE 0,$Z` restores that image from `vm-stack` when `$Z` is the current top, and from memory when the image was moved. A second `UNSAVE` of the same image is not reliable. Both instructions are interruptible in the architecture; the phase counter in `rX` is the plan 05 hook and is not written yet. The official loader starts a process by `UNSAVE` of a fabricated image (MMIX-SIM §37). `load-mmo` with `:argv` builds that image and `UNSAVE`s it. A load without `:argv` still applies `lop_post` directly and sets `PC` from `Main`.

### Trips (§35, plan 02)

Landed. `do-trip` writes the §35 image: bit 63 of `rX` set, `rB ←` the old `$255`, `$255 ← rJ`, `rY`/`rZ` from the operands, `rW ← PC+4`. An enabled exception leaves its event bit clear. When several enables fire, the earliest bit of `D V W I O U Z X` trips and the other bits are recorded. A negative `PC` records every bit and does not trip. Store trips put the virtual address in `rY` and the octa that would have been stored in `rZ`.

`RESUME 0` returns to `rW` when `rX` is negative. Otherwise it inserts the low tetra under ropcodes 0–2. On a kernel VM, `RESUME 1` uses the trap bank and accepts ropcode 3. The default VM still rejects a nonzero `Z`. `GET` and `PUT` with a nonzero `Y` field are illegal instructions (a halt on the default VM, the `b` bit on a kernel VM).

## Kernel, traps, and specials that stay zero

### Forced traps (§36, plan 05)

An architectural `TRAP` clears `rK`, saves `rBB`, `rWW`, `rXX`, `rYY`, `rZZ`, and jumps to `rT`. `XYZ = 0` terminates the process. `XYZ = 1` asks the operating system for the default trip action. MMIX-SIM defines Y = 1…10 as file services when X = 0.

Default `make-vm` still performs those services in Lisp (`exec-trap`) and does not write `rT` or `rK`. `:kernel t` takes the forced-trap image and jumps to the ROM at `#x8000000100000000`. The ROM’s first instruction is `SWYM` `#x485354`, the host call, and only a negative PC on a kernel VM dispatches it. Halt, the trip report, and an unsupported `TRAP` stop there. A file service returns through guest `PUT rBB,$255`, an all-ones `$255`, and `RESUME 1`, so `$255` is the service result and `rK` is all ones again.

`RESUME 1` from a negative address uses `rWW`/`rXX`/`rYY`/`rZZ`. Ropcodes 0 and 2 match plan 02. Ropcode 3 stores the page-table pair `(rYY, rZZ)` on the VM (`:inst` when the tetra’s opcode is `SWYM`, otherwise `:data`) for plan 06. The same `RESUME 1` from a nonnegative address sets `k` and does not resume. User mode still faults with "RESUME with a nonzero XYZ is not implemented".

Software emulation of an opcode is a forced trap whose `rXX` high tetra is `#x02000000`. This plan does not raise that encoding. A translation miss (`#x03000000`, ropcode 3) is stored and not applied until plan 06.

### Dynamic traps (§37, plan 05)

`rQ` and `rK` are 64 bits:

```
24 low-priority I/O | 8 program | 24 high-priority I/O | 8 machine
```

The program byte is `rwxnkbsp`: read, write, execute, negative address, kernel-privileged, bad instruction, security, privileged address. When `rQ ∧ rK ≠ 0` the machine takes a precise trap through `rTT`, using the same bootstrap registers as a forced trap. An instruction that traps with `x`, `k`, or `b` does nothing. A load that traps with `r` or `n` yields 0. A store that traps with any program bit stores nothing.

A security violation (`s`) occurs when an instruction at a nonnegative address runs while any `rwxnkbsp` bit of `rK` is clear. The operating system is the only code that runs with interrupts suppressed, because a `TRAP` clears `rK` and only `RESUME 1` (from a negative address) reloads it from `$255`.

On the default VM, bit 63 of an address signals `mmix-fault` and halts, and `PUT` of a privileged register returns without writing (`privileged-special-p`). A kernel VM records program bits in `rQ` and traps through `rTT` when `rQ ∧ rK ≠ 0`. `x`, `k`, and `b` suppress the instruction. A load that raises `n` yields 0. A store that raises `n` writes nothing. `PUT` of `rN`, `rO`, or `rS` sets `b`. `PUT` of `rC rI rK rQ rT rU rV rTT` from a nonnegative PC sets `k` while `rK`’s `k` bit is set; the same `PUT` from a negative PC writes, and `PUT rQ` keeps any bit that came on since the last `GET rQ`. A nonnegative PC whose `rK` is missing any `rwxnkbsp` bit sets `s` in both `rQ` and `rK`. `p` is recorded for an instruction fetched from a negative address and cleared when `RESUME 1` returns to a nonnegative `rWW`. `SYNC` with XYZ ≥ 4 sets `k` from a nonnegative PC while `rK`'s `k` bit is set, and the cache operation does not run. Otherwise XYZ = 6 drops both translation caches, and XYZ 0–3 records the fence tag from plan 07.

### Machine specials (§40–42, §45, §48, plan 04)

| Register | Specified role | Today |
|----------|----------------|-------|
| `rN` | Version in the high three bytes, Unix time of this instance in the low five. Frozen | `#x010000` and the creation time. `PUT` does not change it |
| `rI` | Decrements; at 0 it requests the interval interrupt (bit 6 of `rQ`, the next-to-leftmost bit of the machine byte) | Counts retired instructions. The 1→0 step sets `rQ` bit 6. No trap yet |
| `rU` | Usage pattern, mask, and 47-bit count of retired opcodes that match | Counts after each retirement. Bit 47 is the negative-address flag |
| `rC` | Physical continuation page, PTE-shaped, used when a register-stack spill would fault | Consulted when virtual memory is on and the stack page lacks `pw`. Stored and unread on the default VM |
| `rF` | Physical address of a memory fault (parity and similar), often unrelated to `rW` | Page-budget failure stores the refused page base |
| `rK` | Interrupt mask. Cleared by `TRAP`. User programs need it all-ones to avoid an `s` trap | 0 and ignored on the default VM. `:kernel t` starts at all ones and clears it on trap entry |
| `rQ` | Interrupt requests | Bit 6 can be set by `rI`. Default `PUT` is ignored. A kernel VM traps through `rTT` when `rQ ∧ rK ≠ 0` |
| `rT`, `rTT` | Forced-trap and dynamic-trap entry | 0 on the default VM. `:kernel t` sets both to the ROM entry |
| `rV` | Page-table root, page size, address-space number, software-translation flag | 0 on the default VM. `:virtual-memory t` walks `b1…b4`, `s`, `r`, `n`, and `f` |

The local-register ring in §42 (256, 512, or 1024 locals, pointers α, β, γ derived from `rO`, `rS`, and `rL`) is an implementation of the same stack the Lisp vector already exposes to `PUSH`/`POP`. It becomes observable when a spill or a `SAVE` is interrupted, and when `rS` walks into a page the process cannot write. That behavior belongs with plans 03, 04, and 06, not with a second register file hidden beside a correct `POP`.

## Virtual memory (§44–47, plan 06)

Implemented in `src/translate.lisp` behind `:virtual-memory t`, which requires `:kernel t`. Default `make-vm` keeps the identity map of the four segments, faults on bit 63, and returns 0 from `LDVTS`.

Nonnegative virtual addresses sit in four `2^61`-byte segments (text, data, pool, stack). The machine maps each through φ. Negative virtual addresses are privileged and map by clearing bit 63: φ(A) = A ∧ `#x7fffffffffffffff`. Physical addresses `≥ 2^48` are memory-mapped I/O and are never cached.

`rV` is `b1 b2 b3 b4 s r n f` (4+4+4+4+8+27+10+3 bits). Page size is `2^s` with `13 ≤ s ≤ 48`. `f = 0` translates in hardware. `f = 1` forces a trap so software can translate; `b1`…`b4` and `r` are then ignored by the hardware. `f > 1` is a protection failure.

A page-table entry holds a physical page number, an address-space number `n` that must match `rV`, and protection `pr pw px`. A page-table pointer is a negative octa pointing at the next level. The first 1024 pages of a segment can sit in the root; larger page numbers walk auxiliary tables. `n` mismatch or a missing permission is a protection fault (`r`, `w`, or `x` in `rQ`).

A translation cache remembers recent pages, separately for instructions and data. `LDVTS` looks up a key, optionally replaces the protection nybble, and returns 0, 1, 2, or 3 according to which cache held the key. `SYNC` with `XYZ = 6` drops those caches.

With the flag on, that walk, those caches, the `f = 1` trap (`rXX` high tetra `#x03000000`), and ropcode 3’s insert of `rZZ` are live. A physical result at or above `2^48` calls `vm-mmio` and is not cached. A register-stack spill onto a page without `pw` writes through `rC` and then raises bit 31 of `rQ`. The 4096-byte vectors in `vm-memory` are the physical backing store. Line caches live behind `:caches t` (plan 07).

## Caches, ordering, and one-processor `SYNC` (§30–31, plan 07)

On a machine with a write buffer or a write-back data cache:

- `PRELD` / `PREGO` / `PREST` bring a span of `X+1` bytes into the appropriate cache.
- `SYNCD` from a nonnegative address writes that span back. From a negative address it also evicts the span.
- `SYNCID` from a nonnegative address makes the span match what the instruction cache will fetch. From a negative address it discards the span, including dirty lines.
- `LDUNC` / `STUNC` bypass the cache. `STCO` and ordinary stores may sit in a write buffer until a drain.

`SYNC` on one processor:

| XYZ | Effect |
|-----|--------|
| 0 | Stall until earlier instructions have finished |
| 1 | Earlier stores complete before later stores |
| 2 | Earlier loads complete before later loads |
| 3 | Earlier memory operations complete before later ones |
| 4 | Power-save until a wake-up. Privileged |
| 5 | Clean data caches into memory. Privileged |
| 6 | Drop translation caches. Privileged |
| 7 | Drop instruction and data caches, discarding dirty data. Privileged |
| > 7 | Illegal instruction |

`XYZ ≥ 4` from a nonnegative PC raises `k` when that bit of `rK` is set, and the cache operation does not run. With `:caches t`, XYZ 0–3 records `:all`, `:store`, `:load`, or `:memory` until the next load or store retires. XYZ 4 sleeps the core until `wake-core` or a bit in `rQ`. XYZ 5 writes dirty data back. XYZ 6 drops the translation caches. XYZ 7 drops the instruction and data caches. A nonnegative `SYNCD` writes the dirty span back; a negative address also drops it. A nonnegative `SYNCID` drops the instruction-cache span and writebacks data; a negative address drops every cache and leaves memory unchanged. `LDUNC` reads memory without allocating. `STUNC` writes memory and drops the data line. The default VM, with caches off, still treats `LDUNC` as `LDOU`, `STUNC` as `STOU`, and `PRE*`/`SYNCD`/`SYNCID` as operations that do not change memory.

`CSWAP` already updates one octa and `rP` inside a single `step-vm`. It is atomic only because nothing else runs. Plan 12 makes that atomic across processors.

## Time (§50, plans 08 and 11)

§50 assigns fixed costs so a student can check a program by hand:

| Operation | Cost |
|-----------|------|
| Add, subtract, compare, logic, shift, `SET`, `GET`, `PUT`, `SYNC`, `SWYM`, wyde ops, conditional set, relative jump | 1υ |
| Correctly predicted branch | 1υ |
| Mispredicted branch, `POP`, `GO` | 3υ |
| Integer multiply | 10υ |
| Integer divide | 60υ |
| `TRAP`, `TRIP`, `RESUME` | 5υ |
| Most floating-point ops | 4υ; `FCMP`/`FEQL`/`FUN` are 1υ; `FDIV`/`FSQRT` are 40υ |
| Load or store | μ + υ, except the holes `#x98`–`#x9F` and `#xB8`–`#xBF` |
| `CSWAP` | 2μ + 2υ |
| `SAVE`, `UNSAVE` | 20μ + υ |

Prediction in that table: ordinary branches predict not taken, probable branches (`PB*`) predict taken. `charge` applies that table when an instruction retires, on the interpreter and on the pipe. `LDSF`/`STSF` cost 4υ and 1μ. `PUSHGO` costs 3υ and no μ. `vm-cycles` and `vm-mems` stay beside `vm-oops` and `vm-mem-cost`. `:pipeline t` counts `vm-pipe-cycles` as well, and `s` prints that count.

`src/pipe.lisp` is one processor of stages F, D, X, M, and W. X uses the §50 unit times: add 1, multiply 10, divide 60, float add 4, float multiply 4, float divide and square root 40. `:cache-config` can set `add`, `multiply`, `divide`, `fadd`, `fmul`, and `fdiv` lower. A memory operation spends `accesstime` in M when caches are on and one cycle otherwise. A destination is busy while its writer occupies X. M and W forward to D in that same cycle, so a load-use costs one extra pipeline cycle. Stores commit in `execute` at W, when the instruction is oldest. Each core of a machine carries its own copy of this pipe. The pipe does not model a reorder buffer or a different delay for a cache hit and a cache miss.

## Several processors (§31, plan 12)

Landed. The architecture’s multiprocessor rules are `CSWAP` and `SYNC`. There is no specified core-count register, no specified inter-processor interrupt opcode, and no specified cache-coherence protocol. MMMIX states that multiprocessing is outside that simulator. The choices below are this repository’s.

`make-machine` returns a machine whose cores share one physical page hash, one page budget, one MMIO hook, and one `CSWAP` lock table. `make-vm` is that machine with one core; the caller still sees a `vm`. Each core has its own general registers, special registers, `PC`, `rV`, translation caches, data cache, instruction cache, pipeline, `rQ`, and `rK`.

`run-machine` retires one instruction from core 0, then core 1, and so on. A halted core is skipped. An asleep core is skipped while `rQ` is zero. `:max-cycles` is the sum of `vm-cycles` deltas. When a core has a pipe, `step-core` advances it until the next instruction retires. The functional scheduler does not require `:pipeline t`.

`CSWAP` holds the target physical octa across the compare and the store. `SYNC` XYZ 0–3 records a fence tag on the core that executes it. XYZ 5 writes that core’s dirty lines back. XYZ 7 drops that core’s caches and leaves another core’s dirty line in place. A store that sits only in a write-back cache is invisible to another core until `SYNC` 5, `SYNCD`, or `STUNC`. There is no silent invalidation.

Physical `#x1000000000008` (`2^48 + 8`) is the inter-processor interrupt register. A store whose low byte is core id `j` sets bit 1 of that core’s `rQ`. A store of 255 wakes every core and sets no `rQ` bit. Delivery is the plan 05 dynamic trap. Bit 6 of `rQ` remains the interval timer. Bit 0 remains the power-failure bit.

## Software around the machine

### MMIXAL (plan 09)

`src/mmixal.lisp` reads `.mms` text. `assemble-mms` returns the same segment list as `assemble`, plus the `GREG` allocation. `load-mms` installs it and sets `rG`. `write-mmo` writes those bytes as `.mmo`. `load-mmo` still loads an object file produced elsewhere.

Accepted: `LOC`, `IS`, `GREG` from 254 downward, `PREFIX`, `LOCAL`, `BYTE`/`WYDE`/`TETRA`/`OCTA`, strings, expressions, and local labels `1H`/`1B`/`1F` through `9H`. `BSPEC`…`ESPEC` tetras stay out of the executable image. The `mmixal` macro language is still absent. `src/asm.lisp` remains the s-expression assembler and is the encoder both paths use.

### MMIX-SIM session (plan 10)

Landed in `src/sim.lisp`, with newline translation in `src/trap.lisp`.

- **Startup image.** `:argv` writes the program name and the arguments into `Pool_Segment`, then `UNSAVE`s a §43 image so `$0` is `argc`, `$1` is `Pool_Segment+8`, and `rL` is 2. `M8[Pool_Segment]` is the first free pool octa. A kernel VM executes the `UNSAVE $255` appended to the ROM and then clears the `p` bit. The default VM calls `unsave-context`. Omitting `:argv` leaves the previous loader.
- **Text files.** Modes 0 and 1 are character streams. The guest newline is `#x0A` (wyde `#x000A`). A host newline becomes `#x0A` on read, and `#x0A` is written as the host newline. Modes 2–4 stay raw.
- **Interactive commands.** `sim-command` reads one line: step, `c`, `q`, `s`, examine and assign with `!` `.` `#` `"`, `+`, `@`, trace `t`/`u`, breakpoints `b[rwx]`, segment bases `T`/`D`/`P`/`S`, `B`, `i`, and `h`. A traced tetra is printed when it is fetched, including during `continue-vm`. Marginal registers reject a nonzero assignment. Specials go through `PUT`.
- **Profile and the statistics line.** `:profile t` adds 1 to a hash keyed by the aligned PC on each retire. `q` prints the nonzero rows, with the `vm-lines` note when one exists. `s` prints `PC`, retired instructions, μ, and υ.

`SWYM` remains a no-op. Its XYZ fields do not call the command reader.

## What the plans deliberately leave alone

- The opcode map, the integer results, the register window, and the `.mmo` XOR loader. Those match the chart and stay.
- Version-1.0.0 page-table layout. Later proposals that replace `b1`…`b4` are not adopted.
- A second, incompatible putchar `TRAP`. `Y = 1` remains `Fopen`. `:legacy-putchar` stays opt-in.
- Building a multi-user operating system. The kernel ROM in plan 05 is the MMIX-SIM service set plus the trap entry the architecture requires.
