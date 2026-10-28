import Examples.Retained

/-! `lake exe retained [N]`: the retained-memory scenario of Examples/Retained.lean,
for `leanprof run --retained retained`. -/

def main (args : List String) : IO Unit :=
  RetainedTest.scenario ((args.head? >>= String.toNat?).getD 1)
