# Roadmap

The gap catalog is [../TAOCP-GAP-ANALYSIS.md](../TAOCP-GAP-ANALYSIS.md). The behavior of the current sources is [../IMPLEMENTATION.md](../IMPLEMENTATION.md). Each plan below is one change that can land on its own, leave `sbcl --script tests/run-tests.lisp` green, and leave `make-vm` as a user-mode interpreter until a later plan turns a feature on.

## Order

| Step | Plan | Starts from | Unlocks |
|------|------|-------------|---------|
| 1 | [02 Trips and RESUME 0](02-trips-and-resume.md) | Landed. §35 image and ropcodes 0–2 | Spec-correct arithmetic trips, which floating point needs |
| 2 | [01 Floating point](01-floating-point.md) | Landed. Enabled exceptions use the plan 02 trip entry | The last data opcodes except `SAVE`/`UNSAVE` |
| 3 | [08 Timing costs](08-timing-costs.md) | Current tree; branch costs get sharper after plan 02 | The μ + υ line students check by hand |
| 4 | [03 SAVE and UNSAVE](03-save-unsave.md) | Landed. Full §43 image in one step; interruptible spill is plan 05 | Process images, and the MMIX-SIM startup prelude |
| 5 | [04 Machine specials](04-machine-specials.md) | Current specials | `rI`, `rU`, `rN`, `rC`, `rF` as values, before they raise interrupts |
| 6 | [09 MMIXAL](09-mmixal.md) | Current assembler and `.mmo` loader | `.mms` in process |
| 7 | [05 Kernel traps](05-kernel-traps.md) | Plans 02 and 03 | `TRAP` through `rT`, `RESUME 1`, dynamic `rQ` |
| 8 | [10 Simulator session](10-simulator-session.md) | Plans 03, 05, and 08 | argv, text newlines, `mmix>` commands, profile |
| 9 | [06 Virtual memory](06-virtual-memory.md) | Plan 05 | `rV`, protection faults, `LDVTS`, MMIO |
| 10 | [07 Caches and SYNC](07-cache-and-sync.md) | Plan 06 for negative-address variants; fences can be drafted earlier | One-processor memory order |
| 11 | [11 Pipeline](11-pipeline.md) | Plans 01, 02, 03, and 07 | One core with F–D–X–M–W |
| 12 | [12 Multi-core](12-multicore.md) | Plans 05, 06, and 07; plan 11 if each core is pipelined | Shared memory, atomic `CSWAP`, cross-core `SYNC` |

Plans 08 and 09 do not wait on plan 01. They sit where they do so the integer machine gains a cost line and an assembler before the kernel work begins.

## Rules for every plan

- Default `make-vm` keeps the current user-mode results: four segments, MMIX-SIM `TRAP` visible as today’s `$255` behavior, bit 63 still a fault until plan 05 replaces that path behind a switch.
- New machinery is reached by an explicit keyword (`:kernel`, `:virtual-memory`, `:pipeline`, `:cores`) or by a new constructor. Turning the default over is a separate, last commit inside that plan, after the old tests pass both ways.
- `PUT` restrictions, once plan 05 lands, signal an interrupt on the kernel path and remain silent no-ops on the user-mode path so existing tests stay valid.
- Opcode names stay in `src/decode.lisp`. Plans add execution. They do not renumber bytes.
- Each plan names the tests that lock its acceptance cases. Those tests live under `tests/` beside the checks already there.

## Done when

The last plan’s acceptance run is: two cores, each with its own `rV`, sharing a physical octa; `CSWAP` from both; `SYNC 3` between a store on one core and a load on the other; a floating-point add that trips and `RESUME`s; a `.mms` program that `PUSHJ`s, `Fputs`s through the kernel ROM, and halts with the MMIX-SIM exit code. The functional one-instruction stepper still runs the original demos.
