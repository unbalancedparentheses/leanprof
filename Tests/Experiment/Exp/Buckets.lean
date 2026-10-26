/-!
The project `scripts/experiment-check.sh` runs `leanprof experiment` on, from
a copy in a fresh git repository. It does not depend on leanprof.

`buckets` updates an element of an outer array while the array still holds
it, so every push copies the inner array. The candidates the check tries
(written by the script):

* `Array.modify` instead: the same values, no copies (KEEP);
* the same, but one value lands elsewhere for the input `inputs/large.txt`
  only, which the timed workload does not reach (DISCARD: the outputs differ);
* a `sorry` in `Exp/Spec.lean`, a weaker theorem statement, a loosened test
  (DISCARD, INCONCLUSIVE, DISCARD: the proof-preservation guard);
* a cheaper proof only: the generated C is unchanged, so the measure is
  compile heartbeats and nothing is timed;
* a change that differs only on the held-out input (KEEP on the inputs it
  is checked on; `finish` finds the difference).
-/

/-- The bucket of value `v` among `k`. -/
def bucketOf (v k : Nat) : Nat := v * 7 % k

def buckets (n k : Nat) : Array (Array Nat) := Id.run do
  let mut bs : Array (Array Nat) := Array.replicate k #[]
  for v in [0:n] do
    let i := bucketOf v k
    bs := bs.set! i (bs[i]!.push v)
  return bs

/-- What `bench` prints for `n` values. -/
def report (n : Nat) : String :=
  let bs := buckets n 16
  s!"n {n}: sizes {bs.map (·.size)}, weighted {bs.foldl (fun (s, j) b => (s + j * b.foldl (· + ·) 0, j + 1)) (0, 0) |>.1}"
