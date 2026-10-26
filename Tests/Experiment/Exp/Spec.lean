import Exp.Buckets

/-! What the project proves about `bucketOf`: the guard checks that no
candidate weakens it. -/

theorem bucketOf_lt (v k : Nat) (h : 0 < k) : bucketOf v k < k :=
  Nat.mod_lt _ h

/-- Every value of a small range lands in one of 16 buckets (a proof that
costs heartbeats: the check makes it cheaper, and more expensive). -/
theorem small_range_in_buckets : ∀ v, v < 24 → bucketOf v 16 < 16 := by
  intro v hv
  unfold bucketOf
  omega
