import Exp

/-! `lake test` of the fixture: sizes only, so a change to which bucket one
large value lands in passes it (the experiment's inputs catch that). -/

def main : IO UInt32 := do
  let bs := buckets 160 16
  let ok := bs.size == 16 && bs.all (·.size == 10)
  IO.println (if ok then "fixture tests passed" else "fixture tests FAILED")
  return if ok then 0 else 1
