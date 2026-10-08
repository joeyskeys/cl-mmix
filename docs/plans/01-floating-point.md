# Plan 01 — Floating point

Status: implemented in `src/float/`. Enabled exceptions trip through the entry that is in the tree today, so the event bit stays set and `rX` is the raw instruction. [Plan 02](02-trips-and-resume.md) rechecks that image.

Depends on [02](02-trips-and-resume.md) for the trip entry that enabled exceptions use. The arithmetic itself can be written against today’s `signal-event`, then rechecked once plan 02 lands.

Spec: `mmix-doc` §21–28 and the exception rules in §32. Opcodes `#x01`–`#x17`, `#x90`–`#x91`, `#xB0`–`#xB1`.

## Outcome

`FADD`, `FSUB`, `FMUL`, `FDIV`, `FREM`, `FSQRT`, `FINT`, `FCMP`, `FEQL`, `FUN`, `FCMPE`, `FEQLE`, `FUNE`, `FLOT`/`FLOTU`/`SFLOT`/`SFLOTU` and their immediate forms, `FIX`/`FIXU`, `LDSF`/`LDSFI`, and `STSF`/`STSFI` produce IEEE results. Rounding follows `rA` bits 17–16. Exceptions update `W I O U Z X` and trip when the matching enable is set.

## Current behavior

`execute` in `src/ops.lisp` calls `unimplemented` for `#x01`–`#x17`, for `LDSF`, and for `STSF`. `rA` bits 17–16 are stored by `PUT` (`#x3FFFF` mask in `put-special`) and never read. `rE` is a writable special and is never read. There is no floating type in `src/util.lisp`.

## Target behavior

General registers hold binary64 bit patterns, not Lisp floats.

- Rounding modes in bits 17–16 of `rA`: 00 nearest, ties to even; 01 toward zero; 10 toward +∞; 11 toward −∞.
- `FLOT`, `SFLOT`, `FLOTU`, `SFLOTU`, `FIX`, `FIXU`, `FINT`, and `FSQRT` take the `Y` field as a rounding override: 0 uses `rA`, 1 is `ROUND_OFF`, 2 is `ROUND_UP`, 3 is `ROUND_DOWN`, 4 is `ROUND_NEAR`. `Y > 4` is an illegal instruction.
- `FADD`/`FSUB`/`FMUL`/`FDIV`/`FSQRT`/`FINT` round the exact result. `FREM` is the IEEE remainder and does not honor the rounding mode.
- Comparisons write −1, 0, or +1 as an integer octa, or the unordered result specified for `FUN` / `FCMP`. `FCMPE`, `FUNE`, and `FEQLE` treat values within `rE` as equivalent, including the signed-zero and NaN cases in §22.
- `LDSF` loads a binary32 tetra, aligns it, and widens it to binary64. `STSF` narrows with the current rounding mode. A value that overflows binary32 sets `O` and `X` (not the integer `V` bit) and still writes the short encoding. Quiet NaNs and the quieting of signaling NaNs follow §22.
- Overflow sets `O` and `X`. Underflow sets `U`, and sets `X` when the underflow is not enabled; when underflow is enabled it may set both. If both enables are on, the `O` or `U` handler runs and the `X` handler does not. Integer `FIX`/`FIXU` overflow sets `W`. Invalid operations set `I`. Divide by zero sets `Z`. Inexact sets `X`.
- An enabled exception trips (plan 02). A disabled exception sets the event bit and delivers the default IEEE result (infinity, largest finite, NaN, or zero, as §21–28 specify for that opcode).

## Design

Directory `src/float/`, loaded after `src/decode.lisp` and before `src/ops.lisp`. `octa.lisp`, `pack.lisp`, `arith.lisp`, and `exec.lisp` split the bit helpers, the packers, the operations, and the opcode glue. Later plans add a sibling directory rather than folding new subsystems into `ops.lisp`. All helpers take and return `(unsigned-byte 64)`.

- `pack.lisp` packs and unpacks binary64 and binary32. Subnormals, overflow to infinity, and the round/sticky bits live in `fpack` and `sfpack`.
- `arith.lisp` is the MMIXware operation set: add, multiply, divide, remainder, square root, compare, epsilon compare, and the integer conversions. NaN payloads stay in the octa.
- `exec.lisp` provides `exec-float`, `exec-ldsf`, and `exec-stsf`. `src/ops.lisp` dispatches to them. The result is written before `rA` is updated.

Do not call `float` or `coerce` to `double-float`. SBCL’s IEEE floats are close, and they are the wrong place to implement a chosen rounding mode and a stable NaN payload.

`STSF` that cannot fit sets `O` and `X` through the same commit used by the arithmetic opcodes. It does not set `V`.

## Tests

Add cases next to the existing arithmetic tests:

- 1.0 + 2.0, and 1.0 + −1.0, including signed zero under each rounding mode.
- A tie that rounds to even.
- Overflow to infinity with `O` and `X` set and the enable clear; the same add with the `O` enable set, `PC` at 80, and the `O` event bit still set until plan 02 clears it.
- `FDIV` by zero sets `Z` and yields an infinity with the right sign.
- `FSQRT` of −1 sets `I`.
- `FREM` of a large exponent against a small one matches a hand-computed remainder.
- `FCMPE` with `rE` covering the gap between two nearby values.
- `LDSF`/`STSF` round trip of 1.0, and a binary64 value that overflows binary32.
- `FIX` of a magnitude past `2^63−1` sets `W`.

## Stays unchanged

Integer opcodes, `rA` bits 0–15, and the default enables of 0. A program that never executes a float opcode sees the same `rA` as today.

## Follow-ons

Plan 08 charges 4υ, 1υ, or 40υ. Plan 11 gives XF/XM/XD their own latencies. Plan 05 may later emulate an opcode through `rXX` high tetra `#x02000000`; once this plan lands, floating point is native and that path is for other software-emulated opcodes.
