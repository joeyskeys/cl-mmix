# Plan 09 — MMIXAL

Depends on the s-expression assembler (`src/asm.lisp`) and the `.mmo` loader (`src/mmo.lisp`). No kernel and no floating point.

Spec: the MMIXAL chapter of MMIXware (`mmixal.w`): `LOC`, `IS`, `GREG`, `PREFIX`, `LOCAL`, `BYTE`, `WYDE`, `TETRA`, `OCTA`, `BSPEC`, `ESPEC`, expressions, and local labels.

## Outcome

`assemble-mms` reads a `.mms` string or pathname and returns the same segment list `assemble` returns, plus a `GREG` allocation that `assemble-into` can apply to `rG`. `load-mms` writes it into a VM. The existing s-expression assembler stays.

## Current behavior

`assemble` accepts lists such as `(setl $1 6)` and `(:org #x100)`. Labels are Lisp symbols. There is no expression parser, no `1H`/`1B`/`1F`, and no `GREG`. `load-mmo` already accepts `mmixal`’s object files, including `lop_post` for `rG` and the symbol trie. Programs that can be assembled only by an external `mmixal` therefore run. Programs that exist only as `.mms` text do not.

## Target behavior

A subset that covers Fascicle 1 listings, then the rest of the assembler directives:

- Mnemonics and the same opcode bytes as `src/decode.lisp`, including backward branches chosen from the sign of the displacement.
- Labels: global identifiers, local `dH` defined and `dB`/`dF` referenced for `d` from 0 to 9.
- `LOC` expression, including `LOC Data_Segment` once those names are predefined constants (`#x0000000000000000`, `#x2000000000000000`, `#x4000000000000000`, `#x6000000000000000`).
- `IS` for symbols. `GREG` expression allocates from 254 downward, never using 255, and the resulting `rG` is the first free global. A bare `GREG` uses the location counter the way `mmixal` does.
- Expressions: integer constants in decimal and `#` hex, `+ - * / % << >> & | ^ ~`, unary minus, and parentheses. Forward references are allowed where `mmixal` allows them (addresses, not register numbers).
- Data: `BYTE`, `WYDE`, `TETRA`, `OCTA`, and string constants.
- `PREFIX` and `LOCAL`.
- `BSPEC` / `ESPEC`: the tetras are recorded on the side and are not placed in the executable image, matching a loader that skips `lop_spec`.
- Comments from `%` to end of line, and the `mmixal` string rules for `BYTE`.

Register names: `$12`, `x` after `x IS $12`, and the special names `rA`…`rZZ`.

Output path: build the in-memory segments and also offer `write-mmo` so a listing can be saved and loaded with `load-mmo`. One code path emits the bytes. `assemble-mms` and `write-mmo` share it, so the two cannot drift.

## Design

`src/mmixal.lisp`, after `src/asm.lisp`.

- Lexer over a string, producing tokens with source line numbers stored into `vm-lines` on `load-mms`.
- Parser producing the same internal forms `encode-form` already understands, plus data directives. Reuse `encode-form` rather than a second opcode encoder.
- Fixup list for forward local labels, resolved before `encode-relative`.
- `GREG` state is a counter starting at 255. Each `GREG` decrements and records the symbol.

Diagnostics name the file and line. A bad mnemonic is a Lisp error from `load-mms`, the same way a bad s-expression opcode is.

## Tests

- The factorial s-expression program, rewritten as a `.mms` string with `LOC #100`, a local label, and `TRAP 0,Halt,0`, returns the same `$3` as `demo-factorial` does for the same n. Use 10 and expect 3628800.
- `GREG @` under `LOC Data_Segment` sets `rG` to 254 and defines the symbol as register 254.
- A forward `1F` and a backward `1B` encode `#xF0`/`#xF1` or the branch opcodes with the displacements `encode-relative` would choose.
- `write-mmo` of that program, then `load-mmo` into a fresh VM, halts at the same result.
- `BSPEC` tetras do not appear at the location counter.

## Stays unchanged

`assemble`, `assemble-into`, and `load-mmo`. External `.mmo` files still load.

## Follow-ons

Plan 10 feeds `load-mms` the argv image. Full macro MMIXAL (`mmixal`’s macro language) is a later extension inside this file once the expressions and labels are stable. The acceptance tests above do not require macros.
