import Leanprof
import Leanprof.Explain
import Leanprof.Fix
import Examples.ExplainPatterns

/-! Tests of the fixes `leanprof explain` prints (Leanprof/Explain.lean), on
`Examples/ExplainPatterns.lean`: for each copying function, `explain` must
name the cause and print code that is, line for line, in the fixed function,
and the fixed function must not copy. -/

namespace Tests.ExplainFixes
open Leanprof Lean

def file := "Examples/ExplainPatterns.lean"

/-- `n`, unknown to the compiler, so calls using it run here. -/
def opaqueNat (n : Nat) : IO Nat := do return n + (← IO.monoMsNow) * 0

/-- Copies made while running `x`. -/
def copiesIn (x : IO α) : IO Nat := do
  let before ← copies
  let _ ← x
  return (← copies) - before

/-- Line (1-based) of `def name` in the example. -/
def defLine (src : Array String) (name : String) : Nat :=
  ((src.findIdx? fun l => l.startsWith s!"def {name} ").map (· + 1)).getD 0

/-- Trimmed code lines of declaration `name`. -/
def declCode (src : Array String) (name : String) : Array String :=
  let l := defLine src name
  if l == 0 then #[] else (Explain.declLines src (l - 1)).map (Explain.codeOf ·.2)

/-- C functions of the example compiled from declaration `name` (the
declaration, its specializations and lambdas). -/
def cSymbols (clines : Array String) (name : String) : Array String :=
  clines.filterMap fun l =>
    if l.endsWith "{" && !l.startsWith " " && !Explain.has l "_boxed(" &&
       (Explain.has l s!"___00{name}_spec" || Explain.has l s!" lp_leanprof_{name}(" ||
        Explain.has l s!" lp_leanprof_{name}___") then
      ((l.splitOn "(").head?.bind fun h => (h.splitOn " ").getLast?).map (·.replace "*" "")
    else none

/-- Explain a copy site of `name` the way `leanprof explain` does, trying each
C function of the declaration as the copying one; the findings of all. -/
def explainAll (cache : IO.Ref Explain.CCache) (clines src : Array String) (name : String)
    (multiThreaded : Bool) : IO (Array Json) := do
  let mut out := #[]
  for sym in cSymbols clines name do
    let site := Json.mkObj [("symbol", sym), ("kind", "Array"), ("function", demangle sym),
      ("where", s!"{file}:{defLine src name}"), ("copies", 100),
      ("shared", if multiThreaded then 0 else 100), ("multi_threaded", if multiThreaded then 100 else 0),
      ("persistent", 0), ("bytes", 8000), ("copy_ns", 1000)]
    let (_, js) ← Explain.explainSite cache site #[]
    if let .arr a := js then out := out ++ a
  return out

/-- The body of declaration `name`: its indented lines after the first (not
blank lines or a closing `end`), raw: indentation included. -/
def declBody (src : Array String) (name : String) : List String :=
  let l := defLine src name
  if l == 0 then [] else
    ((Explain.declLines src (l - 1)).toList.drop 1).map (·.2) |>.filter fun l => l.startsWith " "

/-- One cause: the copying declaration, how it is run, the cause `explain`
must name, and for each printed alternative the fixed declaration that
contains it and how to run that one. -/
structure Case where
  bad : String
  runBad : IO Unit
  cause : String
  multiThreaded : Bool := false
  fixes : List (String × IO Unit)

def run (check : String → Bool → String → StateT Nat IO Unit) : StateT Nat IO Unit := do
  let n ← opaqueNat 400
  let k ← opaqueNat 10
  let modules (_ : Unit) : Std.HashMap Nat ModuleInfo :=
    (List.range k).foldl (fun m i => m.insert i { name := toString i, members := #[] }) {}
  let pure' (x : Unit → Nat) : IO Unit := do let _ ← IO.lazyPure x
  let cases : List Case := [
    { bad := "nestedBuckets", runBad := pure' fun _ => (nestedBuckets n k).size, cause := "nested-array-element",
      fixes := [("nestedBucketsFixed", pure' fun _ => (nestedBucketsFixed n k).size)] },
    { bad := "groupBy", runBad := pure' fun _ => (groupBy n k).size, cause := "map-value-reinserted",
      fixes := [("groupByAlter", pure' fun _ => (groupByAlter n k).size),
                ("groupByErase", pure' fun _ => (groupByErase n k).size)] },
    { bad := "groupByOpt", runBad := pure' fun _ => (groupByOpt n k).size, cause := "map-value-reinserted",
      fixes := [("groupByOptErase", pure' fun _ => (groupByOptErase n k).size)] },
    { bad := "addMembers", runBad := pure' fun _ => (addMembers n k (modules ())).size,
      cause := "map-value-reinserted",
      fixes := [("addMembersModify", pure' fun _ => (addMembersModify n k (modules ())).size),
                ("addMembersErase", pure' fun _ => (addMembersErase n k (modules ())).size)] },
    { bad := "keepHistory", runBad := pure' fun _ => (keepHistory n).2.size, cause := "stored-then-updated",
      fixes := [("keepHistoryLengths", pure' fun _ => (keepHistoryLengths n).2.size)] },
    { bad := "logGlobal", runBad := discard (logGlobal n), cause := "multi-threaded-global",
      multiThreaded := true, fixes := [("logLocal", discard (logLocal n))] },
    { bad := "logMutex", runBad := discard (logMutex n), cause := "multi-threaded-global",
      multiThreaded := true, fixes := [("logMutexLocal", discard (logMutexLocal n))] },
    { bad := "bumpAll", runBad := pure' fun _ => (bumpAll (Array.replicate n 0) k).size,
      cause := "loop-over-updated-array",
      fixes := [("bumpAllIndexed", pure' fun _ => (bumpAllIndexed (Array.replicate n 0) k).size)] }]
  let src := ((← IO.FS.readFile file).splitOn "\n").toArray
  let cache ← IO.mkRef ({} : Explain.CCache)
  let clines ← Explain.readLines cache ".lake/build/ir/Examples/ExplainPatterns.c"
  for c in cases do
    let found := (← explainAll cache clines src c.bad c.multiThreaded).filter fun e =>
      (e.getObjValAs? String "cause").toOption == some c.cause
    let code := match found[0]? with
      | some e => ((e.getObjValAs? (Array String) "fix_code").toOption).getD #[]
      | none => #[]
    check s!"explain fix: {c.bad} is diagnosed as {c.cause}" (!found.isEmpty) s!"{found.size} findings"
    check s!"explain fix: {c.bad} gets one code fix per fixed version" (code.size == c.fixes.length)
      s!"code={code}"
    let before ← copiesIn c.runBad
    check s!"explain fix: {c.bad} copies" (before ≥ k) s!"copies={before}"
    -- `leanprof fix`: each alternative is an edit, and the edited
    -- declaration is the fixed one, line for line (indentation included)
    let plans := match found[0]? with
      | some e => Fix.plansFor e src
      | none => .error "no finding"
    let mechanical := ["nested-array-element", "map-value-reinserted", "loop-over-updated-array"].contains c.cause
    match plans with
    | .ok ps =>
      check s!"fix: {c.bad} has one edit per printed alternative" (mechanical && ps.size == code.size)
        s!"{ps.size} plans, {code.size} alternatives"
      for ((fixed, _), p) in c.fixes.zip ps.toList do
        let edited := Fix.applyEdits src p.edits
        check s!"fix: the edit of {c.bad} ({p.what}) gives {fixed}" (declBody edited c.bad == declBody src fixed)
          s!"edited {declBody edited c.bad}"
    | .error e =>
      check s!"fix: {c.bad} ({c.cause}) is refused as not mechanical, with a reason" (!mechanical && !e.isEmpty) e
    for ((fixed, runFixed), alt) in c.fixes.zip code.toList do
      -- every printed line is a line of the fixed declaration
      let fixedLines := declCode src fixed
      let missing := (alt.splitOn "\n").map Explain.codeOf |>.filter (!fixedLines.contains ·)
      check s!"explain fix: the fix printed for {c.bad} is {fixed}" missing.isEmpty s!"missing {missing}"
      let after ← copiesIn runFixed
      check s!"explain fix: {fixed} does not copy ({c.bad} copied {before} times)" (after == 0)
        s!"copies={after}"

end Tests.ExplainFixes
