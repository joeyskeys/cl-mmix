# Plan 07 — Caches and SYNC

Status: implemented. `:caches t` on `make-vm` builds the write-back caches in `src/cache.lisp`. The default constructor leaves them empty, so loads and stores still reach memory in the same step.

Depends on [06](06-virtual-memory.md) for physical addresses, negative addresses, and translation caches. A functional fence can be unit-tested on the identity map before plan 06 turns translation on. Depends on [05](05-kernel-traps.md) for the privileged-instruction check on `SYNC` XYZ ≥ 4.

Spec: `mmix-doc` §30 and §31. Cache geometry defaults follow [mmix-config](https://mmix.cs.hm.edu/doc/mmix-config.pdf): the translation caches exist by default; instruction and data caches exist when configured.

## Outcome

`PRELD`, `PREGO`, `PREST`, `SYNCD`, `SYNCID`, `LDUNC`, `STUNC`, and `SYNC` do what one processor with caches does. Memory order between instructions on that processor follows the XYZ = 0…3 fences. Privileged XYZ = 4…7 clean or drop caches.

## Current behavior

`exec-mem` treats `PRELD`, `PREGO`, `SYNCD`, `PREST`, and `SYNCID` as no-ops. `LDUNC` is `LDOU`. `STUNC` is `STOU`. `SYNC` (`#xFC`) retires without looking at XYZ (`src/ops.lisp`). `CSWAP` is atomic only because `step-vm` runs one instruction at a time.

## Target behavior

Caches, off unless `:caches t`:

- Data cache and instruction cache, write-back, write-allocate, block size 64, associativity 2, unless a configuration overrides them. Secondary cache is absent unless configured. Translation caches are the structures plan 06 already keeps; this plan does not build a second copy.
- A store retires into the data cache and sets the line dirty. A later load of that address hits.
- `LDUNC` reads memory and does not allocate. `STUNC` writes memory and invalidates the matching line.
- Physical addresses `≥ 2^48` skip the caches.
- `PRELD` and `PREST` allocate the `X+1` bytes starting at `$Y+Z` into the data cache. `PREGO` does the same for the instruction cache. Missing permissions do not fault (§30).
- `SYNCD` from a nonnegative `PC` writes dirty bytes in that span back to memory. From a negative `PC` it also evicts them.
- `SYNCID` from a nonnegative `PC` drops the span from the instruction cache and performs `SYNCD`. From a negative `PC` it drops the span from every cache and does not write dirty data back.
- `SYNC` XYZ = 0 waits until preceding simulated operations have finished. On the functional interpreter that is a no-op aside from a recorded fence, because each instruction already finishes before the next. The fence is still recorded so plan 11 and plan 12 can honor it.
- XYZ = 1 orders stores, XYZ = 2 orders loads, XYZ = 3 orders both. On one functional core the visible result equals XYZ = 0. The tests check the recorded fence kind so a later pipeline cannot ignore it.
- XYZ = 4 sets a power-save flag that `step-vm` honors by returning immediately until `wake-core` or an `rQ` bit. XYZ = 5 writes back dirty data and keeps the lines. XYZ = 6 clears translation caches. XYZ = 7 invalidates instruction and data caches and drops dirty data. XYZ > 7 sets `b`.
- XYZ ≥ 4 from a context whose `k` interrupt is enabled sets `k` and does not perform the cache operation.

`CSWAP` stays a single-core atomic update here. Plan 12 adds the cross-core lock.

## Design

`src/cache.lisp`: `cache` struct (sets, blocks, dirty bits), `cache-load`, `cache-store`, `cache-writeback`, `cache-invalidate`. `mem-ref-u64` and `mem-set-u64` consult the data cache when `:caches` is on. `fetch` consults the instruction cache.

Configuration is a plist on `make-vm`, `:cache-config`, with the mmix-config names that this plan actually implements: `associativity`, `blocksize`, `writeback`, `writeallocate`, `accesstime`. `accesstime` is stored for plan 11 and does not change functional results.

Fence records go on the VM as a fixnum tag (`:all`, `:store`, `:load`, `:memory`) cleared when the next memory operation retires. Plan 12 reads the tag.

## Tests

- Store then load of the same octa with `:caches t` returns the stored value, and memory still holds the previous value until `SYNCD` or `SYNC 5`.
- `LDUNC` after a dirty store sees the value currently in memory, not the dirty line.
- `SYNCID` from a nonnegative address, after a store into the next instruction’s tetra, makes `fetch` see the new tetra.
- `SYNCID` from a negative address drops a dirty line and leaves memory unchanged.
- `SYNC 7` from user code with `k` enabled in `rK` does not drop the cache.
- `SYNC 8` sets `b`.
- `:caches nil` preserves every existing memory test, including `mem-xor` for `.mmo`.

## Stays unchanged

Alignment, endianness, and the results of loads and stores when caches are off. `CSWAP`’s register results on one core.

## Follow-ons

Plan 11 adds hit and miss delays from `accesstime`. Plan 12 keeps one cache per core and uses the fence tags as the memory order between cores.
