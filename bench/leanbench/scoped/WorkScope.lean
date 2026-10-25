import Leanprof
import Work
/-- ../project/WorkMain.lean with the repetitions in one `profile!` scope,
for `leanprof measure --scope work`. -/
def main : IO Unit := do
  Work.setup
  let reps := ((← IO.getEnv "LB_REPS").bind String.toNat?).getD 20
  profile! "work" do
    for _ in [0:reps] do Work.action
  IO.println s!"result {← Work.sink.get}"
