import Fix

/-! `buckets EXE [N]`: the program `scripts/fix-check.sh` runs `leanprof fix`
on. Prints the sizes and sum of `buckets`; `--smooth` prints `smooth`
instead. -/

def main (args : List String) : IO Unit := do
  if args.head? == some "--smooth" then
    let n := (args[1]? >>= String.toNat?).getD 2000
    let xs := smooth (Array.range n) 50
    IO.println s!"smooth sum {xs.foldl (· + ·) 0}, first {xs[0]!}, last {xs.back!}"
  else
    let n := (args.head? >>= String.toNat?).getD 20000
    let bs := buckets n 16
    IO.println s!"sizes {bs.map (·.size)}"
    IO.println s!"sum {bs.foldl (fun s b => s + b.foldl (· + ·) 0) 0}"
