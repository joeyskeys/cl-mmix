# Plan 02 — Trips and RESUME 0

Depends on nothing in the current tree. Plan 01 should land after this one so floating-point exceptions use the same entry.

Spec: `mmix-doc` §32, §34, §35, and §38 for `Z = 0`. `RESUME 1` is plan 05.

## Outcome

`TRIP` and an enabled arithmetic exception enter the handler with the registers §35 names. `RESUME` with `XYZ = 0` either jumps to `rW` or inserts the instruction in `rX`, depending on the sign of `rX` and its ropcode.

## Current behavior

`do-trip` (`src/machine.lisp`) writes `rB ← $255`, `rW ← PC+4`, `rX ←` the raw tetra, `rY` and `rZ` from its keyword arguments, and `PC` to the vector. `TRIP` (`src/ops.lisp`) passes the Y and Z *fields*, not `$Y` and `$Z`. `signal-event` ORs the event bit into `rA` and then trips when the enable bit is set. `RESUME` (`#xF9`) rejects a nonzero XYZ and otherwise sets `PC ← rW`, ignoring `rX`.

`GET` (`#xFE`) and `PUT` (`#xF6`/`#xF7`) ignore a nonzero Y field. §43 makes that an illegal instruction.

The existing test for an enabled `V` trip expects `rW` at the next instruction and `PC` at 32. Update that test to the §35 register image. Keep the vector address.

## Target behavior

`TRIP X,Y,Z`:

- `rX ← #x8000000000000000` OR the raw tetra.
- `rY ← $Y`, `rZ ← $Z`.
- `rB ←` the previous `$255`, then `$255 ← rJ`.
- `rW ← PC+4`.
- `PC ← 0`.

Enabled arithmetic exception, same image, with these differences:

- The handler address is 16, 32, 48, 64, 80, 96, 112, or 128 for `D V W I O U Z X`.
- The event bit stays clear. Disabled exceptions still set the bit and do not trip.
- When two bits would fire (`O` with `X`, or `U` with `X`), the earlier bit in `DVWIOUZX` wins if both enables are set. The other handler is not called.
- `rY` and `rZ` are the operation’s operands. For a store, `rY` is the virtual address and `rZ` is the octa that would have been written.
- The destination register already holds the wrapped or default result before the trip, matching today’s integer path, unless the handler replaces it through ropcode 2.

`RESUME` with `X = Y = 0` and `Z = 0`:

- If `rX` is negative (bit 63 set), set `PC ← rW`. This is the normal return from `TRIP`, and it does not execute the tetra in the low half of `rX`.
- If `rX` is nonnegative, the high byte is the ropcode and the low tetra is inserted as though it occupied `rW−4`.
  - Ropcode 0 executes that tetra.
  - Ropcode 1 executes it with the two operands replaced by `rY` and `rZ`, and only for opcodes whose high nybble is `#x0`–`#x3`, `#x6`, `#x7`, `#xC`, `#xD`, or `#xE`.
  - Ropcode 2 sets `$X ← rZ`, where `X` is the second byte of the low tetra, and raises the exception bits in bits 47–40 of `rX` (the third byte from the left) through `signal-event`. `$X` must not be marginal.
  - Ropcode 3 is rejected on `RESUME 0`. It belongs to `RESUME 1` (plan 05).
  - A ropcode above 3, a `RESUME` inserted by ropcode 0, or a nonzero X or Y field sets the `b` condition. Until plan 05, that still halts with `vm-fault`, the way other illegal cases do today.

Instructions fetched from a negative address do not trip. Until plan 06 those addresses still fault on the user-mode path; the check becomes live with the kernel path in plan 05.

## Design

Extend `do-trip` with the `$255`/`rJ` swap and the forced high bit of `rX`. Split `signal-event` into “record” and “trip”: recording ORs the bit only when the enable is clear.

`exec-resume` in `src/ops.lisp` reads `rX`. Insertion builds an `instruction` via `decode` and calls `execute`, with `PC` still at the interrupted instruction so relative branches and `rW` arithmetic see `rW−4` as their address. Set `PC` to `rW` afterwards when `execute` returns nil. A returned `:jump` keeps the target the inserted instruction wrote.

`GET`/`PUT` with nonzero Y call the same illegal-instruction path.

## Tests

- `TRIP` sets `rX` bit 63, `rB` to the old `$255`, `$255` to the old `rJ`, and `rY`/`rZ` from the registers named by Y and Z.
- `RESUME 0` after that `TRIP` continues at `rW` and does not run the `TRIP` again.
- Enabled `V` on `ADDI` leaves the `V` event bit clear, `PC = 32`, and `rX` negative.
- Disabled `V` sets the event bit and falls through.
- Ropcode 2 replaces `$X` and can itself trip when bits 47–40 of `rX` name an enabled exception.
- `PUT` with `Y ≠ 0` faults.
- The recursive-factorial and hello-world demos still run. They never trip.

## Stays unchanged

`RESUME` with `Z ≠ 0` still faults. Kernel bootstrap registers stay unused. Vectors stay at 0, 16, …, 128.

## Follow-ons

Plan 01 raises `W I O U Z X` through this path. Plan 05 implements `RESUME 1`, ropcode 3, and turns the illegal-instruction fault into the `b` bit of `rQ`.
