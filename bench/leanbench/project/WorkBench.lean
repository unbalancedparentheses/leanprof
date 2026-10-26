import Work
/-- leanprof's scoped view, without a dependency: the `LB_REPS` actions
(default 1) are one region whose time is appended to `$LEANPROF_BENCH_OUT`
as `work<TAB>NANOSECONDS`, the protocol `Leanprof.bench "work"` follows, for
`leanprof measure-pair --scope work`. Start-up and setup are not timed. With
`LEANPROF_BENCH_REPEAT=N` (set by `measure-pair --scope`, default 5) the
region runs N times and each line ends in `<TAB>K`, its repetition. -/
def main : IO Unit := do
  Work.setup
  let reps := ((← IO.getEnv "LB_REPS").bind String.toNat?).getD 1
  let out ← IO.getEnv "LEANPROF_BENCH_OUT"
  let rep ← IO.getEnv "LEANPROF_BENCH_REPEAT"
  let n := if out.isSome then (rep.bind String.toNat?).getD 1 else 1
  for k in [0:Nat.max n 1] do
    let t0 ← IO.monoNanosNow
    for _ in [0:reps] do Work.action
    let t1 ← IO.monoNanosNow
    if let some path := out then
      let tag := if n > 1 then s!"\t{k}" else ""
      IO.FS.withFile path .append fun h => h.putStrLn s!"work\t{t1 - t0}{tag}"
  IO.println s!"result {← Work.sink.get}"
