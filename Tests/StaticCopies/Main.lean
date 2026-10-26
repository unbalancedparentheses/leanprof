import Cases
open Leanprof StaticCopyCases

def reportCopies (name : String) (action : Unit → Nat) : IO Unit := do
  let before ← copies
  let result ← IO.lazyPure action
  let count := (← copies) - before
  IO.println s!"{name}\t{count}\t{result}"

def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 20
  reportCopies "retained" fun _ => let p := retained (Array.replicate n 7) n; p.1.size + p.2.size
  reportCopies "exclusive" fun _ => (exclusive (Array.replicate n 7) n).size
  reportCopies "stored" fun _ => let p := stored (Array.replicate n 7) n; p.1.size + p.2.size
  reportCopies "moved" fun _ => (moved (Array.replicate n 7, n)).size
  reportCopies "released" fun _ => (released (Array.replicate n 7) n).size
  reportCopies "conditional.true" fun _ => let p := conditional true (Array.replicate n 7) n; p.1.size + p.2.size
  reportCopies "conditional.false" fun _ => let p := conditional false (Array.replicate n 7) n; p.1.size + p.2.size
  reportCopies "nested" fun _ => (nested #[Array.replicate n 7] n).size
  reportCopies "nestedFixed" fun _ => (nestedFixed #[Array.replicate n 7] n).size
  reportCopies "emptyRetained" fun _ => let p := emptyRetained n; p.1.size + p.2.size
  reportCopies "interprocedural" fun _ => let p := interprocedural (Array.replicate n 7) n; p.1.size + p.2.size
