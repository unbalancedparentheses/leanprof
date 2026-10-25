import Fix

/-! `lake test` of the fixture: checks sizes only, so a change to the values
`smooth` computes would pass it (`leanprof fix` has to refuse that rewrite
itself). -/

def main : IO UInt32 := do
  let bs := buckets 160 16
  let ok := bs.size == 16 && bs.all (·.size == 10) && (bs.foldl (· + ·.size) 0) == 160 &&
    (smooth (Array.range 10) 3).size == 10
  IO.println (if ok then "fixture tests passed" else "fixture tests FAILED")
  return if ok then 0 else 1
