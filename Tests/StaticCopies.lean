import Leanprof
import Leanprof.StaticCopies
import Examples.ExplainPatterns

/-! Tests of `leanprof explain --static` (Leanprof/StaticCopies.lean): the
updates it flags in the C of this file and of `Examples/ExplainPatterns.lean`
are exactly those of the functions that copy when they run. Each case that
copies has a version that does not. -/

namespace Tests.StaticCopies
open Leanprof

/-! ## Cases -/

/-- The old array is returned too. -/
@[noinline] def retained (xs : Array Nat) (n : Nat) : Array Nat × Array Nat :=
  (xs.push n, xs)

@[noinline] def exclusive (xs : Array Nat) (n : Nat) : Array Nat :=
  xs.push n

/-- Stored in another array, then updated. -/
@[noinline] def stored (xs : Array Nat) (n : Nat) : Array Nat × Array (Array Nat) :=
  let history := #[xs]
  (xs.push n, history)

@[noinline] def moved (state : Array Nat × Nat) : Array Nat :=
  state.1.push state.2

@[noinline] def readHistory (history : Array (Array Nat)) : Nat :=
  history.size + (history[0]?.getD #[]).size

/-- Stored, but the store is released before the update. -/
@[noinline] def released (xs : Array Nat) (n : Nat) : Array Nat :=
  let history := #[xs]
  let size := readHistory history
  xs.push (n + size)

/-- Copies only when `keep`. -/
@[noinline] def conditional (keep : Bool) (xs : Array Nat) (n : Nat) : Array Nat × Array Nat :=
  if keep then (xs.push n, xs) else (xs.push n, #[])

@[noinline] def nested (xs : Array (Array Nat)) (n : Nat) : Array (Array Nat) :=
  xs.set! 0 (xs[0]!.push n)

@[noinline] def nestedFixed (xs : Array (Array Nat)) (n : Nat) : Array (Array Nat) :=
  xs.modify 0 (·.push n)

/-- Copies an empty array: no elements; not flagged. -/
@[noinline] def emptyRetained (capacity : Nat) : Array Nat × Array Nat :=
  let xs := Array.mkEmpty capacity
  (xs.push capacity, xs)

@[noinline] def updateOpaque (xs : Array Nat) (n : Nat) : Array Nat := xs.push n

/-- The update is in another function; the caller keeps the array. -/
@[noinline] def interprocedural (xs : Array Nat) (n : Nat) : Array Nat × Array Nat :=
  (updateOpaque xs n, xs)

@[noinline] def interproceduralFixed (xs : Array Nat) (n : Nat) : Array Nat × Nat :=
  let size := xs.size
  (updateOpaque xs n, size)

@[noinline] def pushTo (bucket : Array Nat) (v : Nat) : Array Nat := bucket.push v

/-- `CFG.build`'s pattern through a helper: an element still held by its array. -/
@[noinline] def nestedHelper (buckets : Array (Array Nat)) (n : Nat) : Array (Array Nat) := Id.run do
  let mut buckets := buckets
  for v in [0:n] do
    let i := v % buckets.size
    buckets := buckets.set! i (pushTo buckets[i]! v)
  return buckets

@[noinline] def nestedHelperFixed (buckets : Array (Array Nat)) (n : Nat) : Array (Array Nat) := Id.run do
  let mut buckets := buckets
  for v in [0:n] do
    let i := v % buckets.size
    buckets := buckets.modify i (pushTo · v)
  return buckets

/-- The loop keeps `base` for its next iteration, so each update copies it. -/
@[noinline] def loopKeeps (base : Array Nat) (k : Nat) : Nat := Id.run do
  let mut total := 0
  for i in [0:k] do
    total := total + (pushTo base i).size
  return total + base.size

@[noinline] def loopKeepsFixed (base : Array Nat) (k : Nat) : Nat := Id.run do
  let mut total := 0
  for _ in [0:k] do
    total := total + base.size + 1
  return total + base.size

/-- Each version of the line is kept, so the next append copies it. -/
@[noinline] def lines (n : Nat) : Array String := Id.run do
  let mut line := ""
  let mut seen : Array String := #[]
  for i in [0:n] do
    seen := seen.push line
    line := line ++ toString (i % 10)
  return seen.push line

@[noinline] def linesFixed (n : Nat) : Array Nat := Id.run do
  let mut line := ""
  let mut seen : Array Nat := #[]
  for i in [0:n] do
    seen := seen.push line.length
    line := line ++ toString (i % 10)
  return seen.push line.length

/-! ## The check -/

/-- `n`, unknown to the compiler, so calls using it run here. -/
def opaqueNat (n : Nat) : IO Nat := do return n + (← IO.monoMsNow) * 0

/-- Copies of shared values made while running `x`. -/
def copiesIn (x : Unit → α) : IO Nat := do
  let before ← copies
  let _ ← IO.lazyPure x
  return (← copies) - before

/-- A new array for each case (a constant the compiler could share between
the cases would arrive shared). -/
@[noinline] def arr (tag n : Nat) : Array Nat := (Array.range n).push tag

/-- Distinct inner arrays (`Array.replicate` would share one). -/
@[noinline] def buckets (tag n : Nat) : Array (Array Nat) := (Array.range 4).map fun i => arr (tag + i) n

/-- Copies made by each case, by declaration name. -/
def measured (n : Nat) : IO (Array (String × Nat)) := do
  let mut out := #[]
  out := out.push ("retained", ← copiesIn fun _ => (retained (arr 1 n) n).1.size)
  out := out.push ("exclusive", ← copiesIn fun _ => (exclusive (arr 2 n) n).size)
  out := out.push ("stored", ← copiesIn fun _ => (stored (arr 3 n) n).1.size)
  out := out.push ("moved", ← copiesIn fun _ => (moved (arr 4 n, n)).size)
  out := out.push ("released", ← copiesIn fun _ => (released (arr 5 n) n).size)
  out := out.push ("conditional", ← copiesIn fun _ => (conditional true (arr 6 n) n).1.size)
  out := out.push ("nested", ← copiesIn fun _ => (nested (buckets 10 n) n).size)
  out := out.push ("nestedFixed", ← copiesIn fun _ => (nestedFixed (buckets 20 n) n).size)
  out := out.push ("emptyRetained", ← copiesIn fun _ => (emptyRetained n).1.size)
  out := out.push ("interprocedural", ← copiesIn fun _ => (interprocedural (arr 7 n) n).1.size)
  out := out.push ("interproceduralFixed", ← copiesIn fun _ => (interproceduralFixed (arr 8 n) n).1.size)
  out := out.push ("nestedHelper", ← copiesIn fun _ => (nestedHelper (buckets 30 n) n).size)
  out := out.push ("nestedHelperFixed", ← copiesIn fun _ => (nestedHelperFixed (buckets 40 n) n).size)
  out := out.push ("loopKeeps", ← copiesIn fun _ => loopKeeps (arr 9 n) 4)
  out := out.push ("loopKeepsFixed", ← copiesIn fun _ => loopKeepsFixed (arr 10 n) 4)
  out := out.push ("lines", ← copiesIn fun _ => (lines n).size)
  out := out.push ("linesFixed", ← copiesIn fun _ => (linesFixed n).size)
  -- Examples/ExplainPatterns.lean
  let k := 10
  let modules (_ : Unit) : Std.HashMap Nat ModuleInfo :=
    (List.range k).foldl (fun m i => m.insert i { name := toString i, members := #[] }) {}
  out := out.push ("nestedBuckets", ← copiesIn fun _ => (nestedBuckets n k).size)
  out := out.push ("nestedBucketsFixed", ← copiesIn fun _ => (nestedBucketsFixed n k).size)
  out := out.push ("groupBy", ← copiesIn fun _ => (groupBy n k).size)
  out := out.push ("groupByAlter", ← copiesIn fun _ => (groupByAlter n k).size)
  out := out.push ("groupByErase", ← copiesIn fun _ => (groupByErase n k).size)
  out := out.push ("groupByOpt", ← copiesIn fun _ => (groupByOpt n k).size)
  out := out.push ("groupByOptErase", ← copiesIn fun _ => (groupByOptErase n k).size)
  out := out.push ("addMembers", ← copiesIn fun _ => (addMembers n k (modules ())).size)
  out := out.push ("addMembersModify", ← copiesIn fun _ => (addMembersModify n k (modules ())).size)
  out := out.push ("addMembersErase", ← copiesIn fun _ => (addMembersErase n k (modules ())).size)
  out := out.push ("keepHistory", ← copiesIn fun _ => (keepHistory n).2.size)
  out := out.push ("keepHistoryLengths", ← copiesIn fun _ => (keepHistoryLengths n).2.size)
  let c0 ← copies; let _ ← logGlobal n; out := out.push ("logGlobal", (← copies) - c0)
  let c0 ← copies; let _ ← logLocal n; out := out.push ("logLocal", (← copies) - c0)
  let c0 ← copies; let _ ← logMutex n; out := out.push ("logMutex", (← copies) - c0)
  let c0 ← copies; let _ ← logMutexLocal n; out := out.push ("logMutexLocal", (← copies) - c0)
  out := out.push ("bumpAll", ← copiesIn fun _ => (bumpAll (Array.replicate n 0) k).size)
  out := out.push ("bumpAllIndexed", ← copiesIn fun _ => (bumpAllIndexed (Array.replicate n 0) k).size)
  return out

/-- The declaration (last name component) each flag of `scan` points at: the
function with the update, or for a flag known from a caller, the caller. -/
def flagged (r : StaticCopies.Scan) : Array String :=
  r.sites.map fun s =>
    let f := match s.via with
      | .caller g .. => g
      | _ => s.f
    Explain.lastComponent (StaticCopies.userDecl (demangle f.name))

def run (check : String → Bool → String → StateT Nat IO Unit) : StateT Nat IO Unit := do
  let mut funs : Array Explain.CFun := #[]
  let mut closed : Std.HashMap String String := {}
  for file in [".lake/build/ir/Tests/StaticCopies.c", ".lake/build/ir/Examples/ExplainPatterns.c"] do
    let lines := ((← IO.FS.readFile file).splitOn "\n").toArray
    funs := funs ++ StaticCopies.functionsOf file lines
    for (c, g) in StaticCopies.closedGlobals file lines do closed := closed.insert c g
  let r := StaticCopies.scan funs closed
  let names := flagged r
  let n ← opaqueNat 40
  let counts ← measured n
  let copying := counts.filter (·.2 > 0) |>.map (·.1)
  let clean := counts.filter (·.2 == 0) |>.map (·.1)
  -- empty arrays copy no elements: not flagged, counted
  let expected := copying.filter (· != "emptyRetained")
  check "static copies: every function that copies is flagged"
    (expected.all names.contains) s!"missed {expected.filter (!names.contains ·)}"
  check "static copies: no function that does not copy is flagged"
    (!clean.any names.contains) s!"wrongly flagged {clean.filter names.contains}"
  check "static copies: the cases cover copies and fixes"
    (expected.size == 16 && clean.size == 18) s!"copying {expected}, clean {clean}"
  check "static copies: an empty array's copy is counted, not flagged"
    (copying.contains "emptyRetained" && !names.contains "emptyRetained" && r.empty ≥ 1) s!"{r.empty}"
  -- the multi-threaded and caller-side causes
  let causeOf (decl : String) : Option StaticCopies.Via :=
    (r.sites.find? fun s => (flagged { r with sites := #[s] }).contains decl).map (·.via)
  check "static copies: a global IO.Ref's updates are multi-threaded"
    (match causeOf "logGlobal", causeOf "logMutex" with | some (.global _), some (.global _) => true | _, _ => false) ""
  check "static copies: a loop that keeps its array is found at the caller"
    (match causeOf "loopKeeps", causeOf "interprocedural" with
     | some (.caller _ _ _ .held), some (.caller _ _ _ (.usedAfter _)) => true | _, _ => false) ""

end Tests.StaticCopies
