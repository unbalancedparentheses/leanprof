import Leanprof

/-! `demangle FILE`: one C symbol per line in, the name leanprof reports for
it out (run from the profiled project, so its package names are known).
`run.py` uses it to give samply's raw profile the names `run --auto` uses. -/

def main (args : List String) : IO Unit := do
  let [file] := args | IO.eprintln "usage: demangle FILE"
  for line in (← IO.FS.readFile file).splitOn "\n" do
    IO.println (Leanprof.demangle line)
