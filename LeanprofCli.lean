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
* `elab`: elaborate files with `trace.profiler` and report compile time per
  declaration (elaboration, kernel, compiler, linters), for `#leanprof` too.
* `compare`: compare two JSON reports. Copies and call counts are exact, so
  any increase is a regression; times use a relative threshold.
* `measure` and `judge`: the harness of an autoresearch loop. `measure` runs
  an executable several times with copy detection and writes one summary
  (time spread, copies, calls, compile heartbeats, exit code, output hash);
  `judge` compares two summaries and prints KEEP or DISCARD.
-/

open Lean System

def usage : String := "usage:
  lake exe leanprof run [--auto | --auto-all] [--trace FILE] [--json FILE] [--keep] EXE [-- ARGS...]
  lake exe leanprof sample [--rate HZ] [--out FILE] [--top N] EXE [-- ARGS...]
  lake exe leanprof elab [--heartbeats] [--top N] [--out FILE] FILE.lean...
  lake exe leanprof compare [--threshold PCT] [--min-ms MS] BASE.json NEW.json
  lake exe leanprof measure [--runs N] [--warmup N] [--heartbeats-files F.lean...] [--check-output FILE] [--out FILE] EXE [-- ARGS...]
  lake exe leanprof judge BASE.json NEW.json"

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

/-- Build `exe` with the copy shims in every package (and, with `auto`, every
function timed). A project that does not depend on leanprof gets leanprof's
runtime compiled for its own Lean version, linked in by the wrapper. A failed
build removes the instrumented objects again. -/
def buildWithShims (exe : String) (auto : Option String) : IO UInt32 := do
  let root ← packageRoot
  let wrapper := root / "scripts" / "leanprof-cc"
  unless ← wrapper.pathExists do
    throw <| IO.userError s!"compiler wrapper not found at {wrapper}"
  let cwd ← IO.currentDir
  let linked := (← ((".lake" : FilePath) / "packages" / "leanprof").pathExists) ||
    (← IO.FS.realPath root) == (← IO.FS.realPath cwd)
  let mut runtimeEnv : Array (String × Option String) := #[]
  unless linked do
    let leanPrefix := (← IO.Process.output { cmd := "lean", args := #["--print-prefix"] }).stdout.trimAscii.toString
    IO.FS.createDirAll ((".lake" : FilePath) / "leanprof")
    let obj := cwd / ".lake" / "leanprof" / "runtime.o"
    let out ← IO.Process.output { cmd := "cc", args := #["-O2", "-fPIC", "-I", leanPrefix ++ "/include", "-c",
      (root / "c" / "leanprof.c").toString, "-o", obj.toString] }
    if out.exitCode != 0 then
      throw <| IO.userError s!"compiling leanprof's runtime failed:\n{out.stderr}"
    runtimeEnv := #[("LEANPROF_RUNTIME", some obj.toString)]
  -- Lake does not notice a new LEAN_CC, so objects built without it must go.
  let removed ← removeWorkspaceObjects
  IO.eprintln s!"leanprof: building {exe} with copy shims{if auto.isSome then " and every function timed" else ""} ({removed} stale objects removed)"
  let buildEnv := #[("LEAN_CC", some wrapper.toString), ("LEANPROF_AUTO", auto)] ++ runtimeEnv
  let rc ← spawnWait "lake" #["build", exe] buildEnv
  if rc != 0 then
    discard <| removeWorkspaceObjects
  return rc

/-- The executable Lake builds for `exe`. -/
def exePath (exe : String) : FilePath := (".lake" : FilePath) / "build" / "bin" / exe

def run (argv : List String) : IO UInt32 := do
  let opts ← IO.ofExcept (parseRun {} argv)
  let some exe := opts.exe | throw <| IO.userError usage
  let rc ← buildWithShims exe opts.auto
  if rc != 0 then return rc
  -- the report `#leanprof` reads, unless another path was asked for
  IO.FS.createDirAll ((".lake" : FilePath) / "leanprof")
  let json := opts.json.getD ".lake/leanprof/report.json"
  let runEnv := #[("LEANPROF_TRACE", opts.trace), ("LEANPROF_JSON", some json)]
  let rc ← spawnWait (exePath exe).toString opts.args runEnv
  unless opts.keep do
    discard <| removeWorkspaceObjects
  return rc

/-! ## compare -/

structure Report where
  exact : Bool := false                            -- heartbeats: compare without a threshold
  scopes : Std.HashMap String (Float × Nat) := {}  -- name@pos ↦ (total ns or heartbeats, calls)
  copies : Std.HashMap String Nat := {}            -- function|kind|scope ↦ copies

def num (j : Json) (k : String) : Float :=
  match j.getObjVal? k with
  | .ok (.num n) => n.toFloat
  | _ => 0

def str (j : Json) (k : String) : String :=
  (j.getObjVal? k >>= Json.getStr?).toOption.getD ""

def loadReport (path : String) : IO Report := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  let mut r : Report := { exact := str j "unit" == "heartbeats" }
  for s in (j.getObjVal? "scopes" >>= Json.getArr?).toOption.getD #[] do
    let key := if (str s "key").isEmpty then s!"{str s "name"} {str s "pos"}" else str s "key"
    -- a declaration's elaboration, kernel and compiler lines share its key
    let (t, c) := r.scopes.getD key (0, 0)
    r := { r with scopes := r.scopes.insert key (t + num s "total_ns", c + (num s "calls").toUInt64.toNat) }
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
      -- heartbeats do not vary between runs, but editing one declaration moves
      -- its neighbours by a few: count increases above 1% and 1,000 heartbeats
      let slower := if base.exact && new.exact then nt - bt > max (bt * 0.01) 1000
        else pct > thr && (nt - bt) / 1e6 > minMs
      let callsChanged := bc != nc
      let mark := if slower || callsChanged then "REGRESSION" else if pct < -thr then "faster" else "ok"
      if slower || callsChanged then regressions := regressions + 1
      let amt (x : Float) := if base.exact then s!"{fmt2 (x / 1000)} kHB" else fmtMs x
      IO.println s!"  {mark}  {k}: {amt bt} -> {amt nt} ({fmt2 pct}%), calls {bc} -> {nc}"
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

/-! ## elab

`trace.profiler` attaches, to each source position, a tree of timed
operations printed as indented lines: `[Class] [amount] mark text`, where the
amount is seconds, or heartbeats with `trace.profiler.useHeartbeats`.
-/

/-- One operation in a trace tree. -/
structure TNode where
  cls : String
  amount : Float           -- seconds or heartbeats, inclusive
  text : String            -- first line of the operation's description
  depth : Nat
  children : Array Nat := #[]
  parent : Option Nat := none
  deriving Inhabited

/-- `[Class] [amount] ...` at the start of a trace line, with its indentation. -/
def traceLine (line : String) : Option (Nat × String × Float × String) := do
  let cs := line.toList
  let indent := (cs.takeWhile (· == ' ')).length
  let cs := cs.drop indent
  guard (cs.head? == some '[')
  let cls := (cs.drop 1).takeWhile (· != ']')
  let rest := ((cs.drop 1).drop (cls.length + 1)).dropWhile (· == ' ')
  guard (rest.head? == some '[')
  let amt := (rest.drop 1).takeWhile (· != ']')
  let ip := amt.takeWhile (· != '.')
  let fp := (amt.dropWhile (· != '.')).drop 1
  let i ← (String.ofList ip).toNat?
  let f := (String.ofList fp).toNat?.getD 0
  let text := ((rest.drop 1).drop (amt.length + 1)).dropWhile (· == ' ')
  -- drop the status mark (✅️, ❌️, 💥️: a symbol and a variation selector)
  let text := match text with
    | _ :: '️' :: ' ' :: t => t
    | t => t
  return (indent, String.ofList cls, i.toFloat + f.toFloat / (10 : Float) ^ fp.length.toFloat, String.ofList text)

/-- Parse one message's trace into nodes (index 0 is the root). -/
def parseTrace (data : String) : Array TNode := Id.run do
  let mut nodes : Array TNode := #[]
  let mut stack : Array Nat := #[]  -- open nodes by indentation
  for line in data.splitOn "\n" do
    match traceLine line with
    | some (indent, cls, amount, text) =>
      while !stack.isEmpty && nodes[stack.back!]!.depth >= indent do
        stack := stack.pop
      let parent := stack.back?
      let i := nodes.size
      nodes := nodes.push { cls, amount, text, depth := indent, parent }
      if let some p := parent then
        nodes := nodes.modify p fun n => { n with children := n.children.push i }
      stack := stack.push i
    | none =>
      -- continuation of a multi-line description: part of the operation
      if let some last := stack.back? then
        let t := String.ofList (line.toList.dropWhile (· == ' '))
        if !t.isEmpty && nodes[last]!.text.length < 160 then
          nodes := nodes.modify last fun n => { n with text := n.text ++ " " ++ t }
  return nodes

/-- Merge operations that differ only in metavariable numbers (`?m.123`). -/
def normalizeOp (t : String) : String := Id.run do
  let mut out : List Char := []
  let mut cs := t.toList
  while !cs.isEmpty do
    match cs with
    | '?' :: rest =>
      let name := rest.takeWhile (fun c => c.isAlpha || c == '_')
      let after := rest.drop name.length
      if after.head? == some '.' && ((after.drop 1).head?.map Char.isDigit).getD false then
        out := out ++ '?' :: name ++ ['.', 'n']
        cs := (after.drop 1).dropWhile Char.isDigit
      else
        out := out ++ ['?']
        cs := rest
    | c :: rest =>
      out := out ++ [c]
      cs := rest
    | [] => break
  return String.ofList (out.take 120)

/-- Classes whose repeated identical operations are worth reporting. -/
def repeatable (cls : String) : Bool :=
  cls == "Meta.synthInstance" || cls == "Meta.isDefEq" || cls == "Meta.whnf" ||
    cls == "Meta.isDefEq.delta" || cls == "Elab.step" || cls.startsWith "Meta.Tactic" || cls == "Tactic.simp"

structure LineCost where
  total : Float := 0
  elaboration : Float := 0
  kernel : Float := 0
  compile : Float := 0
  lint : Float := 0
  name : String := ""
  top : Array (Float × String) := #[]  -- most expensive nested operations

/-- The declared name in a command's text (`theorem foo ...` gives `foo`),
when it has one. -/
def declName (text : String) : Option String := Id.run do
  let words := (text.splitOn " ").filter (· != "")
  let kws := ["def", "theorem", "lemma", "abbrev", "instance", "structure", "inductive", "class", "opaque",
    "axiom"]
  for i in [0:words.length] do
    if kws.contains words[i]! then
      if let some w := words[i + 1]? then
        if !(w.startsWith "(" || w.startsWith "[" || w.startsWith "{" || w.startsWith ":" || w.startsWith "⦃") then
          return some w
      return none
  return none

/-- A command's text without its leading doc comment, so a documented
declaration is named after the declaration. -/
def dropDocComment (text : String) : String :=
  if text.startsWith "/--" then
    match text.splitOn "-/" with
    | _ :: rest@(_ :: _) => ("-/".intercalate rest).trimAscii.toString
    | _ => text
  else text

/-- `File.lean:12` as (file, line). -/
def splitPos (k : String) : String × Nat :=
  match k.splitOn ":" with
  | [f, l] => (f, l.toNat!)
  | _ => (k, 0)

/-- Name of the declaration that starts closest above `key` in its file. -/
def ownerName (named : Array (String × LineCost)) (key : String) : String := Id.run do
  let (f, l) := splitPos key
  let mut best := 0
  let mut name := ""
  for (k, c) in named do
    let (f', l') := splitPos k
    if f' == f && l' ≤ l && l' ≥ best then
      best := l'
      name := c.name
  return name

structure OpCost where
  count : Nat := 0
  total : Float := 0
  maxOne : Float := 0
  firstAt : String := ""

def elabCmd (argv : List String) : IO UInt32 := do
  let rec parse (top : Nat) (hb : Bool) (out : String) (files : List String) :
      List String → Nat × Bool × String × List String
    | [] => (top, hb, out, files.reverse)
    | "--top" :: v :: rest => parse v.toNat! hb out files rest
    | "--heartbeats" :: rest => parse top true out files rest
    | "--out" :: f :: rest => parse top hb f files rest
    | f :: rest => parse top hb out (f :: files) rest
  let (top, hb, outPath, files) := parse 15 false ".lake/leanprof/elab.json" [] argv
  if files.isEmpty then throw <| IO.userError usage
  -- amounts: nanoseconds, or heartbeats (exact, the same on every run)
  let scale : Float := if hb then 1 else 1e9
  let fmtAmt (x : Float) : String := if hb then s!"{fmt2 (x / 1000)} kHB" else fmtMs x
  let mut lines : Std.HashMap String LineCost := {}
  let mut byClass : Std.HashMap String Float := {}
  let mut ops : Std.HashMap (String × String) OpCost := {}
  let mut grand : Float := 0
  for file in files do
    let mut args := #["env", "lean", "--json", "-Dtrace.profiler=true", "-Dtrace.profiler.threshold=0"]
    if hb then args := args.push "-Dtrace.profiler.useHeartbeats=true"
    let out ← IO.Process.output { cmd := "lake", args := args.push file }
    for msgLine in out.stdout.splitOn "\n" do
      let some m := (Json.parse msgLine).toOption | continue
      let nodes := parseTrace (str m "data")
      let some root := nodes[0]? | continue
      let ln := ((m.getObjVal? "pos" >>= (·.getObjVal? "line")) >>= Json.getNat?).toOption.getD 0
      let key := s!"{file}:{ln}"
      let rootAmt := root.amount * scale
      grand := grand + rootAmt
      -- per line: total and kind
      let mut c := lines.getD key {}
      c := { c with total := c.total + rootAmt }
      if root.cls == "Elab.async" then
        match (nodes[1]?.map (·.cls)) with
        | some "Kernel" => c := { c with kernel := c.kernel + rootAmt }
        | some "Compiler" => c := { c with compile := c.compile + rootAmt }
        | some "Elab.lint" => c := { c with lint := c.lint + rootAmt }
        | _ => c := { c with elaboration := c.elaboration + rootAmt }
      else
        c := { c with elaboration := c.elaboration + rootAmt }
        if root.cls == "Elab.command" && c.name.isEmpty then
          c := { c with name := String.ofList ((dropDocComment root.text).toList.take 60) }
      -- self time per class; repeated operations; the line's heaviest nested operations
      for i in [0:nodes.size] do
        let n := nodes[i]!
        let childSum := n.children.foldl (fun acc j => acc + nodes[j]!.amount) 0
        let self := max 0 (n.amount - childSum) * scale
        byClass := byClass.insert n.cls (byClass.getD n.cls 0 + self)
        if i > 0 && repeatable n.cls then
          -- only the outermost of a nest of the same class
          let nested := Id.run do
            let mut p := n.parent
            let mut found := false
            while true do
              let some q := p | break
              if nodes[q]!.cls == n.cls then found := true; break
              p := nodes[q]!.parent
            return found
          unless nested do
            let k := (n.cls, normalizeOp n.text)
            let o := ops.getD k {}
            let amt := n.amount * scale
            ops := ops.insert k { count := o.count + 1, total := o.total + amt, maxOne := max o.maxOne amt,
                                  firstAt := if o.firstAt.isEmpty then key else o.firstAt }
            c := { c with top := c.top.push (amt, s!"[{n.cls}] {normalizeOp n.text}") }
      -- the line's heaviest operations, ignoring those under 1% of it
      c := { c with top := (((c.top.filter (·.1 ≥ c.total * 0.01)).qsort (fun a b => a.1 > b.1)).toList.take 5).toArray }
      lines := lines.insert key c
  let pad (t : String) (w : Nat) := t.pushn ' ' (w - t.length)
  let pct (x : Float) := s!"{fmt2 (if grand > 0 then x / grand * 100 else 0)}%"
  IO.println s!"\nleanprof elab: {files.length} files, {fmtAmt grand} {if hb then "(heartbeats, exact)" else "compile time"}"
  -- where compile time went
  IO.println "\n  where compile time went (self, by operation kind)"
  for (cls, x) in ((byClass.toArray.qsort (fun a b => a.2 > b.2)).toList.take top) do
    IO.println s!"  {pad (fmtAmt x) 12} {pad (pct x) 8} {cls}"
  -- costliest lines
  -- kernel and compiler work can sit on a line of its own: name it after the
  -- declaration that starts closest above it
  let named := lines.toArray.filter (!·.2.name.isEmpty)
  let lineCosts : Array (String × LineCost) := lines.toArray.map fun (k, c) =>
    if c.name.isEmpty then (k, { c with name := ownerName named k }) else (k, c)
  let rows := (lineCosts.filter (·.2.total > 0)).qsort (fun a b => a.2.total > b.2.total)
  IO.println s!"\n  costliest lines (elab / kernel / compiler / lint)"
  for (k, c) in rows.toList.take top do
    IO.println s!"  {pad (fmtAmt c.total) 12} {pad (fmtAmt c.elaboration) 11}/ {pad (fmtAmt c.kernel) 10}/ {pad (fmtAmt c.compile) 10}/ {pad (fmtAmt c.lint) 10} {k}  {c.name.replace "\n" " "}"
    for (amt, op) in c.top.toList.take 3 do
      IO.println s!"      {pad (fmtAmt amt) 12} {String.ofList (op.toList.take 100)}"
  -- repeated work
  let reps := (ops.toArray.filter (·.2.count > 1)).qsort (fun a b => a.2.total > b.2.total)
  if !reps.isEmpty then
    IO.println "\n  repeated work (the same operation done more than once)"
    for ((cls, op), o) in reps.toList.take top do
      IO.println s!"  {pad (fmtAmt o.total) 12} {pad s!"{o.count}×" 6} [{cls}] {String.ofList (op.toList.take 90)}  (first at {o.firstAt})"
  -- for #leanprof and compare
  let scopes := rows.map fun (k, c) => Json.mkObj [("name", Json.str (c.name.replace "\n" " ")), ("pos", Json.str k),
    -- what `compare` matches on: the declaration, so edits that move lines still compare
    ("key", Json.str ((declName c.name).map (fun d => s!"{(splitPos k).1} {d}") |>.getD k)),
    ("total_ns", toJson c.total), ("elab_ns", toJson c.elaboration), ("kernel_ns", toJson c.kernel),
    ("compile_ns", toJson c.compile), ("lint_ns", toJson c.lint),
    ("top", Json.arr (c.top.map fun (a, op) => Json.mkObj [("amount", toJson a), ("op", Json.str op)]))]
  let repeated := reps.map fun ((cls, op), o) => Json.mkObj [("class", Json.str cls), ("op", Json.str op),
    ("count", toJson o.count), ("total", toJson o.total), ("first_at", Json.str o.firstAt)]
  if let some dir := (outPath : FilePath).parent then IO.FS.createDirAll dir
  IO.FS.writeFile outPath
    (Json.mkObj [("version", toJson (3 : Nat)), ("elab", Json.bool true),
      ("unit", Json.str (if hb then "heartbeats" else "ns")), ("wall_ns", toJson grand),
      ("scopes", Json.arr scopes), ("repeated", Json.arr repeated), ("copies", Json.arr #[])]).compress
  IO.println s!"\nwritten to {outPath}; `#leanprof` shows it next to the code"
  return 0

/-! ## measure and judge

The harness of an autoresearch loop (an agent edits code, measures, and keeps
the change only if it is better): `measure` builds a program with copy
detection, runs it several times and writes one summary; `judge` compares two
summaries and says KEEP or DISCARD.
-/

structure MeasureOpts where
  runs : Nat := 5
  warmup : Nat := 1
  hbFiles : Array String := #[]
  checkOutput : Option String := none
  out : String := ".lake/leanprof/measure.json"
  exe : Option String := none
  args : Array String := #[]

partial def parseMeasure (o : MeasureOpts) : List String → Except String MeasureOpts
  | [] => .ok o
  | "--runs" :: v :: rest => parseMeasure { o with runs := max 1 v.toNat! } rest
  | "--warmup" :: v :: rest => parseMeasure { o with warmup := v.toNat! } rest
  | "--out" :: f :: rest => parseMeasure { o with out := f } rest
  | "--check-output" :: f :: rest => parseMeasure { o with checkOutput := some f } rest
  | "--heartbeats-files" :: rest =>
    -- every `.lean` argument that follows
    let fs := rest.takeWhile (·.endsWith ".lean")
    parseMeasure { o with hbFiles := o.hbFiles ++ fs.toArray } (rest.drop fs.length)
  | "--" :: rest => .ok { o with args := o.args ++ rest.toArray }
  | a :: rest =>
    if a.startsWith "--" then .error s!"unknown option {a}"
    else if o.exe.isNone then parseMeasure { o with exe := some a } rest
    else parseMeasure { o with args := o.args.push a } rest

/-- 64-bit FNV-1a of `b` as 16 hex digits: a stable fingerprint of a
program's output (not cryptographic). -/
def fnv1a (b : ByteArray) : String := Id.run do
  let mut h : UInt64 := 14695981039346656037
  for x in b do
    h := (h ^^^ x.toUInt64) * 1099511628211
  let hex := Nat.toDigits 16 h.toNat
  return "fnv1a64:" ++ String.ofList (List.replicate (16 - hex.length) '0' ++ hex)

/-- Median of a non-empty array. -/
def median (xs : Array Nat) : Nat :=
  let s := xs.qsort (· < ·)
  if s.size % 2 == 1 then s[s.size / 2]! else (s[s.size / 2 - 1]! + s[s.size / 2]!) / 2

/-- `[{"key": k, field: v}, ...]`, sorted by key so summaries diff cleanly. -/
def keyedArr (field : String) (xs : List (String × Json)) : Json :=
  Json.arr ((xs.toArray.qsort (·.1 < ·.1)).map fun (k, v) => Json.mkObj [("key", Json.str k), (field, v)])

def measureCmd (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseMeasure {} argv)
  let some exe := o.exe | throw <| IO.userError usage
  let rc ← buildWithShims exe none
  if rc != 0 then return rc
  let dir : FilePath := ".lake" / "leanprof"
  IO.FS.createDirAll dir
  let reportPath := dir / "report.json"  -- the last run's stays, for `#leanprof`
  let env := #[("LEANPROF_QUIET", some "1"), ("LEANPROF_JSON", some reportPath.toString)]
  let mut times : Array Nat := #[]
  let mut hashes : Array String := #[]
  let mut codes : Array UInt32 := #[]
  let mut reports : Array Report := #[]
  try
    for i in [0:o.warmup + o.runs] do
      if ← reportPath.pathExists then IO.FS.removeFile reportPath
      -- a stale output file must not pass for this run's
      if let some f := o.checkOutput then
        if ← (f : FilePath).pathExists then IO.FS.removeFile f
      let t0 ← IO.monoNanosNow
      let out ← IO.Process.output { cmd := (exePath exe).toString, args := o.args, env }
      let t1 ← IO.monoNanosNow
      if i < o.warmup then continue
      times := times.push (t1 - t0)
      codes := codes.push out.exitCode
      if out.exitCode != 0 && codes.size == 1 then
        IO.eprintln s!"leanprof: {exe} exited with {out.exitCode}:\n{out.stderr}"
      hashes := hashes.push <| ← match o.checkOutput with
        | some f => do
          if ← (f : FilePath).pathExists then pure (fnv1a (← IO.FS.readBinFile f)) else pure "missing"
        | none => pure (fnv1a out.stdout.toUTF8)
      reports := reports.push <| ← if ← reportPath.pathExists then loadReport reportPath.toString else pure {}
  finally
    discard <| removeWorkspaceObjects
  -- copies and calls are exact: take the last run's, and say if runs disagree
  let last := reports.back?.getD {}
  let copyTotal (r : Report) := r.copies.fold (fun acc _ n => acc + n) 0
  let copiesStable := reports.all (copyTotal · == copyTotal last)
  let outputStable := hashes.all (· == hashes.back!)
  unless copiesStable do
    IO.eprintln "leanprof: copy counts differ between runs (threads?); using the last run's"
  unless outputStable do
    IO.eprintln "leanprof: output differs between runs; judge will reject every change (use --check-output FILE)"
  -- compile cost per declaration, exact
  let mut hb : Option (List (String × Float)) := none
  if !o.hbFiles.isEmpty then
    let hbPath := dir / "measure-elab.json"
    discard <| IO.FS.withIsolatedStreams
      (elabCmd (["--heartbeats", "--out", hbPath.toString] ++ o.hbFiles.toList))
    hb := some ((← loadReport hbPath.toString).scopes.toList.map fun (k, (t, _)) => (k, t))
  let summary := Json.mkObj [
    ("version", toJson (1 : Nat)), ("leanprof", Json.str "measure"),
    ("command", toJson (#[exe] ++ o.args)), ("runs", toJson o.runs),
    ("exit_code", toJson codes.back!.toNat),
    ("output", Json.mkObj [("source", Json.str (o.checkOutput.getD "stdout")),
      ("hash", Json.str hashes.back!), ("stable", Json.bool outputStable)]),
    ("time_ns", Json.mkObj [("median", toJson (median times)), ("min", toJson (times.foldl min times[0]!)),
      ("max", toJson (times.foldl max 0)), ("runs", toJson times)]),
    ("copies_total", toJson (copyTotal last)), ("copies_stable", Json.bool copiesStable),
    ("copies", keyedArr "copies" (last.copies.toList.map fun (k, n) => (k, toJson n))),
    ("calls", keyedArr "calls" (last.scopes.toList.map fun (k, (_, c)) => (k, toJson c))),
    ("heartbeats_total", match hb with
      | some xs => toJson (xs.foldl (fun a (_, t) => a + t) (0 : Float))
      | none => Json.null),
    ("heartbeats", match hb with
      | some xs => keyedArr "heartbeats" (xs.map fun (k, t) => (k, toJson t))
      | none => Json.null)]
  if let some d := (o.out : FilePath).parent then
    if !d.toString.isEmpty then IO.FS.createDirAll d
  IO.FS.writeFile o.out (summary.pretty ++ "\n")
  IO.println s!"\nleanprof measure: {exe}, {o.runs} runs"
  IO.println s!"  time     median {fmtMs (median times).toFloat}, min {fmtMs (times.foldl min times[0]!).toFloat}, max {fmtMs (times.foldl max 0).toFloat}"
  IO.println s!"  copies   {copyTotal last} (shared + multi-threaded)"
  IO.println s!"  output   {hashes.back!} ({o.checkOutput.getD "stdout"}), exit code {codes.back!}"
  if let some xs := hb then
    IO.println s!"  compile  {fmt2 ((xs.foldl (fun a (_, t) => a + t) 0) / 1000)} kHB in {xs.length} declarations"
  IO.println s!"written to {o.out}"
  return 0

/-- What `judge` reads back from a `measure` summary. -/
structure Summary where
  command : Json := Json.null
  exitCode : Nat := 0
  outputSource : String := ""
  outputHash : String := ""
  outputStable : Bool := true
  median : Float := 0
  min : Float := 0
  max : Float := 0
  copies : Nat := 0
  sites : Std.HashMap String Nat := {}
  calls : Std.HashMap String Nat := {}
  heartbeats : Option (Std.HashMap String Float) := none

/-- `[{"key": k, field: v}, ...]` back into a map. -/
def keyedMap (j : Json) (field : String) : Std.HashMap String Float :=
  (j.getArr?.toOption.getD #[]).foldl (fun m e => m.insert (str e "key") (num e field)) {}

def loadSummary (path : String) : IO Summary := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  unless str j "leanprof" == "measure" do
    throw <| IO.userError s!"{path} is not a `leanprof measure` summary"
  let out := (j.getObjVal? "output").toOption.getD Json.null
  let time := (j.getObjVal? "time_ns").toOption.getD Json.null
  let field (k : String) := (j.getObjVal? k).toOption.getD Json.null
  let toNatMap (m : Std.HashMap String Float) := m.fold (fun acc k v => acc.insert k v.toUInt64.toNat) {}
  return {
    command := field "command", exitCode := (num j "exit_code").toUInt64.toNat
    outputSource := str out "source", outputHash := str out "hash"
    outputStable := (out.getObjValAs? Bool "stable").toOption.getD true
    median := num time "median", min := num time "min", max := num time "max"
    copies := (num j "copies_total").toUInt64.toNat
    sites := toNatMap (keyedMap (field "copies") "copies")
    calls := toNatMap (keyedMap (field "calls") "calls")
    heartbeats := if field "heartbeats" == Json.null then none else some (keyedMap (field "heartbeats") "heartbeats") }

/-- KEEP or DISCARD a change, from the summaries before and after it.

DISCARD when the command, exit code or output changed, the output was not
the same on every run, copies went up, the compile heartbeats of the
measured files went up by more than 1% and 1,000, or every new run was slower
than every base run. Otherwise KEEP when copies or heartbeats went down (by the same
margins) or every new run was faster than every base run (new max below
base min: with 5 runs each, chance alone does that 1 time in 252). -/
def judgeCmd (argv : List String) : IO UInt32 := do
  let [basePath, newPath] := argv | throw <| IO.userError usage
  let b ← loadSummary basePath
  let n ← loadSummary newPath
  let mut worse : Array String := #[]
  let mut better : Array String := #[]
  let mut notes : Array String := #[]
  if b.command != n.command then
    worse := worse.push s!"different commands measured: {b.command.compress} vs {n.command.compress}"
  if b.exitCode != n.exitCode then
    worse := worse.push s!"exit code changed: {b.exitCode} -> {n.exitCode}"
  if b.outputSource != n.outputSource || b.outputHash != n.outputHash then
    worse := worse.push s!"output changed ({n.outputSource}): {b.outputHash} -> {n.outputHash}"
  if !b.outputStable || !n.outputStable then
    worse := worse.push "output differs between runs, so changes to it cannot be detected (measure with --check-output)"
  -- copies: exact
  if n.copies > b.copies then worse := worse.push s!"copies: {b.copies} -> {n.copies}"
  else if n.copies < b.copies then better := better.push s!"copies: {b.copies} -> {n.copies}"
  for k in (b.sites.toList.map (·.1) ++ n.sites.toList.map (·.1)).eraseDups do
    let (x, y) := (b.sites.getD k 0, n.sites.getD k 0)
    if x != y then notes := notes.push s!"copies {k}: {x} -> {y}"
  -- compile heartbeats: exact, but editing one declaration moves its
  -- neighbours by a few, so only changes above 1% and 1,000 count. Judged
  -- on the total, since experiments move code between declarations.
  if let (some bh, some nh) := (b.heartbeats, n.heartbeats) then
    let kHB (x : Float) := s!"{fmt2 (x / 1000)} kHB"
    let (x, y) := (bh.fold (fun a _ v => a + v) 0, nh.fold (fun a _ v => a + v) 0)
    let margin := max (x * 0.01) 1000
    if y - x > margin then worse := worse.push s!"compile heartbeats: {kHB x} -> {kHB y}"
    else if x - y > margin then better := better.push s!"compile heartbeats: {kHB x} -> {kHB y}"
    for k in (bh.toList.map (·.1) ++ nh.toList.map (·.1)).eraseDups do
      match bh.get? k, nh.get? k with
      | some x, some y =>
        if (y - x).abs > max (x * 0.01) 1000 then notes := notes.push s!"compile {k}: {kHB x} -> {kHB y}"
      | some x, none => notes := notes.push s!"compile {k}: gone (was {kHB x})"
      | none, some y => notes := notes.push s!"compile {k}: new, {kHB y}"
      | none, none => pure ()
  else if b.heartbeats.isSome != n.heartbeats.isSome then
    notes := notes.push "compile heartbeats measured in only one summary; not compared"
  -- calls: exact, but restructuring code changes them legitimately
  for k in (b.calls.toList.map (·.1) ++ n.calls.toList.map (·.1)).eraseDups do
    let (x, y) := (b.calls.getD k 0, n.calls.getD k 0)
    if x != y then notes := notes.push s!"calls {k}: {x} -> {y}"
  -- time: only when the runs do not overlap
  let t := s!"time: median {fmtMs b.median} -> {fmtMs n.median}"
  if n.max < b.min then better := better.push s!"{t} (every new run faster than every base run)"
  else if n.min > b.max then worse := worse.push s!"{t} (every new run slower than every base run)"
  else notes := notes.push s!"{t} (within noise: base {fmtMs b.min}..{fmtMs b.max}, new {fmtMs n.min}..{fmtMs n.max})"
  let keep := worse.isEmpty && !better.isEmpty
  IO.println (if keep then "KEEP" else "DISCARD")
  for r in worse do IO.println s!"  - {r}"
  for r in better do IO.println s!"  + {r}"
  if worse.isEmpty && better.isEmpty then IO.println "  - no measurable improvement"
  for r in notes do IO.println s!"    {r}"
  return if keep then 0 else 1

def main (argv : List String) : IO UInt32 := do
  try
    match argv with
    | "run" :: rest => run rest
    | "measure" :: rest => measureCmd rest
    | "judge" :: rest => judgeCmd rest
    | "compare" :: rest => compare rest
    | "sample" :: rest => sample rest
    | "elab" :: rest => elabCmd rest
    | _ =>
      IO.eprintln usage
      return 2
  catch e =>
    IO.eprintln s!"leanprof: {e}"
    return 2
