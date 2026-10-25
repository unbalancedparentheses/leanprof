import Lean.Util.Path

/-!
# `leanprof elab`: exact source ranges, from the in-process driver

`leanprof-elab-driver` (LeanprofElabDriver.lean) elaborates a file with every
term and tactic elaborator wrapped, and prints each one that took longer than
the threshold as a trace node `[Leanprof.term]` or `[Leanprof.tactic]` whose
description is `@line:col-line:col kind | source` (columns from 1). This file
reads those descriptions and finds the driver. A driver can only load `.olean`
files of the Lean it is built with: the one built with leanprof serves projects
on leanprof's Lean, and for a project on another toolchain `elab` builds one with
that toolchain, from the source compiled into the command, once per toolchain
(`findDriver`). Only when that build fails does `elab` elaborate with the
project's `lean --json`, finding tactics by their text.
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

/-- The driver's source, compiled into the command (the lakefile's `needs` rebuilds this
module when it changes): `elab` builds the driver from it for a project on another Lean. -/
def driverSource : String := include_str "LeanprofElabDriver.lean"

def driverExe : String := "leanprof-elab-driver" ++ (if System.Platform.isWindows then ".exe" else "")

/-- The driver built with leanprof (next to this program), or `LEANPROF_ELAB_DRIVER`. -/
def bundledDriver : IO (Option FilePath) := do
  if let some p ← IO.getEnv "LEANPROF_ELAB_DRIVER" then
    return if p.isEmpty then none else some p
  let app ← IO.appPath
  let some dir := app.parent | return none
  let p := dir / driverExe
  return if ← p.pathExists then some p else none

/-- Where drivers built for other Lean versions are kept: `LEANPROF_CACHE`, else
`$XDG_CACHE_HOME/leanprof`, else `~/.cache/leanprof`. -/
def cacheDir : IO FilePath := do
  if let some d ← IO.getEnv "LEANPROF_CACHE" then if !d.isEmpty then return d
  if let some d ← IO.getEnv "XDG_CACHE_HOME" then if !d.isEmpty then return (d : FilePath) / "leanprof"
  let home := (← IO.getEnv "HOME").getD "."
  return (home : FilePath) / ".cache" / "leanprof"

/-- The Lean commit a program prints with `--githash`, or none when it does not run. -/
def githashOf (cmd : String) : IO (Option String) := do
  try
    let out ← IO.Process.output { cmd, args := #["--githash"] }
    let h := out.stdout.trimAscii.toString
    return if out.exitCode == 0 && !h.isEmpty then some h else none
  catch _ => return none

/-- Hex digits of a string's hash. -/
def hexHash (s : String) : String := String.ofList (Nat.toDigits 16 (hash s).toNat)

/-- Where the driver for the Lean at `sysroot` (commit `commit`) is kept:
`cacheDir/drivers/COMMIT-KEY/`, the key naming this driver source and that Lean's
directory (the driver is linked against that Lean's shared library, where it is). -/
def cachedDriverDir (sysroot : FilePath) (commit : String) : IO FilePath :=
  return (← cacheDir) / "drivers" / s!"{commit.take 12}-{hexHash (driverSource ++ "\x00" ++ sysroot.toString)}"

/-- The core shared libraries of the Lean at `sysroot` (`libInit_shared`,
`libleanshared`, `libleanshared_1`, ...), as linker flags: the driver's code calls
into each, and a linker does not look into a library's own dependencies. -/
def sharedLibFlags (lib : FilePath) : IO (Array String) := do
  let ext := if System.Platform.isOSX then ".dylib" else if System.Platform.isWindows then ".dll" else ".so"
  let names := (← lib.readDir).filterMap fun e =>
    let n := e.fileName
    if n.endsWith ext && (n.startsWith "libleanshared" || n.startsWith "libInit_shared") then
      let base := (n.drop 3).toString
      some (String.ofList (base.toList.take (base.length - ext.length)))
    else none
  return (names.qsort (· < ·)).map ("-l" ++ ·)

/-- Build the driver for the Lean at `sysroot` (commit `commit`) with that Lean:
`lean -c` on the driver's source, then `leanc`, linked against that Lean's shared
libraries (as `lean` itself is). Built in a directory of its own and moved into
place when it runs and reports `commit`, so a failed or concurrent build never
leaves a broken driver behind. -/
def buildDriver (sysroot : FilePath) (commit : String) (dir : FilePath) : IO (Except String FilePath) := do
  let final := dir / driverExe
  let stage : FilePath := dir.toString ++ s!".build-{← IO.Process.getPID}-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll stage
    let src := stage / "LeanprofElabDriver.lean"
    IO.FS.writeFile src driverSource
    let lib := sysroot / "lib" / "lean"
    -- that Lean's own library and compiler, not those of the project or of leanprof's `run`
    let env : Array (String × Option String) :=
      #[("LEAN_PATH", none), ("LEAN_SYSROOT", some sysroot.toString), ("LEAN_CC", none), ("LEAN_CFLAGS", none)]
    let steps : List (String × Array String) := [
      ((sysroot / "bin" / "lean").toString, #["-c", (stage / "driver.c").toString, src.toString]),
      ((sysroot / "bin" / "leanc").toString, #["-O3", "-o", (stage / driverExe).toString, (stage / "driver.c").toString,
        "-rdynamic", "-L", lib.toString, s!"-Wl,-rpath,{lib}"] ++ (← sharedLibFlags lib))]
    for (cmd, args) in steps do
      let out ← IO.Process.output { cmd, args, env, cwd := stage }
      if out.exitCode != 0 then
        let msg := (out.stdout ++ out.stderr).trimAscii.toString
        throw <| IO.userError s!"{(cmd : FilePath).fileName.getD cmd} failed: {String.ofList (msg.toList.take 600)}"
    if (← githashOf (stage / driverExe).toString) != some commit then
      throw <| IO.userError "the driver it built does not run"
    -- several `elab`s at once: the first to finish puts it in place, the others use it
    unless ← final.pathExists do
      IO.FS.createDirAll dir
      IO.FS.rename (stage / driverExe) final
    IO.FS.removeDirAll stage
    return .ok final
  catch e =>
    try IO.FS.removeDirAll stage catch _ => pure ()
    return .error s!"{e}"

/-- The driver to elaborate with, or why there is none. It must be built with the same
Lean (same commit) as the project's `lean`: the one built with leanprof when that is
the project's Lean, else the one built for the project's Lean, by that Lean, the
first time it is needed (`buildDriver`), and kept in `cacheDir` for the next runs.
`LEANPROF_ELAB_DRIVER` names a driver to use as it is. -/
def findDriver (lean : String) (sysroot : FilePath) : IO (Except String String) := do
  let some theirs ← githashOf lean | return .error s!"{lean} does not run"
  if let some p := (← IO.getEnv "LEANPROF_ELAB_DRIVER") then
    if p.isEmpty then return .error "LEANPROF_ELAB_DRIVER is empty"
    let some ours ← githashOf p | return .error s!"{p} does not run"
    if ours != theirs then
      return .error s!"the project's Lean ({theirs.take 12}) is not the one {p} was built with ({ours.take 12})"
    return .ok p
  -- the driver next to this program is built with this program's Lean
  if let some p ← bundledDriver then
    if Lean.githash == theirs then return .ok p.toString
  let dir ← cachedDriverDir sysroot theirs
  let cached := dir / driverExe
  if ← cached.pathExists then return .ok cached.toString
  -- `Lean (version 4.34.1, arm64-apple-darwin, commit ..., Release)` as `Lean 4.34.1`
  let version := match ((← IO.Process.output { cmd := lean, args := #["--version"] }).stdout.splitOn "version ")[1]? with
    | some v => s!"Lean {(v.splitOn ",").headD v}"
    | none => s!"Lean {theirs.take 12}"
  IO.eprintln s!"leanprof: building leanprof-elab-driver for the project's {version} (once; kept in {dir})"
  let t0 ← IO.monoMsNow
  match ← buildDriver sysroot theirs dir with
  | .ok p =>
    IO.eprintln s!"leanprof: built in {(← IO.monoMsNow) - t0} ms"
    return .ok p.toString
  | .error e =>
    return .error s!"the project's {version} is not the one leanprof was built with, and the driver could not be built for it: {e}"

end Leanprof.Elab
