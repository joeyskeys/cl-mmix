# Plan 06 — Virtual memory

Status: implemented. `:virtual-memory t` on `make-vm` requires `:kernel t` and walks `rV` in `src/translate.lisp`. The default constructor keeps the identity map, faults on bit 63, and returns 0 from `LDVTS`.

Depends on [05](05-kernel-traps.md) for protection faults, `RESUME 1`, and ropcode 3. The continuation register’s format comes from [04](04-machine-specials.md).

Spec: `mmix-doc` §44–47.

## Outcome

A nonnegative virtual address is translated through `rV` and a page table in physical memory. A negative virtual address clears bit 63 and is privileged. `LDVTS` reports and edits the translation caches. Physical addresses at and above `2^48` are I/O and are not cached. Default `make-vm` still sees the four segments as it does today.

## Current behavior

`vm-memory` is a hash of 4096-byte pages keyed by a virtual page number (`src/machine.lisp`, `+page-size+` 4096). `ensure-page` charges `vm-mem-bytes` against `vm-mem-limit`. Bit 63 signals `mmix-fault`. `LDVTS` (`exec-mem` in `src/ops.lisp`) sets `$X ← 0`. `rV` is ignored. The 4096-byte chunk is an allocator granule, not the architectural page size `2^s`.

## Target behavior

`rV` fields, from the top:

| Width | Field | Meaning |
|-------|--------|---------|
| 4 | `b1` `b2` `b3` `b4` | Roots for the four segments. `b0 = 0`. Segment `i` has at most `1024^(b[i+1]−b[i])` pages, and none when `b[i] > b[i+1]` |
| 8 | `s` | Page size `2^s`, `13 ≤ s ≤ 48` |
| 27 | `r` | Root page index |
| 10 | `n` | Address-space number |
| 3 | `f` | 0 hardware translation, 1 software translation, anything else a protection failure |

PTE, one octa: ignored high bits, physical page number `a` in the `48−s` field, ignored `s−13` bits, a 10-bit `n` that must match `rV`, and `pr pw px`. PTP: sign bit 1, physical base, `n` matching `rV`. The walk is the one in §45 and the program in §47: the page number in radix 1024, root pages at physical `2^13 (r + b[i])`, auxiliary levels when higher digits are nonzero.

Translation:

- `A < 0`: physical `A ∧ #x7fffffffffffffff`. Allowed from a negative `PC`, or when the kernel mask permits. From a nonnegative `PC` this sets `n` in `rQ` and the access yields 0 on a load or is dropped on a store.
- `A ≥ 0` and `f = 0`: walk the table. Missing permission sets `r`, `w`, or `x`. `n` mismatch is a protection failure. `px` is checked on fetch, `pr` on load, `pw` on store.
- `f = 1`: forced trap, high tetra of `rXX` is `#x03000000`, `rYY` is the virtual address. The handler writes the PTE to `rZZ` and `RESUME 1` with ropcode 3. The machine inserts that translation into the instruction cache if the trapped opcode is `SWYM`, otherwise into the data cache.
- Physical result `≥ 2^48`: the access is I/O. It is not placed in a cache (plan 07). This plan delivers it to a hook, `vm-mmio`, defaulting to read 0 and ignore writes, and sets `rF` on an unmapped I/O address.

Translation caches: two sets of keys, instruction and data, in the §46 layout. `LDVTS` takes `$Y + Z` as a key. If the key is present, the low three bits of the sum replace `p`; `p = 0` removes the key. `$X` becomes 0, 1, 2, or 3 as §46 says. Changes sit in the cache structure immediately in the functional machine; plan 07’s `SYNC`/`SYNCD` is what a pipelined machine waits for. `SYNC` XYZ = 6 drops both caches (the opcode’s privilege check is plan 05; the drop is this plan).

Register-stack spill that would write a virtual page without `pw` uses `rC` as the physical continuation page (§45) until the next interruptible instruction, then raises the stack-overflow interrupt. The bit used for that interrupt is the leftmost high-priority I/O bit, recorded in the plan’s constant list, because §45 does not assign a number. One constant, one test.

Default `:virtual-memory nil` installs an identity map in the translator: the four segment bases pass through, bit 63 still faults, and `LDVTS` still returns 0. `:virtual-memory t` requires `:kernel t` and uses `rV`.

The 4096-byte hash becomes the **physical** memory. Architectural pages are `2^s` and may span several chunks. `mem-size` remains the physical budget.

## Design

`src/translate.lisp` with `translate`, `walk-pte`, `tc-lookup`, and `ldvts`. `mem-ref-u*` and `fetch` call `translate` when the flag is on. `fetch` asks for execute permission; loads ask for read; stores ask for write.

`:internal t` accesses, used by the `.mmo` loader and by `stack-push-octa`, pass the virtual address through the identity map so loading a program does not require a page table. The kernel ROM is fetched as a negative physical address.

A small builder `install-segment-pages` writes a one-level table for tests: `s = 13`, one segment, `n = 0`, `f = 0`, `b` values that give segment 0 a handful of pages.

## Tests

- Identity flag: the existing hello-world and page-budget tests pass unchanged.
- Hardware walk: a store to virtual page 0 of the data segment appears at the physical page named by the PTE, and a second virtual page with `pw = 0` sets the `w` bit and leaves memory unchanged.
- Fetch from a page with `px = 0` sets `x` and does not retire the instruction.
- Negative virtual address from `PC = #x100` sets `n`. The same address fetched while `PC` is negative reads physical memory.
- `f = 1` traps with `rXX` high tetra `#x03000000`. `RESUME 1` ropcode 3 then satisfies the load.
- `LDVTS` returns 2 after a data access to that page and 0 for a page that was never used. A following `LDVTS` with protection 0 makes the next access miss.
- An access whose physical address is `#x1000000000000` invokes `vm-mmio` and does not allocate a cache line.

## Stays unchanged

Alignment by masking low bits, applied to the virtual address before translation. Big-endian byte order. The page budget, counted in physical bytes.

## Follow-ons

Plan 07 caches the physical lines and honors `SYNCD`/`SYNCID` from negative versus nonnegative addresses. Plan 12 gives each core its own `rV` and its own translation caches over one physical memory.
