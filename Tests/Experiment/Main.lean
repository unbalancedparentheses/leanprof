import Exp

/-! `bench ARG...`: for each argument, a number `n` or a file of numbers (one
per line), prints `report n`, and writes every line to `result.txt`. -/

def main (args : List String) : IO UInt32 := do
  let mut lines : Array String := #[]
  for a in args do
    let ns ← match a.toNat? with
      | some n => pure [n]
      | none => do
        let text ← IO.FS.readFile a
        pure ((text.splitOn "\n").filterMap (·.trimAscii.toString.toNat?))
    for n in ns do
      let r := report n
      IO.println r
      lines := lines.push r
  IO.FS.writeFile "result.txt" ("\n".intercalate lines.toList ++ "\n")
  return 0
