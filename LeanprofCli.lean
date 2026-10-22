import Lean.Data.Json
import Leanprof.Core

/-!
# `lake exe leanprof`

* `run`: build an executable with leanprof's compiler wrapper (copy shims
  everywhere, optionally every function timed), run it, and remove the
  instrumented objects again so a later plain `lake build` does not reuse them.
* `sample`: build normally and run under samply (no instrumentation), then
  report CPU time per Lean declaration with source positions, and rewrite
  samply's symbols so `samply load` shows Lean names.
* `compare`: compare two JSON reports. Copies and call counts are exact, so
  any increase is a regression; times use a relative threshold.
-/

open Lean System

def usage : String := "usage:
  lake exe leanprof run [--auto | --auto-all] [--trace FILE] [--json FILE] [--keep] EXE [-- ARGS...]
  lake exe leanprof sample [--rate HZ] [--out FILE] [--top N] EXE [-- ARGS...]
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
  -- the report `#leanprof` reads, unless another path was asked for
  IO.FS.createDirAll ((".lake" : FilePath) / "leanprof")
  let json := opts.json.getD ".lake/leanprof/report.json"
  let runEnv := #[("LEANPROF_TRACE", opts.trace), ("LEANPROF_JSON", some json)]
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

/-! ## sample -/

structure SampleOpts where
  rate : Nat := 4000
  out : Option String := none
  top : Nat := 25
  exe : Option String := none
  args : Array String := #[]

partial def parseSample (o : SampleOpts) : List String → Except String SampleOpts
  | [] => .ok o
  | "--rate" :: v :: rest => parseSample { o with rate := v.toNat! } rest
  | "--out" :: f :: rest => parseSample { o with out := some f } rest
  | "--top" :: v :: rest => parseSample { o with top := v.toNat! } rest
  | "--" :: rest => .ok { o with args := o.args ++ rest.toArray }
  | a :: rest =>
    if a.startsWith "--" then .error s!"unknown option {a}"
    else if o.exe.isNone then parseSample { o with exe := some a } rest
    else parseSample { o with args := o.args.push a } rest

def getArr (j : Json) (k : String) : Array Json := (j.getObjVal? k >>= Json.getArr?).toOption.getD #[]
def getNatAt (a : Array Json) (i : Nat) : Option Nat := (a[i]? >>= fun x => x.getNat?.toOption)

/-- Symbols defined in `bin`, as `nm` lists them (Mach-O's leading `_` removed). -/
def binarySymbols (bin : FilePath) : IO (Array String) := do
  let out ← IO.Process.output { cmd := "nm", args := #[bin.toString] }
  let mut syms := #[]
  for line in out.stdout.splitOn "\n" do
    match (line.splitOn " ").filter (· != "") with
    | [_, _, name] | [_, name] =>
      syms := syms.push (if System.Platform.isOSX && name.startsWith "_" then (name.drop 1).toString else name)
    | _ => pure ()
  return syms

/-- One library's symbols from samply's sidecar: sorted (start, end, name). -/
def libSymbols (lib : Json) (strings : Array String) : Array (Nat × Nat × String) := Id.run do
  let mut v := #[]
  for e in getArr lib "symbol_table" do
    let rva := (e.getObjVal? "rva" >>= Json.getNat?).toOption.getD 0
    let size := (e.getObjVal? "size" >>= Json.getNat?).toOption.getD 0
    let sym := (e.getObjVal? "symbol" >>= Json.getNat?).toOption.getD 0
    v := v.push (rva, rva + size, strings[sym]?.getD "?")
  return v.qsort (·.1 < ·.1)

def lookupSym (tbl : Array (Nat × Nat × String)) (addr : Nat) : Option String := Id.run do
  let mut lo := 0
  let mut hi := tbl.size
  while lo < hi do
    let mid := (lo + hi) / 2
    if tbl[mid]!.1 ≤ addr then lo := mid + 1 else hi := mid
  if lo == 0 then return none
  let (s, e, n) := tbl[lo - 1]!
  if s ≤ addr && addr < e then some n else none

/-- What a runtime (non-Lean) function is spending time on, for the
breakdown; `none` for code that is neither the Lean runtime nor leanprof. -/
def runtimeCategory (raw : String) : Option String :=
  let r := if raw.startsWith "_" then (raw.drop 1).toString else raw
  let has (p : String) := (r.splitOn p).length > 1
  if r.startsWith "leanprof_" || r.startsWith "lpf_" || r.startsWith "__cyg_profile" then some "leanprof itself"
  else if has "lean_copy_" then some "copying non-exclusive values"
  else if has "lean_mark_mt" || has "lean_mark_persistent" then some "marking objects multi-threaded/persistent"
  else if has "lean_dec_ref" || has "lean_del_core" || has "lean_free" || has "del_core" then some "freeing objects (reference counts reaching zero)"
  else if has "lean_alloc" || r.startsWith "mi_" || has "malloc" || has "mi_page" then some "allocation"
  else if has "lean_apply" then some "applying closures"
  else if has "gmpz" || has "lean_nat_big" || has "mpz" then some "big-number arithmetic"
  else if r.startsWith "lean_" || has "lean::" then some "other Lean runtime"
  else none

def sample (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseSample {} argv)
  let some exe := o.exe | throw <| IO.userError usage
  let rc ← spawnWait "lake" #["build", exe] #[]
  if rc != 0 then return rc
  let bin : FilePath := (".lake" : FilePath) / "build" / "bin" / exe
  let out : FilePath := o.out.getD s!".lake/leanprof/{exe}.json"
  if let some dir := out.parent then IO.FS.createDirAll dir
  let rc ← spawnWait "samply" (#["record", "--save-only", "--unstable-presymbolicate", "--rate", toString o.rate,
    "-o", out.toString, bin.toString] ++ o.args) #[("LEANPROF_QUIET", some "1")]
  if rc != 0 then
    IO.eprintln s!"leanprof: samply exited with {rc} (is it installed? brew install samply / cargo install samply)"
    return rc
  let symsPath : FilePath := out.withExtension "syms.json"
  let profile ← IO.ofExcept (Json.parse (← IO.FS.readFile out))
  let syms ← IO.ofExcept (Json.parse (← IO.FS.readFile symsPath))
  let strings := (getArr syms "string_table").map fun j => j.getStr?.toOption.getD "?"
  Leanprof.setSymbols (← binarySymbols bin)
  -- per library: symbol table, and whether it is the profiled binary
  let libsMeta := getArr profile "libs"
  let symData := getArr syms "data"
  let mut libTables : Array (Array (Nat × Nat × String)) := #[]
  let mut libIsMain : Array Bool := #[]
  for l in libsMeta do
    let dn := str l "debugName"
    let entry := symData.find? fun e => str e "debug_name" == dn
    libTables := libTables.push (entry.map (libSymbols · strings) |>.getD #[])
    libIsMain := libIsMain.push (dn == exe)
  -- CPU time per display name: self (leaf) and inclusive (anywhere in the stack)
  let mut selfT : Std.HashMap String Float := {}
  let mut inclT : Std.HashMap String Float := {}
  let mut total : Float := 0
  let mut names : Std.HashMap String String := {}  -- raw symbol ↦ display name
  let mut leanDecls : Std.HashSet String := {}       -- display names that are Lean declarations
  let mut categories : Std.HashMap String String := {} -- display name ↦ runtime category
  let mut catT : Std.HashMap String Float := {}
  for t in getArr profile "threads" do
    let samples ← IO.ofExcept (t.getObjVal? "samples")
    let stacks := getArr samples "stack"
    let deltas := getArr samples "threadCPUDelta"
    let st ← IO.ofExcept (t.getObjVal? "stackTable")
    let parents := getArr st "prefix"
    let frameOf := getArr st "frame"
    let ft ← IO.ofExcept (t.getObjVal? "frameTable")
    let addrs := getArr ft "address"
    let funcOf := getArr ft "func"
    let fu ← IO.ofExcept (t.getObjVal? "funcTable")
    let resOf := getArr fu "resource"
    let rt ← IO.ofExcept (t.getObjVal? "resourceTable")
    let libOf := getArr rt "lib"
    -- display name of each frame, computed once
    let mut frameName : Array String := #[]
    for i in [0:addrs.size] do
      let addr := getNatAt addrs i |>.getD 0
      let lib := (getNatAt funcOf i >>= getNatAt resOf >>= getNatAt libOf).getD 0
      let raw := (libTables[lib]? >>= (lookupSym · addr)).getD s!"0x{String.ofList (Nat.toDigits 16 addr)}"
      let isMain := libIsMain[lib]?.getD false
      let disp ← match names.get? raw with
        | some d => pure d
        | none => do
          let d := if isMain then Leanprof.demangle raw else s!"[{(str (libsMeta[lib]?.getD Json.null) "name")}] {raw}"
          names := names.insert raw d
          let r := if raw.startsWith "_" then (raw.drop 1).toString else raw
          if isMain && (r.startsWith "l_" || r.startsWith "lp_" || r == "_lean_main" || r == "lean_main") then
            leanDecls := leanDecls.insert d
          if isMain then
            if let some c := runtimeCategory raw then categories := categories.insert d c
          pure d
      frameName := frameName.push disp
    for i in [0:stacks.size] do
      let some s0 := getNatAt stacks i | continue
      let w : Float := match deltas[i]? with
        | some (.num n) => n.toFloat
        | _ => 1000
      if w == 0 then continue
      total := total + w
      let mut seen : Std.HashSet String := {}
      let mut s? := some s0
      let mut leaf := true
      while true do
        let some s := s? | break
        let f := getNatAt frameOf s |>.getD 0
        let n := frameName[f]?.getD "?"
        if leaf then
          selfT := selfT.insert n (selfT.getD n 0 + w)
          if let some c := categories.get? n then catT := catT.insert c (catT.getD c 0 + w)
          leaf := false
        unless seen.contains n do
          inclT := inclT.insert n (inclT.getD n 0 + w)
          seen := seen.insert n
        s? := getNatAt parents s
  -- report
  let fmtCpu (us : Float) : String := s!"{fmt2 (us / 1000)} ms"
  let pct (us : Float) : String := s!"{fmt2 (if total > 0 then us / total * 100 else 0)}%"
  IO.println s!"\nleanprof sample: {exe}, {fmtCpu total} CPU sampled at {o.rate} Hz (samply, no instrumentation)"
  let pad (s : String) (n : Nat) := s.pushn ' ' (n - s.length)
  IO.println "\n  where the Lean runtime's time went (self time)"
  for (c, w) in (catT.toArray.qsort (fun a b => a.2 > b.2)).toList do
    IO.println s!"  {pad (fmtCpu w) 12} {pad (pct w) 8} {c}"
  IO.println s!"\n  top {o.top} functions by self CPU time"
  let bySelf := selfT.toArray.qsort (fun a b => a.2 > b.2)
  for (n, w) in bySelf.toList.take o.top do
    let wh ← Leanprof.whereIs n
    IO.println s!"  {(fmtCpu w).pushn ' ' (12 - (fmtCpu w).length)} {(pct w).pushn ' ' (8 - (pct w).length)} {n}{if wh.isEmpty then "" else s!"  ({wh})"}"
  IO.println s!"\n  top {o.top} Lean declarations by inclusive CPU time"
  let leanIncl := (inclT.toArray.filter fun (n, _) => leanDecls.contains n && !n.startsWith "initialize_").qsort (fun a b => a.2 > b.2)
  for (n, w) in leanIncl.toList.take o.top do
    let wh ← Leanprof.whereIs n
    IO.println s!"  {(fmtCpu w).pushn ' ' (12 - (fmtCpu w).length)} {(pct w).pushn ' ' (8 - (pct w).length)} {n}{if wh.isEmpty then "" else s!"  ({wh})"}"
  -- Lean names for Firefox Profiler: rewrite the sidecar's strings
  let renamed := strings.map fun r => names.getD r r
  let syms' := syms.setObjVal! "string_table" (Json.arr (renamed.map Json.str))
  IO.FS.writeFile symsPath syms'.compress
  -- a report `#leanprof` can show in the editor: sampled CPU per declaration
  let mut scopes : Array Json := #[]
  for (n, w) in leanIncl.toList do
    let wh ← Leanprof.whereIs n
    if wh.isEmpty then continue
    scopes := scopes.push <| Json.mkObj [("name", Json.str n), ("pos", Json.str wh), ("auto", Json.bool true),
      ("total_ns", toJson (w * 1000)), ("self_ns", toJson (selfT.getD n 0 * 1000)), ("calls", toJson (0 : Nat))]
  let report := Json.mkObj [("version", toJson (3 : Nat)), ("sampled", Json.bool true),
    ("wall_ns", toJson (total * 1000)), ("scopes", Json.arr scopes), ("copies", Json.arr #[])]
  IO.FS.writeFile ".lake/leanprof/report.json" report.compress
  IO.println s!"\nflamegraph with Lean names: samply load {out}"
  IO.println "in the editor: add `#leanprof` to a file to see these numbers next to its code"
  return 0

def main (argv : List String) : IO UInt32 := do
  try
    match argv with
    | "run" :: rest => run rest
    | "compare" :: rest => compare rest
    | "sample" :: rest => sample rest
    | _ =>
      IO.eprintln usage
      return 2
  catch e =>
    IO.eprintln s!"leanprof: {e}"
    return 2
