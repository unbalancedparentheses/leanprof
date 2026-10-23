import Lean.Data.Json
import Leanprof.Core
import Leanprof.Explain
import LeanprofHtml
import LeanprofLive
import LeanprofElab

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
* `report-md`: the GitHub Action's pull-request comment, as Markdown: base
  against head for copies, allocations, calls, compile heartbeats and time.
-/

open Lean System

/-- One line per command, then its options and what it does. -/
def commands : List (String × String × String) := [
  ("run", "[--auto | --auto-all] [--allocs] [--counters] [--frees] [--core] [--trace FILE] [--json FILE] [--keep] [--cwd DIR] EXE [-- ARGS...]",
    "Build EXE with probes (copies of shared values, tasks, blocking waits; --auto: every function's\n" ++
    "time; --allocs: allocations; --counters: failed constructor reuse and closure applications;\n" ++
    "--frees: freeing pauses and atomic decrements), run it, print the report and save it to\n" ++
    ".lake/leanprof/report.json. Memory (peak, per scope) is always sampled.\n" ++
    "Works in any Lake project: leanprof's runtime is compiled for the project's Lean version.\n" ++
    "--core also sees copies, tasks (and with --allocs, allocations) inside Lean's precompiled\n" ++
    "libraries, by linking against copies rewritten with llvm-objcopy (cached in .lake/leanprof/core).\n" ++
    "--trace FILE also writes a Perfetto timeline; --keep keeps the instrumented build;\n" ++
    "--cwd DIR runs EXE in DIR (for programs that read the current directory)."),
  ("stat", "[--auto | --auto-all] [--no-allocs] [--no-frees] [--trace FILE] [--json FILE] [--keep] [--cwd DIR] EXE [-- ARGS...]",
    "Build EXE with probes, run it and print a one-screen summary: wall and CPU time, peak memory,\n" ++
    "allocations, copies, frees, tasks and the top 3 scopes. Allocations and frees are counted\n" ++
    "unless turned off (they slow the program down); --auto times every function."),
  ("sample", "[--rate HZ] [--top N] [--out FILE] [--cwd DIR] EXE [-- ARGS...]",
    "Run EXE under samply (no probes) and report CPU time per Lean declaration with file:line,\n" ++
    "plus where the Lean runtime's time went. `samply load` on the saved profile opens a flame\n" ++
    "graph with Lean names. Needs samply (brew install samply / cargo install samply)."),
  ("elab", "[--heartbeats] [--compact] [--project | --module-glob GLOB] [--jobs N] [--counts] [--threshold N] [--no-defs] [--no-driver] [--top N] [--out FILE] [FILE.lean...]",
    "Compile cost per line and declaration: elaboration, kernel, compiler, linters, by kind of\n" ++
    "operation, repeated work, and the definitions behind the work (what isDefEq and whnf unfolded,\n" ++
    "instances tried, simp lemmas), each with its own file:line. --project profiles every built module of\n" ++
    "the package in parallel (--module-glob: those matching, e.g. 'Foo.Data.*'). --counts adds Lean's exact\n" ++
    "unfold counts (slower). --heartbeats counts\n" ++
    "heartbeats, which are the same on every run. With the project on leanprof's Lean, terms and tactics\n" ++
    "are timed by exact source range (line:column); --compact times only those (close to plain lean).\n" ++
    "--no-driver elaborates with `lean --json` instead."),
  ("compare", "[--threshold PCT] [--min-ms MS] BASE.json NEW.json",
    "Exit 1 on a regression: more copies, changed call counts, compile heartbeats up by more than\n" ++
    "1% and 1,000, or a scope slower by more than PCT% (default 10) and MS ms (default 1)."),
  ("measure", "[--runs N] [--warmup N] [--heartbeats-files F.lean...] [--check-output FILE] [--out FILE] EXE [-- ARGS...]",
    "Run EXE N times (default 5) with probes and write one summary: time spread, copies, calls,\n" ++
    "compile heartbeats, exit code and an output hash. For `judge` and autoresearch loops."),
  ("judge", "BASE.json NEW.json",
    "KEEP (exit 0) if nothing got worse and something improved beyond noise; DISCARD (exit 1) if\n" ++
    "output or exit code changed, or copies, heartbeats or time got worse."),
  ("report-md", "[--fail-on copies,allocs,calls,heartbeats|none] [--title T] [--threshold PCT] [--min-ms MS] [--top N] BASE.json NEW.json [BASE_ELAB.json NEW_ELAB.json]",
    "Markdown summary of two `run --json` reports (and optionally two `elab --heartbeats` reports), for a\n" ++
    "pull-request comment: copies, allocations, calls, compile heartbeats and time, base against head,\n" ++
    "with pass/fail per exact metric. Exit 1 if a metric named by --fail-on (default: copies) regressed."),
  ("explain", "[--report FILE] [--out FILE] [--top N] [--all] [--json] [--why EXE [-- ARGS...]]",
    "For each copy of a shared value in the last report, say where the second reference comes from,\n" ++
    "read from the compiler's IR (.lake/build/ir/*.c), with source lines and, when the cause is\n" ++
    "recognised, the fix as Lean code with the program's own names. --json prints the ranked findings\n" ++
    "(cause, location, fix and fix code, cost) for agents. --why EXE first reruns EXE recording where\n" ++
    "each copied value became shared. Writes .lake/leanprof/explain.json (or --out FILE) for\n" ++
    "#leanprof hovers."),
  ("html", "[-o FILE] [--trace FILE] [--profile FILE] [--threshold PCT] [--min-ms MS] [--context N] [--title T] [REPORT.json...]",
    "One self-contained HTML page (no network) from reports (default: report.json, elab.json and\n" ++
    "measure.json in .lake/leanprof/), written to .lake/leanprof/report.html unless -o is given:\n" ++
    "summary, flame graph, sortable tables, source lines with hints, and a comparison when given\n" ++
    "two reports of a kind (base, then new; regressions as `compare` counts them). The flame graph\n" ++
    "of a sampled report reads samply's profile next to it (or --profile FILE); for a run report,\n" ++
    "pass the timeline of `run --trace FILE` as --trace FILE."),
  ("top", "[--interval MS] [--rows N] [--frames N] [--plain] [--flight DIR] [--slow-ms MS] [run options] EXE [-- ARGS...] | --attach FILE | --pid PID",
    "Run EXE with probes (as `run`) and show it live, refreshed like top: hottest scopes, copy sites,\n" ++
    "allocation sites, tasks and waits with rates per second, memory, CPU and what each thread is inside.\n" ++
    "--attach/--pid watch a program started with LEANPROF_LIVE=FILE or LEANPROF_LIVE=1. --flight and\n" ++
    "--slow-ms turn on the flight recorder. Plain ANSI; --plain (or no terminal) prints frames."),
  ("dump", "[--timeout S] PID",
    "Ask a program running with the flight recorder (LEANPROF_FLIGHT, LEANPROF_SLOW_MS) for a Perfetto\n" ++
    "trace of its last seconds (SIGUSR1) and print its path."),
  ("mcp", "",
    "Model Context Protocol server on stdio for AI agents: tools to run, sample, stat, elab and measure\n" ++
    "targets, read reports, list hot scopes/copies/allocations with file:line, compare, judge, and\n" ++
    "query (live) or dump (dump) a running program."),
  ("doctor", "",
    "Check that the tools leanprof needs are installed and the project is set up, and say what to fix."),
  ("help", "[COMMAND]", "Show this overview, or one command's options.")]

/-- What each command is for, in one line. -/
def summary : String → String
  | "run" => "profile a program exactly: copies, tasks, waits; --auto every function, --allocs allocations"
  | "stat" => "one-screen summary: time, peak memory, allocations, copies, frees, tasks, top scopes"
  | "sample" => "sample a program with samply: CPU per Lean declaration, no probes"
  | "elab" => "compile cost per line and declaration, repeated work, exact heartbeats"
  | "compare" => "compare two reports, exit 1 on regressions (for CI)"
  | "measure" => "run a program several times into one summary (for judge / autoresearch)"
  | "judge" => "KEEP or DISCARD a change from two measure summaries"
  | "report-md" => "Markdown summary of base and head reports, for pull-request comments"
  | "explain" => "why each copy happened: where the second reference comes from, and a fix"
  | "html" => "one self-contained HTML report: flame graph, tables, source, comparison"
  | "top" => "live view of a running program: hot scopes, copies, allocations, tasks, per second"
  | "dump" => "write a running program's last seconds to a Perfetto trace (flight recorder)"
  | "mcp" => "MCP server on stdio: profiling tools for AI agents"
  | "doctor" => "check that leanprof's tools and the project are set up"
  | "help" => "this overview, or one command's options"
  | _ => ""

def usage : String :=
  "leanprof: profiler for Lean 4 programs (https://github.com/unbalancedparentheses/leanprof)\n\n" ++
  "usage: leanprof COMMAND [OPTIONS]   (or `lake exe leanprof` in a project that depends on it)\n\n" ++
  String.join (commands.map fun (c, _, _) => s!"  {c.pushn ' ' (11 - c.length)}{summary c}\n") ++
  "\nleanprof help COMMAND shows a command's options. Docs: docs/guide/getting-started.md"

def commandHelp (c : String) : Option String :=
  (commands.find? (·.1 == c)).map fun (c, opts, d) => s!"usage: leanprof {c} {opts}\n\n{d}"

def usageFor (c : String) : String := (commandHelp c).getD usage

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

def spawnWait (cmd : String) (args : Array String) (env : Array (String × Option String))
    (cwd : Option FilePath := none) : IO UInt32 := do
  let child ← IO.Process.spawn { cmd, args, env, cwd }
  child.wait

structure RunOpts where
  auto : Option String := none
  trace : Option String := none
  json : Option String := none
  keep : Bool := false
  allocs : Bool := false
  counters : Bool := false
  frees : Bool := false
  core : Bool := false
  cwd : Option String := none
  exe : Option String := none
  args : Array String := #[]

partial def parseRun (opts : RunOpts) : List String → Except String RunOpts
  | [] => .ok opts
  | "--auto" :: rest => parseRun { opts with auto := some "1" } rest
  | "--auto-all" :: rest => parseRun { opts with auto := some "all" } rest
  | "--trace" :: f :: rest => parseRun { opts with trace := some f } rest
  | "--json" :: f :: rest => parseRun { opts with json := some f } rest
  | "--keep" :: rest => parseRun { opts with keep := true } rest
  | "--allocs" :: rest => parseRun { opts with allocs := true } rest
  | "--counters" :: rest => parseRun { opts with counters := true } rest
  | "--frees" :: rest => parseRun { opts with frees := true } rest
  | "--core" :: rest => parseRun { opts with core := true } rest
  | "--cwd" :: d :: rest => parseRun { opts with cwd := some d } rest
  | "--" :: rest => .ok { opts with args := opts.args ++ rest.toArray }
  | a :: rest =>
    if a.startsWith "--" then .error s!"unknown option {a}"
    else if opts.exe.isNone then parseRun { opts with exe := some a } rest
    else parseRun { opts with args := opts.args.push a } rest

/-- The executable Lake builds for `exe`. -/
def exePathOf (exe : String) : FilePath := (".lake" : FilePath) / "build" / "bin" / exe

/-- The executable and Lake's records of it, which an instrumented build replaces. -/
def exeFiles (exe : String) : List FilePath :=
  exePathOf exe :: ["trace", "hash", "rsp"].map (exePathOf exe).withExtension

def savedDir : FilePath := (".lake" : FilePath) / "leanprof" / "saved"

/-- Keep the normal build of `exe` aside before replacing it with an instrumented one. -/
def saveExe (exe : String) : IO Unit := do
  IO.FS.createDirAll savedDir
  for f in exeFiles exe do
    if ← f.pathExists then
      discard <| IO.Process.output { cmd := "cp", args := #["-p", f.toString, (savedDir / f.fileName.get!).toString] }

/-- Put the normal build back, so running `exe` afterwards does not profile it. -/
def restoreExe (exe : String) : IO Unit := do
  for f in exeFiles exe do
    let saved := savedDir / f.fileName.get!
    if ← saved.pathExists then
      discard <| IO.Process.output { cmd := "mv", args := #[saved.toString, f.toString] }

/-- Undo an instrumented build: its objects (Lake does not notice a new
`LEAN_CC`) and its executable. -/
def cleanupInstrumented (exe : String) : IO Unit := do
  discard <| removeWorkspaceObjects
  restoreExe exe
/-! ## Core-library coverage (`run --core`)

Lean's precompiled libraries call the runtime directly, so the `-D` flags
never reach them. `run --core` links against copies of them in which every
reference to a redirected runtime function is renamed to its `leanprof_*`
shim, the static-archive equivalent of `ld --wrap`. The functions are defined
in libleanrt, which is left alone, so the shims still reach the real ones. -/

/-- The `-Dold=leanprof_*` pairs in the compiler wrapper (the one list of
redirected functions): the base set, plus what `LEANPROF_ALLOCS=1` adds. -/
def wrapperRenames (allocs : Bool) (frees : Bool := false) : IO (Array (String × String)) := do
  let text ← IO.FS.readFile ((← packageRoot) / "scripts" / "leanprof-cc")
  -- the block an env switch guards: from its test to the next `fi`
  let block (switch : String) : String :=
    match text.splitOn s!"{switch}:-" with
    | _ :: r :: _ => (r.splitOn "\nfi").head!
    | _ => ""
  let base := (text.splitOn "LEANPROF_ALLOCS:-").head!
  let alloc := block "LEANPROF_ALLOCS" ++ (if frees then " " ++ block "LEANPROF_FREES" else "")
  let pairs (s : String) : Array (String × String) :=
    ((s.replace "\n" " ").splitOn " ").toArray.filterMap fun tok =>
      match tok.splitOn "=" with
      | [d, new] => if d.startsWith "-D" && new.startsWith "leanprof_" then
          some (d.replace "-D" "", new) else none
      | _ => none
  return pairs base ++ pairs (if allocs then alloc else if frees then block "LEANPROF_FREES" else "")

/-- An objcopy that can rename symbols in this platform's archives:
LEANPROF_OBJCOPY, then llvm-objcopy (also versioned, and in Homebrew's and
Debian's LLVM directories), then GNU objcopy on Linux. -/
def findObjcopy : IO (Option String) := do
  if let some p ← IO.getEnv "LEANPROF_OBJCOPY" then return some p
  let path := ((← IO.getEnv "PATH").getD "").splitOn ":" |>.filter (!·.isEmpty)
  let versions := (List.range 10).map (23 - ·)
  let names := "llvm-objcopy" :: versions.map (s!"llvm-objcopy-{·}")
  let dirs := ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"] ++ versions.flatMap fun v =>
    [s!"/opt/homebrew/opt/llvm@{v}/bin", s!"/usr/local/opt/llvm@{v}/bin", s!"/usr/lib/llvm-{v}/bin"]
  let gnu := if System.Platform.isOSX then [] else path.map (· ++ "/objcopy")
  let candidates := names.flatMap (fun n => path.map (· ++ "/" ++ n)) ++
    dirs.map (· ++ "/llvm-objcopy") ++ gnu
  for c in candidates do
    if ← FilePath.pathExists c then return some c
  return none

/-- The toolchain's Lean libraries with references to the redirected runtime
functions renamed to leanprof's shims, cached in `.lake/leanprof/core/` by
toolchain and set of renamed symbols. Returns the directory to search first. -/
def coreLibDir (allocs : Bool) (frees : Bool := false) : IO FilePath := do
  let some objcopy ← findObjcopy | throw <| IO.userError <|
    "leanprof run --core needs llvm-objcopy: brew install llvm, apt install llvm (GNU objcopy also " ++
    "works on Linux), or set LEANPROF_OBJCOPY"
  let leanOut (arg : String) : IO String := do
    return (← IO.Process.output { cmd := "lean", args := #[arg] }).stdout.trimAscii.toString
  let leanPrefix : FilePath := ⟨← leanOut "--print-prefix"⟩
  let renames ← wrapperRenames allocs frees
  -- Mach-O symbol names carry a leading underscore
  let us := if System.Platform.isOSX then "_" else ""
  let key := hash s!"{leanPrefix} {← leanOut "--githash"} {renames}"
  let dir := (← IO.currentDir) / ".lake" / "leanprof" / "core" /
    s!"{leanPrefix.fileName.getD "lean"}-{String.ofList (Nat.toDigits 16 key.toNat)}"
  IO.FS.createDirAll dir
  let args := renames.flatMap fun (old, new) => #["--redefine-sym", s!"{us}{old}={us}{new}"]
  let mut made := 0
  for lib in ["Init", "Std", "Lean", "Lake", "LeanExport"] do
    let src := leanPrefix / "lib" / "lean" / s!"lib{lib}.a"
    let dst := dir / s!"lib{lib}.a"
    unless (← src.pathExists) && !(← dst.pathExists) do continue
    let tmp := dir / s!"lib{lib}.a.tmp"
    -- `lake exe` puts the toolchain's lib on the loader path, and its libLLVM
    -- is not the one a Homebrew or Debian llvm-objcopy was built against
    let env := #["DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "LD_LIBRARY_PATH"].map (·, none)
    let out ← IO.Process.output { cmd := objcopy, args := args ++ #[src.toString, tmp.toString], env }
    if out.exitCode != 0 then
      throw <| IO.userError s!"{objcopy} failed on {src}:\n{out.stderr}"
    IO.FS.rename tmp dst
    made := made + 1
  IO.eprintln s!"leanprof: Lean's libraries with {renames.size} runtime functions redirected{if made == 0 then " (cached)" else s!" by {objcopy}"}: {dir}"
  return dir

/-- Build `exe` with the copy shims in every package (and, with `auto`, every
function timed). A project that does not depend on leanprof gets leanprof's
runtime compiled for its own Lean version, linked in by the wrapper. A failed
build removes the instrumented objects again. -/
def buildWithShims (exe : String) (auto : Option String) (allocs : Bool := false)
    (counters : Bool := false) (frees : Bool := false) (extraEnv : Array (String × Option String) := #[]) :
    IO UInt32 := do
  let root ← packageRoot
  let wrapper := root / "scripts" / "leanprof-cc"
  unless ← wrapper.pathExists do
    throw <| IO.userError s!"compiler wrapper not found at {wrapper}"
  let leanOk ← try pure ((← IO.Process.output { cmd := "lean", args := #["--print-prefix"] }).exitCode == 0)
    catch _ => pure false
  unless leanOk do
    throw <| IO.userError ("`lean` was not found on PATH: add elan's bin directory " ++
      "(export PATH=$HOME/.elan/bin:$PATH); `leanprof doctor` checks the setup")
  saveExe exe
  -- Lake would keep an executable linked against an older leanprof runtime
  -- (the rebuilt objects hash the same): make it relink
  for f in exeFiles exe do
    if ← f.pathExists then IO.FS.removeFile f
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
  IO.eprintln s!"leanprof: building {exe} with copy shims{if auto.isSome then " and every function timed" else ""}{if allocs then " and allocations counted" else ""}{if counters then " and reuse/closure counters" else ""}{if frees then " and frees timed" else ""} ({removed} stale objects removed)"
  let buildEnv := #[("LEAN_CC", some wrapper.toString), ("LEANPROF_AUTO", auto),
    ("LEANPROF_ALLOCS", if allocs then some "1" else none),
    ("LEANPROF_COUNTERS", if counters then some "1" else none),
    ("LEANPROF_FREES", if frees then some "1" else none),
    -- the build may run instrumented code (precompiled modules are loaded
    -- into `lean`): no reports from it, and none over the program's
    ("LEANPROF_QUIET", some "1"), ("LEANPROF_JSON", none), ("LEANPROF_TRACE", none),
    ("LEANPROF_STAT", none)] ++ runtimeEnv ++ extraEnv
  let rc ← spawnWait "lake" #["build", exe] buildEnv
  if rc != 0 then
    cleanupInstrumented exe
  return rc

/-- The executable Lake builds for `exe`. -/
def exePath (exe : String) : FilePath := (".lake" : FilePath) / "build" / "bin" / exe

def absPath (p : FilePath) : IO FilePath := do
  if p.isAbsolute then return p
  return (← IO.currentDir) / p

/-- Run the instrumented `exe` in the project, or in `--cwd DIR` (for
programs that read their input from the current directory): paths become
absolute, and LEANPROF_PROJECT tells the runtime where the `.ilean` files are. -/
def runInstrumented (exe : String) (opts : RunOpts) (env : Array (String × Option String)) : IO UInt32 := do
  let fix (v : Option String) : IO (Option String) := v.mapM fun p => return (← absPath p).toString
  let mut env' := #[]
  for (k, v) in env do
    env' := env'.push (k, ← if k == "LEANPROF_JSON" || k == "LEANPROF_TRACE" then fix v else pure v)
  if opts.cwd.isSome then env' := env'.push ("LEANPROF_PROJECT", some (← IO.currentDir).toString)
  spawnWait (← absPath (exePath exe)).toString opts.args env' (opts.cwd.map (·))

def run (argv : List String) : IO UInt32 := do
  let opts ← IO.ofExcept (parseRun {} argv)
  let some exe := opts.exe | throw <| IO.userError (usageFor "run")
  let coreEnv ← if opts.core then
      pure #[("LEANPROF_CORE_LIB", some (← coreLibDir opts.allocs opts.frees).toString)]
    else pure #[]
  let rc ← buildWithShims exe opts.auto opts.allocs opts.counters opts.frees coreEnv
  if rc != 0 then return rc
  -- the report `#leanprof` reads, unless another path was asked for
  IO.FS.createDirAll ((".lake" : FilePath) / "leanprof")
  let json := opts.json.getD ".lake/leanprof/report.json"
  let runEnv := #[("LEANPROF_TRACE", opts.trace), ("LEANPROF_JSON", some json)]
  let rc ← runInstrumented exe opts runEnv
  unless opts.keep do
    cleanupInstrumented exe
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
  -- project reports (`elab --project`): each module's total, as `module M`
  if (j.getObjVal? "project" >>= Json.getBool?).toOption.getD false then
    for f in (j.getObjVal? "files" >>= Json.getArr?).toOption.getD #[] do
      r := { r with scopes := r.scopes.insert (str f "key") (num f "total_ns", 0) }
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
  let [basePath, newPath] := files | throw <| IO.userError (usageFor "compare")
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
  cwd : Option String := none
  exe : Option String := none
  args : Array String := #[]

partial def parseSample (o : SampleOpts) : List String → Except String SampleOpts
  | [] => .ok o
  | "--rate" :: v :: rest => parseSample { o with rate := v.toNat! } rest
  | "--out" :: f :: rest => parseSample { o with out := some f } rest
  | "--top" :: v :: rest => parseSample { o with top := v.toNat! } rest
  | "--cwd" :: d :: rest => parseSample { o with cwd := some d } rest
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
  -- every small allocation also bumps the thread's heartbeat counter
  else if has "lean_alloc" || r.startsWith "mi_" || has "malloc" || has "mi_page" || has "lean_inc_heartbeat" then some "allocation"
  else if has "lean_apply" then some "applying closures"
  else if has "gmpz" || has "lean_nat_big" || has "mpz" then some "big-number arithmetic"
  -- Lean's C++ code for expressions and the kernel (also the hash maps it caches in)
  else if (r.startsWith "lean_" || has "lean::") && (has "expr" || has "replace" || has "instantiate" ||
      has "abstract" || has "type_checker" || has "loose_bvar" || has "kernel" || has "level") then
    some "expressions and kernel (Lean's C++: instantiate, replace, type checking)"
  else if r.startsWith "lean_" || has "lean::" then some "other Lean runtime"
  -- reached through a thread-local variable: the allocator's heap, the heartbeat counter
  else if has "tlv_get_addr" then some "thread-local variable lookups"
  else none

/-- A C++ name without template arguments (`std::__1::__hash_table<…>::find`):
they can run to thousands of characters. -/
def elideTemplates (s : String) : String := Id.run do
  unless (s.splitOn "::").length > 1 && (s.splitOn "<").length > 1 do return s
  let mut out := ""
  let mut depth := 0
  let mut prev := ' '
  for c in s.toList do
    if c == '<' && !out.endsWith "operator" then
      if depth == 0 then out := out ++ "<…"
      depth := depth + 1
    else if c == '>' && depth > 0 && prev != '-' then
      depth := depth - 1
      if depth == 0 then out := out.push '>'
    else if depth == 0 then out := out.push c
    prev := c
  return out

/-- Symbols of a system library that samply did not symbolicate (libdyld,
whose `tlv_get_addr` serves every thread-local variable), from the labels in
`dyld_info -disassemble`: sorted (start, end, name) relative to `__TEXT`. -/
def dyldInfoSymbols (path arch : String) : IO (Array (Nat × Nat × String)) := do
  unless System.Platform.isOSX do return #[]
  let run (what : String) : IO String := do
    let out ← IO.Process.output { cmd := "dyld_info", args := #["-arch", arch, what, path] }
    return if out.exitCode == 0 then out.stdout else ""
  let hex (w : String) : Option Nat :=
    if w.startsWith "0x" then (w.drop 2).foldl (init := some 0) fun acc c =>
      acc.bind fun n => if c.isDigit then some (n * 16 + (c.toNat - '0'.toNat))
        else if 'A' ≤ c && c ≤ 'F' then some (n * 16 + (c.toNat - 'A'.toNat + 10))
        else if 'a' ≤ c && c ≤ 'f' then some (n * 16 + (c.toNat - 'a'.toNat + 10)) else none
    else none
  let words (l : String) := (l.splitOn " ").filter (· != "")
  let text (l : String) : Option Nat := match words l with
    | a :: "__TEXT" :: _ => hex a
    | _ => none
  let some base := ((← run "-segments").splitOn "\n").findSome? text | return #[]
  let mut syms : Array (Nat × String) := #[]
  let mut label : Option String := none
  for l in (← try run "-disassemble" catch _ => pure "").splitOn "\n" do
    if l.endsWith ":" && !l.startsWith "0x" && !l.startsWith "/" then
      label := some ((l.dropEnd 1).toString)
    else if let some name := label then
      if let some a := (words l).head? >>= hex then
        if a ≥ base then syms := syms.push (a - base, if name.startsWith "_" then (name.drop 1).toString else name)
        label := none
  return (List.range syms.size).toArray.map fun i =>
    (syms[i]!.1, (syms[i + 1]?.map (·.1)).getD (syms[i]!.1 + 4), syms[i]!.2)

def sample (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseSample {} argv)
  let some exe := o.exe | throw <| IO.userError (usageFor "sample")
  let rc ← spawnWait "lake" #["build", exe] #[]
  if rc != 0 then return rc
  let bin : FilePath := (".lake" : FilePath) / "build" / "bin" / exe
  let out : FilePath := o.out.getD s!".lake/leanprof/{exe}.json"
  if let some dir := out.parent then IO.FS.createDirAll dir
  if ← out.pathExists then IO.FS.removeFile out
  let samplyArgs := #["record", "--save-only", "--unstable-presymbolicate", "--rate", toString o.rate,
    "-o", (← absPath out).toString, (← absPath bin).toString] ++ o.args
  let rc ← try spawnWait "samply" samplyArgs #[("LEANPROF_QUIET", some "1")] (o.cwd.map (·))
    catch e =>
      IO.eprintln s!"leanprof: cannot run samply ({e}); install it: brew install samply / cargo install samply"
      return 1
  -- samply exits with the program's exit code: a failing program still has a profile
  unless ← out.pathExists do
    IO.eprintln s!"leanprof: samply exited with {rc} and wrote no profile"
    return if rc == 0 then 1 else rc
  if rc != 0 then IO.eprintln s!"leanprof: {exe} exited with {rc}; its profile so far:"
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
    libTables := libTables.push <| ← match entry with
      | some e => pure (libSymbols e strings)
      | none => try dyldInfoSymbols (str l "path") (str l "arch") catch _ => pure #[]
    libIsMain := libIsMain.push (dn == exe)
  -- CPU time per display name: self (leaf) and inclusive (anywhere in the stack)
  let mut selfT : Std.HashMap String Float := {}
  let mut inclT : Std.HashMap String Float := {}
  let mut total : Float := 0
  let mut names : Std.HashMap String String := {}  -- raw symbol ↦ display name
  let mut leanDecls : Std.HashSet String := {}       -- display names that are Lean declarations
  let mut categories : Std.HashMap String String := {} -- display name ↦ runtime category
  let mut catT : Std.HashMap String Float := {}
  -- code the linker outlined (OUTLINED_FUNCTION_N): its time is its caller's
  let mut outlined : Std.HashSet String := {}
  -- callers of specializations: `g (in f)` is named after the first `g` that
  -- needed `f` specialized, but the compiler reuses it for other callers
  let mut specCallers : Std.HashMap String (Std.HashMap String Float) := {}
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
          let r := if raw.startsWith "_" then (raw.drop 1).toString else raw
          let lean := r.startsWith "l_" || r.startsWith "lp_" || r == "_lean_main" || r == "lean_main"
          -- only Lean symbols are demangled (C++ names, already demangled by
          -- samply, are not cut to the demangler's buffer)
          let d := elideTemplates <|
            if isMain then (if lean then Leanprof.demangle raw else raw)
            else s!"[{(str (libsMeta[lib]?.getD Json.null) "name")}] {raw}"
          names := names.insert raw d
          if r.startsWith "OUTLINED_FUNCTION_" then outlined := outlined.insert d
          if isMain && lean then
            leanDecls := leanDecls.insert d
          if isMain || r.endsWith "tlv_get_addr" then
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
      let mut spec : Option String := none  -- the frame below, if a specialization
      let mut specSeen : Std.HashSet String := {}
      while true do
        let some s := s? | break
        let f := getNatAt frameOf s |>.getD 0
        let n := frameName[f]?.getD "?"
        if outlined.contains n then
          s? := getNatAt parents s
          continue
        -- the nearest Lean caller, past `lean_apply_N` and other runtime frames
        if let some sp := spec then
          if leanDecls.contains n then
            unless specSeen.contains sp do
              let m := specCallers.getD sp {}
              specCallers := specCallers.insert sp (m.insert n (m.getD n 0 + w))
              specSeen := specSeen.insert sp
            spec := none
        if (n.splitOn " (in ").length > 1 then spec := some n
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
  -- a specialization is named after the first caller that needed it, but the
  -- compiler reuses it (and inlines callers): say who calls it in this run
  let callerNote (n : String) : IO Unit := do
    let some m := specCallers.get? n | return
    let named := (n.splitOn " (in ").head!
    let some (c, cw) := (m.toArray.qsort (fun a b => a.2 > b.2))[0]? | return
    let base := (c.splitOn " (in ").head!
    if base != named && !base.startsWith (named ++ ".") && leanDecls.contains c then
      let cwh ← Leanprof.whereIs c
      let all := inclT.getD n 0
      IO.println s!"{"".pushn ' ' 24}{fmt2 (if all > 0 then cw / all * 100 else 0)}% of it called from {c}{if cwh.isEmpty then "" else s!"  ({cwh})"}"
  for (n, w) in bySelf.toList.take o.top do
    let wh ← Leanprof.whereIs n
    IO.println s!"  {(fmtCpu w).pushn ' ' (12 - (fmtCpu w).length)} {(pct w).pushn ' ' (8 - (pct w).length)} {n}{if wh.isEmpty then "" else s!"  ({wh})"}"
    callerNote n
  IO.println s!"\n  top {o.top} Lean declarations by inclusive CPU time"
  let leanIncl := (inclT.toArray.filter fun (n, _) => leanDecls.contains n && !n.startsWith "initialize_").qsort (fun a b => a.2 > b.2)
  for (n, w) in leanIncl.toList.take o.top do
    let wh ← Leanprof.whereIs n
    IO.println s!"  {(fmtCpu w).pushn ' ' (12 - (fmtCpu w).length)} {(pct w).pushn ' ' (8 - (pct w).length)} {n}{if wh.isEmpty then "" else s!"  ({wh})"}"
    callerNote n
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
  return rc

/-! ## elab: in LeanprofElab.lean -/

def elabCmd (argv : List String) : IO UInt32 := Leanprof.Elab.main argv

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
  let some exe := o.exe | throw <| IO.userError (usageFor "measure")
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
    cleanupInstrumented exe
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
  let [basePath, newPath] := argv | throw <| IO.userError (usageFor "judge")
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

/-! ## report-md -/

/-- `n` with thousands separators. -/
def groupDigits (n : Nat) : String :=
  if _h : n < 1000 then toString n
  else
    let r := n % 1000
    groupDigits (n / 1000) ++ "," ++ (if r < 10 then "00" else if r < 100 then "0" else "") ++ toString r
termination_by n
decreasing_by omega

def fmtCount (x : Float) : String := groupDigits x.abs.round.toUInt64.toNat

def fmtHeartbeats (x : Float) : String :=
  if x.abs ≥ 1e6 then s!"{fmt2 (x / 1e6)} MHB" else s!"{fmt2 (x / 1000)} kHB"

/-- A name for a Markdown table cell. -/
def mdCode (s : String) : String := s!"`{(s.replace "`" "'").replace "|" "\\|"}`"

/-- `+12 (+3.40%)`: the change from `b` to `n`, formatted with `f`. -/
def fmtChange (f : Float → String) (b n : Float) : String :=
  let d := n - b
  let sign := if d > 0 then "+" else if d < 0 then "−" else ""
  let pct := if b > 0 && d != 0 then s!" ({sign}{fmt2 ((d / b * 100).abs)}%)" else ""
  if d == 0 then "0" else s!"{sign}{f d.abs}{pct}"

/-- Entries whose value differs, largest change first. -/
def mdDiffs (b n : Std.HashMap String Float) : Array (String × Float × Float) :=
  let keys := (b.toList.map (·.1) ++ n.toList.map (·.1)).eraseDups
  let ds := keys.filterMap fun k =>
    let x := b.getD k 0
    let y := n.getD k 0
    if x == y then none else some (k, x, y)
  ds.toArray.qsort (fun a c => (a.2.2 - a.2.1).abs > (c.2.2 - c.2.1).abs)

def mapSum (m : Std.HashMap String Float) : Float := m.fold (fun s _ v => s + v) 0

/-- The metrics of one `run --json` or `elab` report, keyed so that edits which
only move lines still match. -/
structure MdReport where
  isElab : Bool := false
  heartbeats : Bool := false
  copies : Std.HashMap String Float := {}   -- function [kind] in scope ↦ copies
  allocs : Std.HashMap String Float := {}   -- function in scope ↦ allocations
  calls : Std.HashMap String Float := {}    -- scope name ↦ calls
  time : Std.HashMap String Float := {}     -- scope name ↦ total ns
  compile : Std.HashMap String Float := {}  -- declaration ↦ heartbeats (or ns)
  wall : Float := 0

/-- A row's function; code without a symbol is reported by address, which
moves between runs (ASLR), so all of it is one entry. -/
def fnName (j : Json) : String :=
  let f := str j "function"
  if f.startsWith "0x" then "(no symbol)" else f

def loadMdReport (path : String) : IO MdReport := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  let isElab := (j.getObjVal? "elab" >>= Json.getBool?).toOption.getD false
  let add (m : Std.HashMap String Float) (k : String) (v : Float) := m.insert k (m.getD k 0 + v)
  let mut r : MdReport := { isElab, heartbeats := str j "unit" == "heartbeats", wall := num j "wall_ns" }
  for s in getArr j "scopes" do
    if isElab then
      let key := if (str s "key").isEmpty then s!"{str s "name"} {str s "pos"}" else str s "key"
      r := { r with compile := add r.compile key (num s "total_ns") }
    else
      r := { r with calls := add r.calls (str s "name") (num s "calls"),
                    time := add r.time (str s "name") (num s "total_ns") }
  unless isElab do
    for c in getArr j "copies" do
      let n := num c "shared" + num c "multi_threaded"
      if n > 0 then
        r := { r with copies := add r.copies s!"{fnName c} [{str c "kind"}] in {str c "scope"}" n }
    for a in getArr j "allocations" do
      r := { r with allocs := add r.allocs s!"{fnName a} in {str a "scope"}" (num a "allocs") }
  return r

/-- One row of the summary table, with the entries that changed. -/
structure MdMetric where
  id : String
  label : String
  isExact : Bool
  base : Float
  new : Float
  fmt : Float → String
  rows : Array (String × Float × Float)
  /-- which changed entries count as regressions -/
  bad : Array (String × Float × Float)
  /-- what a regression is, for the details -/
  rule : String

structure MdOpts where
  failOn : List String := ["copies"]
  threshold : Float := 10
  minMs : Float := 1
  title : String := "leanprof"
  top : Nat := 10
  files : Array String := #[]

def mdMetricIds : List String := ["copies", "allocs", "calls", "heartbeats"]

partial def parseReportMd (o : MdOpts) : List String → Except String MdOpts
  | [] => .ok o
  | "--fail-on" :: v :: rest =>
    let ids := (v.splitOn ",").map (·.trimAscii.toString) |>.filter (· != "")
    if ids == ["none"] then parseReportMd { o with failOn := [] } rest
    else match ids.find? (!mdMetricIds.contains ·) with
      | some bad => .error s!"--fail-on: unknown metric {bad} (use {", ".intercalate mdMetricIds} or none)"
      | none => parseReportMd { o with failOn := ids } rest
  | "--threshold" :: v :: rest => parseReportMd { o with threshold := v.toNat!.toFloat } rest
  | "--min-ms" :: v :: rest => parseReportMd { o with minMs := v.toNat!.toFloat } rest
  | "--title" :: v :: rest => parseReportMd { o with title := v } rest
  | "--top" :: v :: rest => parseReportMd { o with top := v.toNat! } rest
  | a :: rest =>
    if a.startsWith "--" then .error s!"unknown option {a}"
    else parseReportMd { o with files := o.files.push a } rest

/-- A Markdown summary of two pairs of reports (a run's and an elab's), for a
pull-request comment. Exits 1 when a metric named by `--fail-on` regressed. -/
def reportMd (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseReportMd {} argv)
  unless o.files.size == 2 || o.files.size == 4 do throw <| IO.userError (usageFor "report-md")
  let mut run : Option (MdReport × MdReport) := none
  let mut elabPair : Option (MdReport × MdReport) := none
  for i in [0:o.files.size / 2] do
    let b ← loadMdReport o.files[2 * i]!
    let n ← loadMdReport o.files[2 * i + 1]!
    if b.isElab != n.isElab then
      throw <| IO.userError s!"{o.files[2 * i]!} and {o.files[2 * i + 1]!}: one is an elab report and the other is not"
    if b.isElab then elabPair := some (b, n) else run := some (b, n)
  let mut metrics : Array MdMetric := #[]
  let mut timeRow : Option (MdReport × MdReport) := none
  if let some (b, n) := run then
    let d := mdDiffs b.copies n.copies
    metrics := metrics.push {
      id := "copies", label := "copies", isExact := true,
      base := mapSum b.copies, new := mapSum n.copies, fmt := fmtCount, rows := d,
      bad := d.filter (fun (_, x, y) => y > x), rule := "any increase at a call site" }
    if b.allocs.size + n.allocs.size > 0 then
      let d := mdDiffs b.allocs n.allocs
      let (tb, tn) := (mapSum b.allocs, mapSum n.allocs)
      metrics := metrics.push {
        id := "allocs", label := "allocations", isExact := true,
        base := tb, new := tn, fmt := fmtCount, rows := d,
        bad := if tn > tb then d.filter (fun (_, x, y) => y > x) else #[],
        rule := "the total grew" }
    let d := mdDiffs b.calls n.calls
    metrics := metrics.push {
      id := "calls", label := "calls", isExact := true,
      base := mapSum b.calls, new := mapSum n.calls, fmt := fmtCount, rows := d,
      bad := d.filter (fun (k, _, _) => b.calls.contains k && n.calls.contains k),
      rule := "any change in a scope present in both" }
    timeRow := some (b, n)
  if let some (b, n) := elabPair then
    -- editing one declaration moves its neighbours by a few heartbeats: list
    -- only changes above the regression threshold, and new or removed ones
    let d := (mdDiffs b.compile n.compile).filter fun (k, x, y) =>
      !b.compile.contains k || !n.compile.contains k || (y - x).abs > max (x * 0.01) 1000
    if b.heartbeats && n.heartbeats then
      metrics := metrics.push {
        id := "heartbeats", label := "compile heartbeats", isExact := true,
        base := mapSum b.compile, new := mapSum n.compile, fmt := fmtHeartbeats, rows := d,
        bad := d.filter (fun (k, x, y) => b.compile.contains k && y - x > max (x * 0.01) 1000),
        rule := "a declaration up by more than 1% and 1,000 heartbeats; smaller changes not listed" }
    else
      metrics := metrics.push {
        id := "compile-time", label := "compile time (noisy)", isExact := false,
        base := mapSum b.compile, new := mapSum n.compile, fmt := fmtMs, rows := d, bad := #[],
        rule := "informational: run `leanprof elab --heartbeats` for an exact count" }
  let failed := metrics.filter fun m => m.isExact && !m.bad.isEmpty && o.failOn.contains m.id
  let mut out : Array String := #[]
  out := out.push s!"### {o.title}: {if failed.isEmpty then "✅ no regressions" else "❌ regression"}"
  out := out.push ""
  out := out.push "| metric | base | head | change | check |"
  out := out.push "|---|---:|---:|---:|---|"
  for m in metrics do
    let check :=
      if !m.isExact then "noisy, not checked"
      else if m.bad.isEmpty then (if m.new < m.base then "✅ pass (better)" else "✅ pass")
      else if o.failOn.contains m.id then "❌ fail"
      else "⚠️ worse (not enforced)"
    out := out.push s!"| {m.label} | {m.fmt m.base} | {m.fmt m.new} | {fmtChange m.fmt m.base m.new} | {check} |"
  if let some (b, n) := timeRow then
    out := out.push s!"| time (wall, noisy) | {fmtMs b.wall} | {fmtMs n.wall} | {fmtChange fmtMs b.wall n.wall} | noisy, not checked |"
  out := out.push ""
  let enforced := if o.failOn.isEmpty then "nothing (fail-on: none)" else ", ".intercalate o.failOn
  out := out.push s!"Exact metrics (copies, allocations, calls, heartbeats) do not vary between runs; time does, so it is shown but never checked. Enforced: {enforced}."
  let row (m : MdMetric) (k : String) (x y : Float) : String :=
    let mark := if !m.bad.any (·.1 == k) then "" else if o.failOn.contains m.id then " ❌" else " ⚠️"
    s!"| {mdCode k} | {m.fmt x} | {m.fmt y} | {fmtChange m.fmt x y}{mark} |"
  for m in metrics do
    if m.rows.isEmpty then continue
    out := out.push ""
    let openAttr := if m.bad.isEmpty then "" else " open"
    out := out.push s!"<details{openAttr}><summary>{m.label}: {m.rows.size} changed (regression: {m.rule})</summary>"
    out := out.push ""
    out := out.push s!"| {if m.id == "heartbeats" || m.id == "compile-time" then "declaration" else if m.id == "calls" then "scope" else "where"} | base | head | change |"
    out := out.push "|---|---:|---:|---:|"
    for (k, x, y) in (m.bad ++ m.rows.filter (fun r => !m.bad.any (·.1 == r.1))).toList.take o.top do
      out := out.push (row m k x y)
    if m.rows.size > o.top then out := out.push s!"\n… and {m.rows.size - o.top} more"
    out := out.push ""
    out := out.push "</details>"
  if let some (b, n) := timeRow then
    let d := (mdDiffs b.time n.time).filter fun (_, x, y) =>
      (x == 0 || (y - x).abs / x * 100 > o.threshold) && (y - x).abs / 1e6 > o.minMs
    unless d.isEmpty do
      out := out.push ""
      out := out.push s!"<details><summary>time: {d.size} {if d.size == 1 then "scope" else "scopes"} moved by more than {fmt2 o.threshold}% and {fmt2 o.minMs} ms (noisy)</summary>"
      out := out.push ""
      out := out.push "| scope | base | head | change |"
      out := out.push "|---|---:|---:|---:|"
      for (k, x, y) in d.toList.take o.top do
        out := out.push s!"| {mdCode k} | {fmtMs x} | {fmtMs y} | {fmtChange fmtMs x y} |"
      out := out.push ""
      out := out.push "</details>"
  IO.println ("\n".intercalate out.toList)
  return if failed.isEmpty then 0 else 1

/-! ## doctor -/

def doctor : IO UInt32 := do
  let mut problems := 0
  let report (ok : Bool) (what fix : String) : IO Bool := do
    IO.println s!"  {if ok then "ok " else "!! "} {what}{if ok || fix.isEmpty then "" else s!"\n       {fix}"}"
    return ok
  let tryCmd (cmd : String) (args : Array String) : IO (Option IO.Process.Output) := do
    try return some (← IO.Process.output { cmd, args }) catch _ => return none
  IO.println "leanprof doctor"
  -- Lean
  let lean ← tryCmd "lean" #["--version"]
  let leanOk := lean.any (·.exitCode == 0)
  unless ← report leanOk s!"Lean: {(lean.map (·.stdout.trimAscii.toString)).getD "not found"}"
      "install Lean with elan: https://github.com/leanprover/elan" do problems := problems + 1
  let lake ← tryCmd "lake" #["--version"]
  unless ← report (lake.any (·.exitCode == 0)) "Lake" "comes with Lean; is elan's bin directory on PATH?" do
    problems := problems + 1
  -- project
  let isProject := (← ("lakefile.toml" : FilePath).pathExists) || (← ("lakefile.lean" : FilePath).pathExists)
  unless ← report isProject "inside a Lake project" "run leanprof from a project's root directory" do
    problems := problems + 1
  let dep ← (pure (← ((".lake" : FilePath) / "packages" / "leanprof").pathExists) <||>
    (do return (← IO.FS.realPath (← packageRoot)) == (← IO.FS.realPath (← IO.currentDir))))
  discard <| report true (if dep then "project depends on leanprof (profile!, #leanprof, test assertions available)"
    else "project does not depend on leanprof (run/sample/elab still work; add it for profile! and #leanprof)") ""
  -- leanprof's own files
  let root ← packageRoot
  unless ← report (← (root / "scripts" / "leanprof-cc").pathExists) s!"leanprof files at {root}"
      "reinstall with scripts/install.sh" do problems := problems + 1
  -- C compiler for probes
  if leanOk then
    let leanPrefix := ((← tryCmd "lean" #["--print-prefix"]).map (·.stdout.trimAscii.toString)).getD ""
    let tmp := (← IO.FS.createTempFile).2
    let out ← tryCmd "cc" #["-fsyntax-only", "-I", leanPrefix ++ "/include", (root / "c" / "leanprof.c").toString]
    unless ← report (out.any (·.exitCode == 0)) "C compiler builds leanprof's runtime for this Lean"
        s!"{(out.map (·.stderr.take 300 |>.toString)).getD "cc not found"}" do problems := problems + 1
    let probe := tmp.withExtension "c"
    IO.FS.writeFile probe "int f(int x) { return x + 1; }\n"
    let clang ← tryCmd "sh" #["-c", s!"LEANPROF_AUTO=1 {root / "scripts" / "leanprof-cc"} -c {probe} -o {tmp}.o"]
    unless ← report (clang.any (·.exitCode == 0)) "clang with -finstrument-functions-after-inlining (for --auto)"
        "install clang (Xcode command line tools, or your distribution's clang package)" do problems := problems + 1
  -- samply
  let samply ← tryCmd "samply" #["--version"]
  discard <| report (samply.any (·.exitCode == 0))
    s!"{(samply.map (·.stdout.trimAscii.toString)).getD "samply"} (for `leanprof sample`)"
    "optional: brew install samply, or cargo install samply"
  IO.println (if problems == 0 then "everything leanprof needs is here" else s!"{problems} problem(s)")
  return if problems == 0 then 0 else 1

/-! ## stat -/

/-- `n` with thousands separators. -/
def withCommas (n : Nat) : String :=
  let ds := (toString n).toList.reverse
  let grouped := (List.range ds.length).zip ds |>.foldl (init := []) fun acc (i, c) =>
    if i > 0 && i % 3 == 0 then c :: ',' :: acc else c :: acc
  String.ofList grouped

def fmtBytes (b : Float) : String :=
  if b < 1024 then s!"{b.toUInt64} B"
  else if b < 1024 * 1024 then s!"{fmt2 (b / 1024)} KiB"
  else if b < 1024 * 1024 * 1024 then s!"{fmt2 (b / 1048576)} MiB"
  else s!"{fmt2 (b / 1073741824)} GiB"

def fmtTime (ns : Float) : String :=
  if ns < 1e3 then s!"{ns.toUInt64} ns"
  else if ns < 1e6 then s!"{fmt2 (ns / 1e3)} µs"
  else if ns < 1e9 then s!"{fmt2 (ns / 1e6)} ms"
  else s!"{fmt2 (ns / 1e9)} s"

def statCmd (argv : List String) : IO UInt32 := do
  -- allocations and frees are on unless turned off
  let (offAllocs, argv) := (argv.contains "--no-allocs", argv.filter (· != "--no-allocs"))
  let (offFrees, argv) := (argv.contains "--no-frees", argv.filter (· != "--no-frees"))
  let opts ← IO.ofExcept (parseRun {} argv)
  let some exe := opts.exe | throw <| IO.userError (usageFor "stat")
  let allocs := !offAllocs
  let frees := !offFrees
  let rc ← buildWithShims exe opts.auto allocs (frees := frees)
  if rc != 0 then return rc
  IO.FS.createDirAll ((".lake" : FilePath) / "leanprof")
  let json := opts.json.getD ".lake/leanprof/report.json"
  if ← (json : FilePath).pathExists then IO.FS.removeFile json
  let env := #[("LEANPROF_QUIET", some "1"), ("LEANPROF_STAT", some "1"), ("LEANPROF_JSON", some json),
    ("LEANPROF_TRACE", opts.trace)]
  let t0 ← IO.monoNanosNow
  let code ← try runInstrumented exe opts env
    finally
      unless opts.keep do cleanupInstrumented exe
  let outside := (← IO.monoNanosNow) - t0
  unless ← (json : FilePath).pathExists do
    IO.eprintln s!"leanprof: {exe} wrote no report (exit code {code}); was it killed?"
    return if code == 0 then 1 else code
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile json))
  let mem := (j.getObjVal? "memory").toOption.getD Json.null
  let user := num mem "user_ns"
  let sys := num mem "sys_ns"
  let row (k v : String) := IO.println s!"  {k.pushn ' ' (13 - k.length)}{v}"
  IO.println s!"\nleanprof stat: {" ".intercalate (exe :: opts.args.toList)}   (exit code {code})\n"
  -- the program's own wall time (start to exit), not leanprof's report or process launch
  let wall := num mem "wall_ns"
  row "wall" s!"{fmtTime wall}  ({fmtTime outside.toFloat} including process start and the report)"
  row "CPU" s!"{fmtTime user} user + {fmtTime sys} system ({fmt2 ((user + sys) / (if wall > 0 then wall else 1))} cores)"
  row "peak memory" s!"{fmtBytes (num mem "peak_rss")} resident, {fmtBytes (num mem "peak_commit")} committed by Lean's allocator"
  let allocSites := getArr j "allocations"
  if allocs then
    let n := allocSites.foldl (fun a s => a + num s "allocs") 0
    let b := allocSites.foldl (fun a s => a + num s "bytes") 0
    row "allocations" s!"{withCommas n.toUInt64.toNat} objects, {fmtBytes b} (by compiled Lean code)"
  else row "allocations" "not counted (--no-allocs)"
  let copies := (getArr j "copies").filter fun c => num c "shared" + num c "multi_threaded" > 0
  let nc := copies.foldl (fun a c => a + num c "shared" + num c "multi_threaded") 0
  let bc := copies.foldl (fun a c => a + num c "bytes") 0
  let tc := copies.foldl (fun a c => a + num c "copy_ns") 0
  row "copies" s!"{withCommas nc.toUInt64.toNat} of shared values, {fmtBytes bc}, {fmtTime tc}"
  match j.getObjVal? "frees" with
  | .ok f =>
    row "frees" s!"{withCommas (num f "objects").toUInt64.toNat} objects in {withCommas (num f "cascades").toUInt64.toNat} cascades, {fmtTime (num f "free_ns")} (pause p99 {fmtTime (num f "p99_ns")}, max {fmtTime (num f "max_ns")})"
    row "" s!"{withCommas (num f "mt_decrements").toUInt64.toNat} atomic decrements of multi-threaded objects"
  | .error _ => row "frees" (if frees then "none seen" else "not tracked (--no-frees)")
  let tasks := getArr j "tasks"
  let nt := tasks.foldl (fun a t => a + num t "tasks") 0
  let rt := tasks.foldl (fun a t => a + num t "run_sum_ns") 0
  row "tasks" (if nt == 0 then "none spawned" else s!"{withCommas nt.toUInt64.toNat} spawned, {fmtTime rt} run")
  let scopes := (getArr j "scopes").qsort fun a b => num a "total_ns" > num b "total_ns"
  if scopes.isEmpty then
    row "top scopes" "none (mark code with profile!, or pass --auto)"
  else
    let jw := num j "wall_ns" - num j "probe_ns"
    for i in [0:min 3 scopes.size] do
      let s := scopes[i]!
      let pos := str s "pos"
      let pct := if jw > 0 then s!"  {fmt2 (num s "total_ns" / jw * 100)}%" else ""
      row (if i == 0 then "top scopes" else "")
        s!"{fmtTime (num s "total_ns")}{pct}  {str s "name"}{if pos.isEmpty then "" else s!"  ({pos})"}"
  if allocs || frees || opts.auto.isSome then
    IO.println "\n  times include the probes' cost; `leanprof run` and the JSON report have the details"
  IO.println s!"  report: {json}"
  return code

def main (argv : List String) : IO UInt32 := do
  try
    match argv with
    | [] | ["help"] | ["--help"] | ["-h"] =>
      IO.println usage
      return 0
    | ["help", c] | [c, "--help"] | [c, "-h"] =>
      match commandHelp c with
      | some h => IO.println h; return 0
      | none => IO.eprintln usage; return 2
    | ["doctor"] => doctor
    | "run" :: rest => run rest
    | "stat" :: rest => statCmd rest
    | "measure" :: rest => measureCmd rest
    | "judge" :: rest => judgeCmd rest
    | "compare" :: rest => compare rest
    | "report-md" :: rest => reportMd rest
    | "sample" :: rest => sample rest
    | "elab" :: rest => elabCmd rest
    | "explain" :: rest =>
      Leanprof.Explain.explainCmd rest fun args env => do spawnWait (← IO.appPath).toString args env
    | "html" :: rest => LeanprofHtml.htmlCmd (usageFor "html") rest
    | "top" :: rest => LeanprofLive.topCmd rest
    | "dump" :: rest => LeanprofLive.dumpCmd rest
    | "mcp" :: rest => LeanprofLive.mcpCmd rest
    | _ =>
      IO.eprintln usage
      return 2
  catch e =>
    IO.eprintln s!"leanprof: {e}"
    return 2
