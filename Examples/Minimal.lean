module

public import Leanprof

/-! The smallest use of `profile!`, as a module: the elaborator behind
`profile!` is only needed while compiling, so the program does not
initialize Lean's front end at startup. -/

def triple (n : Nat) : Nat := profile! "triple" (n * 3)

public def main : IO Unit := do
  IO.println (triple 14)
