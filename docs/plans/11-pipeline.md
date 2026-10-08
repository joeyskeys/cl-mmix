# Plan 11 — Pipeline

Depends on [01](01-floating-point.md), [02](02-trips-and-resume.md), [03](03-save-unsave.md), and [07](07-cache-and-sync.md), so every opcode the pipe can issue has a finished functional meaning and a cache.

Spec: [MMMIX](https://mmix.cs.hm.edu/doc/mmmix.pdf) and [mmix-pipe](https://mmix.cs.hm.edu/doc/mmix-pipe.pdf). One processor. Multiprocessing stays in plan 12.

## Outcome

With `:pipeline t`, instructions overlap across fetch, decode, execute, memory, and write-back. Functional results match `step-vm` with `:pipeline nil`. Cycle counts come from the pipe. Hazards stall. Probable branches predict taken.

## Current behavior

`step-vm` fetches, executes, and retires one instruction before the next fetch. `PB*` uses the same predicate as `B*` and has no prediction state (`src/ops.lisp`). Cache access times from plan 07 are stored and unused.

## Target behavior

Stages, as in the meta-simulator’s description:

- **F** fetches from the instruction cache into a fetch buffer.
- **D** decodes and reads registers, stalling on a register that a previous instruction will write and has not yet written.
- **X** executes. Integer add and logic use a 1-cycle unit. Multiply uses XM. Divide uses XD. Floating add uses XF. Floating multiply uses XM. Floating divide and square root use XD. Memory-address calculation happens here; the memory itself is stage M.
- **M** performs the load, store, or `CSWAP` through the data cache.
- **W** writes the general or special register.

Default latencies, overridable from the same configuration plist as plan 07: add 1, multiply 10, divide 60, float add 4, float multiply 4, float divide 40. These match §50 so a dependency-free stream is in the same ballpark as the hand estimate. A configuration may set them lower, which is the point of MMMIX.

Prediction:

- Ordinary branches predict not taken. Probable branches predict taken.
- A misprediction flushes F and D and costs the cycles those stages already spent, which on the default geometry is the 3υ of §50 when no other stall applies.
- `GO`, `PUSHGO`, `POP`, `JMP`, `TRAP`, `TRIP`, and `RESUME` are indirect or absolute and flush the same way.

Precise interrupts: an exception or a dynamic trap retires in program order. Later stages that belong to later instructions are discarded. `rW`, `rX`, `rY`, and `rZ` describe the faulting instruction, never a younger one. This is §34.

`SYNC` XYZ = 0 drains the pipe before the next instruction issues. XYZ = 1…3 constrain M: a store fence does not let a later store pass an earlier store. XYZ ≥ 4 still perform the plan 07 cache operations after the drain.

`:pipeline nil` is exactly today’s `step-vm`.

The pipe does not model a second core, a reorder buffer past the five stages, or speculative writes to memory. Stores enter the cache at M only when they are the oldest instruction.

## Design

`src/pipe.lisp`. A `pipe` struct holds the five stage slots, each either empty or an instruction record with its operands already captured at D. `step-cycle` advances every stage once. `run-vm` with the flag set calls `step-cycle` until halt, breakpoint, or `:max-cycles` counted in pipeline cycles.

Register bypass: W’s result is visible to D in the same cycle, matching a simple pipeline and avoiding a one-cycle load-use penalty beyond the M stage itself. Document that choice. A load-use dependency therefore costs one extra cycle, which a test should lock.

Breakpoints: an `:exec` breakpoint stops when the instruction is about to retire, not when it is fetched. That preserves `continue-vm`’s meaning of “the stopped instruction runs.”

`vm-pipe-cycles` is the new counter. `vm-oops` and `vm-mem-cost` still accumulate the §50 charges so the hand estimate remains available.

## Tests

- `:pipeline nil` and `:pipeline t` produce the same `$255`, the same memory, and the same halt on hello, on recursive factorial, and on a `DIV` by zero.
- Two independent `ADDU`s can be in X and D in the same cycle. A `ADDU` that reads the previous `ADDU`’s destination cannot.
- A load immediately followed by an add of the loaded register takes one more cycle than the same add from a register that was already live.
- A taken `BN` flushes the instruction that was fetched after it. A taken `PBN` does not.
- An enabled `V` trip reports `rW` as the instruction after the overflowing add, even if a younger add had entered D.
- `SYNC 0` between two stores reports a drain: the second store is not in M until the first has retired.

## Stays unchanged

Functional results, the opcode map, and the user-mode default of `:pipeline nil`.

## Follow-ons

Plan 12 duplicates the pipe per core. It does not share stages across cores.
