# Plan 03 — SAVE and UNSAVE

Depends on the register stack in `src/machine.lisp` (`push-frame`, `pop-frame`, `vm-stack`, `rO`, `rS`). Interruptible saves need plan 05; the memory image in this plan is complete without it.

Spec: `mmix-doc` §43. The loader prelude that *uses* `UNSAVE` is plan 10.

## Outcome

`SAVE $X,0` writes a process image on the register stack and leaves `$X` holding its top address. `UNSAVE 0,$Z` restores that image. `Y` is 0. `Z` of `SAVE` is 0. `X` of `UNSAVE` is 0. `$X` of `SAVE` is a global register.

## Current behavior

`#xFA` and `#xFB` call `unimplemented` with "SAVE/UNSAVE is not implemented" (`src/ops.lisp`). The hidden stack is a Lisp vector mirrored at `Stack_Segment + 8*tau` only for values `stack-push-octa` writes. Locals are not mirrored on every write.

## Target behavior

`SAVE`, in order:

1. Push `$0`…`$(rL−1)` and then the hole value 255, the same slide as `push-frame` with `X = 255` when `255 ≥ rG` (the `X ≥ rG` arm). `rL ← 0`.
2. Push `$rG`, `$(rG+1)`, …, `$255`.
3. Push `rB`, `rD`, `rE`, `rH`, `rJ`, `rM`, `rR`, `rP`, `rW`, `rX`, `rY`, `rZ`, in that order.
4. Push one octa whose top byte is `rG`, whose next three bytes are 0, and whose low tetra is `rA`.
5. Set `$X` to the address of that last octa. `$X` must be global (`X ≥ rG` after the locals were pushed, which is any `X` since `rL` is now 0, except the marginal range is empty; the spec still requires a global, so `X ≥ rG`).
6. Set `rO` and `rS` to the first byte after the image. The register stack is empty: a `POP` before the next `UNSAVE` faults.

`UNSAVE` reads that image from the top downward and reverses the steps, ending with `rO = rS` equal to the address just past the restored stack region that `SAVE` had emptied. Restored locals sit in `$0`…`$(rL−1)` with the saved `rL` recovered from the hole. The in-memory image may be clobbered by later pushes. A second `UNSAVE` of the same address is not a supported operation; the test uses a fresh image.

Both opcodes require the unused fields to be zero. A nonzero field is an illegal instruction (fault until plan 05, then the `b` bit).

The image is stored with `stack-push-octa`, so it appears both in `vm-stack` and at `Stack_Segment`. `UNSAVE` reads from `vm-stack` when the address matches `rO`/`rS`, and from memory when a program saved the image and then moved it. Reading from memory is the path the OS uses.

## Design

`save-context` and `unsave-context` live in `src/machine.lisp` next to `push-frame`. `execute` dispatches `#xFA` and `#xFB` to them.

Interruptibility: record a phase and a count in `rX` if a trip or trap arrives mid-save, using the convention §34 describes (`α = β = γ`, `rO = rS`, `rL = 0` means the handler sees a fresh stack on top of a partial image). The first version may run the whole `SAVE` inside one `step-vm` and document the phase counter as the hook plan 05 will poll. Do not pretend a single Lisp call is interruptible until `step-vm` can return mid-instruction.

`rG` packed in the top byte uses `(logior (ash rg 56) (logand ra #xffffffff))`.

## Tests

- `SAVE` then `UNSAVE` restores `rL`, `rG`, `rA`, `rJ`, three locals, and two globals, and returns `rO` to its previous relationship with `tau`.
- After `SAVE`, `rL` is 0, `rO = rS`, and `$X` addresses an octa whose top byte is the old `rG` and whose low tetra is the old `rA`.
- The octa just under that one is `rZ`.
- `POP` immediately after `SAVE` faults.
- A nonzero Y field faults.
- `demo-recursive-factorial` still returns 3628800 for 10!. It does not execute `SAVE`.

## Stays unchanged

`PUSHJ` / `POP` results for programs that never `SAVE`. `lop_post` still writes globals directly.

## Follow-ons

Plan 10 builds the MMIX-SIM startup image and `UNSAVE`s it so `$0` is `argc` and `$1` points at `argv`. Plan 05 makes a long `SAVE` interruptible.
