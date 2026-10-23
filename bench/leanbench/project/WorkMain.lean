import Work
/-- leanprof's view: one process runs the action `LB_REPS` times (default 20,
like LeanBench's default 20 samples) and prints a deterministic result. -/
def main : IO Unit := do
  Work.setup
  let reps := ((← IO.getEnv "LB_REPS").bind String.toNat?).getD 20
  for _ in [0:reps] do Work.action
  IO.println s!"result {← Work.sink.get}"
