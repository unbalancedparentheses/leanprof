/-!
The project `scripts/fix-check.sh` runs `leanprof fix` on, from a copy in a
fresh git repository. It does not depend on leanprof.

* `buckets` updates an element of an outer array while the array still holds
  it, so every push copies the inner array (`nested-array-element`). The fix
  `explain` prints, `Array.modify`, removes the copies and keeps the output:
  `fix` must KEEP it and commit it.
* `smooth` loops over the array it updates (`loop-over-updated-array`). The
  fix `explain` prints, a loop over the indices, reads the current array, and
  here the body writes the element the next pass reads: the values would
  change. The tests would still pass (they only check sizes), so `fix` must
  refuse the rewrite from the code, before changing anything.
-/

def buckets (n k : Nat) : Array (Array Nat) := Id.run do
  let mut bs : Array (Array Nat) := Array.replicate k #[]
  for v in [0:n] do
    let i := v * 7 % k
    bs := bs.set! i (bs[i]!.push v)
  return bs

def smooth (start : Array Nat) (rounds : Nat) : Array Nat := Id.run do
  let mut xs := start
  for _ in [0:rounds] do
    let mut j := 0
    for x in xs do
      xs := xs.set! ((j + 1) % xs.size) (x + j % 3)
      j := j + 1
  return xs
