# cl-mmix vs a full MMIX machine

This document is the gap between the sources described in [IMPLEMENTATION.md](IMPLEMENTATION.md) (ASDF system `cl-mmix` 0.9.0) and a complete MMIX. It replaces the older write-up, which compared an early MVP (flat registers, about 64 opcodes, a private putchar `TRAP`) with a user-mode practice target. That user-mode target is what the tree implements now. The paragraphs below describe what is still missing after it.

The work that closes each gap is a separate plan under [plans/](plans/00-roadmap.md).

Analysis only. This file does not change the ISA.

## What “full” means

Three layers, all in scope:

1. **The architecture** in Donald Knuth’s *MMIX: A RISC Computer for the New Millennium* (`mmix-doc`, version 1.0.0). Every opcode has its specified result, `rA` event, and trip. Special registers do what §39–43 say. Trips, forced traps, and dynamic traps follow §32–38. Virtual addresses follow §44–47. `SAVE`/`UNSAVE` follow §43. Running time can be reported in μ and υ as in §50.
2. **The MMIXware simulators.** `mmix` is the user-mode functional simulator (MMIX-SIM): MMIX-SIM `TRAP` services, command-line arguments in `Pool_Segment`, an interactive session, and a startup `UNSAVE`. `mmmix` is the configurable pipeline (fetch, decode, execute, memory, write-back, caches, branch prediction). Its own introduction leaves out multiprocessing and the low-level details of memory-mapped I/O.
3. **Several processors on one memory.** `mmix-doc` §31 says MMIX is designed for that case. `CSWAP` is the atomic primitive. `SYNC` is the ordering and cache-maintenance instruction. Neither shipped simulator runs more than one processor. A full machine in this repository includes a shared-memory multiprocessor, with the coherence protocol and the inter-processor interrupt bit chosen here, because the architecture leaves both to the implementation.

Out of scope, and absent from the plans: proposals that change version 1.0.0 (a different `rV` layout, an `rKK` register, virtualization of negative addresses). Also out of scope: a general-purpose operating system beyond a kernel ROM that implements the MMIX-SIM services and the page-fault path. The hardware plans leave room for that ROM. They do not include a Unix.

## Sources

Current behavior: [IMPLEMENTATION.md](IMPLEMENTATION.md), then `src/machine.lisp`, `src/decode.lisp`, `src/ops.lisp`, `src/trap.lisp`, `src/asm.lisp`, `src/mmo.lisp`, `src/api.lisp`, `tests/tests.lisp`.

Specification:

- [mmix-doc](https://mmix.cs.hm.edu/doc/mmix-doc.pdf) and the [opcode chart](https://cs.stanford.edu/~knuth/mmop.html). Section numbers below are that document’s.
- [MMIX-SIM](https://mmix.cs.hm.edu/doc/mmix-sim.pdf), the user-mode simulator and its interactive commands.
- [MMMIX](https://mmix.cs.hm.edu/doc/mmmix.pdf), [mmix-pipe](https://mmix.cs.hm.edu/doc/mmix-pipe.pdf), and [mmix-config](https://mmix.cs.hm.edu/doc/mmix-config.pdf) for the pipeline and caches.
- Special-register numbers: [registers.html](https://mmix.cs.hm.edu/doc/registers.html).

Where this file and the code disagree, the code wins for “implemented” and `mmix-doc` wins for “specified.”

## Baseline already in the tree

These are done. The plans must keep `sbcl --script tests/run-tests.lisp` green (50 checks) and must keep `make-vm` usable as a user-mode interpreter.

- All 256 opcode bytes are named in `src/decode.lisp`.
- Integer arithmetic, shifts, compares, bitwise ops, wyde immediates, conditional sets, branches (including backward and probable forms), `JMP`/`GETA`/`GO`/`PUSHJ`/`PUSHGO`/`POP`, tetra and immediate loads and stores, `LDHT`/`STHT`/`STCO`/`CSWAP`/`MOR`/`MXOR`.
- The `rL`/`rG` window, a Lisp register stack, and `rO`/`rS` kept consistent with `Stack_Segment + 8*tau`.
- `GET`/`PUT`/`PUTI` with the user-mode restrictions. `rA` event and enable bits. `TRIP` and `RESUME` with `XYZ = 0`, in a simplified form (see plan 02).
- Four segments, sparse 4096-byte grow-on-touch chunks, a page budget (`:memory-size`, default `#x2000000`). Those chunks are an allocator granule. They are not architectural pages (`2^s` with `s ≥ 13`).
- MMIX-SIM `TRAP` services Y = 0…10, intercepted in Lisp. Handles 0–2 are StdIn, StdOut, StdErr. Legacy putchar is opt-in.
- S-expression assembler, `.mmo` loader, breakpoints, `step-vm` / `run-vm` / `continue-vm`, dumps.

`vm-cycles` counts retired instructions. `vm-mems` counts loads and stores. That is a runaway guard and a rough mem count. It is not μ/υ, and it is not a pipeline.

## Catalog

| Plan | Gap | Current | Full target |
|------|-----|---------|-------------|
| [01](plans/01-floating-point.md) | Floating point | Opcodes execute in `src/float/`. Enabled exceptions still use today's trip image | Same arithmetic; plan 02 supplies the spec trip entry |
| [02](plans/02-trips-and-resume.md) | Trips and `RESUME 0` | Trip enters a vector; `rX` is the raw tetra; `RESUME` always jumps to `rW` | §35 and §38: negative `rX`, `$255 ← rJ`, ropcodes 0–2 |
| [03](plans/03-save-unsave.md) | `SAVE` / `UNSAVE` | Fault "SAVE/UNSAVE is not implemented" | §43 context image; interruptible spill once traps exist |
| [04](plans/04-machine-specials.md) | `rC` `rF` `rI` `rN` `rU` | Slots exist and stay 0; `PUT` ignores them | Interval timer, usage counter, frozen serial, failure address, continuation page |
| [05](plans/05-kernel-traps.md) | Forced and dynamic traps | `TRAP` is a Lisp syscall; bit 63 halts; privileged `PUT` is a silent no-op | `rT` / `rTT`, `rK`/`rQ`, `rwxnkbsp`, `RESUME 1`, kernel ROM for MMIX-SIM |
| [06](plans/06-virtual-memory.md) | `rV` translation | Flat segments; `LDVTS` returns 0 | PTEs, PTPs, protection, translation caches, MMIO at physical `≥ 2^48` |
| [07](plans/07-cache-and-sync.md) | Caches and `SYNC` | `PRE*`/`SYNC*`/`LDUNC`/`STUNC` are nops or plain octas | §30–31 on one processor: caches, prefetch, ordering, privileged `SYNC` |
| [08](plans/08-timing-costs.md) | μ and υ | One counter per instruction, one per load/store | §50 costs, including mispredicted branches |
| [09](plans/09-mmixal.md) | MMIXAL | S-expressions only; `.mmo` loads | `.mms` in process: `LOC`, `GREG`, `IS`, local labels, expressions, `PREFIX` |
| [10](plans/10-simulator-session.md) | MMIX-SIM session | Library API, raw file bytes, no argv | Text newlines, `argc`/`argv`, interactive commands, profile |
| [11](plans/11-pipeline.md) | Pipeline | One instruction retires before the next is fetched | Configurable F–D–X–M–W pipeline, one core, as in MMMIX |
| [12](plans/12-multicore.md) | Several processors | One `vm` struct | Shared physical memory, atomic `CSWAP`, `SYNC` fences, per-core `rQ` |

Dependency order is in the [roadmap](plans/00-roadmap.md). Plans 01, 02, 03, 08, and 09 can start from today’s tree. Plans 05–07, 11, and 12 stack.

## Opcodes that still fault

`execute` in `src/ops.lisp` sends these to `unimplemented`, which signals `mmix-fault`. `step-vm` stores the reason in `vm-fault` and halts. `run-vm` does not resignal it as a Lisp error.

| Bytes | Names | Fault string |
|-------|--------|----------------|
| `#xFA`–`#xFB` | `SAVE`/`UNSAVE` | "SAVE/UNSAVE is not implemented" |
| `#xF9` with `XYZ ≠ 0` | `RESUME 1` and any other Z | "RESUME with a nonzero XYZ is not implemented" |

Everything else has a handler. Several handlers are the functional single-processor approximation of an instruction whose real effect is a cache, a pipe drain, a translation cache, or a kernel entry. Those are gaps of meaning, listed below, and they are not missing names in `*op-name*`.

### Floating point (§21–28, plan 01)

The arithmetic is in `src/float/`. Registers hold binary64 patterns, `LDSF`/`STSF` widen and narrow binary32, and `rA` bits 17–16 select the rounding mode. What plan 02 still owes this path is the trip image: today every event bit stays set, `rX` is the raw instruction, and `$255` is not loaded from `rJ`. The handler that runs is already the highest enabled bit of `D V W I O U Z X`.

### `SAVE` / `UNSAVE` (§43, plan 03)

`SAVE $X,0` pushes locals as `PUSHGO` with `X = 255` would, sets `rL ← 0`, pushes `$G`…`$255`, then `rB rD rE rH rJ rM rR rP rW rX rY rZ`, then one octa packing `rG` in the top byte and `rA` in the low tetra. `$X` (a global) receives the address of that top octa. Afterwards `rO = rS` and the register stack is empty.

`UNSAVE 0,$Z` restores that image. It is destructive: a second `UNSAVE` of the same image is not reliable. Both instructions are interruptible in the architecture. The official loader starts a process by `UNSAVE` of a fabricated image (MMIX-SIM §37). Today `load-mmo` applies `lop_post` directly and sets `PC` from `Main`.

### Trips that do not match §35 (plan 02)

`do-trip` in `src/machine.lisp` writes `rB ← $255`, `rW ← PC+4`, `rX ←` the raw tetra, `rY`/`rZ` from the keyword arguments, and `PC ←` the vector. `signal-event` ORs the event bit into `rA` and then trips when the enable is set.

§35 differs in all of the following:

- A `TRIP` sets the high tetra of `rX` to `#x80000000`, sets `rY ← $Y` and `rZ ← $Z` (register contents, not the Y and Z fields), sets `rB ←` the old `$255`, and sets `$255 ← rJ`.
- An enabled arithmetic exception does the same kind of entry at `16, 32, …, 128`. The event bit records an exception that was **not** tripped. An enabled exception therefore trips with that event bit left clear.
- Instructions at negative virtual addresses do not take trip handlers.
- Store trips put the virtual address in `rY` and the full octa that would be stored in `rZ`.

`RESUME` with `XYZ = 0` (§38): if `rX` is negative, fetch at `rW`. If `rX` is nonnegative, insert the low tetra of `rX` as if it stood at `rW−4`, under the ropcode in the high byte of `rX`. Ropcode 0 inserts it. Ropcode 1 substitutes `rY` and `rZ` as the operands. Ropcode 2 sets `$X ← rZ` and raises the exception bits in bits 47–40 of `rX` (the third byte from the left). Today every `RESUME 0` jumps to `rW` and ignores `rX`.

`GET` and `PUT` require `Y = 0`. A nonzero `Y` is an illegal instruction. The handlers ignore `Y`.

## Kernel, traps, and specials that stay zero

### Forced traps (§36, plan 05)

An architectural `TRAP` clears `rK`, saves `rBB`, `rWW`, `rXX`, `rYY`, `rZZ`, and jumps to `rT`. `XYZ = 0` terminates the process. `XYZ = 1` asks the operating system for the default trip action. MMIX-SIM defines Y = 1…10 as file services when X = 0, and the current `exec-trap` performs those services in Lisp without ever writing `rT` or `rK`.

A full machine keeps both facts. `TRAP` enters the kernel. A ROM at a negative address implements Halt and the file services, then `RESUME 1`. Existing user programs still see `$255` results. Tests that expect an immediate halt on `TRAP 0,0,0` keep working because the ROM halts.

Software emulation of an opcode, and software page translation, are also forced traps. The high tetra of `rXX` is `#x02000000` for an emulated operation and `#x03000000` when the handler must supply a page-table entry. `RESUME 1` with ropcode 2 or 3 finishes the instruction. Neither encoding exists today.

### Dynamic traps (§37, plan 05)

`rQ` and `rK` are 64 bits:

```
24 low-priority I/O | 8 program | 24 high-priority I/O | 8 machine
```

The program byte is `rwxnkbsp`: read, write, execute, negative address, kernel-privileged, bad instruction, security, privileged address. When `rQ ∧ rK ≠ 0` the machine takes a precise trap through `rTT`, using the same bootstrap registers as a forced trap. An instruction that traps with `x`, `k`, or `b` does nothing. A load that traps with `r` or `n` yields 0. A store that traps with any program bit stores nothing.

A security violation (`s`) occurs when an instruction at a nonnegative address runs while any `rwxnkbsp` bit of `rK` is clear. The operating system is the only code that runs with interrupts suppressed, because a `TRAP` clears `rK` and only `RESUME 1` (from a negative address) reloads it from `$255`.

Today bit 63 of an address signals `mmix-fault` and halts. `PUT` of `rC`, `rN`, `rO`, `rS`, `rI`, `rT`, `rTT`, `rK`, `rQ`, `rU`, `rV`, `rF`, `rBB`, `rWW`, `rXX`, `rYY`, `rZZ` returns without writing and without an interrupt (`privileged-special-p` in `src/machine.lisp`). §43 distinguishes three outcomes: a successful write, an illegal-instruction interrupt (`b`), and a privileged-operation interrupt (`k`) for `rC rI rK rQ rT rU rV rTT` when the privilege bit of `rK` is set. `rN`, `rO`, and `rS` are never writable. `PUT rQ` cannot clear a bit that came on after the last `GET` of `rQ`.

### Machine specials (§40–42, §45, §48, plan 04)

| Register | Specified role | Today |
|----------|----------------|-------|
| `rN` | Version in the high three bytes, Unix time of this instance in the low five. Frozen | 0 |
| `rI` | Decrements; at 0 it requests the interval interrupt (bit 6 of `rQ`, the next-to-leftmost bit of the machine byte) | 0, no decrement |
| `rU` | Usage pattern, mask, and 47-bit count of retired opcodes that match | 0 |
| `rC` | Physical continuation page, PTE-shaped, used when a register-stack spill would fault | 0 |
| `rF` | Physical address of a memory fault (parity and similar), often unrelated to `rW` | 0 |
| `rK` | Interrupt mask. Cleared by `TRAP`. User programs need it all-ones to avoid an `s` trap | 0, ignored |
| `rQ` | Interrupt requests | 0 |
| `rT`, `rTT` | Forced-trap and dynamic-trap entry | 0 |
| `rV` | Page-table root, page size, address-space number, software-translation flag | 0 |

The local-register ring in §42 (256, 512, or 1024 locals, pointers α, β, γ derived from `rO`, `rS`, and `rL`) is an implementation of the same stack the Lisp vector already exposes to `PUSH`/`POP`. It becomes observable when a spill or a `SAVE` is interrupted, and when `rS` walks into a page the process cannot write. That behavior belongs with plans 03, 04, and 06, not with a second register file hidden beside a correct `POP`.

## Virtual memory (§44–47, plan 06)

Nonnegative virtual addresses sit in four `2^61`-byte segments (text, data, pool, stack). The machine maps each through φ. Negative virtual addresses are privileged and map by clearing bit 63: φ(A) = A ∧ `#x7fffffffffffffff`. Physical addresses `≥ 2^48` are memory-mapped I/O and are never cached.

`rV` is `b1 b2 b3 b4 s r n f` (4+4+4+4+8+27+10+3 bits). Page size is `2^s` with `13 ≤ s ≤ 48`. `f = 0` translates in hardware. `f = 1` forces a trap so software can translate; `b1`…`b4` and `r` are then ignored by the hardware. `f > 1` is a protection failure.

A page-table entry holds a physical page number, an address-space number `n` that must match `rV`, and protection `pr pw px`. A page-table pointer is a negative octa pointing at the next level. The first 1024 pages of a segment can sit in the root; larger page numbers walk auxiliary tables. `n` mismatch or a missing permission is a protection fault (`r`, `w`, or `x` in `rQ`).

A translation cache remembers recent pages, separately for instructions and data. `LDVTS` looks up a key, optionally replaces the protection nybble, and returns 0, 1, 2, or 3 according to which cache held the key. `SYNC` with `XYZ = 6` drops those caches. Today `LDVTS` writes 0 and allocates nothing.

The 4096-byte vectors in `vm-memory` can remain the physical backing store. They must stop being the virtual address space once `rV` is live. Default `make-vm` keeps today’s identity map of the four segments so the existing tests do not build page tables.

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

`XYZ ≥ 4` from a user address raises the privileged-instruction interrupt (`k`) unless that interrupt is disabled. Today every `SYNC`, `SYNCD`, `SYNCID`, `PRELD`, `PREGO`, and `PREST` retires as a no-op, and `LDUNC`/`STUNC` are `LDOU`/`STOU`.

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

Prediction in that table: ordinary branches predict not taken, probable branches (`PB*`) predict taken. `vm-cycles` and `vm-mems` do not match this table. Plan 08 adds the counters on the functional interpreter. Plan 11 replaces them, when a pipeline is enabled, with cycle counts from the pipe.

MMMIX’s pipeline has stages F, D, X, M, W, with X split into XF (add), XM (multiply), and XD (divide). A configuration file sets functional-unit latencies and up to five caches (instruction, data, secondary, and two translation caches): associativity, block size, write-back, write-allocate, access time, ports, replacement. `mmmix` simulates one processor. Plan 11 is that one processor. It does not grow a second core; plan 12 does.

## Several processors (§31, plan 12)

The architecture’s multiprocessor rules are `CSWAP` and `SYNC`. There is no specified core-count register, no specified inter-processor interrupt opcode, and no specified cache-coherence protocol. MMMIX states that multiprocessing is outside that simulator.

The full machine in this repository is still a multiprocessor, with these implementation choices written down in plan 12 so two cores have one meaning:

- Each core has its own general registers, special registers, `PC`, and (once plan 11 exists) pipeline.
- Physical memory is shared. Virtual memory is per core, because each core has its own `rV`.
- `CSWAP` locks the target octa for the duration of the compare and the possible store.
- `SYNC` XYZ = 0…3 is a fence on that core’s accesses to the shared memory. XYZ = 5…7 also maintain that core’s caches. A fence does not stall another core except through the shared-memory order the fence creates.
- One implementation-defined machine bit in `rQ` is the inter-processor interrupt. A core raises another core’s bit through a memory-mapped register at a physical address `≥ 2^48`. Device bits in the I/O fields of `rQ` stay available for a later device model.
- The functional scheduler runs cores by taking one retired instruction from each runnable core in turn. Lockstep pipelines are not required.

## Software around the machine

### MMIXAL (plan 09)

Students type `.mms`: `LOC`, `IS`, `GREG`, `PREFIX`, `LOCAL`, `BYTE`/`WYDE`/`TETRA`/`OCTA`, strings, expressions, and local labels `1H`/`1B`/`1F` through `9H`. `GREG` allocates globals from 254 downward and the object file’s postamble sets `rG`. `BSPEC`…`ESPEC` brackets special tetras the loader may skip.

`src/asm.lisp` assembles s-expressions into the same opcode bytes `mmixal` emits. It has no expression language, no local labels, and no `GREG`. `src/mmo.lisp` loads `mmixal` output: quote, loc, skip, fixups, file, line, spec (skipped), post, stab, end. That split is enough to run a book program that was assembled elsewhere. A full tree also accepts `.mms` directly.

### MMIX-SIM session (plan 10)

Still different from `mmix prog.mmo args…` and from the `mmix>` prompt:

- **Startup image.** `$0` is `argc`. `$1` points at the first argument pointer. The program name is argument 0. Strings and pointers live in `Pool_Segment`. `M[Pool_Segment]` is the first free pool octa. `rL` starts at 2. MMIX-SIM builds this by fabricating a stack and executing `UNSAVE`. `load-mmo` sets `PC` to `Main` and does not build that image.
- **Text files.** Modes 0 and 1 are C text streams (`"r"` / `"w"`). Newline inside the guest is the byte `#x0A` (wyde `#x000A`). Host text translation happens at the stream boundary. Modes 2–4 are binary. This tree opens every file as `(unsigned-byte 8)` and does not translate.
- **Interactive commands.** Step (empty line), `c`, `q`, `s`, dump and assign with `!` `.` `#` `"`, `+`, `@`, trace `t`/`u`, breakpoints `b[rwx]`, segment `T`/`D`/`P`/`S`, `B`, `i`, `h`. The Lisp API has `step-vm`, `continue-vm`, three breakpoint kinds, and hex dumps. It has no command reader, no floating or string dump, and no tracepoint separate from a breakpoint.
- **Profile and the statistics line.** MMIX-SIM can count executions per instruction and print mems and oops. `vm-lines` holds file and line from `lop_line`. Nothing increments a profile, and the exit report is `vm-cycles` plus `vm-mems`.

`SWYM` is specified as a no-op whose XYZ fields may signal a debugger. The functional interpreter correctly retires it as a no-op. A debugger hook on `SWYM` belongs to plan 10, not to a change in the opcode’s register effect.

## What the plans deliberately leave alone

- The opcode map, the integer results, the register window, and the `.mmo` XOR loader. Those match the chart and stay.
- Version-1.0.0 page-table layout. Later proposals that replace `b1`…`b4` are not adopted.
- A second, incompatible putchar `TRAP`. `Y = 1` remains `Fopen`. `:legacy-putchar` stays opt-in.
- Building a multi-user operating system. The kernel ROM in plan 05 is the MMIX-SIM service set plus the trap entry the architecture requires.
