import Work
/-- leanprof's scoped view, without a dependency: the `LB_REPS` actions
(default 1) are one region whose time is appended to `$LEANPROF_BENCH_OUT`
as `work<TAB>NANOSECONDS`, the protocol `Leanprof.bench "work"` follows, for
`leanprof measure-pair --scope work`. Start-up and setup are not timed. -/
def main : IO Unit := do
  Work.setup
  let reps := ((← IO.getEnv "LB_REPS").bind String.toNat?).getD 1
  let t0 ← IO.monoNanosNow
  for _ in [0:reps] do Work.action
  let t1 ← IO.monoNanosNow
  if let some path ← IO.getEnv "LEANPROF_BENCH_OUT" then
    IO.FS.withFile path .append fun h => h.putStrLn s!"work\t{t1 - t0}"
  IO.println s!"result {← Work.sink.get}"
