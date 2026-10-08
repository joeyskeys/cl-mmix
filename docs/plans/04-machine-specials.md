# Plan 04 — Machine specials

Depends on nothing for the counters and the frozen serial. Raising `rQ` has no effect until plan 05. The continuation page is consulted when plan 06’s protection faults exist; this plan stores `rC` in the architectural format.

Spec: `mmix-doc` §40 (`rI`, `rU`), §41 (`rN`), §45 (`rC`), §48 (`rF`).

## Outcome

`rN` identifies this instance. `rI` counts down and requests an interrupt at 0. `rU` counts retired opcodes selected by its pattern and mask. `rC` holds a continuation-page descriptor. `rF` holds a physical fault address when the memory system reports one.

## Current behavior

The 32 specials are a vector of zeros (`src/machine.lisp`). `PUT` ignores numbers 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 22, 7, and 28–31. Nothing reads `rI`, `rU`, `rN`, `rC`, or `rF`. `make-vm` does not stamp `rN`.

## Target behavior

`rN`, written once in `make-vm` and never again:

- Low five bytes: seconds since 1970-01-01 UTC at the time the VM was created.
- High three bytes: architecture version. Use `#x010000` for version 1.0.0, matching the “three most significant bytes are the version” rule in §41. Document the constant next to the assignment.

`PUT rN` does not change it.

`rI`:

- `step-vm` subtracts 1 when `rI` is nonzero, after the instruction retires.
- The transition from 1 to 0 sets bit 6 of `rQ`. The machine byte is bits 7–0. §40 puts the interval interrupt in the next-to-leftmost bit of that byte, which is also the seventh-least-significant bit of `rQ`.
- A `PUT` may store any value. The decrement uses the functional interpreter’s retired instructions. Plan 08 may later decrement by υ instead of by 1; until that plan, one retired instruction is one tick, and the test says so.

`rU` fields:

- `up` = bits 63–56, `um` = bits 55–48, `uc` = bits 47–0.
- After an instruction with opcode `op` retires, if `(logand op um) = up`, add 1 to `uc` modulo `2^47`. Bit 47 of `rU` is the kernel-counting flag: instructions at negative addresses count only when that bit is 1. On the user-mode path every instruction is nonnegative, so the flag does not matter yet.
- Examples from §40 that the tests should hit: `up = um = 0` counts everything; `up = POP` and `um = #xFF` counts completed `POP`s.

`rC` is stored as a PTE (plan 06). This plan accepts a `PUT` only on the kernel path. On the user-mode path `PUT rC` stays a silent ignore, consistent with today.

`rF` is read-only to `PUT`. The memory system writes it. The first writer is the page-budget failure in `ensure-page`: store the physical address that was refused. That is a stand-in for §48’s parity address until a real memory fault exists. Document it as the address of the failed physical access, not as `rW`.

## Design

`stamp-serial` and `note-usage` in `src/machine.lisp`. Call `note-usage` from `step-vm` next to the `vm-cycles` increment. Call the `rI` decrement there too, so a breakpoint that refuses to execute does not tick.

`special-name` already prints these registers. `dump-registers` should include `rN`, `rI`, and `rU` when they are nonzero.

## Tests

- A fresh VM has `rN` nonzero, stable across `PUT rN`, and stable across `reset-vm` without `:clear-registers`. `:clear-registers` restamps or preserves `rN`; pick preserve, and test it.
- `rI = 3` retires three instructions and sets `rQ` bit 6 on the third. `rQ` is readable with `GET` even though `PUT rQ` is ignored.
- `rU` with `up = um = 0` equals the number of retired instructions.
- `rU` with `um = #xFF` and `up = #xF8` counts only `POP`.
- Exceeding the page budget sets `rF` to the refused address and still halts with the current fault string.

## Stays unchanged

`PUT` of privileged registers on the default VM. `rO` and `rS` formulas. The 50 existing checks, aside from any test that assumed `rN` was zero. Search `tests/tests.lisp` for `rN` and special-register dumps before changing assertions.

## Follow-ons

Plan 05 delivers the interval bit through `rTT` when `rK` unmasks it. Plan 08 may redefine one `rI` tick as one υ. Plan 06 uses `rC` when a stack spill touches a page without write permission.
