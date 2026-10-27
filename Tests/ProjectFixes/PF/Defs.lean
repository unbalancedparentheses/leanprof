/-!
For `scripts/experiment-check.sh`: `leanprof fix --elab --project` finds these
cross-file hypotheses in a profile of the package and checks each one.

* `double` is unfolded by proofs in two other modules: making it irreducible
  breaks them (`rfl`, `decide`), so the build fails and the change is discarded;
* `double_of_big` is a simp lemma every `simp` in those modules tries and never
  uses (its hypothesis cannot be discharged);
* `walk` and `climb` recurse without `termination_by`: Lean searches for their
  measures, and stating them is cheaper.
-/

def double (n : Nat) : Nat := n + n

@[simp] theorem double_of_big (n : Nat) (_h : n > 1000) : double n = n + n := rfl

def walk (lo hi : Nat) : Nat :=
  if lo < hi then walk (lo + 1) hi + 1 else 0

def climb (a b c : Nat) : Nat :=
  if a + b < c then climb (a + 1) b c + climb a (b + 1) c else a
