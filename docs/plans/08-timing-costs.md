# Plan 08 — μ and υ costs

Status: implemented. `charge` in `src/ops.lisp` adds §50 υ to `vm-oops` and μ to `vm-mem-cost` when `execute` returns. `vm-cycles`, `vm-mems`, and `rI` keep their previous meanings. `LDSF`/`STSF` take 4υ and 1μ. `PUSHGO` takes 3υ and no μ, the same as `GO`.

Depends on nothing. Branch-prediction costs match the functional branches already in `src/ops.lisp`. Floating-point costs become real when [01](01-floating-point.md) retires those opcodes instead of faulting.

Spec: `mmix-doc` §50.

## Outcome

After `run-vm`, a program can read the §50 totals: mems (μ) and oops (υ). `vm-cycles` and `vm-mems` keep their current meanings so existing tests stay valid.

## Current behavior

`step-vm` increments `vm-cycles` once per fetch and `note-mem` increments `vm-mems` on a load or store (`src/ops.lisp`, `src/machine.lisp`). `GO` costs one cycle. A taken branch costs one cycle. `MUL` costs one cycle. There is no υ and no separate prediction penalty.

## Target behavior

Two new slots, `vm-oops` and `vm-mem-cost`.

| Retired operation | Added cost |
|-------------------|------------|
| Arithmetic other than multiply and divide, logic, shift, wyde, compare, conditional set, `GET`, `PUT`, `SWYM`, `SYNC`, relative `JMP`/`GETA`/`PUSHJ` | 1υ |
| Untaken ordinary branch, taken probable branch | 1υ |
| Taken ordinary branch, untaken probable branch, `POP`, `GO`/`GOI` | 3υ |
| `MUL`/`MULI`/`MULU`/`MULUI` | 10υ |
| `DIV`/`DIVI`/`DIVU`/`DIVUI` | 60υ |
| `TRAP`, `TRIP`, `RESUME` | 5υ |
| `FCMP`, `FEQL`, `FUN` | 1υ |
| `FDIV`, `FSQRT` | 40υ |
| Other floating-point opcodes, including `LDSF`/`STSF` | 4υ |
| Load or store whose opcode is outside `#x98`–`#x9F` and `#xB8`–`#xBF` | μ + υ, with μ counted in `vm-mem-cost` |
| `CSWAP` | 2μ + 2υ |
| `SAVE`, `UNSAVE` | 20μ + υ |
| `PRE*`, `SYNC`, `SYNCD`, `SYNCID`, `LDVTS`, `GO` | no μ. `GO` is 3υ and is not a load |

Prediction used for the branch rows: `BN`…`BEV` predict not taken, `PBN`…`PBEV` predict taken. The functional machine does not guess ahead of time. The cost is computed from the prediction and the actual outcome, which is what §50’s hand estimate does.

`vm-cycles` remains “instructions retired.” `vm-mems` remains “load/store operations,” including those §50 excludes from μ, so current tests that read `vm-mems` do not change. Document the difference in `dump-registers`, which prints oops and the §50 mem cost beside the old counters.

A faulting floating-point opcode, before plan 01, adds nothing because it does not retire.

## Design

`charge` in `src/ops.lisp`, called from `execute` with the opcode and, for branches, a taken flag. `step-vm` does not add the 1 itself; double-counting is the main risk, so delete any ad-hoc increment and keep `vm-cycles` where it is.

`rI` stays one tick per retired instruction (plan 04). A later revision may tick υ instead. This plan does not change `rI`.

## Tests

- Ten `ADDU`s cost 10υ and 0μ.
- A taken `BZ` that falls through the backward case costs 3υ. A taken `PBZ` of the same shape costs 1υ.
- `MUL` then `DIV` costs 70υ.
- `LDO` costs 1μ + 1υ. `GO` costs 3υ and 0μ.
- `CSWAP` costs 2μ + 2υ.
- `demo-sum-1-to-n` still returns 55. Its cycle count assertion, if any, still reads `vm-cycles`.

## Stays unchanged

`vm-cycles`, `vm-mems`, `:max-cycles`, and the halt behavior of `run-vm`.

## Follow-ons

Plan 11 reports pipeline cycles in a third slot and leaves these §50 totals available as the hand-estimate line. Plan 10 prints both in the statistics command.
