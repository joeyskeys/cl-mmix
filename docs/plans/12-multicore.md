# Plan 12 — Multi-core

Depends on [05](05-kernel-traps.md), [06](06-virtual-memory.md), and [07](07-cache-and-sync.md). If [11](11-pipeline.md) has landed, each core carries its own pipe. The functional scheduler does not require the pipe.

Spec: `mmix-doc` §31. MMMIX’s introduction excludes multiprocessing; the choices below are this repository’s, written here so two cores have one meaning.

## Outcome

One machine holds N cores and one physical memory. `CSWAP` is atomic across cores. `SYNC` is a fence on the core that executes it. A core can raise an interrupt on another core. Each core has its own registers, `PC`, `rV`, caches, and translation caches.

## Current behavior

A `vm` struct is the whole machine (`src/machine.lisp`). Memory, registers, and `PC` are slots of that one struct. `CSWAP` is atomic because `step-vm` does not interleave. `SYNC` has no cross-core effect.

## Target behavior

`make-machine` returns a machine with `:cores N` (default 1) and a shared physical memory. `make-vm` remains the one-core constructor and returns a machine whose single core is what existing code already calls a VM. Slot accessors keep working on that one core.

Each core has:

- general registers, specials, `PC`, halt flag, local stack, `rV`, translation caches, data cache, instruction cache, pipeline state, `rQ`, and `rK`;
- its own `vm-cycles`, `vm-oops`, and fault slot.

Shared:

- the physical page hash and the page budget;
- the MMIO dispatcher;
- a lock table for octas under `CSWAP`.

Memory order on the functional scheduler (no pipeline, or a pipeline that only retires the oldest memory operation):

- The scheduler runs core 0’s next retired instruction, then core 1’s, and so on. A halted core is skipped.
- A store becomes visible to later retires of other cores when it retires, unless it sits in that core’s write-back cache. Another core’s load sees the dirty line only after `SYNCD`, `SYNC 5`, `STUNC`, or an ordinary store that missed and wrote through because caches are off.
- `SYNC` XYZ = 0 drains that core. XYZ = 1 and 3 make that core’s earlier stores visible before its later stores. XYZ = 2 and 3 make that core’s earlier loads satisfy before its later loads. They do not stall another core’s fetch.
- `CSWAP` holds the target physical octa across the compare and the store. The functional scheduler must not retire another core’s access to that octa in the middle. Implement this as a lock around the existing `CSWAP` body, not as a second copy of the instruction.
- `SYNC` XYZ = 6 and 7 affect only the executing core’s caches.

Inter-processor interrupt:

- Machine bit 1 of `rQ` (bit 1 of the machine byte) is the inter-processor interrupt. Bit 6 remains the interval timer (plan 04). Bit 0 remains available for the power-failure meaning §37 gives the rightmost machine bit.
- MMIO at physical `#x1000000000008` (`2^48 + 8`) is a 64-bit register. A negative virtual address reaches it by clearing bit 63, so the kernel uses `#x8001000000000008`. A store of core id `j` in the low byte sets bit 1 of core `j`’s `rQ`. A store of 255 wakes every core from plan 07’s power-save flag and sets no `rQ` bit.
- Delivery uses the dynamic trap of plan 05. No new opcode.

`run-machine` retires instructions until every core has halted, a breakpoint has fired on any core, or the sum of retired instructions reaches `:max-cycles`.

## Design

`src/machine.lisp` gains a `machine` struct: `cores` (vector of `vm`), `memory`, `mem-bytes`, `mem-limit`, `mmio`, `locks`. Move `vm-memory` and the budget onto the machine, and leave a slot on `vm` that points back at the machine so `mem-ref-u64` does not change its first argument in user code. A one-core `make-vm` allocates a private machine the caller never sees.

`step-core` is today’s `step-vm` body. `run-machine` loops over cores.

Cache coherence is write-back plus explicit `SYNCD` / `SYNC 5` / `STUNC`. There is no silent invalidation. Two cores that write the same octa without `CSWAP` or a fence have an undefined last writer, and the test states that by using `CSWAP` and `SYNC` rather than racing bare stores.

## Tests

- `:cores 1` matches `make-vm` on hello, the page budget, and a `CSWAP`.
- Two cores, caches off. Core 0 stores an octa and executes `SYNC 3`. Core 1, scheduled after that store retires, loads the octa and sees the new value.
- Two cores `CSWAP` the same octa, both expecting the original `rP` value. One `$X` becomes 1 and the other becomes 0. `rP` on the loser is the winner’s stored value.
- Core 0 stores to the IPI register with value 1. Core 1, with that bit unmasked in `rK` and a handler at `rTT`, enters the handler before its next user instruction.
- Core 0’s `SYNC 7` leaves core 1’s dirty line dirty.
- A data store on core 0 is invisible to core 1’s load while it remains only in core 0’s write-back cache, and visible after core 0’s `SYNC 5`.

## Stays unchanged

Single-core opcode results, `rV` on a core that never shares, and the user-mode default of one core with caches off and the kernel off.

## Done

This is the last plan in the [roadmap](00-roadmap.md). After it, the machine has the opcode set, the kernel entry, virtual memory, one-processor caches, a pipeline switch, and more than one processor on the memory §31 describes.
