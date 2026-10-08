# Plan 10 — Simulator session

Depends on [03](03-save-unsave.md) for the startup `UNSAVE`, on [05](05-kernel-traps.md) so that startup is a real `UNSAVE` under the ROM, and on [08](08-timing-costs.md) for the statistics line. Text-mode newline translation can land before the kernel, behind the same file objects.

Spec: [MMIX-SIM](https://mmix.cs.hm.edu/doc/mmix-sim.pdf) §2–§4, including the interactive command list and the `argc`/`argv` prelude in §18 and §37.

## Outcome

`load-mmo` of a user program with `:argv` builds the pool image and enters the user at `Main` with `$0 = argc`, `$1 = argv`, and `rL = 2`. Text-mode files translate newlines. A small command loop approximates `mmix>`.

## Current behavior

`load-mmo` (`src/mmo.lisp`) XORs the image, applies `lop_post` to `rG` and the globals, and sets `PC` from `Main`, from the first text tetra, or from 0. It does not build an argument vector and does not `UNSAVE`.

`src/trap.lisp` opens files as `(unsigned-byte 8)`. Text and binary differ only in read versus write permission. Guest newline is whatever byte the host string contained.

Breakpoints, `step-vm`, `continue-vm`, `dump-registers`, and `dump-memory` exist. There is no command reader, no floating-point or character dump, no per-instruction profile, and no tracepoint distinct from a breakpoint. `vm-lines` stores source locations and nothing increments a count.

## Target behavior

### Arguments

Given program name `P` and argument strings `a1…ak`:

- `argc = k+1`.
- At `Pool_Segment + 8` sit `k+1` octas, each a pointer at the corresponding string, then a zero octa.
- Strings are zero-terminated bytes, allocated after those pointers, 8-byte aligned.
- `M8[Pool_Segment]` is the first octa after the strings.
- `$0 ← argc`, `$1 ← Pool_Segment+8`, `rL ← 2`, other locals 0.
- Implement this by writing the `UNSAVE` image plan 03 defines and executing `UNSAVE`, which is how MMIX-SIM §37 starts a process. On a `:kernel t` VM the ROM executes that `UNSAVE`. On the default VM, `load-mmo` calls `unsave-context` directly so argv works before the kernel is the default.

### Text streams

Modes 0 and 1 go through a character stream. The guest’s newline byte is `#x0A`. On read, the host newline becomes `#x0A`. On write, `#x0A` becomes the host newline. Modes 2, 3, and 4 stay raw. Wyde I/O treats `#x000A` as newline. This matches MMIX-SIM’s statement that the guest newline is `#x0A` and that the host’s C text mode performs the translation. UNIX hosts see no change in the file bytes, which the tests should lock by writing `#x0A` and reading it back on this platform.

### Commands

`sim-command` reads one line and implements:

| Line | Action |
|------|--------|
| empty | `step-vm`, then print the disassembly of the instruction just retired |
| `c` | `continue-vm` |
| `q` | return |
| `s` | print `PC`, retired instructions, μ, υ |
| `lN`, `gN`, `$N`, `rA`…`rZZ`, `Maddr` | print, with suffix `!` decimal, `#` hex, `.` binary64, `"` eight characters |
| the same with `=value` | assign, then print. Values accept decimal, `#` hex, a float constant, and a string |
| `+N` | the next N items in the previous format |
| `@addr` | set `PC` |
| `taddr` / `uaddr` | trace on fetch / trace off |
| `b[rwx]addr` | breakpoint. `baddr` with no letters clears it |
| `T` `D` `P` `S` | add that segment base to later addresses |
| `B` | list breakpoints and tracepoints |
| `i file` | read commands from a file. A line starting with `%` or `i` is skipped. No nested `i` |
| `h` | print this table |

Marginal registers reject a nonzero assignment. Specials reject values `PUT` would reject on the active path.

Tracing prints the disassembly whenever the traced tetra is fetched, including during `continue-vm`.

### Profile

`:profile t` adds 1 to a hash keyed by the aligned `PC` on each retire. `sim-command` `q` prints the nonzero entries with the line from `vm-lines` when one exists.

## Design

`src/sim.lisp` for the command reader and the argv builder. Newline translation lives in `src/trap.lisp` inside `fio-read-into` and `fio-write-from`, selected by the mode already stored on `fio`.

`dump-registers` grows an optional float and string view rather than a second formatter.

## Tests

- `load-mmo` with argv `("prog" "a")` yields `$0 = 2`, `$1 = Pool_Segment+8`, `rL = 2`, and the string at the first pointer is `prog`.
- A text-mode `Fwrite` of the bytes for `A`, newline, `B` is read back by text-mode `Fread` as those guest bytes.
- A binary-mode read of a file that contains a host-specific newline does not translate.
- Command `bx` at the `TRAP` of hello stops with `vm-break` before the halt, and `c` then halts.
- Command `$255#` after `SETH $255,#2000` prints the hex octa.
- Profile of a two-instruction loop counts the branch tetra twice when the body runs twice.

## Stays unchanged

Lisp-level `step-vm` and `breakpoint`. `Fread`/`Fgets` return codes. `:legacy-putchar`.

## Follow-ons

Plan 11’s statistics line adds pipeline cycles next to μ and υ. The command parser does not grow a second syntax for that; `s` prints whatever slots exist.
