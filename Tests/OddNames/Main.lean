import OddNames.Basic

def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 10
  let mut total := 0
  for i in [0:2000] do
    total := total + Odd.callAll (n + i % 7) + «top level» n + «ελ» n
  IO.println total
