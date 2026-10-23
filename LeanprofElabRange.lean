import Lean.Util.Path

/-!
# `leanprof elab`: exact source ranges, from the in-process driver

`leanprof-elab-driver` (LeanprofElabDriver.lean) elaborates a file with every
term and tactic elaborator wrapped, and prints each one that took longer than
the threshold as a trace node `[Leanprof.term]` or `[Leanprof.tactic]` whose
description is `@line:col-line:col kind | source` (columns from 1). This file
reads those descriptions, finds the driver and decides whether it can be used:
it is built with leanprof's Lean, and can only load `.olean` files of that same
Lean, so for a project on another toolchain `elab` elaborates with that
project's `lean --json` and finds tactics by their text, as before.
-/

open System

namespace Leanprof.Elab

/-- A source node: `range` is `line:col-line:col`, `line` the line it starts on,
`kind` the syntax kind (`Lean.Parser.Tactic.simp`), `text` the source (at most
100 characters, whitespace collapsed). -/
structure SrcRange where
  range : String
  line : Nat
  kind : String
  text : String
  deriving Inhabited, BEq, Repr

/-- The classes of source nodes. -/
def isSourceClass (cls : String) : Bool := cls == "Leanprof.tactic" || cls == "Leanprof.term"

/-- A source node's description `@12:3-12:40 Lean.Parser.Tactic.simp | simp [foo]`. -/
def parseSrcRange (t : String) : Option SrcRange := do
  guard (t.startsWith "@")
  let (head, text) := match t.splitOn " | " with
    | h :: rest => (h, " | ".intercalate rest)
    | [] => (t, "")
  match ((head.drop 1).toString.splitOn " ") with
  | [range, kind] =>
    let line ← (range.splitOn ":").head?.bind String.toNat?
    guard ((range.splitOn "-").length == 2)
    return { range, line, kind, text }
  | _ => none

/-- `Lean.Parser.Tactic.simp` as `simp`; `Lean.Parser.Term.app` as `app`. -/
def shortKind (k : String) : String :=
  let parts := k.splitOn "."
  -- `Lean.Parser.Tactic.tacticSimp_arith_` and the like: the parser's name, without `tactic`
  let last := parts.getLastD k
  if last.startsWith "tactic" && last.length > 6 && last != "tacticSeq" then (last.drop 6).toString else last

/-- Tactic sequences: their cost is the sum of their tactics', not shown on their own. -/
def seqKind (k : String) : Bool :=
  k.endsWith ".tacticSeq" || k.endsWith ".tacticSeq1Indented" || k.endsWith ".tacticSeqBracketed"

/-- A command's text without the `set_option o v in` and `open X in` before it: the
driver names a command by its source, where Lean printed the command it expands to. -/
partial def dropInPrefix (text : String) : String :=
  let words := text.splitOn " "
  let rest? : Option (List String) := match words with
    | "set_option" :: _ :: _ :: "in" :: rest => some rest
    | "open" :: rest =>
      match (rest.take 8).findIdx? (· == "in") with
      | some i => some (rest.drop (i + 1))
      | none => none
    | _ => none
  match rest? with
  | some rest => dropInPrefix (" ".intercalate (rest.dropWhile (· == "")))
  | none => text

/-- Where `leanprof-elab-driver` is: `LEANPROF_ELAB_DRIVER`, or next to this program. -/
def driverPath : IO (Option FilePath) := do
  if let some p ← IO.getEnv "LEANPROF_ELAB_DRIVER" then
    return if p.isEmpty then none else some p
  let app ← IO.appPath
  let some dir := app.parent | return none
  let p := dir / ("leanprof-elab-driver" ++ (if System.Platform.isWindows then ".exe" else ""))
  return if ← p.pathExists then some p else none

/-- The driver to elaborate with, or why there is none: it must exist and be built
with the same Lean (same commit) as the project's `lean`. -/
def findDriver (lean : String) : IO (Except String String) := do
  let some p ← driverPath
    | return .error "leanprof-elab-driver is not built (`lake build leanprof-elab-driver`)"
  -- the driver next to this program is built with this program's Lean; another one is asked
  let a ← if (← IO.getEnv "LEANPROF_ELAB_DRIVER").isNone then pure Lean.githash else
    let ours ← try IO.Process.output { cmd := p.toString, args := #["--githash"] }
      catch e => return .error s!"{p} does not run: {e}"
    if ours.exitCode != 0 then return .error s!"{p} does not run"
    pure ours.stdout.trimAscii.toString
  let theirs ← try IO.Process.output { cmd := lean, args := #["--githash"] }
    catch e => return .error s!"{lean} does not run: {e}"
  let b := theirs.stdout.trimAscii.toString
  if a.isEmpty then return .error s!"{p} does not run"
  if a != b then
    return .error s!"the project's Lean ({b.take 12}) is not the one leanprof was built with ({a.take 12})"
  return .ok p.toString

end Leanprof.Elab
