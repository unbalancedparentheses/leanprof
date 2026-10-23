import Lean.Util.Path
import Std.Data.HashMap

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
  let words := (text.replace "\n" " ").splitOn " "
  -- up to `in`, within the first `n` words
  let upToIn (rest : List String) (n : Nat) : Option (List String) :=
    match (rest.take n).findIdx? (· == "in") with
    | some i => some (rest.drop (i + 1))
    | none => none
  let rest? : Option (List String) := match words with
    | "set_option" :: _ :: _ :: "in" :: rest => some rest
    | "open" :: rest => upToIn rest 8
    -- `variable (x : T) in`, `omit [Foo α] in`, `include h in`, `attribute [local simp] f in`
    | "variable" :: rest => upToIn rest 40
    | "omit" :: rest => upToIn rest 40
    | "include" :: rest => upToIn rest 40
    | "attribute" :: rest => upToIn rest 40
    | _ => none
  match rest? with
  | some rest => dropInPrefix (" ".intercalate (rest.dropWhile (· == "")))
  | none => text

/-- The driver's source, compiled into the command: `elab` builds it for a project whose
Lean is not the one leanprof was built with (`buildDriver`). -/
def driverSource : String := include_str "LeanprofElabDriver.lean"

/-- The driver built with leanprof (next to this program), or `LEANPROF_ELAB_DRIVER`. -/
def bundledDriver : IO (Option FilePath) := do
  if let some p ← IO.getEnv "LEANPROF_ELAB_DRIVER" then
    return if p.isEmpty then none else some p
  let app ← IO.appPath
  let some dir := app.parent | return none
  let p := dir / ("leanprof-elab-driver" ++ (if System.Platform.isWindows then ".exe" else ""))
  return if ← p.pathExists then some p else none

/-- Where drivers built for other Lean versions are kept: `LEANPROF_CACHE`, else
`$XDG_CACHE_HOME/leanprof`, else `~/.cache/leanprof`. -/
def cacheDir : IO FilePath := do
  if let some d ← IO.getEnv "LEANPROF_CACHE" then if !d.isEmpty then return d
  if let some d ← IO.getEnv "XDG_CACHE_HOME" then if !d.isEmpty then return (d : FilePath) / "leanprof"
  let home := (← IO.getEnv "HOME").getD "."
  return (home : FilePath) / ".cache" / "leanprof"

/-- The Lean commit a program reports with `--githash`, or none when it does not run. -/
def runGithash (cmd : String) : IO (Option String) := do
  try
    let out ← IO.Process.output { cmd, args := #["--githash"] }
    let h := out.stdout.trimAscii.toString
    return if out.exitCode == 0 && !h.isEmpty then some h else none
  catch _ => return none

/-- `runGithash`, remembered for the process and on disk (`cacheDir/githash/`, by the
program's path, size and modification time): every `elab` asks it of the project's `lean`. -/
initialize githashMemo : IO.Ref (Std.HashMap String (Option String)) ← IO.mkRef {}

def githashOf (cmd : String) : IO (Option String) := do
  if let some h := (← githashMemo.get).get? cmd then return h
  let key? ← try
      let p ← IO.FS.realPath cmd
      let m ← p.metadata
      pure (some s!"{p}|{m.byteSize}|{m.modified.sec}|{m.modified.nsec}")
    catch _ => pure none
  let file? ← key?.mapM fun k => return (← cacheDir) / "githash" / (String.ofList (Nat.toDigits 16 (hash k).toNat))
  if let (some k, some f) := (key?, file?) then
    if let some line ← (try some <$> IO.FS.readFile f catch _ => pure none) then
      if let [k', h] := line.trimAscii.toString.splitOn "\n" then
        if k' == k then
          githashMemo.modify (·.insert cmd (some h))
          return some h
  let h ← runGithash cmd
  githashMemo.modify (·.insert cmd h)
  if let (some k, some f, some h) := (key?, file?, h) then
    try
      IO.FS.createDirAll (f.parent.getD ".")
      IO.FS.writeFile f s!"{k}\n{h}\n"
    catch _ => pure ()
  return h

/-- Hex digits of a string's hash: names the build of this source. -/
def sourceKey (s : String) : String :=
  String.ofList (Nat.toDigits 16 (hash s).toNat)

/-- The driver compiled for the Lean at `sysroot` (commit `commit`), as lean-source-profiler
does: `lean -c` on its source, then `leanc` linked against that Lean's shared library. Kept
in `cacheDir/driver/COMMIT/SOURCE/`, built once (a few seconds); a build that fails or
reports another commit is not kept. -/
def buildDriver (sysroot : FilePath) (commit : String) : IO (Except String FilePath) := do
  let exe := "leanprof-elab-driver" ++ (if System.Platform.isWindows then ".exe" else "")
  let dir := (← cacheDir) / "driver" / commit / sourceKey driverSource
  let final := dir / exe
  if ← final.pathExists then
    if (← githashOf final.toString) == some commit then return .ok final
  let stage : FilePath := dir.toString ++ s!".build-{← IO.Process.getPID}-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll stage
    let src := stage / "LeanprofElabDriver.lean"
    IO.FS.writeFile src driverSource
    let lib := sysroot / "lib" / "lean"
    let env : Array (String × Option String) := #[("LEAN_PATH", none), ("LEAN_SYSROOT", some sysroot.toString)]
    let steps : List (String × Array String) := [
      ((sysroot / "bin" / "lean").toString, #["-R", stage.toString, "-c", (stage / "driver.c").toString, src.toString]),
      ((sysroot / "bin" / "leanc").toString, #["-O3", "-o", (stage / exe).toString, (stage / "driver.c").toString,
        "-rdynamic", "-L", lib.toString, s!"-Wl,-rpath,{lib}", "-lleanshared"])]
    for (cmd, args) in steps do
      let out ← IO.Process.output { cmd, args, env, cwd := stage }
      if out.exitCode != 0 then
        let msg := (out.stdout ++ out.stderr).trimAscii.toString
        throw <| IO.userError s!"{(cmd : FilePath).fileName.getD cmd} failed: {String.ofList (msg.toList.take 600)}"
    if (← githashOf (stage / exe).toString) != some commit then
      throw <| IO.userError "the driver it built does not run"
    -- several `elab`s at once: the first to finish publishes, the others use it
    if !(← final.pathExists) then
      IO.FS.createDirAll dir
      IO.FS.rename (stage / exe) final
    IO.FS.removeDirAll stage
    return .ok final
  catch e =>
    try IO.FS.removeDirAll stage catch _ => pure ()
    return .error s!"could not build leanprof-elab-driver for this Lean ({e})"

/-- The driver to elaborate with, or why there is none. It must be built with the same Lean
(same commit) as the project's `lean`: the one built with leanprof when that is the
project's Lean, else one built for the project's Lean on demand (`buildDriver`).
`LEANPROF_ELAB_DRIVER` names one to use as it is. -/
def findDriver (lean : String) (sysroot : FilePath) : IO (Except String String) := do
  let some theirs ← githashOf lean | return .error s!"{lean} does not run"
  let explicit := (← IO.getEnv "LEANPROF_ELAB_DRIVER").isSome
  if let some p ← bundledDriver then
    -- the driver next to this program is built with this program's Lean; another one is asked
    let ours ← if explicit then githashOf p.toString else pure (some Lean.githash)
    let some ours := ours | return .error s!"{p} does not run"
    if ours == theirs then return .ok p.toString
    if explicit then
      return .error s!"the project's Lean ({theirs.take 12}) is not the one {p} was built with ({ours.take 12})"
  else if explicit then
    return .error "LEANPROF_ELAB_DRIVER is empty"
  if !(← (sysroot / "bin" / "leanc").pathExists) && !(← (sysroot / "bin" / "leanc.exe").pathExists) then
    return .error s!"the project's Lean ({theirs.take 12}) is not the one leanprof was built with, and {sysroot} has no leanc to build a driver for it"
  let cached := (← cacheDir) / "driver" / theirs / sourceKey driverSource
  unless ← cached.pathExists do
    IO.eprintln s!"leanprof: building leanprof-elab-driver for the project's Lean ({theirs.take 12}), once; kept in {cached.parent.getD cached}"
  match ← buildDriver sysroot theirs with
  | .ok p => return .ok p.toString
  | .error e => return .error e

end Leanprof.Elab
