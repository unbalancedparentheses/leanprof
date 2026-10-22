import Lean.Data.Json

/-!
# `lake exe leanprof`

* `run`: build an executable with leanprof's compiler wrapper (copy shims
  everywhere, optionally every function timed), run it, and remove the
  instrumented objects again so a later plain `lake build` does not reuse them.
* `compare`: compare two JSON reports. Copies and call counts are exact, so
  any increase is a regression; times use a relative threshold.
-/

open Lean System

def usage : String := "usage:
  lake exe leanprof run [--auto | --auto-all] [--trace FILE] [--json FILE] [--keep] EXE [-- ARGS...]
  lake exe leanprof compare [--threshold PCT] [--min-ms MS] BASE.json NEW.json"

/-- leanprof's package directory: this executable is `<root>/.lake/build/bin/leanprof`. -/
def packageRoot : IO FilePath := do
  let app ← IO.appPath
  match app.parent >>= (·.parent) >>= (·.parent) >>= (·.parent) with
  | some root => return root
  | none => throw <| IO.userError s!"cannot locate leanprof's package from {app}"

/-- Delete compiled C objects (`*.c.o*`) under `dir`; returns how many. -/
partial def removeObjects (dir : FilePath) : IO Nat := do
  unless ← dir.isDir do return 0
  let mut n := 0
  for e in ← dir.readDir do
    if ← e.path.isDir then
      n := n + (← removeObjects e.path)
    else if (e.fileName.splitOn ".c.o").length > 1 then
      IO.FS.removeFile e.path
      n := n + 1
  return n

/-- Objects of this workspace: the root package's and each dependency's. -/
def removeWorkspaceObjects : IO Nat := do
  let mut n ← removeObjects ((".lake" : FilePath) / "build" / "ir")
  let pkgs : FilePath := ".lake" / "packages"
  if ← pkgs.isDir then
    for e in ← pkgs.readDir do
      n := n + (← removeObjects (e.path / ".lake" / "build" / "ir"))
  return n

def spawnWait (cmd : String) (args : Array String) (env : Array (String × Option String)) : IO UInt32 := do
  let child ← IO.Process.spawn { cmd, args, env }
  child.wait

structure RunOpts where
  auto : Option String := none
  trace : Option String := none
  json : Option String := none
  keep : Bool := false
  exe : Option String := none
  args : Array String := #[]

partial def parseRun (opts : RunOpts) : List String → Except String RunOpts
  | [] => .ok opts
  | "--auto" :: rest => parseRun { opts with auto := some "1" } rest
  | "--auto-all" :: rest => parseRun { opts with auto := some "all" } rest
  | "--trace" :: f :: rest => parseRun { opts with trace := some f } rest
  | "--json" :: f :: rest => parseRun { opts with json := some f } rest
  | "--keep" :: rest => parseRun { opts with keep := true } rest
  | "--" :: rest => .ok { opts with args := opts.args ++ rest.toArray }
  | a :: rest =>
    if a.startsWith "--" then .error s!"unknown option {a}"
    else if opts.exe.isNone then parseRun { opts with exe := some a } rest
    else parseRun { opts with args := opts.args.push a } rest

def run (argv : List String) : IO UInt32 := do
  let opts ← IO.ofExcept (parseRun {} argv)
  let some exe := opts.exe | throw <| IO.userError usage
  let wrapper := (← packageRoot) / "scripts" / "leanprof-cc"
  unless ← wrapper.pathExists do
    throw <| IO.userError s!"compiler wrapper not found at {wrapper}"
  -- Lake does not notice a new LEAN_CC, so objects built without it must go.
  let removed ← removeWorkspaceObjects
  IO.eprintln s!"leanprof: building {exe} with copy shims{if opts.auto.isSome then " and every function timed" else ""} ({removed} stale objects removed)"
  let buildEnv := #[("LEAN_CC", some wrapper.toString), ("LEANPROF_AUTO", opts.auto)]
  let rc ← spawnWait "lake" #["build", exe] buildEnv
  if rc != 0 then
    discard <| removeWorkspaceObjects
    return rc
  let runEnv := #[("LEANPROF_TRACE", opts.trace), ("LEANPROF_JSON", opts.json)]
  let rc ← spawnWait ((".lake" : FilePath) / "build" / "bin" / exe).toString opts.args runEnv
  unless opts.keep do
    discard <| removeWorkspaceObjects
  return rc

/-! ## compare -/

structure Report where
  scopes : Std.HashMap String (Float × Nat) := {}  -- name@pos ↦ (total ns, calls)
  copies : Std.HashMap String Nat := {}            -- function|kind|scope ↦ copies

def num (j : Json) (k : String) : Float :=
  match j.getObjVal? k with
  | .ok (.num n) => n.toFloat
  | _ => 0

def str (j : Json) (k : String) : String :=
  (j.getObjVal? k >>= Json.getStr?).toOption.getD ""

def loadReport (path : String) : IO Report := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  let mut r : Report := {}
  for s in (j.getObjVal? "scopes" >>= Json.getArr?).toOption.getD #[] do
    let key := s!"{str s "name"} {str s "pos"}"
    r := { r with scopes := r.scopes.insert key (num s "total_ns", (num s "calls").toUInt64.toNat) }
  for c in (j.getObjVal? "copies" >>= Json.getArr?).toOption.getD #[] do
    let n := (num c "shared").toUInt64.toNat + (num c "multi_threaded").toUInt64.toNat
    if n > 0 then
      let key := s!"{str c "function"} [{str c "kind"}] in {str c "scope"}"
      r := { r with copies := r.copies.insert key (r.copies.getD key 0 + n) }
  return r

/-- `x` with two decimals. -/
def fmt2 (x : Float) : String :=
  let v := (x.abs * 100).round.toUInt64.toNat
  let frac := v % 100
  s!"{if x < 0 && v > 0 then "-" else ""}{v / 100}.{if frac < 10 then "0" else ""}{frac}"

def fmtMs (ns : Float) : String := s!"{fmt2 (ns / 1e6)} ms"

def compare (argv : List String) : IO UInt32 := do
  let rec parse (thr minMs : Float) (files : List String) : List String → Except String (Float × Float × List String)
    | [] => .ok (thr, minMs, files.reverse)
    | "--threshold" :: v :: rest => parse (v.toNat!.toFloat) minMs files rest
    | "--min-ms" :: v :: rest => parse thr (v.toNat!.toFloat) files rest
    | a :: rest => parse thr minMs (a :: files) rest
  let (thr, minMs, files) ← IO.ofExcept (parse 10 1 [] argv)
  let [basePath, newPath] := files | throw <| IO.userError usage
  let base ← loadReport basePath
  let new ← loadReport newPath
  let mut regressions := 0
  IO.println s!"scopes (time: regression above +{fmt2 thr}% and {fmt2 minMs} ms; calls: any change)"
  let keys := (base.scopes.toList.map (·.1) ++ new.scopes.toList.map (·.1)).eraseDups
  for k in keys do
    match base.scopes.get? k, new.scopes.get? k with
    | some (bt, bc), some (nt, nc) =>
      let pct := if bt > 0 then (nt - bt) / bt * 100 else 0
      let slower := pct > thr && (nt - bt) / 1e6 > minMs
      let callsChanged := bc != nc
      let mark := if slower || callsChanged then "REGRESSION" else if pct < -thr then "faster" else "ok"
      if slower || callsChanged then regressions := regressions + 1
      IO.println s!"  {mark}  {k}: {fmtMs bt} -> {fmtMs nt} ({fmt2 pct}%), calls {bc} -> {nc}"
    | none, some (nt, nc) => IO.println s!"  new  {k}: {fmtMs nt}, calls {nc}"
    | some (bt, _), none => IO.println s!"  gone {k}: was {fmtMs bt}"
    | none, none => pure ()
  IO.println "copies of shared or multi-threaded values (any increase is a regression)"
  let ckeys := (base.copies.toList.map (·.1) ++ new.copies.toList.map (·.1)).eraseDups
  for k in ckeys do
    let b := base.copies.getD k 0
    let n := new.copies.getD k 0
    if n > b then
      regressions := regressions + 1
      IO.println s!"  REGRESSION  {k}: {b} -> {n}"
    else if n < b then
      IO.println s!"  fewer  {k}: {b} -> {n}"
  if regressions == 0 then
    IO.println "no regressions"
    return 0
  IO.println s!"{regressions} regressions"
  return 1

def main (argv : List String) : IO UInt32 := do
  try
    match argv with
    | "run" :: rest => run rest
    | "compare" :: rest => compare rest
    | _ =>
      IO.eprintln usage
      return 2
  catch e =>
    IO.eprintln s!"leanprof: {e}"
    return 2
