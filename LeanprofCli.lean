import Lean.Data.Json
import Leanprof.Core
import Leanprof.Explain
import Leanprof.Fix
import Leanprof.Experiment
import Leanprof.Judge
import Leanprof.Regress
import Leanprof.Workload
import LeanprofHtml
import LeanprofLive
import LeanprofElab
import Leanprof.BuildCmd

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
open Leanprof.Regress (mdCode mdProse htmlCode)

/-- One line per command, then its options and what it does. -/
def commands : List (String × String × String) := [
  ("run", "[--auto | --auto-all] [--time-tiny] [--allocs] [--counters] [--frees] [--core] [--all-copies] [--no-deps] [--trace FILE] [--json FILE] [--keep] [--cwd DIR] EXE [-- ARGS...]",
    "Build EXE with probes (copies of shared values, tasks, blocking waits; --auto: every function's\n" ++
    "time, except functions too small to time, which --time-tiny includes; --allocs: allocations; --counters: failed constructor reuse and closure applications;\n" ++
    "--frees: freeing pauses and atomic decrements), run it, print the report and save it to\n" ++
    ".lake/leanprof/report.json, the last report (what explain, html and #leanprof read; --json FILE,\n" ++
    "or --out FILE, also saves it to FILE). Memory (peak, per scope) is always sampled.\n" ++
    "Works in any Lake project: leanprof's runtime is compiled for the project's Lean version.\n" ++
    "Dependencies are rebuilt with the probes too (their normal build is put back afterwards, so\n" ++
    "nothing is recompiled after); --no-deps rebuilds only this package (faster with large ones).\n" ++
    "--core also sees copies, tasks (and with --allocs, allocations) inside Lean's precompiled\n" ++
    "libraries, by linking against copies rewritten with llvm-objcopy (cached in .lake/leanprof/core).\n" ++
    "--all-copies lists copies of constants and of empty or tiny values row by row (summarized\n" ++
    "by default). --trace FILE also writes a Perfetto timeline; --keep keeps the instrumented build;\n" ++
    "--cwd DIR runs EXE in DIR (for programs that read the current directory)."),
  ("stat", "[--auto | --auto-all] [--time-tiny] [--no-allocs] [--no-frees] [--no-deps] [--trace FILE] [--json FILE] [--keep] [--cwd DIR] EXE [-- ARGS...]",
    "Build EXE with probes, run it and print a one-screen summary: wall and CPU time, peak memory,\n" ++
    "allocations, copies, frees, tasks and the top 3 scopes. Allocations and frees are counted\n" ++
    "unless turned off (they slow the program down); --auto times every function."),
  ("sample", "[--rate HZ] [--top N] [--out FILE] [--json FILE] [--cwd DIR] EXE [-- ARGS...]",
    "Run EXE under samply (no probes) and report CPU time per Lean declaration with file:line,\n" ++
    "plus where the Lean runtime's time went. `samply load` on the saved profile (--out FILE) opens a flame\n" ++
    "graph with Lean names. The sampled report becomes the last report, .lake/leanprof/report.json\n" ++
    "(--json FILE also saves it to FILE). EXE is a target of this project or a path to any program, such as\n" ++
    "a toolchain's bin/lean (Lean's own code is named and placed in the toolchain's sources).\n" ++
    "Needs samply: the one on PATH, else the one `install.sh --samply` put in leanprof's home\n" ++
    "(`leanprof doctor` says how to get it)."),
  ("elab", "[--heartbeats] [--compact] [--project | --module-glob GLOB] [--jobs N] [--counts] [--threshold N] [--no-defs] [--no-driver] [--top N] [--out FILE] [FILE.lean...]",
    "Compile cost per line and declaration: elaboration, kernel, compiler, linters, by kind of\n" ++
    "operation, repeated work, and the definitions behind the work (what isDefEq and whnf unfolded,\n" ++
    "instances tried, simp lemmas), each with its own file:line. --project profiles every built module of\n" ++
    "the package in parallel (--module-glob: those matching, e.g. 'Foo.Data.*'). --counts adds Lean's exact\n" ++
    "unfold counts (slower). --heartbeats counts\n" ++
    "heartbeats, which are nearly the same on every run. Terms and tactics are timed by exact source range\n" ++
    "(line:column); --compact times only those (close to plain lean). On another Lean than leanprof's,\n" ++
    "the first run builds its driver for that Lean (seconds, once; ~/.cache/leanprof/drivers).\n" ++
    "--no-driver elaborates with `lean --json` instead."),
  ("build", "[--clean] [--jobs N] [--validate K] [--imports K] [--top N] [--json FILE] [--html FILE] [--from FILE] [--keep-worktree] [--quiet] [TARGETS...]",
    "Measure a real `lake build` (TARGETS, default the package's): every process Lake runs (module,\n" ++
    "C compile, link) with its start, end, peak memory and CPU time, recorded through a copy of the\n" ++
    "toolchain whose programs run through leanprof's shim; the build itself is a normal one.\n" ++
    "Reports the critical path (and each job's slack), how many jobs ran over time and where the build\n" ++
    "was serialized, and an estimate of the rebuild after touching each module (a scheduling\n" ++
    "simulation of the measured durations with --jobs workers, default the hardware threads).\n" ++
    "--clean removes .lake/build first, so every module of the package is rebuilt (dependencies stay).\n" ++
    "--validate K touches K modules in a git worktree and rebuilds, to compare with the estimates.\n" ++
    "--imports K tries removing the K most promising imports there; one counts only if the build,\n" ++
    "proofs included, passes. Writes .lake/leanprof/build.json (--json FILE); --html FILE draws the\n" ++
    "timeline with the critical path; --from FILE shows a saved report."),
  ("compare", "[--threshold PCT] [--min-ms MS] [--explain NEW_EXPLAIN.json] BASE.json NEW.json",
    "Exit 1 on a regression: more copies, more allocations in total (when both reports counted\n" ++
    "them), changed call counts, compile heartbeats up by more than 1% and 1,000, or a scope slower\n" ++
    "by more than PCT% (default 10) and MS ms (default 1). For each declaration that got more\n" ++
    "expensive, what changed inside it (definitions unfolded, instances, simp lemmas, repeated work,\n" ++
    "`--counts` counters); --explain names explain's cause for each copy site that copies more."),
  ("measure", "[--runs N] [--warmup N] [--scope NAME] [--heartbeats-files F.lean...] [--check-output FILE] [--ignore-lines TEXT]... [--no-allocs] [--core] [--no-deps] [--out FILE] EXE [-- ARGS...]",
    "Run EXE N times (default 5) with probes and write one summary: time spread, copies,\n" ++
    "allocations (unless --no-allocs), calls, compile heartbeats, exit code and an output hash.\n" ++
    "--core also counts copies and allocations inside Lean's precompiled libraries (as `run --core`);\n" ++
    "judge compares only summaries measured the same way.\n" ++
    "--scope NAME times only the `profile! \"NAME\"` scope (its total per run), not the whole process.\n" ++
    "--ignore-lines TEXT leaves stdout's lines containing TEXT out of its hash (a benchmark's own timings).\n" ++
    "For `judge` and autoresearch loops."),
  ("measure-pair", "(--base BIN --candidate BIN [--base-cwd DIR] | --base-rev REV --exe NAME [--candidate BIN]) [--candidate-cwd DIR] [--runs N] [--fixed] [--min-change PCT] [--scope NAME] [--warmup N] [--check-output FILE] [--ignore-lines TEXT]... [--out FILE] [-- ARGS...]",
    "Measure two prebuilt binaries in alternating AB/BA order (1 warmup pair), stopping as soon as the\n" ++
    "time verdict is settled: slower or faster by more than PCT% (default 1), or within ±PCT%; at most N\n" ++
    "pairs (default 30), looking after 6, 8, 10, ... pairs (a group-sequential sign test: each of these\n" ++
    "claims is wrong at most 2.5% of the time). --fixed measures exactly N pairs instead.\n" ++
    "--scope NAME times only the region the program wraps in `Leanprof.bench \"NAME\"` (or reports as\n" ++
    "`NAME<TAB>NANOSECONDS` lines appended to $LEANPROF_BENCH_OUT), not the whole process.\n" ++
    "--base-rev REV --exe NAME builds NAME at git revision REV once, kept in .lake/leanprof/base by commit\n" ++
    "and build settings, and builds the candidate with `lake build NAME` in --candidate-cwd (default .).\n" ++
    "No probes are added. Saves every timing, exit status and output hash in one session,\n" ++
    "and prints `judge PAIR.json`'s verdict."),
  ("judge", "[--min-change PCT] [--allow-overloaded] BASE.json NEW.json | PAIR.json",
    "KEEP (exit 0) if nothing got worse and something improved beyond noise; DISCARD (exit 1) if\n" ++
    "output or exit code changed, or copies, allocations, heartbeats or time got worse. Time counts only\n" ++
    "when the runs do not overlap and the median moved by at least PCT% (default 1), and never when the\n" ++
    "machine was overloaded while measuring (--allow-overloaded judges a paired session anyway, for a\n" ++
    "machine that is always shared; the verdict says so)."),
  ("report-md", "[--fail-on copies,allocs,calls,heartbeats|none] [--title T] [--threshold PCT] [--min-ms MS] [--top N] [--explain NEW_EXPLAIN.json] [--max-chars N] BASE.json NEW.json [BASE_ELAB.json NEW_ELAB.json]",
    "Markdown summary of two `run --json` reports (and optionally two `elab --heartbeats` reports), for a\n" ++
    "pull-request comment: copies, allocations, calls, compile heartbeats and time, base against head,\n" ++
    "with pass/fail per exact metric, and why each regressed declaration or copy site got worse (as\n" ++
    "`compare`). At most N characters (default 60000, under GitHub's comment limit).\n" ++
    "Exit 1 if a metric named by --fail-on (default: copies) regressed."),
  ("explain", "[--report FILE] [--out FILE] [--top N] [--all] [--json] [--why EXE [-- ARGS...]]",
    "For each copy of a shared value in the last report, say where the second reference comes from,\n" ++
    "read from the compiler's IR (.lake/build/ir/*.c), with source lines and, when the cause is\n" ++
    "recognised, the fix as Lean code with the program's own names. --json prints the ranked findings\n" ++
    "(cause, location, fix and fix code, cost) for agents. --why EXE first reruns EXE recording where\n" ++
    "each copied value became shared. Writes .lake/leanprof/explain.json (or --out FILE) for\n" ++
    "#leanprof hovers."),
  ("fix", "[--exe EXE [-- ARGS...]] [--test CMD] [--check-output FILE] [--finding N] [--all] [--dry-run] [--report FILE] [--runs N] [--pairs N] [--no-deps] [--branch NAME] [--allow-overloaded]",
    "Apply the fix `explain` prints for the costliest copy whose cause has a mechanical edit\n" ++
    "(Array.modify for an element of an outer array, HashMap alter/modify/erase for a value read and\n" ++
    "inserted back, an index loop for a loop over the array it updates), then check it: on a new git\n" ++
    "branch, build, run the tests (--test CMD, or `lake test` when the project has a test driver),\n" ++
    "compare the output with the original's (stdout, or --check-output FILE), measure both versions\n" ++
    "(exact copies and allocations), time both plain binaries in pairs (measure-pair), and judge.\n" ++
    "KEEP commits on the branch with the evidence in the message; DISCARD deletes the branch and says\n" ++
    "why. The checkout is left as it was; a tree with uncommitted changes is refused. --exe profiles\n" ++
    "EXE first (otherwise the last report is read); --finding N picks finding N of the list printed;\n" ++
    "--all also considers copy sites of only empty or tiny values (as explain --all); --dry-run\n" ++
    "prints the findings and the diff only."),
  ("experiment", "start [--exe EXE [--inputs DIR] [--cases FILE] [--heldout DIR] [--check-output FILE]... [--ignore-lines TEXT]... [-- ARGS...]] [--test CMD | --no-test] [--protect GLOB]... [--runs N] [--pairs N] [--min-change PCT] [--no-deps] [--base REV] [--id ID] | try [REV | --working-tree] [--time] [--no-commit] [--message MSG] [--allow-overloaded] [--json] [--id ID] | finish [--keep-worktrees] [--json] [--id ID] | status [--json] [--id ID]",
    "One experiment, from baseline to verdict. `start` records the base (HEAD, or --base REV) in a git\n" ++
    "worktree under .lake/leanprof/experiments/ID: the build (default targets and EXE), the tests (--test CMD,\n" ++
    "or `lake test` with a test driver), the behaviour on every case (ARGS, ARGS with each file of --inputs DIR\n" ++
    "in place of {} or appended, each line of --cases FILE; stdout, stderr, exit code and each --check-output\n" ++
    "file, the same on two runs; --ignore-lines TEXT: lines containing TEXT are not compared), the held-out cases (--heldout DIR, as hashes only) and `measure`.\n" ++
    "`try` checks a commit or the working tree in a worktree of its own, each step only after the one before\n" ++
    "passed: build; the proof-preservation audit of the changed modules and their dependents (DISCARD for\n" ++
    "sorry, a new axiom, implemented_by, extern, unsafe or partial, a removed theorem, a changed test, expected\n" ++
    "output or input; INCONCLUSIVE when a theorem statement or a definition it uses changed); tests; identical\n" ++
    "behaviour on every case; then, if the generated C is the base's, compile heartbeats only (--time times it\n" ++
    "anyway), else exact counts (`measure`; worse: DISCARD without timing) and paired timing (`measure-pair`).\n" ++
    "Without --exe the measure is `elab --heartbeats` on the changed modules and their dependents.\n" ++
    "Exit code 0 KEEP, 1 DISCARD, 2 ERROR, 3 INCONCLUSIVE; evidence in tries/N/evidence.json (--json prints it).\n" ++
    "A KEEP becomes the base; from the working tree it is committed on the current branch with the evidence\n" ++
    "in the message (--no-commit: not), a commit gets a git note (refs/notes/leanprof-experiments).\n" ++
    "`finish` runs the held-out cases on the final base and removes the worktrees; exit 1 if they differ."),
  ("html", "[-o FILE] [--trace FILE] [--profile FILE] [--threshold PCT] [--min-ms MS] [--context N] [--title T] [--ranges N] [--keep N] [REPORT.json...]",
    "One self-contained HTML page (no network) from reports (default: report.json, elab.json and\n" ++
    "measure.json in .lake/leanprof/), written to .lake/leanprof/report.html unless -o is given:\n" ++
    "summary, flame graph, sortable tables, source lines with hints, and a comparison when given\n" ++
    "two reports of a kind (base, then new; regressions as `compare` counts them). The flame graph\n" ++
    "of a sampled report reads samply's profile next to it (or --profile FILE); for a run report,\n" ++
    "pass the timeline of `run --trace FILE` as --trace FILE. A compile-time report (elab.json) opens\n" ++
    "on a drill-down: project, folder, module, declaration, term or tactic, each with repeated work and\n" ++
    "the definitions behind the work, compared level by level with a base; --ranges N keeps the N\n" ++
    "costliest term and tactic ranges (default 2000), --keep N the N costliest repeated operations and\n" ++
    "definitions, and the operations inside the N costliest declarations (default 3000)."),
  ("top", "[--interval MS] [--rows N] [--frames N] [--plain] [--flight DIR] [--slow-ms MS] [run options] EXE [-- ARGS...] | --attach FILE | --pid PID",
    "Run EXE with probes (as `run`) and show it live, refreshed like top: hottest scopes, copy sites,\n" ++
    "allocation sites, tasks and waits with rates per second, memory, CPU and what each thread is inside.\n" ++
    "--attach/--pid watch a program started with LEANPROF_LIVE=FILE or LEANPROF_LIVE=1. --flight and\n" ++
    "--slow-ms turn on the flight recorder. Plain ANSI; --plain (or no terminal) prints frames."),
  ("dump", "[--timeout S] PID",
    "Ask a program running with the flight recorder (LEANPROF_FLIGHT, LEANPROF_SLOW_MS) for a Perfetto\n" ++
    "trace of its last seconds (SIGUSR1) and print its path."),
  ("mcp", "",
    "Model Context Protocol server on stdio for AI agents: tools to run, sample, stat, elab, build, measure and\n" ++
    "measure_pair targets, read reports, list hot scopes/copies/allocations with file:line, compare,\n" ++
    "judge (measure summaries or a paired session), and\n" ++
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
  | "build" => "a real lake build: critical path, parallelism, rebuild cost per module, verified imports"
  | "compare" => "compare two reports, exit 1 on regressions (for CI)"
  | "measure" => "run a program several times into one summary (for judge / autoresearch)"
  | "measure-pair" => "interleave two prebuilt binaries for paired timing and correctness checks"
  | "judge" => "KEEP or DISCARD from measure summaries or one paired session"
  | "report-md" => "Markdown summary of base and head reports, for pull-request comments"
  | "explain" => "why each copy happened: where the second reference comes from, and a fix"
  | "experiment" => "start an experiment, try candidates (KEEP/DISCARD/INCONCLUSIVE with evidence), finish on held-out inputs"
  | "fix" => "apply explain's fix on a new branch, test, measure and judge it; commit KEEPs with the evidence"
  | "html" => "one self-contained HTML report: flame graph, tables, source, comparison"
  | "top" => "live view of a running program: hot scopes, copies, allocations, tasks, per second"
  | "dump" => "write a running program's last seconds to a Perfetto trace (flight recorder)"
  | "mcp" => "MCP server on stdio: profiling tools for AI agents"
  | "doctor" => "check that leanprof's tools and the project are set up"
  | "help" => "this overview, or one command's options"
  | _ => ""

def usage : String :=
  "leanprof: profiler for Lean 4 programs (https://github.com/unbalancedparentheses/leanprof)\n\n" ++
  "usage: leanprof COMMAND [OPTIONS]   (or `lake exe leanprof` in a project that depends on it)\n" ++
  "In a Lake project, `leanprof` alone (or `leanprof EXE -- ARGS`) finds what to profile, profiles it and says what next.\n\n" ++
  String.join (commands.map fun (c, _, _) => s!"  {c.pushn ' ' (14 - c.length)}{summary c}\n") ++
  "\nleanprof help COMMAND shows a command's options. Docs: docs/guide/getting-started.md"

def commandHelp (c : String) : Option String :=
  (commands.find? (·.1 == c)).map fun (c, opts, d) => s!"usage: leanprof {c} {opts}\n\n{d}"

def usageFor (c : String) : String := (commandHelp c).getD usage

/-! ## The tools leanprof uses, and how to install them -/

/-- The system's package manager, for install commands. -/
inductive Os where
  | mac | debian | arch | fedora | linux
  deriving BEq

def detectOs : IO Os := do
  if System.Platform.isOSX then return .mac
  let rel ← try IO.FS.readFile "/etc/os-release" catch _ => pure ""
  let field (k : String) : String := ((rel.splitOn "\n").find? (·.startsWith s!"{k}=")).map
    (fun l => ((l.drop (k.length + 1)).toString.replace "\"" "")) |>.getD ""
  let ids := (field "ID" ++ " " ++ field "ID_LIKE").splitOn " "
  if ids.any (· ∈ ["debian", "ubuntu"]) then return .debian
  if ids.any (· ∈ ["arch", "manjaro"]) then return .arch
  if ids.any (· ∈ ["fedora", "rhel", "centos"]) then return .fedora
  return .linux

/-- The command that installs `tool` (`clang` or `objcopy`) on this system. -/
def installHint (tool : String) : IO String := do
  let os ← detectOs
  return match tool, os with
    | "clang", .mac => "xcode-select --install   (Apple's command line tools; or brew install llvm)"
    | "clang", .debian => "sudo apt install clang"
    | "clang", .arch => "sudo pacman -S clang"
    | "clang", .fedora => "sudo dnf install clang"
    | "clang", _ => "install clang with your distribution's package manager"
    | _, .mac => "brew install llvm   (or set LEANPROF_OBJCOPY to an llvm-objcopy)"
    | _, .debian => "sudo apt install llvm   (or binutils, for GNU objcopy)"
    | _, .arch => "sudo pacman -S llvm   (or binutils, for GNU objcopy)"
    | _, .fedora => "sudo dnf install llvm   (or binutils, for GNU objcopy)"
    | _, _ => "install llvm (llvm-objcopy) or binutils (objcopy), or set LEANPROF_OBJCOPY"

/-- What is wrong with the C compiler (`cc`), if anything, and how to fix it:
it is missing, or on macOS a stub that asks for the command line tools. -/
def ccProblem : IO (Option String) := do
  let out ← try some <$> IO.Process.output { cmd := "cc", args := #["--version"], stdin := .null }
    catch _ => pure none
  match out with
  | some o =>
    if o.exitCode == 0 then return none
    let why := (o.stderr.trimAscii.toString.splitOn "\n").head!
    return some s!"the C compiler does not run ({why}); install one: {← installHint "clang"}"
  | none => return some s!"no C compiler (cc) found; install one: {← installHint "clang"}"

/-- Where the installer keeps releases, the source checkout and samply:
`LEANPROF_HOME` (the installed launcher sets it), else `~/.local/share/leanprof`. -/
def leanprofHome : IO FilePath := do
  if let some h ← IO.getEnv "LEANPROF_HOME" then
    if !h.isEmpty then return h
  return ((← IO.getEnv "HOME").getD ".") ++ "/.local/share/leanprof"

/-- The samply the installer fetched (`install.sh --samply`). -/
def bundledSamply : IO FilePath := return (← leanprofHome) / "samply" / "samply"

/-- The samply to run: `LEANPROF_SAMPLY` (`none`: act as if there were none),
else the one on PATH, else the one the installer fetched into leanprof's home;
`none` if there is none. -/
def findSamply : IO (Option String) := do
  if let some s ← IO.getEnv "LEANPROF_SAMPLY" then
    if s == "none" then return none
    if !s.isEmpty then return some s
  let runs (cmd : String) : IO Bool := do
    try return (← IO.Process.output { cmd, args := #["--version"], stdin := .null }).exitCode == 0
    catch _ => return false
  if ← runs "samply" then return some "samply"
  let b ← bundledSamply
  if (← b.pathExists) && (← runs b.toString) then return some b.toString
  return none

/-- The command that fetches the pinned samply into leanprof's home. -/
def samplyInstallCmd : IO String := do
  let home ← IO.getEnv "LEANPROF_HOME"
  let def_ := ((← IO.getEnv "HOME").getD "") ++ "/.local/share/leanprof"
  let pre := match home with
    | some h => if h.isEmpty || h == def_ then "" else s!"LEANPROF_HOME={h} "
    | none => ""
  return s!"curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | {pre}sh -s -- --samply-only"

/-- Why `leanprof sample` cannot sample on this machine, if it cannot: on
Linux, perf events must be open to users. -/
def samplingBlocked : IO (Option String) := do
  if System.Platform.isOSX then return none
  let v ← try IO.FS.readFile "/proc/sys/kernel/perf_event_paranoid" catch _ => return none
  let uid ← try (·.stdout.trimAscii.toString) <$> IO.Process.output { cmd := "id", args := #["-u"] }
    catch _ => pure ""
  let some n := v.trimAscii.toString.toInt? | return none
  if n > 1 && uid != "0" then
    return some s!"perf events are closed to users (kernel.perf_event_paranoid = {n}); open them with: sudo sysctl kernel.perf_event_paranoid=1"
  return none

/-- The project's targets, from its Lake configuration (`none` outside a project). -/
def projectTargets : IO (Option Leanprof.Workload.Targets) := do
  if ← ("lakefile.lean" : FilePath).pathExists then
    return some (Leanprof.Workload.parseLean (← IO.FS.readFile "lakefile.lean"))
  if ← ("lakefile.toml" : FilePath).pathExists then
    return some (Leanprof.Workload.parseToml (← IO.FS.readFile "lakefile.toml"))
  return none

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

/-- The directories of the workspace's packages: the root, and with `deps`
each dependency from `lake-manifest.json` (git packages under its
`packagesDir`, path packages where they are). -/
def workspacePackages (deps : Bool := true) : IO (Array FilePath) := do
  let mut dirs : Array FilePath := #["."]
  unless deps do return dirs
  let manifest : FilePath := "lake-manifest.json"
  unless ← manifest.pathExists do return dirs
  let some j := (Json.parse (← IO.FS.readFile manifest)).toOption | return dirs
  let pkgsDir : FilePath := ((j.getObjValAs? String "packagesDir").toOption.getD ".lake/packages")
  for p in (j.getObjVal? "packages" >>= Json.getArr?).toOption.getD #[] do
    let name := (p.getObjValAs? String "name").toOption.getD ""
    let dir : FilePath := match (p.getObjValAs? String "type").toOption with
      | some "path" => (p.getObjValAs? String "dir").toOption.getD name
      | _ => match (p.getObjValAs? String "subDir").toOption with
        | some sub => pkgsDir / name / sub
        | none => pkgsDir / name
    if ← dir.isDir then dirs := dirs.push dir
  return dirs

/-- Where a package's normal objects wait while an instrumented build uses
its `.lake/build/ir`. -/
def stashDir (pkg : FilePath) : FilePath := pkg / ".lake" / "leanprof" / "normal-objects"

/-- Move compiled C objects (`*.c.o*`, with Lake's trace files) from `src`
to the same place under `dst`; returns how many. -/
partial def moveObjects (src dst : FilePath) : IO Nat := do
  unless ← src.isDir do return 0
  let mut n := 0
  for e in ← src.readDir do
    if ← e.path.isDir then
      n := n + (← moveObjects e.path (dst / e.fileName))
    else if (e.fileName.splitOn ".c.o").length > 1 then
      IO.FS.createDirAll dst
      IO.FS.rename e.path (dst / e.fileName)
      n := n + 1
  return n

/-- Put back the normal objects of every package a previous instrumented
build set aside (none if there was none): the instrumented ones go. Run
after profiling, and before, in case a run was interrupted or used `--keep`. -/
def restoreObjects : IO Unit := do
  for pkg in ← workspacePackages do
    let stash := stashDir pkg
    unless ← stash.isDir do continue
    discard <| removeObjects (pkg / ".lake" / "build" / "ir")
    discard <| moveObjects stash (pkg / ".lake" / "build" / "ir")
    IO.FS.removeDirAll stash

/-- Set aside the compiled objects of the root package and, with `deps`, of
every dependency, so Lake recompiles them through the wrapper (it does not
notice a new `LEAN_CC`) and `restoreObjects` can put the normal build back
without recompiling. Returns how many objects and packages. -/
def stashObjects (deps : Bool) : IO (Nat × Nat) := do
  restoreObjects
  let mut n := 0
  let mut pkgs := 0
  for pkg in ← workspacePackages deps do
    -- the stash marks the package even when empty: what is built in it now
    -- is instrumented and goes afterwards
    IO.FS.createDirAll (stashDir pkg)
    let moved ← moveObjects (pkg / ".lake" / "build" / "ir") (stashDir pkg)
    n := n + moved
    if moved > 0 then pkgs := pkgs + 1
  return (n, pkgs)
/-- The environment `lake exe` runs a program with (`lake env` in `dir`): the
workspace's `LEAN_PATH`, `LEAN_SYSROOT`, library paths and so on. Programs
that load Lean modules at run time (`importModules`, `supportInterpreter`)
fail without it. Empty outside a Lake project, or when `lake` is missing. -/
def lakeRunEnv (dir : Option FilePath := none) : IO (Array (String × Option String)) := do
  let out ← try IO.Process.output { cmd := "lake", args := #["env"], cwd := dir, stdin := .null }
    catch _ => return #[]
  if out.exitCode != 0 then return #[]
  return out.stdout.splitOn "\n" |>.toArray |>.filterMap fun line =>
    match line.splitOn "=" with
    | k :: v :: rest =>
      let v := "=".intercalate (v :: rest)
      if k.isEmpty || v.isEmpty || k.startsWith "LEANPROF_" then none else some (k, some v)
    | _ => none

/-- From now on, catch INT, TERM and HUP and pass them to process `pid`
(0: none), so that an interrupted command still puts the normal build back
(`c/cli.c`). -/
@[extern "leanprof_cli_guard"] opaque guardSignals (pid : UInt32) : IO Unit
/-- The signal caught by `guardSignals`'s handler, 0 if none. -/
@[extern "leanprof_cli_caught"] opaque caughtSignal : IO UInt32

/-- Stop if a signal was caught (the caller's `finally` puts the build back). -/
def checkInterrupted : IO Unit := do
  let s ← caughtSignal
  if s != 0 then throw <| IO.userError s!"interrupted by signal {s}"

def spawnWait (cmd : String) (args : Array String) (env : Array (String × Option String))
    (cwd : Option FilePath := none) : IO UInt32 := do
  let child ← IO.Process.spawn { cmd, args, env, cwd }
  guardSignals child.pid
  try child.wait finally guardSignals 0

/-- `IO.Process.output`, with INT, TERM and HUP passed on to the child
while it runs (`guardSignals`). -/
def guardedOutput (args : IO.Process.SpawnArgs) : IO IO.Process.Output := do
  let child ← IO.Process.spawn { args with stdout := .piped, stderr := .piped }
  guardSignals child.pid
  try
    let err ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
    let stdout ← child.stdout.readToEnd
    let stderr ← IO.ofExcept err.get
    let exitCode ← child.wait
    return { exitCode, stdout, stderr }
  finally guardSignals 0

structure RunOpts where
  auto : Option String := none
  timeTiny : Bool := false
  trace : Option String := none
  json : Option String := none
  keep : Bool := false
  allocs : Bool := false
  counters : Bool := false
  frees : Bool := false
  core : Bool := false
  deps : Bool := true
  allCopies : Bool := false
  cwd : Option String := none
  exe : Option String := none
  args : Array String := #[]

/-- `--time-tiny`: `--auto` also times functions too small to time
(scripts/leanprof-tiny.awk), which it otherwise leaves out. -/
def tinyEnv (opts : RunOpts) : Array (String × Option String) :=
  #[("LEANPROF_AUTO_TINY", if opts.timeTiny then some "1" else none)]

partial def parseRun (opts : RunOpts) : List String → Except String RunOpts
  | [] => .ok opts
  | "--auto" :: rest => parseRun { opts with auto := some "1" } rest
  | "--auto-all" :: rest => parseRun { opts with auto := some "all" } rest
  | "--time-tiny" :: rest => parseRun { opts with timeTiny := true } rest
  | "--trace" :: f :: rest => parseRun { opts with trace := some f } rest
  | "--json" :: f :: rest => parseRun { opts with json := some f } rest
  -- `--out` as in the other commands: where this command's report goes
  | "--out" :: f :: rest => parseRun { opts with json := some f } rest
  | "--keep" :: rest => parseRun { opts with keep := true } rest
  | "--allocs" :: rest => parseRun { opts with allocs := true } rest
  | "--counters" :: rest => parseRun { opts with counters := true } rest
  | "--frees" :: rest => parseRun { opts with frees := true } rest
  | "--core" :: rest => parseRun { opts with core := true } rest
  | "--no-deps" :: rest => parseRun { opts with deps := false } rest
  | "--all-copies" :: rest => parseRun { opts with allCopies := true } rest
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

/-- Put the normal build back, so running `exe` afterwards does not profile
it; with no normal build to put back, remove the instrumented one (Lake
builds a normal one next time). -/
def restoreExe (exe : String) (removeUnsaved := true) : IO Unit := do
  for f in exeFiles exe do
    let saved := savedDir / f.fileName.get!
    if ← saved.pathExists then
      discard <| IO.Process.output { cmd := "mv", args := #[saved.toString, f.toString] }
    else if removeUnsaved && (← f.pathExists) then
      IO.FS.removeFile f

/-- Undo an instrumented build: the normal objects of every package come
back (Lake does not notice a new `LEAN_CC`, and nothing is recompiled), and
so does the executable. -/
def cleanupInstrumented (exe : String) : IO Unit := do
  restoreObjects
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
Debian's LLVM directories), then GNU objcopy on Linux, then the llvm-objcopy
that rustup's toolchains ship as `rust-objcopy` (when it runs on its own). -/
def findObjcopy : IO (Option String) := do
  if let some p ← IO.getEnv "LEANPROF_OBJCOPY" then
    if !p.isEmpty then return some p
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
  -- rustup: ~/.rustup/toolchains/*/lib/rustlib/*/bin/rust-objcopy; some need
  -- their toolchain's libLLVM on the loader path, so only one that runs counts
  let some home ← IO.getEnv "HOME" | return none
  let tcs : FilePath := home ++ "/.rustup/toolchains"
  for tc in (← (try tcs.readDir catch _ => pure #[])).qsort (·.fileName > ·.fileName) do
    for host in (← (try (tc.path / "lib" / "rustlib").readDir catch _ => pure #[])) do
      let c := host.path / "bin" / "rust-objcopy"
      unless ← c.pathExists do continue
      let ok ← try pure ((← IO.Process.output { cmd := c.toString, args := #["--version"] }).exitCode == 0)
        catch _ => pure false
      if ok then return some c.toString
  return none

/-- The toolchain's Lean libraries with references to the redirected runtime
functions renamed to leanprof's shims, cached in `.lake/leanprof/core/` by
toolchain and set of renamed symbols. Returns the directory to search first. -/
def coreLibDir (allocs : Bool) (frees : Bool := false) : IO FilePath := do
  let some objcopy ← findObjcopy | throw <| IO.userError <|
    s!"--core needs llvm-objcopy, which is not installed; install it with:\n  {← installHint "objcopy"}"
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

/-- The environment Lake compiles a program's C in under `leanprof run`
(`leanc` calling the wrapper), with only the copy flags: how `c/selfcheck.c`
is compiled, so its copies take the same path as the program's. -/
def selfCheckEnv (wrapper : FilePath) : Array (String × Option String) :=
  #[("LEAN_CC", some wrapper.toString)] ++
    #["LEANPROF_AUTO", "LEANPROF_ALLOCS", "LEANPROF_COUNTERS", "LEANPROF_FREES", "LEANPROF_WHY"].map (·, none)

/-- `leanprof doctor`'s copy-detection check: builds a small C program from
leanprof's runtime and `c/selfcheck.c` (compiled and linked as `leanprof run`
does) and runs the self-check. Returns the operations checked and the
warning (empty when every known copy was counted), or why it could not run. -/
def selfCheckProbe (root : FilePath) : IO (Except String (String × String)) := do
  let wrapper := root / "scripts" / "leanprof-cc"
  let leanPrefix := (← IO.Process.output { cmd := "lean", args := #["--print-prefix"] }).stdout.trimAscii.toString
  let dir := (← IO.FS.createTempDir)
  let main := dir / "probe.c"
  -- no libc headers: on Linux the wrapper compiles with Lean's own leanc,
  -- whose sysroot has only what Lean's generated C includes
  IO.FS.writeFile main <| "#include <lean/lean.h>\nint puts(const char *);\n" ++
    "const char *leanprof_self_check_message(void);\nconst char *leanprof_self_check_ops(void);\n" ++
    "void lean_initialize_runtime_module(void);\n" ++
    "int main(void) {\n  lean_initialize_runtime_module();\n" ++
    "  puts(leanprof_self_check_ops());\n  puts(leanprof_self_check_message());\n  return 0;\n}\n"
  let env := selfCheckEnv wrapper ++ #[("LEANPROF_QUIET", some "1")]
  let steps : List (String × Array String × Array (String × Option String)) := [
    ("cc", #["-O0", "-fPIC", "-I", leanPrefix ++ "/include", "-c", (root / "c" / "leanprof.c").toString,
      "-o", (dir / "rt.o").toString], #[]),
    ("leanc", #["-c", (root / "c" / "selfcheck.c").toString, "-o", (dir / "sc.o").toString], env),
    ("leanc", #["-c", main.toString, "-o", (dir / "probe.o").toString], env),
    ("leanc", #["-o", (dir / "probe").toString, (dir / "probe.o").toString, (dir / "rt.o").toString,
      (dir / "sc.o").toString], env)]
  try
    for (cmd, args, env) in steps do
      let out ← IO.Process.output { cmd, args, env }
      if out.exitCode != 0 then
        return .error s!"{cmd} failed: {out.stderr.take 300}"
    let out ← IO.Process.output { cmd := (dir / "probe").toString, env := #[("LEANPROF_QUIET", some "1")] }
    if out.exitCode != 0 then return .error s!"the probe exited with {out.exitCode}: {out.stderr.take 300}"
    match out.stdout.splitOn "\n" with
    | ops :: msg :: _ => return .ok (ops, msg)
    | _ => return .error s!"unexpected output: {out.stdout}"
  catch e => return .error (toString e)
  finally
    discard <| IO.Process.output { cmd := "rm", args := #["-rf", dir.toString] }

/-- Forget Lake's records (`.trace`, `.hash`) of the instrumented objects of
the packages being profiled and of `exe`, once they are built. If leanprof is
killed before it puts the normal build back (SIGKILL, a crash), a plain
`lake build` then finds no record and compiles them normally again, instead
of keeping instrumented objects that would carry the runtime into every
later build. The next `leanprof run` (or `leanprof doctor`) restores the
normal objects without compiling. -/
partial def dropBuildRecords (deps : Bool) (exe : String) : IO Nat := do
  let rec go (dir : FilePath) : IO Nat := do
    unless ← dir.isDir do return 0
    let mut n := 0
    for e in ← dir.readDir do
      if ← e.path.isDir then n := n + (← go e.path)
      else if (e.fileName.splitOn ".c.o").length > 1 &&
          (e.fileName.endsWith ".trace" || e.fileName.endsWith ".hash") then
        IO.FS.removeFile e.path
        n := n + 1
    return n
  let mut n := 0
  for pkg in ← workspacePackages deps do
    n := n + (← go (pkg / ".lake" / "build" / "ir"))
  for f in (exeFiles exe).drop 1 do
    if (f.extension == some "trace" || f.extension == some "hash") && (← f.pathExists) then
      IO.FS.removeFile f
  return n

/-- Build `exe` with the copy shims in every package (with `deps := false`,
only the root package; and, with `auto`, every function timed). A project that does not depend on leanprof gets leanprof's
runtime compiled for its own Lean version, linked in by the wrapper. A failure
anywhere from setting the executable aside to the build itself puts the
normal build back. -/
def buildWithShims (exe : String) (auto : Option String) (allocs : Bool := false)
    (counters : Bool := false) (frees : Bool := false) (extraEnv : Array (String × Option String) := #[])
    (deps : Bool := true) : IO UInt32 := do
  let root ← packageRoot
  let wrapper := root / "scripts" / "leanprof-cc"
  unless ← wrapper.pathExists do
    throw <| IO.userError s!"compiler wrapper not found at {wrapper}"
  let leanOk ← try pure ((← IO.Process.output { cmd := "lean", args := #["--print-prefix"] }).exitCode == 0)
    catch _ => pure false
  unless leanOk do
    throw <| IO.userError ("`lean` was not found on PATH: add elan's bin directory " ++
      "(export PATH=$HOME/.elan/bin:$PATH); `leanprof doctor` checks the setup")
  -- a normal executable kept aside by an interrupted or `--keep` run comes back first
  restoreExe exe (removeUnsaved := false)
  -- From here every step changes the build (the executable is kept aside and
  -- removed, the runtime compiled, objects set aside, the build run): a
  -- failure at any of them, or a signal (caught from now on), puts the
  -- normal build back.
  guardSignals 0
  let exeRemoved ← IO.mkRef false
  let undo : IO Unit := do
    restoreObjects
    restoreExe exe (removeUnsaved := ← exeRemoved.get)
  let rc ← try
      saveExe exe
      -- Lake would keep an executable linked against an older leanprof runtime
      -- (the rebuilt objects hash the same): make it relink
      exeRemoved.set true
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
        let rt := cwd / ".lake" / "leanprof" / "runtime-core.o"
        let sc := cwd / ".lake" / "leanprof" / "runtime-selfcheck.o"
        -- -mno-outline as in the lakefile: Apple clang's outliner made the
        -- program's probes differ from (and cost more than) the calibrated ones
        let inc := #["-O2", "-fPIC"] ++ (if System.Platform.isOSX then #["-mno-outline"] else #[]) ++
          #["-I", leanPrefix ++ "/include", "-c"]
        -- the runtime, and its self-check compiled as Lake compiles the program's
        -- C (leanc with LEAN_CC set to the wrapper; copy flags only), in one object
        let steps : List (String × Array String × Array (String × Option String)) := [
          ("cc", inc ++ #[(root / "c" / "leanprof.c").toString, "-o", rt.toString], #[]),
          ("leanc", #["-O2", "-c", (root / "c" / "selfcheck.c").toString, "-o", sc.toString], selfCheckEnv wrapper),
          ("ld", #["-r", "-o", obj.toString, rt.toString, sc.toString], #[])]
        if let some p ← ccProblem then
          throw <| IO.userError s!"leanprof compiles its runtime with the C compiler: {p}"
        for (cmd, args, env) in steps do
          let out ← IO.Process.output { cmd, args, env }
          if out.exitCode != 0 then
            throw <| IO.userError s!"compiling leanprof's runtime failed ({cmd}):\n{out.stderr}"
        runtimeEnv := #[("LEANPROF_RUNTIME", some obj.toString)]
      checkInterrupted
      -- dependencies Lake has not downloaded yet (a fresh clone) are fetched
      -- first, so that they are set aside and put back like the others
      -- (loading the workspace resolves them; their output stays visible)
      if deps then discard <| spawnWait "lake" #["env", "true"] #[]
      checkInterrupted
      -- Lake does not notice a new LEAN_CC, so objects built without it must go:
      -- they wait in .lake/leanprof/normal-objects and come back afterwards
      let (stashed, pkgs) ← stashObjects deps
      IO.eprintln s!"leanprof: building {exe} with copy shims{if auto.isSome then " and every function timed" else ""}{if allocs then " and allocations counted" else ""}{if counters then " and reuse/closure counters" else ""}{if frees then " and frees timed" else ""} in {if deps then "every package" else "the root package only"} ({stashed} normal objects of {pkgs} package{if pkgs == 1 then "" else "s"} set aside)"
      let buildEnv := #[("LEAN_CC", some wrapper.toString), ("LEANPROF_AUTO", auto),
        ("LEANPROF_ALLOCS", if allocs then some "1" else none),
        ("LEANPROF_COUNTERS", if counters then some "1" else none),
        ("LEANPROF_FREES", if frees then some "1" else none),
        -- the build may run instrumented code (precompiled modules are loaded
        -- into `lean`): no reports from it, and none over the program's
        ("LEANPROF_QUIET", some "1"), ("LEANPROF_JSON", none), ("LEANPROF_TRACE", none),
        ("LEANPROF_STAT", none)] ++ runtimeEnv ++ extraEnv
      checkInterrupted
      spawnWait "lake" #["build", exe] buildEnv
    catch e => undo; throw e
  if rc != 0 || (← caughtSignal) != 0 then
    undo
    checkInterrupted
    -- the probes are compiled by the system's C compiler: say so when it is the cause
    if let some p ← ccProblem then IO.eprintln s!"leanprof: {p}"
  else
    discard <| dropBuildRecords deps exe
  return rc

/-- The executable Lake builds for `exe`. -/
def exePath (exe : String) : FilePath := (".lake" : FilePath) / "build" / "bin" / exe

/-- The prefix of the Lean toolchain whose sources and `.ilean` files describe
Lean's own code in `bin`: the toolchain `bin` is in, else `lean --print-prefix`. -/
def toolchainPrefix (bin : FilePath) : IO (Option String) := do
  if let some pre := bin.parent >>= (·.parent) then
    if ← (pre / "lib" / "lean" / "Lean.ilean").pathExists then return some pre.toString
  try
    let out ← IO.Process.output { cmd := "lean", args := #["--print-prefix"] }
    return if out.exitCode == 0 then some out.stdout.trimAscii.toString else none
  catch _ => return none

def absPath (p : FilePath) : IO FilePath := do
  if p.isAbsolute then return p
  return (← IO.currentDir) / p

/-- Run the instrumented `exe` in the project, or in `--cwd DIR` (for
programs that read their input from the current directory): paths become
absolute, and LEANPROF_PROJECT tells the runtime where the `.ilean` files are. -/
def instrumentedEnv (exe : String) (opts : RunOpts) (env : Array (String × Option String)) :
    IO (Array (String × Option String)) := do
  let fix (v : Option String) : IO (Option String) := v.mapM fun p => return (← absPath p).toString
  -- as `lake exe` would run it, then leanprof's own variables
  let mut env' ← lakeRunEnv
  for (k, v) in env do
    env' := env'.push (k, ← if k == "LEANPROF_JSON" || k == "LEANPROF_TRACE" then fix v else pure v)
  if opts.cwd.isSome then env' := env'.push ("LEANPROF_PROJECT", some (← IO.currentDir).toString)
  -- positions of Lean's own functions (copies inside its libraries with `--core`)
  if let some pre ← toolchainPrefix (exePath exe) then env' := env'.push ("LEANPROF_CORE_DIR", some pre)
  return env'

def runInstrumented (exe : String) (opts : RunOpts) (env : Array (String × Option String)) : IO UInt32 := do
  spawnWait (← absPath (exePath exe)).toString opts.args (← instrumentedEnv exe opts env) (opts.cwd.map (·))

/-- The last report: what `run`, `stat`, `sample` and `measure` leave, and
what `explain`, `html`, MCP `report`/`hot`/`explain` and `#leanprof` read by
default. -/
def lastReport : FilePath := (".lake" : FilePath) / "leanprof" / "report.json"

/-- Before a command makes a report: remove the last one (and the file named
by `--json`/`--out`), so that after a failed build or a killed program no
older report passes for this one. -/
def clearReports (json : Option String) : IO Unit := do
  IO.FS.createDirAll (lastReport.parent.getD ".")
  for f in lastReport :: json.toList.map (⟨·⟩) do
    if ← f.pathExists then IO.FS.removeFile f

/-- After a report was written to `json`: it is also the last report. -/
def publishReport (json : FilePath) : IO Unit := do
  unless ← json.pathExists do return
  if (← absPath json) == (← absPath lastReport) then return
  IO.FS.writeBinFile lastReport (← IO.FS.readBinFile json)

def run (argv : List String) : IO UInt32 := do
  let opts ← IO.ofExcept (parseRun {} argv)
  let some exe := opts.exe | throw <| IO.userError (usageFor "run")
  let coreEnv ← if opts.core then
      pure #[("LEANPROF_CORE_LIB", some (← coreLibDir opts.allocs opts.frees).toString)]
    else pure #[]
  clearReports opts.json
  let rc ← buildWithShims exe opts.auto opts.allocs opts.counters opts.frees (coreEnv ++ tinyEnv opts) opts.deps
  if rc != 0 then return rc
  -- written where asked (--json/--out), and always as the last report
  let json := opts.json.getD lastReport.toString
  let runEnv := #[("LEANPROF_TRACE", opts.trace), ("LEANPROF_JSON", some json)] ++
    (if opts.allCopies then #[("LEANPROF_ALL_COPIES", some "1")] else #[])
  let rc ← try runInstrumented exe opts runEnv
    finally
      unless opts.keep do
        cleanupInstrumented exe
  publishReport json
  return rc

/-! ## compare -/

structure Report where
  exact : Bool := false                            -- heartbeats: compare without a threshold
  isElab : Bool := false
  total : Float := 0                               -- elab reports: the whole report's amount
  scopes : Std.HashMap String (Float × Nat) := {}  -- name@pos ↦ (total ns or heartbeats, calls)
  copies : Std.HashMap String Nat := {}            -- function|kind|scope ↦ copies
  selfCheck : String := ""                          -- the runtime self-check's warning, if any
  allocs : Std.HashMap String Nat := {}            -- function in scope ↦ allocations (empty: not counted)
  allocBytes : Nat := 0
  /-- total ns per scope name, over every position with that name (for `measure --scope`) -/
  named : Std.HashMap String Float := {}
  /-- time fields too small to measure, per scope key (`too_small` in the JSON) -/
  tooSmall : Std.HashMap String (Array String) := {}
  /-- scope names with a position whose total was too small to measure -/
  smallNamed : Array String := #[]

def num (j : Json) (k : String) : Float :=
  match j.getObjVal? k with
  | .ok (.num n) => n.toFloat
  | _ => 0

def str (j : Json) (k : String) : String :=
  (j.getObjVal? k >>= Json.getStr?).toOption.getD ""

def loadReport (path : String) : IO Report := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  let exact := str j "unit" == "heartbeats"
  let isElab := (j.getObjVal? "elab" >>= Json.getBool?).toOption.getD false
  let sc := (j.getObjVal? "self_check").toOption.getD Json.null
  let mut r : Report := { exact, isElab, total := num j "wall_ns", selfCheck := str sc "warning" }
  for s in (j.getObjVal? "scopes" >>= Json.getArr?).toOption.getD #[] do
    let key := if (str s "key").isEmpty then s!"{str s "name"} {str s "pos"}" else str s "key"
    -- a declaration's elaboration, kernel and compiler lines share its key
    let (t, c) := r.scopes.getD key (0, 0)
    r := { r with scopes := r.scopes.insert key (t + num s "total_ns", c + (num s "calls").toUInt64.toNat),
                  named := r.named.insert (str s "name") (r.named.getD (str s "name") 0 + num s "total_ns") }
    let small := ((s.getObjVal? "too_small" >>= Json.getArr?).toOption.getD #[]).filterMap (·.getStr?.toOption)
    if !small.isEmpty then r := { r with tooSmall := r.tooSmall.insert key small }
    if small.contains "total_ns" then r := { r with smallNamed := r.smallNamed.push (str s "name") }
  -- project reports (`elab --project`): each module's total, as `module M`
  if (j.getObjVal? "project" >>= Json.getBool?).toOption.getD false then
    for f in (j.getObjVal? "files" >>= Json.getArr?).toOption.getD #[] do
      r := { r with scopes := r.scopes.insert (str f "key") (num f "total_ns", 0) }
  for c in (j.getObjVal? "copies" >>= Json.getArr?).toOption.getD #[] do
    let n := (num c "shared").toUInt64.toNat + (num c "multi_threaded").toUInt64.toNat
    if n > 0 then
      let key := s!"{str c "function"} [{str c "kind"}] in {str c "scope"}"
      r := { r with copies := r.copies.insert key (r.copies.getD key 0 + n) }
  for a in (j.getObjVal? "allocations" >>= Json.getArr?).toOption.getD #[] do
    -- code without a symbol is named by its address, which moves between runs
    let f := str a "function"
    let key := s!"{if f.startsWith "0x" then "(no symbol)" else f} in {str a "scope"}"
    r := { r with allocs := r.allocs.insert key (r.allocs.getD key 0 + (num a "allocs").toUInt64.toNat),
                  allocBytes := r.allocBytes + (num a "bytes").toUInt64.toNat }
  return r

/-- `x` with two decimals. -/
def fmt2 (x : Float) : String :=
  let v := (x.abs * 100).round.toUInt64.toNat
  let frac := v % 100
  s!"{if x < 0 && v > 0 then "-" else ""}{v / 100}.{if frac < 10 then "0" else ""}{frac}"

def fmtMs (ns : Float) : String := s!"{fmt2 (ns / 1e6)} ms"

def fmtTime (ns : Float) : String :=
  if ns < 1e3 then s!"{ns.toUInt64} ns"
  else if ns < 1e6 then s!"{fmt2 (ns / 1e3)} µs"
  else if ns < 1e9 then s!"{fmt2 (ns / 1e6)} ms"
  else s!"{fmt2 (ns / 1e9)} s"

/-- How reports show a time too small to measure (listed in a row's
`too_small`): what is left of a scope after subtracting the probes' cost. -/
def tooSmallLabel : String := "< probe cost"

/-! ## Why a declaration or copy site got worse (compare, report-md) -/

/-- `n` with thousands separators. -/
def groupDigits (n : Nat) : String :=
  if _h : n < 1000 then toString n
  else
    let r := n % 1000
    groupDigits (n / 1000) ++ "," ++ (if r < 10 then "00" else if r < 100 then "0" else "") ++ toString r
termination_by n
decreasing_by omega

/-- What a row of `Regress.Explanation` is, in words. -/
def whatLabel : String → String
  | "unfold" => "isDefEq unfolds"
  | "whnf" => "whnf reduces"
  | "instance" => "instance tried"
  | "simp" => "simp lemma rewrote with"
  | "repeated" => "repeated operation"
  | "unfolds" => "unfolded (count)"
  | "kernel" => "kernel unfolded (count)"
  | "instances" => "instance used (count)"
  | "simp_used" => "simp lemma used (count)"
  | "simp_failed" => "simp lemma failed (count)"
  | "grind_instances" => "grind instantiated (count)"
  | w => w

def fmtKHB (x : Float) : String := s!"{fmt2 (x / 1000)} kHB"

def fmtSigned (f : Float → String) (d : Float) : String :=
  if d > 0 then s!"+{f d}" else if d < 0 then s!"−{f d.abs}" else "0"

/-- One side of a row: heartbeats (and how many times), or a count. -/
def rowSide (r : Leanprof.Regress.Row) (v : Option Float) (t : Option Nat) : String :=
  match v with
  | none => "not listed"
  | some x =>
    if r.isCount then groupDigits x.toUInt64.toNat
    -- no heartbeats credited on either side: only how often
    else if r.base.getD 0 == 0 && r.new.getD 0 == 0 && t.isSome then s!"{t.getD 0}×"
    else s!"{fmtKHB x}{match t with | some t => s!", {t}×" | none => ""}"

def rowChange (r : Leanprof.Regress.Row) : String :=
  match r.delta? with
  | none => "?"
  | some d =>
    if r.isCount then fmtSigned (fun x => groupDigits x.toUInt64.toNat) d
    else if d == 0 then s!"{if r.timesDelta > 0 then "+" else "−"}{r.timesDelta.natAbs}×"
    else fmtSigned fmtKHB d

/-- The rows to show of an explanation: credited work, then exact counts, `n` of each. -/
def shownRows (e : Leanprof.Regress.Explanation) (n : Nat) : Array Leanprof.Regress.Row × Nat :=
  let rows := (e.work.toList.take n ++ e.counts.toList.take n).toArray
  (rows, e.work.size + e.counts.size - rows.size)

/-- The explanation's headline: its largest change. -/
def topCause (e : Leanprof.Regress.Explanation) : Option Leanprof.Regress.Row :=
  e.headline

/-- What changed inside each regressed declaration, as `compare` prints it. -/
def whyText (e : Leanprof.Regress.Explanation) (top : Nat) : Array String := Id.run do
  let mut out := #[s!"  {e.key} ({e.pos}): {fmtKHB e.base} -> {fmtKHB e.new}" ++
    (if e.parts.isEmpty then "" else
      s!"  [{", ".intercalate (e.parts.toList.map fun (p, x, y) => s!"{p} {fmtSigned fmtKHB (y - x)}")}]")]
  let (rows, more) := shownRows e top
  for r in rows do
    out := out.push s!"    {whatLabel r.what} {r.name}{if r.loc.isEmpty then "" else s!" ({r.loc})"}: {rowSide r r.base r.baseTimes} -> {rowSide r r.new r.newTimes}  ({rowChange r})"
  if more > 0 then out := out.push s!"    ({more} more changed)"
  for n in e.notes do out := out.push s!"    note: {n}"
  return out

/-- The regressed declarations of two `elab` reports (as `compare` counts them),
explained, largest increase first. -/
def explainElab (bj nj : Json) (regressed : Array String) : Array Leanprof.Regress.Explanation :=
  let bi := Leanprof.Regress.loadElab bj
  let ni := Leanprof.Regress.loadElab nj
  regressed.filterMap fun k => do
    let b ← bi.decls.get? k
    let n ← ni.decls.get? k
    return Leanprof.Regress.explainDecl bi ni k b n

/-- explain's cause of a copy site, in one line (`none`: no explain.json). -/
def copyCauseText (fs : Option (Array Leanprof.Regress.Finding)) (key : String) (count : Nat) : Option String := do
  let fs ← fs
  match Leanprof.Regress.findingsFor fs key count with
  | .error e => return s!"cause not attributed: {e}"
  | .ok #[] => return "cause not attributed: explain.json has no finding for this site (explain only explains its --top sites)"
  | .ok found =>
    return "; ".intercalate (found.toList.map fun f =>
      let lines := if f.lines.isEmpty then "" else s!" ({f.file}: {", ".intercalate (f.lines.toList.map toString)})"
      s!"{if f.cause.isEmpty then "" else s!"{f.cause}: "}{f.why}{lines}")

def loadFindings (path : Option String) : IO (Option (Array Leanprof.Regress.Finding)) := do
  let some p := path | return none
  return some (Leanprof.Regress.loadExplain (← IO.ofExcept (Json.parse (← IO.FS.readFile p))))

def compare (argv : List String) : IO UInt32 := do
  let rec parse (thr minMs : Float) (ex : Option String) (files : List String) :
      List String → Except String (Float × Float × Option String × List String)
    | [] => .ok (thr, minMs, ex, files.reverse)
    | "--threshold" :: v :: rest => parse (v.toNat!.toFloat) minMs ex files rest
    | "--min-ms" :: v :: rest => parse thr (v.toNat!.toFloat) ex files rest
    | "--explain" :: v :: rest => parse thr minMs (some v) files rest
    | a :: rest => parse thr minMs ex (a :: files) rest
  let (thr, minMs, explainPath, files) ← IO.ofExcept (parse 10 1 none [] argv)
  let [basePath, newPath] := files | throw <| IO.userError (usageFor "compare")
  let base ← loadReport basePath
  let new ← loadReport newPath
  let findings ← loadFindings explainPath
  let mut regressions := 0
  let mut slowerDecls : Array String := #[]
  IO.println s!"scopes (time: regression above +{fmt2 thr}% and {fmt2 minMs} ms; calls: any change)"
  let keys := (base.scopes.toList.map (·.1) ++ new.scopes.toList.map (·.1)).eraseDups
  let amt (x : Float) := if base.exact then s!"{fmt2 (x / 1000)} kHB" else fmtTime x
  -- the largest changes first (a project report has thousands of scopes)
  let change (k : String) : Float :=
    ((new.scopes.get? k).map (·.1)).getD 0 - ((base.scopes.get? k).map (·.1)).getD 0
  let keys := keys.toArray.qsort fun a b => (change a).abs > (change b).abs || ((change a).abs == (change b).abs && a < b)
  for k in keys do
    -- a total too small to measure is shown as such, never as 0
    let small (r : Report) := (r.tooSmall.getD k #[]).contains "total_ns"
    let time (r : Report) (x : Float) := if small r then tooSmallLabel else fmtTime x
    match base.scopes.get? k, new.scopes.get? k with
    | some (bt, bc), some (nt, nc) =>
      let pct := if bt > 0 then (nt - bt) / bt * 100 else 0
      -- heartbeats barely vary between runs, but editing one declaration moves
      -- its neighbours by a few: count increases above 1% and 1,000 heartbeats
      let slower := if base.exact && new.exact then nt - bt > max (bt * 0.01) 1000
        else pct > thr && (nt - bt) / 1e6 > minMs
      let callsChanged := bc != nc
      let mark := if slower || callsChanged then "REGRESSION" else if pct < -thr then "faster" else "ok"
      if slower || callsChanged then regressions := regressions + 1
      if slower && base.isElab && new.isElab then slowerDecls := slowerDecls.push k
      let amt (r : Report) (x : Float) :=
        if base.exact then s!"{fmt2 (x / 1000)} kHB" else time r x
      let change := if (small base || small new) && !base.exact then "" else s!" ({fmt2 pct}%)"
      let calls := if base.isElab then "" else s!", calls {bc} -> {nc}"
      IO.println s!"  {mark}  {k}: {amt base bt} -> {amt new nt}{change}{calls}"
    | none, some (nt, nc) =>
      IO.println s!"  new  {k}: {if base.exact then s!"{fmt2 (nt / 1000)} kHB" else time new nt}{if base.isElab then "" else s!", calls {nc}"}"
    | some (bt, _), none => IO.println s!"  gone {k}: was {if base.exact then s!"{fmt2 (bt / 1000)} kHB" else time base bt}"
    | none, none => pure ()
  if base.isElab && new.isElab && base.total > 0 then
    IO.println s!"total: {amt base.total} -> {amt new.total} ({fmt2 ((new.total - base.total) / base.total * 100)}%)"
  if base.exact && new.exact && !slowerDecls.isEmpty then
    let bj ← IO.ofExcept (Json.parse (← IO.FS.readFile basePath))
    let nj ← IO.ofExcept (Json.parse (← IO.FS.readFile newPath))
    IO.println "why (what changed inside each declaration that got more expensive; counts are exact, heartbeats nearly so)"
    for e in explainElab bj nj slowerDecls do
      for l in whyText e 8 do IO.println l
  IO.println "copies of shared or multi-threaded values (any increase is a regression)"
  let ckeys := (base.copies.toList.map (·.1) ++ new.copies.toList.map (·.1)).eraseDups
  for k in ckeys do
    let b := base.copies.getD k 0
    let n := new.copies.getD k 0
    if n > b then
      regressions := regressions + 1
      IO.println s!"  REGRESSION  {k}: {b} -> {n}"
      if let some c := copyCauseText findings k n then IO.println s!"    why: {c}"
    else if n < b then
      IO.println s!"  fewer  {k}: {b} -> {n}"
  -- allocations: exact; judged on the total, since inlining and refactoring
  -- move them between sites
  if !base.allocs.isEmpty && !new.allocs.isEmpty then
    let total (r : Report) := r.allocs.fold (fun a _ n => a + n) 0
    let (b, n) := (total base, total new)
    IO.println "allocations by compiled Lean code (an increase of the total is a regression)"
    if n > b then
      regressions := regressions + 1
      IO.println s!"  REGRESSION  total: {b} -> {n}"
    else IO.println s!"  {if n < b then "fewer" else "ok"}  total: {b} -> {n}"
    let akeys := (base.allocs.toList.map (·.1) ++ new.allocs.toList.map (·.1)).eraseDups
    let changed := (akeys.filterMap fun k =>
      let (x, y) := (base.allocs.getD k 0, new.allocs.getD k 0)
      if x == y then none else some (k, x, y)).toArray.qsort fun (_, x1, y1) (_, x2, y2) =>
        (Int.ofNat y1 - x1).natAbs > (Int.ofNat y2 - x2).natAbs
    for (k, x, y) in changed.toList.take 10 do
      IO.println s!"  {if y > x then "more" else "fewer"}  {k}: {x} -> {y}"
      if y > x && findings.isSome then
        IO.println "    why: cause not attributed: explain explains copies, not allocations"
    if changed.size > 10 then IO.println s!"  ({changed.size - 10} more sites changed)"
  else if base.allocs.isEmpty != new.allocs.isEmpty then
    IO.println "allocations counted in only one report (run --allocs); not compared"
  if regressions == 0 then
    IO.println "no regressions"
    return 0
  IO.println s!"{regressions} regressions"
  return 1

/-! ## sample -/

structure SampleOpts where
  rate : Nat := 4000
  out : Option String := none
  /-- `--json FILE`: the sampled report also saved there -/
  json : Option String := none
  top : Nat := 25
  cwd : Option String := none
  exe : Option String := none
  args : Array String := #[]

partial def parseSample (o : SampleOpts) : List String → Except String SampleOpts
  | [] => .ok o
  | "--rate" :: v :: rest => parseSample { o with rate := v.toNat! } rest
  | "--out" :: f :: rest => parseSample { o with out := some f } rest
  | "--json" :: f :: rest => parseSample { o with json := some f } rest
  | "--top" :: v :: rest => parseSample { o with top := v.toNat! } rest
  | "--cwd" :: d :: rest => parseSample { o with cwd := some d } rest
  | "--" :: rest => .ok { o with args := o.args ++ rest.toArray }
  | a :: rest =>
    if a.startsWith "--" then .error s!"unknown option {a}"
    else if o.exe.isNone then parseSample { o with exe := some a } rest
    else parseSample { o with args := o.args.push a } rest

def getArr (j : Json) (k : String) : Array Json := (j.getObjVal? k >>= Json.getArr?).toOption.getD #[]
def getNatAt (a : Array Json) (i : Nat) : Option Nat := (a[i]? >>= fun x => x.getNat?.toOption)

open LeanprofHtml (binarySymbols libSymbols lookupSym)

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

/-- Lean's own shared libraries, which hold compiled Lean code (`lean`,
`lake` and the language server of a toolchain link them). -/
def isLeanSharedLib (name : String) : Bool :=
  name.startsWith "libleanshared" || name.startsWith "libInit_shared" || name.startsWith "libLake_shared"

def sample (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseSample {} argv)
  let some target := o.exe | throw <| IO.userError (usageFor "sample")
  -- a path (`/…/bin/lean`, `./prog`) is sampled as it is; a name is a target of this project
  let isPath := target.contains '/'
  let bin : FilePath ← if isPath then absPath target else pure ((".lake" : FilePath) / "build" / "bin" / target)
  let exe := bin.fileName.getD target
  if isPath then
    unless ← bin.pathExists do throw <| IO.userError s!"{target}: no such file"
  else
    let rc ← spawnWait "lake" #["build", target] #[]
    if rc != 0 then return rc
  clearReports o.json
  let out : FilePath := o.out.getD s!".lake/leanprof/{exe}.json"
  if let some dir := out.parent then IO.FS.createDirAll dir
  if ← out.pathExists then IO.FS.removeFile out
  let samplyArgs := #["record", "--save-only", "--unstable-presymbolicate", "--rate", toString o.rate,
    "-o", (← absPath out).toString, (← absPath bin).toString] ++ o.args
  let some samply ← findSamply | do
    IO.eprintln s!"leanprof: `leanprof sample` needs samply, which is not installed; get it with:\n  {← samplyInstallCmd}\n(or brew install samply / cargo install samply)"
    return 1
  let rc ← try spawnWait samply samplyArgs ((← lakeRunEnv) ++ #[("LEANPROF_QUIET", some "1")]) (o.cwd.map (·))
    catch e =>
      IO.eprintln s!"leanprof: cannot run {samply} ({e}); get samply with: {← samplyInstallCmd}"
      return (1 : UInt32)
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
  -- positions of Lean's own declarations, from the toolchain the binary is part
  -- of (`…/bin/lean`), else from the project's
  if let some pre ← toolchainPrefix bin then Leanprof.setCoreDir pre
  -- per library: symbol table, and whether it holds the program's Lean code
  -- (the binary itself, or Lean's shared libraries for `lean` and `lake`)
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
    libIsMain := libIsMain.push (dn == exe || isLeanSharedLib dn)
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
  -- callers of hot code outside the project (Lean's library, the runtime, C
  -- libraries): the nearest frame below it that is the project's own code
  let mut leafCallers : Std.HashMap String (Std.HashMap String Float) := {}
  let mut ownCode : Std.HashMap String Bool := {}  -- display name ↦ declared in the project
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
    -- Cut stacks. On Linux samply unwinds a copy of the top of the stack
    -- (at most 64 KiB, perf's limit), so a sample deep in recursion loses
    -- its outer frames: 10,000 calls deep, the phase that started the
    -- recursion was missing from 90% of the samples. A stack is whole when
    -- its outermost frame is one that is only ever outermost (`_start`,
    -- `start_thread`); a cut one is completed with the frames outside it in
    -- the thread's last whole stack, from the outermost call of the cut
    -- stack's outermost function.
    let nameAt (s : Nat) : String := frameName[(getNatAt frameOf s).getD 0]?.getD "?"
    let mut rootOf : Array Nat := Array.mkEmpty parents.size
    let mut inner : Std.HashSet String := {}
    for s in [0:parents.size] do
      match getNatAt parents s with
      | some p =>
        rootOf := rootOf.push (rootOf[p]?.getD p)
        inner := inner.insert (nameAt s)
      | none => rootOf := rootOf.push s
    let mut whole : Option Nat := none            -- the thread's last whole stack
    let mut outside : Std.HashMap String Nat := {} -- its frames: name ↦ parent of the outermost
    for i in [0:stacks.size] do
      let some s0 := getNatAt stacks i | continue
      let root := nameAt (rootOf[s0]?.getD s0)
      let mut stitch : Option Nat := none
      if !inner.contains root then
        if whole != some s0 then
          whole := some s0
          outside := {}
          let mut c? := some s0
          while true do
            let some c := c? | break
            let p := getNatAt parents c
            if let some p := p then outside := outside.insert (nameAt c) p
            c? := p
      else
        stitch := outside.get? root
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
      let mut outsideLeaf : Option String := none  -- the leaf, while its project caller is sought
      while true do
        if s?.isNone then
          s? := stitch
          stitch := none
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
        if leaf || outsideLeaf.isSome then
          -- the project's own code: a Lean declaration placed at a relative path
          let own ← match ownCode.get? n with
            | some b => pure b
            | none => do
              let b ← if leanDecls.contains n then
                  (do let wh ← Leanprof.whereIs n; pure (!wh.isEmpty && !wh.startsWith "/"))
                else pure false
              ownCode := ownCode.insert n b
              pure b
          if leaf then
            unless own do outsideLeaf := some n
          else if own then
            if let some lf := outsideLeaf then
              let m := leafCallers.getD lf {}
              leafCallers := leafCallers.insert lf (m.insert n (m.getD n 0 + w))
            outsideLeaf := none
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
  -- for code outside the project: which of the project's functions it runs under
  let outsideNote (n : String) (self : Float) : IO Bool := do
    let some m := leafCallers.get? n | return false
    let rows := (m.toArray.filter fun (_, cw) => self > 0 && cw / self ≥ 0.05).qsort (fun a b => a.2 > b.2)
    for (c, cw) in rows.toList.take 3 do
      let cwh ← Leanprof.whereIs c
      IO.println s!"{"".pushn ' ' 24}{fmt2 (cw / self * 100)}% of it under {c}{if cwh.isEmpty then "" else s!"  ({cwh})"}"
    return !rows.isEmpty
  for (n, w) in bySelf.toList.take o.top do
    let wh ← Leanprof.whereIs n
    IO.println s!"  {(fmtCpu w).pushn ' ' (12 - (fmtCpu w).length)} {(pct w).pushn ' ' (8 - (pct w).length)} {n}{if wh.isEmpty then "" else s!"  ({wh})"}"
    unless ← outsideNote n w do callerNote n
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
  -- the project's own functions also get `own_ns`: their self time plus that of
  -- code outside the project (Lean's library, the runtime) they called directly
  let mut ownT : Std.HashMap String Float := {}
  for (n, w) in selfT.toList do
    if ownCode.getD n false then ownT := ownT.insert n (ownT.getD n 0 + w)
  -- and `own_top`, the outside code that took most of that time
  let mut ownLeaves : Std.HashMap String (Array (String × Float)) := {}
  for (lf, m) in leafCallers.toList do
    for (c, cw) in m.toList do
      ownT := ownT.insert c (ownT.getD c 0 + cw)
      ownLeaves := ownLeaves.insert c ((ownLeaves.getD c #[]).push (lf, cw))
  let mut scopes : Array Json := #[]
  for (n, w) in leanIncl.toList do
    let wh ← Leanprof.whereIs n
    if wh.isEmpty then continue
    scopes := scopes.push <| Json.mkObj ([("name", Json.str n), ("pos", Json.str wh), ("auto", Json.bool true),
      ("total_ns", toJson (w * 1000)), ("self_ns", toJson (selfT.getD n 0 * 1000)), ("calls", toJson (0 : Nat))] ++
      (match ownT.get? n with
        | some o =>
          let top := ((ownLeaves.getD n #[]).qsort (·.2 > ·.2)).toList.take 3 |>.map fun (lf, w) =>
            Json.mkObj [("name", Json.str lf), ("ns", toJson (w * 1000))]
          [("own_ns", toJson (o * 1000)), ("own_top", Json.arr top.toArray)]
        | none => []))
  -- where the runtime's time went, for `leanprof` with no arguments' findings
  let runtime := (catT.toArray.qsort (fun a b => a.2 > b.2)).map fun (c, w) =>
    Json.mkObj [("category", Json.str c), ("self_ns", toJson (w * 1000))]
  let report := Json.mkObj [("version", toJson (3 : Nat)), ("sampled", Json.bool true),
    ("exe", Json.str exe), ("exit_code", toJson rc.toNat),
    ("wall_ns", toJson (total * 1000)), ("scopes", Json.arr scopes), ("copies", Json.arr #[]),
    ("runtime", Json.arr runtime)]
  -- the last report, and --json FILE (with --out elsewhere, nothing has
  -- created .lake/leanprof yet)
  IO.FS.createDirAll ".lake/leanprof"
  IO.FS.writeFile lastReport report.compress
  if let some f := o.json then
    if let some d := (f : FilePath).parent then
      if !d.toString.isEmpty then IO.FS.createDirAll d
    IO.FS.writeFile f report.compress
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
  /-- lines of stdout containing any of these are left out of its hash (a program's own timings) -/
  ignoreLines : Array String := #[]
  allocs : Bool := true
  core : Bool := false
  scope : Option String := none
  out : String := ".lake/leanprof/measure.json"
  deps : Bool := true
  exe : Option String := none
  args : Array String := #[]

partial def parseMeasure (o : MeasureOpts) : List String → Except String MeasureOpts
  | [] => .ok o
  | "--runs" :: v :: rest => parseMeasure { o with runs := max 1 v.toNat! } rest
  | "--warmup" :: v :: rest => parseMeasure { o with warmup := v.toNat! } rest
  | "--out" :: f :: rest => parseMeasure { o with out := f } rest
  | "--scope" :: n :: rest => parseMeasure { o with scope := some n } rest
  | "--check-output" :: f :: rest => parseMeasure { o with checkOutput := some f } rest
  | "--ignore-lines" :: t :: rest =>
    if t.isEmpty then .error "--ignore-lines needs a text" else parseMeasure { o with ignoreLines := o.ignoreLines.push t } rest
  | "--no-deps" :: rest => parseMeasure { o with deps := false } rest
  | "--no-allocs" :: rest => parseMeasure { o with allocs := false } rest
  | "--core" :: rest => parseMeasure { o with core := true } rest
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

open Leanprof.Judge (dropLines stdoutSource)

/-- A decimal like `33.23` (no exponent). -/
def parseDecimal? (t : String) : Option Float :=
  match t.splitOn "." with
  | [w] => w.toNat?.map (·.toFloat)
  | [w, f] => do
    let wn ← (if w.isEmpty then some 0 else w.toNat?)
    let fn ← f.toNat?
    return wn.toFloat + fn.toFloat / (10 : Float) ^ f.length.toFloat
  | _ => none

/-- The 1-minute load average and the number of CPUs, when the system says
(`/proc/loadavg` and `nproc` on Linux, `sysctl` on macOS). A time verdict
from a machine running more jobs than it has CPUs is not trustworthy. -/
@[extern "leanprof_cli_loadavg"] opaque cliLoadAvg : IO Float

/-- The 1-minute load average, read in process. -/
def loadNow : IO (Option Float) := do
  let l ← cliLoadAvg
  return if l < 0 then none else some l

def machineLoad : IO (Option Float × Option Nat) := do
  let out (cmd : String) (args : Array String) : IO String := do
    try pure (← IO.Process.output { cmd, args }).stdout catch _ => pure ""
  let words (x : String) := (x.split (fun c => c == ' ' || c == '\n' || c == '{' || c == '}')).toList.map (·.toString)
    |>.filter (· != "")
  let (la, cpus) ← if System.Platform.isOSX then
      pure ((← out "sysctl" #["-n", "vm.loadavg"]), (← out "sysctl" #["-n", "hw.ncpu"]))
    else
      pure ((← try IO.FS.readFile "/proc/loadavg" catch _ => pure ""), (← out "nproc" #[]))
  return ((words la).head? >>= parseDecimal?, (words cpus).head? >>= String.toNat?)

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
  -- --core: Lean's libraries linked with their runtime calls redirected, so
  -- copies and allocations inside them (`List`, `Array`, `HashMap` code
  -- compiled into libInit, libStd, libLean) are counted too
  let coreEnv ← if o.core then
      pure #[("LEANPROF_CORE_LIB", some (← coreLibDir o.allocs).toString)]
    else pure #[]
  let rc ← buildWithShims exe none (allocs := o.allocs) (extraEnv := coreEnv) (deps := o.deps)
  if rc != 0 then return rc
  let dir : FilePath := ".lake" / "leanprof"
  IO.FS.createDirAll dir
  let reportPath := dir / "report.json"  -- the last run's stays, for `#leanprof`
  let coreDir ← if o.core then
      pure ((← toolchainPrefix (exePath exe)).toArray.map (("LEANPROF_CORE_DIR", some ·)))
    else pure #[]
  let env := (← lakeRunEnv) ++ #[("LEANPROF_QUIET", some "1"), ("LEANPROF_JSON", some reportPath.toString)] ++ coreDir
  let mut times : Array Nat := #[]
  let mut hashes : Array String := #[]
  let mut codes : Array UInt32 := #[]
  let mut reports : Array Report := #[]
  -- runs whose --scope time was too small to measure: a 0 there is no time
  let mut smallRuns := 0
  let (load0, cpus) ← machineLoad
  try
    for i in [0:o.warmup + o.runs] do
      if ← reportPath.pathExists then IO.FS.removeFile reportPath
      -- a stale output file must not pass for this run's
      if let some f := o.checkOutput then
        if ← (f : FilePath).pathExists then IO.FS.removeFile f
      -- a signal between two runs: no next run
      checkInterrupted
      let t0 ← IO.monoNanosNow
      let out ← guardedOutput { cmd := (exePath exe).toString, args := o.args, env, stdin := .null }
      let t1 ← IO.monoNanosNow
      checkInterrupted
      if i < o.warmup then continue
      let report ← if ← reportPath.pathExists then loadReport reportPath.toString else pure {}
      -- --scope: the scope's own total, without start-up and setup
      times := times.push <| ← match o.scope with
        | none => pure (t1 - t0)
        | some s => match report.named.get? s with
          | some ns => pure ns.toUInt64.toNat
          | none => throw <| IO.userError (s!"scope {s} is not in the report of {exe} " ++
              s!"(mark it with profile! \"{s}\"; its scopes: {report.named.toList.map (·.1)})")
      if o.scope.any report.smallNamed.contains then smallRuns := smallRuns + 1
      codes := codes.push out.exitCode
      if out.exitCode != 0 && codes.size == 1 then
        IO.eprintln s!"leanprof: {exe} exited with {out.exitCode}:\n{out.stderr}"
      hashes := hashes.push <| ← match o.checkOutput with
        | some f => do
          if ← (f : FilePath).pathExists then pure (fnv1a (← IO.FS.readBinFile f)) else pure "missing"
        | none => pure (fnv1a (dropLines o.ignoreLines out.stdout).toUTF8)
      reports := reports.push report
  finally
    cleanupInstrumented exe
  let (load1, _) ← machineLoad
  let loadMax := match load0, load1 with
    | some a, some b => some (max a b) | some a, none | none, some a => some a | none, none => none
  let overloaded := match loadMax, cpus with | some l, some c => l > c.toFloat | _, _ => false
  let mean := times.foldl (fun a t => a + t.toFloat) 0 / times.size.toFloat
  let stddev := Float.sqrt (times.foldl (fun a t => a + (t.toFloat - mean) ^ 2) 0 /
    (if times.size > 1 then (times.size - 1).toFloat else 1))
  -- copies and calls are exact: take the last run's, and say if runs disagree
  let last := reports.back?.getD {}
  let copyTotal (r : Report) := r.copies.fold (fun acc _ n => acc + n) 0
  let copiesStable := reports.all (copyTotal · == copyTotal last)
  -- allocations: exact too, but threads can change them; judge uses the range
  let allocTotal (r : Report) := r.allocs.fold (fun acc _ n => acc + n) 0
  let allocRuns := reports.map allocTotal
  let allocsStable := allocRuns.all (· == allocTotal last)
  let outputStable := hashes.all (· == hashes.back!)
  unless copiesStable do
    IO.eprintln "leanprof: copy counts differ between runs (threads?); using the last run's"
  if o.allocs && !allocsStable then
    IO.eprintln "leanprof: allocation counts differ between runs (threads?); judge compares their ranges"
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
    ("command", toJson (#[exe] ++ o.args)), ("runs", toJson o.runs), ("core", Json.bool o.core),
    ("scope", match o.scope with | some s => Json.str s | none => Json.null),
    ("exit_code", toJson codes.back!.toNat),
    ("output", Json.mkObj [("source", Json.str (o.checkOutput.getD (stdoutSource o.ignoreLines))),
      ("hash", Json.str hashes.back!), ("stable", Json.bool outputStable)]),
    ("time_ns", Json.mkObj ([("median", toJson (median times)), ("min", toJson (times.foldl min times[0]!)),
      ("max", toJson (times.foldl max 0)), ("mean", toJson mean.round), ("stddev", toJson stddev.round),
      ("runs", toJson times)] ++ (if o.scope.isSome then [("too_small_runs", toJson smallRuns)] else []))),
    ("machine", Json.mkObj [("load_avg_1m", match loadMax with | some l => toJson l | none => Json.null),
      ("cpus", match cpus with | some c => toJson c | none => Json.null), ("overloaded", Json.bool overloaded)]),
    ("copies_total", toJson (copyTotal last)), ("copies_stable", Json.bool copiesStable),
    ("self_check_warning", Json.str last.selfCheck),
    ("copies", keyedArr "copies" (last.copies.toList.map fun (k, n) => (k, toJson n))),
    ("calls", keyedArr "calls" (last.scopes.toList.map fun (k, (_, c)) => (k, toJson c))),
    ("allocs_total", if o.allocs then toJson (allocTotal last) else Json.null),
    ("allocs_runs", if o.allocs then toJson allocRuns else Json.null),
    ("allocs_stable", if o.allocs then Json.bool allocsStable else Json.null),
    ("alloc_bytes_total", if o.allocs then toJson (last.allocBytes) else Json.null),
    ("allocs", if o.allocs then keyedArr "allocs" (last.allocs.toList.map fun (k, n) => (k, toJson n)) else Json.null),
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
  IO.println s!"  time     {match o.scope with | some s => s!"scope {s}: " | none => ""}median {fmtMs (median times).toFloat}, min {fmtMs (times.foldl min times[0]!).toFloat}, max {fmtMs (times.foldl max 0).toFloat}, mean {fmtMs mean} ± {fmtMs stddev}"
  if smallRuns > 0 then
    IO.println s!"  warning  the scope's time was too small to measure (below leanprof's probe cost) in {smallRuns} of {o.runs} runs: judge will not use time"
  if let (some l, some c) := (loadMax, cpus) then
    IO.println s!"  machine  load average {fmt2 l} on {c} CPUs{if overloaded then " (overloaded: judge will not use time)" else ""}"
  IO.println s!"  copies   {copyTotal last} (shared + multi-threaded)"
  if o.allocs then
    IO.println s!"  allocs   {allocTotal last} by compiled Lean code{if o.core then ", Lean's libraries included" else " of the project (--core adds Lean's libraries)"}{if allocsStable then "" else s!" (runs: {allocRuns.toList})"}"
  unless last.selfCheck.isEmpty do IO.println s!"  warning  {last.selfCheck}"
  IO.println s!"  output   {hashes.back!} ({o.checkOutput.getD (stdoutSource o.ignoreLines)}), exit code {codes.back!}"
  if let some xs := hb then
    IO.println s!"  compile  {fmt2 ((xs.foldl (fun a (_, t) => a + t) 0) / 1000)} kHB in {xs.length} declarations"
  IO.println s!"written to {o.out}"
  return 0

structure PairOpts where
  base : String := ""
  candidate : String := ""
  baseCwd : String := "."
  candidateCwd : String := "."
  /-- the most pairs; the session stops at the first look that settles the time verdict -/
  runs : Nat := 30
  /-- one look after `runs` pairs instead (no early stop) -/
  fixed : Bool := false
  minChange : Float := 1
  warmup : Nat := 1
  /-- time only what `Leanprof.bench NAME` reports, not the whole process -/
  scope : Option String := none
  /-- build the base at this git revision (cached) and the candidate in its directory -/
  baseRev : Option String := none
  exe : Option String := none
  checkOutput : Option String := none
  ignoreLines : Array String := #[]
  out : String := ".lake/leanprof/paired.json"
  args : Array String := #[]

partial def parsePair (o : PairOpts) : List String → Except String PairOpts
  | [] => .ok o
  | "--base" :: x :: rest => parsePair {o with base := x} rest
  | "--candidate" :: x :: rest => parsePair {o with candidate := x} rest
  | "--base-cwd" :: x :: rest => parsePair {o with baseCwd := x} rest
  | "--candidate-cwd" :: x :: rest => parsePair {o with candidateCwd := x} rest
  | "--out" :: x :: rest => parsePair {o with out := x} rest
  | "--check-output" :: x :: rest => parsePair {o with checkOutput := some x} rest
  | "--ignore-lines" :: t :: rest =>
    if t.isEmpty then .error "--ignore-lines needs a text" else parsePair {o with ignoreLines := o.ignoreLines.push t} rest
  | "--scope" :: x :: rest =>
    if x.isEmpty || x.any (fun c => c == '\t' || c == '\n') then .error "--scope needs a name without tabs or newlines"
    else parsePair {o with scope := some x} rest
  | "--fixed" :: rest => parsePair {o with fixed := true} rest
  | "--base-rev" :: x :: rest => parsePair {o with baseRev := some x} rest
  | "--exe" :: x :: rest =>
    if x.isEmpty || x.any (· == '/') then .error "--exe needs the name of a Lake executable"
    else parsePair {o with exe := some x} rest
  | "--min-change" :: x :: rest => do
    let some pct := parseDecimal? x | throw "--min-change must be a percentage from 0 to 100"
    unless pct ≤ 100 do throw "--min-change must be a percentage from 0 to 100"
    parsePair {o with minChange := pct} rest
  | "--runs" :: x :: rest => do
    let some n := x.toNat? | throw "--runs must be an integer from 6 to 1000"
    unless n ≥ 6 && n ≤ 1000 do throw "--runs must be an integer from 6 to 1000"
    parsePair {o with runs := n} rest
  | "--warmup" :: x :: rest => do
    let some n := x.toNat? | throw "--warmup must be an integer from 0 to 1000"
    unless n ≤ 1000 do throw "--warmup must be an integer from 0 to 1000"
    parsePair {o with warmup := n} rest
  | "--" :: rest => .ok {o with args := rest.toArray}
  | x :: _ => .error s!"unknown or incomplete measure-pair option: {x}"

/-- The total of a `Leanprof.bench` region's lines (`NAME<TAB>NANOSECONDS`) in
`file`, as written to `$LEANPROF_BENCH_OUT`; `none` when the region never ran. -/
def benchTotal (file : FilePath) (scope : String) : IO (Option Nat) := do
  unless ← file.pathExists do return none
  let mut total : Option Nat := none
  for line in (← IO.FS.readFile file).splitOn "\n" do
    match line.splitOn "\t" with
    | [name, ns] => if name == scope then
        if let some v := ns.toNat? then total := some (total.getD 0 + v)
    | _ => pure ()
  return total

/-- Settings besides the commit that change what `lake build` makes. -/
def buildSettingVars : Array String :=
  #["ELAN_TOOLCHAIN", "LEAN_CC", "LEANC_OPTS", "LEAN_SYSROOT", "LEAN_AR", "LEANPROF_SANITIZE",
    "LEANPROF_ALLOCS", "LEANPROF_COUNTERS", "LEANPROF_FREES", "LEANPROF_AUTO", "LEANPROF_RUNTIME"]

/-- `cmd args` in `cwd`; its stdout, trimmed, or an error with its stderr. -/
def runOut (cmd : String) (args : Array String) (cwd : FilePath) : IO String := do
  let out ← IO.Process.output { cmd, args, cwd := some cwd, stdin := .null }
  unless out.exitCode == 0 do
    throw <| IO.userError s!"{cmd} {" ".intercalate args.toList} failed in {cwd}:\n{out.stderr}{out.stdout}"
  return out.stdout.trimAscii.toString

/-- `lake build EXE` in `dir` and the seconds it took. -/
def lakeBuildExe (dir : FilePath) (exe : String) : IO (FilePath × Float) := do
  let t0 ← IO.monoNanosNow
  discard <| runOut "lake" #["build", exe] dir
  let secs := ((← IO.monoNanosNow) - t0).toFloat / 1e9
  let bin := dir / ".lake" / "build" / "bin" / exe
  unless ← bin.pathExists do throw <| IO.userError s!"lake build {exe} in {dir} made no {bin}"
  return (bin, secs)

/-- The base for `measure-pair --base-rev REV --exe NAME`: NAME built at commit
REV, in `.lake/leanprof/base/` of the project in `projDir`, and kept there by
commit and build settings (`buildSettingVars`, and the executable), so later
verdicts against the same base do not build it again. The tree is `git
archive` of the commit (no worktree is registered); the project's
`.lake/packages` are copied in when its manifest is the same at REV. Returns the
binary, its working directory, and what was done. -/
def cachedBase (projDir : FilePath) (rev exe : String) : IO (FilePath × FilePath × Json) := do
  let top ← IO.FS.realPath (← runOut "git" #["rev-parse", "--show-toplevel"] projDir)
  let proj ← IO.FS.realPath projDir
  let rel := (proj.toString.drop top.toString.length).toString.dropWhile (· == '/') |>.toString
  let commit ← runOut "git" #["rev-parse", "--verify", "--quiet", rev ++ "^{commit}"] projDir
  let mut settings := s!"exe={exe}"
  for v in buildSettingVars do
    if let some x ← IO.getEnv v then settings := settings ++ s!"\n{v}={x}"
  let key := (fnv1a (commit ++ "\n" ++ settings).toUTF8).drop 8 |>.take 12 |>.toString
  let root := proj / ".lake" / "leanprof" / "base" / s!"{commit.take 12}-{key}"
  let tree := root / "src"
  let dir := if rel.isEmpty then tree else tree / rel
  let bin := dir / ".lake" / "build" / "bin" / exe
  let marker := root / "built.json"
  let info (cache : String) (secs : Float) := Json.mkObj [("rev", Json.str rev), ("commit", Json.str commit),
    ("cache", Json.str cache), ("dir", Json.str root.toString), ("build_s", toJson secs)]
  if (← marker.pathExists) && (← bin.pathExists) then
    return (bin, dir, info "hit" 0)
  if ← root.pathExists then IO.FS.removeDirAll root
  IO.FS.createDirAll tree
  let t0 ← IO.monoNanosNow
  let tar := root / "src.tar"
  discard <| runOut "git" #["archive", "--format=tar", "-o", tar.toString, commit] top
  discard <| runOut "tar" #["-xf", tar.toString, "-C", tree.toString] top
  IO.FS.removeFile tar
  let manifest := "lake-manifest.json"
  let packages := proj / ".lake" / "packages"
  if (← packages.pathExists) && (← (dir / manifest).pathExists) && (← (proj / manifest).pathExists) then
    if (← IO.FS.readFile (dir / manifest)) == (← IO.FS.readFile (proj / manifest)) then
      IO.FS.createDirAll (dir / ".lake")
      discard <| runOut "cp" #["-R", packages.toString, (dir / ".lake").toString] proj
  discard <| lakeBuildExe dir exe
  let secs := ((← IO.monoNanosNow) - t0).toFloat / 1e9
  IO.FS.writeFile marker ((Json.mkObj [("commit", Json.str commit), ("settings", Json.str settings),
    ("build_s", toJson secs)]).pretty ++ "\n")
  return (bin, dir, info "built" secs)

def measurePairCmd (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parsePair {} argv)
  -- --base-rev REV --exe NAME: base from the cache, candidate built here
  let (o, builds) ← match o.baseRev, o.exe with
    | some rev, some exe => do
      unless o.base.isEmpty do throw <| IO.userError "give --base or --base-rev, not both"
      let (bin, dir, info) ← cachedBase o.candidateCwd rev exe
      let (cand, candSecs) ← if o.candidate.isEmpty then
          (fun (b, t) => (b.toString, some t)) <$> lakeBuildExe o.candidateCwd exe
        else pure (o.candidate, none)
      let what := match info.getObjValAs? String "cache" with
        | .ok "hit" => "from the cache"
        | _ => s!"built in {fmt2 ((info.getObjValAs? Float "build_s").toOption.getD 0)} s and cached"
      let short := ((info.getObjValAs? String "commit").toOption.getD "").take 12
      IO.println (s!"leanprof measure-pair: base {rev} ({short}) {what}" ++
        (match candSecs with | some t => s!", candidate built in {fmt2 t} s" | none => ""))
      pure ({ o with base := bin.toString, baseCwd := dir.toString, candidate := cand },
        some (info.setObjVal! "candidate_build_s" (match candSecs with | some t => toJson t | none => Json.null)))
    | some _, none | none, some _ => throw <| IO.userError "--base-rev and --exe go together"
    | none, none => pure (o, none)
  unless !o.base.isEmpty && !o.candidate.isEmpty do
    throw <| IO.userError (usageFor "measure-pair")
  -- Resolve binaries before changing cwd: relative paths belong to the caller.
  let binaries ← #[o.base, o.candidate].mapM fun p => IO.FS.realPath (FilePath.mk p)
  let dirs ← #[o.baseCwd, o.candidateCwd].mapM fun p => IO.FS.realPath (FilePath.mk p)
  let binaryHashes ← binaries.mapM fun p => return fnv1a (← IO.FS.readBinFile p)
  let (initialLoad, cpus) ← machineLoad
  let design : Leanprof.Judge.SeqDesign := if o.fixed then .fixed o.runs else { max := o.runs }
  let bounds := (Leanprof.Judge.seqBounds design).1
  let mut maxLoad := initialLoad
  let mut samples : Array Json := #[]
  let mut loads : Array Json := #[]
  let mut changes : Array Float := #[]
  -- each side as `lake exe` would run it in its own directory (both at once:
  -- `lake env` takes about 0.1 s)
  let envTasks ← dirs.mapM fun d => IO.asTask (lakeRunEnv (some d))
  let lakeEnvs ← envTasks.mapM fun t => IO.ofExcept t.get
  -- --scope: each run appends its `Leanprof.bench` timings to this file
  -- (absolute: each side runs in its own directory)
  let benchFile : FilePath := (o.out : FilePath).withExtension "bench.tmp"
  let cwd ← IO.currentDir
  let benchFile := if benchFile.isAbsolute then benchFile else cwd / benchFile
  if o.scope.isSome then if let some dir := benchFile.parent then IO.FS.createDirAll dir
  let env := #[("LEANPROF_QUIET", some "1"), ("LEANPROF_JSON", none),
    ("LEANPROF_TRACE", none), ("LEANPROF_LIVE", none), ("LEANPROF_FLIGHT", none),
    ("LEANPROF_BENCH_OUT", o.scope.map fun _ => benchFile.toString)]
  -- Warmups are a separate phase, so measured pair zero always starts AB.
  let mut stopped := false
  for phase in [:2] do
    let count := if phase == 0 then o.warmup else o.runs
    for pair in [:count] do
      if stopped then break
      let mut times : Array Nat := #[0, 0]
      for offset in [:2] do
        let side := (pair + offset) % 2
        let checked := o.checkOutput.map fun p => dirs[side]! / p
        if let some p := checked then
          if ← p.pathExists then IO.FS.removeFile p
        checkInterrupted
        if o.scope.isSome then
          if ← benchFile.pathExists then IO.FS.removeFile benchFile
        let t0 ← IO.monoNanosNow
        let sideEnv := lakeEnvs[side]! ++ env
        let result ← guardedOutput { cmd := binaries[side]!.toString, args := o.args, cwd := some dirs[side]!, env := sideEnv, stdin := .null }
        let elapsed := (← IO.monoNanosNow) - t0
        checkInterrupted
        let timed ← match o.scope with
          | none => pure elapsed
          | some s => do
            let some t ← benchTotal benchFile s
              | throw <| IO.userError (s!"{binaries[side]!} did not report scope {s}: wrap the region in " ++
                  s!"`Leanprof.bench \"{s}\" fun _ => ...`, or append `{s}<TAB>NANOSECONDS` lines to $LEANPROF_BENCH_OUT" ++
                  (if result.exitCode != 0 then s!" (it exited with {result.exitCode}: {result.stderr})" else ""))
            pure (Nat.max t 1)
        if phase == 0 then
          if result.exitCode != 0 then throw <| IO.userError s!"warmup failed for {binaries[side]!}: {result.stderr}"
          continue
        times := times.set! side timed
        let present ← match checked with
          | some p => p.pathExists
          | none => pure true
        let output ← match checked with
          | some p => if present then pure (fnv1a (← IO.FS.readBinFile p)) else pure "missing"
          | none => pure (fnv1a (dropLines o.ignoreLines result.stdout).toUTF8)
        samples := samples.push <| Json.mkObj ([
          ("pair", toJson pair), ("side", Json.str (if side == 0 then "base" else "candidate")),
          ("time_ns", toJson timed), ("exit_code", toJson result.exitCode.toNat),
          ("stdout_hash", Json.str (fnv1a (dropLines o.ignoreLines result.stdout).toUTF8)),
          ("stderr_hash", Json.str (fnv1a result.stderr.toUTF8)),
          ("output_hash", Json.str output), ("output_present", Json.bool present)] ++
          (if o.scope.isSome then [("process_ns", toJson elapsed)] else []))
      let load ← loadNow
      maxLoad := match maxLoad, load with
        | some a, some b => some (max a b)
        | none, x | x, none => x
      if phase == 1 then
        loads := loads.push (match load with | some v => toJson v | none => Json.null)
        changes := changes.push ((times[1]!.toFloat / times[0]!.toFloat - 1) * 100)
        stopped := Leanprof.Judge.seqStop design bounds changes o.minChange
  if o.scope.isSome then
    if ← benchFile.pathExists then IO.FS.removeFile benchFile
  let overloaded := match maxLoad, cpus with | some l, some c => l > c.toFloat | _, _ => false
  let finalHashes ← binaries.mapM fun p => return fnv1a (← IO.FS.readBinFile p)
  unless finalHashes == binaryHashes do throw <| IO.userError "a benchmark binary changed during measurement"
  let j := Json.mkObj [("version", toJson (2 : Nat)), ("leanprof", "measure-pair"),
    ("mode", "plain"), ("runs", toJson changes.size), ("warmup", toJson o.warmup),
    ("design", design.json), ("min_change", toJson o.minChange),
    ("scope", match o.scope with | some s => Json.str s | none => Json.null),
    ("builds", builds.getD Json.null),
    ("base", Json.str binaries[0]!.toString), ("candidate", Json.str binaries[1]!.toString),
    ("base_hash", Json.str binaryHashes[0]!), ("candidate_hash", Json.str binaryHashes[1]!),
    ("base_cwd", Json.str dirs[0]!.toString), ("candidate_cwd", Json.str dirs[1]!.toString),
    ("args", toJson o.args), ("output_source", Json.str (o.checkOutput.getD (stdoutSource o.ignoreLines))),
    ("samples", Json.arr samples),
    ("machine", Json.mkObj [("overloaded", Json.bool overloaded),
      ("load_avg_1m", match maxLoad with | some v => toJson v | none => Json.null),
      ("cpus", match cpus with | some v => toJson v | none => Json.null),
      ("pair_loads", Json.arr loads)])]
  if let some dir := (o.out : FilePath).parent then IO.FS.createDirAll dir
  IO.FS.writeFile o.out (j.pretty ++ "\n")
  let how := if o.fixed then "" else s!" (stops when settled, at most {o.runs})"
  IO.println s!"leanprof measure-pair: {changes.size} pairs{how}, alternating AB/BA; written to {o.out}"
  IO.print (← IO.ofExcept (Leanprof.Judge.judgePaired j o.minChange)).render
  -- Like measure, collection succeeds even when the candidate is discarded.
  return 0

def loadSummary (path : String) : IO Leanprof.Judge.Summary := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  match Leanprof.Judge.Summary.ofJson j with
  | .ok s => return s
  | .error e => throw <| IO.userError s!"{path}: {e}"

/-- KEEP or DISCARD a change, from the summaries before and after it (the
rules are in `Leanprof.Judge`). Exits 0 for KEEP. -/
def judgeCmd (argv : List String) : IO UInt32 := do
  let mut minChange : Float := 1
  let mut allowOverloaded := false
  let mut argv := argv
  repeat
    match argv with
    | "--min-change" :: v :: rest =>
      let some pct := parseDecimal? v | throw <| IO.userError "--min-change must be a percentage from 0 to 100"
      unless pct ≤ 100 do throw <| IO.userError "--min-change must be a percentage from 0 to 100"
      minChange := pct
      argv := rest
    | "--allow-overloaded" :: rest =>
      allowOverloaded := true
      argv := rest
    | _ => break
  let v ← match argv with
    | [pairPath] => do
      let j ← IO.ofExcept (Json.parse (← IO.FS.readFile pairPath))
      IO.ofExcept (Leanprof.Judge.judgePaired j minChange allowOverloaded)
    | [basePath, newPath] => pure (Leanprof.Judge.judge (← loadSummary basePath) (← loadSummary newPath) minChange)
    | _ => throw <| IO.userError (usageFor "judge")
  IO.print v.render
  return if v.keep then 0 else 1

/-! ## report-md -/

def fmtCount (x : Float) : String := groupDigits x.abs.round.toUInt64.toNat

def fmtHeartbeats (x : Float) : String :=
  if x.abs ≥ 1e6 then s!"{fmt2 (x / 1e6)} MHB" else s!"{fmt2 (x / 1000)} kHB"

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
  explain : Option String := none
  maxChars : Nat := 60000

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
  | "--explain" :: v :: rest => parseReportMd { o with explain := some v } rest
  | "--max-chars" :: v :: rest => parseReportMd { o with maxChars := v.toNat! } rest
  | a :: rest =>
    if a.startsWith "--" then .error s!"unknown option {a}"
    else parseReportMd { o with files := o.files.push a } rest

/-- What can be said about an allocation site `key` (`function in scope`) that
allocates more: explain names causes of copies only. `copied`: the copy sites
that copy more. -/
def allocNote (copied : Array (String × Float × Float)) (key : String) : String :=
  let (fn, sc) := match key.splitOn " in " with
    | f :: rest => (f, " in ".intercalate rest)
    | [] => (key, "")
  let same := copied.filter fun (ck, _, _) => ck.startsWith s!"{fn} [" && ck.endsWith s!"] in {sc}"
  "Cause not attributed: explain explains copies, not allocations." ++
    (if same.isEmpty then "" else s!" The same function copies more too ({", ".intercalate (same.toList.map fun (ck, cx, cy) => s!"{mdCode ck} {fmtChange fmtCount cx cy}")}).")

/-- `s` cut to about `n` characters, at a space. -/
def shorten (s : String) (n : Nat) : String :=
  if s.length ≤ n then s
  else
    let cut := String.ofList (s.toList.take n)
    let words := cut.splitOn " "
    " ".intercalate (words.take (words.length - 1)) ++ " …"

/-- What changed inside a regressed declaration, as a collapsed block of the comment. -/
def whyMd (e : Leanprof.Regress.Explanation) (rowsEach : Nat := 5) : String := Id.run do
  let headline := match topCause e with
    | some r => s!"; top change: {whatLabel r.what} {htmlCode r.name} {rowChange r}"
    | none => "; cause not attributed"
  let mut l : Array String := #[
    s!"<details><summary>why {htmlCode e.key} got more expensive: {fmtSigned fmtHeartbeats (e.new - e.base)}{headline}</summary>", "",
    s!"{mdCode e.pos}: {fmtHeartbeats e.base} → {fmtHeartbeats e.new}" ++
      (if e.parts.isEmpty then "" else
        s!" ({", ".intercalate (e.parts.toList.map fun (p, x, y) => s!"{p} {fmtSigned fmtHeartbeats (y - x)}")})")]
  let (rows, more) := shownRows e rowsEach
  unless rows.isEmpty do
    l := l ++ #["", "| what changed | | defined at | base | head | change |", "|---|---|---|---:|---:|---:|"]
    for r in rows do
      l := l.push s!"| {whatLabel r.what} | {mdCode r.name} | {if r.loc.isEmpty then "" else mdCode r.loc} | {rowSide r r.base r.baseTimes} | {rowSide r r.new r.newTimes} | {rowChange r} |"
    if more > 0 then l := l.push s!"\n… and {more} more changed (`leanprof compare` lists them)"
  unless e.notes.isEmpty do
    l := l.push ""
    for n in e.notes do l := l.push s!"- {n}"
  l := l ++ #["", "</details>"]
  return "\n".intercalate l.toList

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
        rule := "a larger total" }
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
  out := out.push s!"Copies, allocations and calls do not vary between runs (unless threads race) and heartbeats nearly so (a declaration counts as regressed above 1% and 1,000); time does, so it is shown but never checked. Enforced: {enforced}."
  let introEnd := out.size
  let row (m : MdMetric) (k : String) (x y : Float) : String :=
    let mark := if !m.bad.any (·.1 == k) then "" else if o.failOn.contains m.id then " ❌" else " ⚠️"
    s!"| {mdCode k} | {m.fmt x} | {m.fmt y} | {fmtChange m.fmt x y}{mark} |"
  for m in metrics do
    if m.rows.isEmpty then continue
    out := out.push ""
    let openAttr := if m.bad.isEmpty then "" else " open"
    -- the rule is what would count, not a finding: say whether it happened
    let verdict := if m.bad.isEmpty then "no regression" else s!"{m.bad.size} regressed"
    out := out.push (if m.isExact then
        s!"<details{openAttr}><summary>{m.label}: {m.rows.size} changed, {verdict} (a regression is {m.rule})</summary>"
      else s!"<details{openAttr}><summary>{m.label}: {m.rows.size} changed ({m.rule})</summary>")
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
  -- why: what changed inside each regressed declaration and copy site
  let mut why : Array String := #[]
  if let some m := metrics.find? (·.id == "heartbeats") then
    if !m.bad.isEmpty then
      let i := if run.isSome then 2 else 0
      let bj ← IO.ofExcept (Json.parse (← IO.FS.readFile o.files[i]!))
      let nj ← IO.ofExcept (Json.parse (← IO.FS.readFile o.files[i + 1]!))
      for e in explainElab bj nj ((m.bad.toList.take o.top).toArray.map (·.1)) do
        why := why.push (whyMd e)
  if let some m := metrics.find? (·.id == "copies") then
    if !m.bad.isEmpty then
      let findings ← loadFindings o.explain
      let mut items : Array String := #[]
      for (k, x, y) in m.bad.toList.take o.top do
        let cause := (copyCauseText findings k y.toUInt64.toNat).getD
          "cause not attributed: no `leanprof explain` findings were given (`report-md --explain HEAD_EXPLAIN.json`)"
        items := items.push s!"- {mdCode k}: {fmtChange fmtCount x y} copies. {mdProse (shorten cause 600)}"
      -- allocation sites that went up, with the copies made in the same function and scope
      why := why.push ("\n".intercalate ([
        s!"<details><summary>why: {m.bad.size} copy {if m.bad.size == 1 then "site copies" else "sites copy"} more (causes from leanprof explain on the head)</summary>", ""] ++
        items.toList ++ ["", "</details>"]))
  -- allocation sites that went up: explain has no causes for them; say which also copy more
  if let some am := metrics.find? (·.id == "allocs") then
    if !am.bad.isEmpty then
      let copied := ((metrics.find? (·.id == "copies")).map (·.bad)).getD #[]
      let mut items : Array String := #[]
      for (k, x, y) in am.bad.toList.take o.top do
        items := items.push (s!"- {mdCode k}: {fmtChange fmtCount x y} allocations. " ++ allocNote copied k)
      why := why.push ("\n".intercalate ([
        s!"<details><summary>why: {am.bad.size} allocation {if am.bad.size == 1 then "site allocates" else "sites allocate"} more</summary>", ""] ++
        items.toList ++ ["", "</details>"]))
  -- within GitHub's comment limit: the summary and tables first, then as many explanations as fit
  let core := ("\n".intercalate out.toList).length
  let mut shown : Array String := #[]
  let mut used := core
  let mut dropped := 0
  for w in why do
    if used + w.length + 2 + 200 ≤ o.maxChars then
      shown := shown.push w
      used := used + w.length + 2
    else dropped := dropped + 1
  if dropped > 0 then
    shown := shown.push s!"_{dropped} more {if dropped == 1 then "explanation" else "explanations"} not shown (comment size limit); `leanprof compare` prints all of them._"
  let whyLines := shown.toList.flatMap fun w => ["", w]
  let final := out.toList.take introEnd ++ whyLines ++ out.toList.drop introEnd
  IO.println ("\n".intercalate final)
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
  if let some t ← projectTargets then
    let what := match Leanprof.Workload.choose t with
      | .exe e why => s!"`{e}` ({why})"
      | .ambiguous exes _ => s!"one of {exes.size} executables, named: leanprof EXE -- ARGS"
      | .elab => "compile time of the libraries (no executable)"
      | .nothing => "nothing (no lean_exe or lean_lib in the lakefile)"
    discard <| report true s!"`leanprof` with no arguments profiles {what}" ""
  -- an instrumented build left by an interrupted (or `--keep`) run: put the normal one back
  if isProject then
    let stashed ← (← workspacePackages).filterM fun p => (stashDir p).isDir
    let saved ← if ← savedDir.isDir then
        pure ((← savedDir.readDir).filterMap fun e =>
          if e.fileName.endsWith ".trace" || e.fileName.endsWith ".hash" || e.fileName.endsWith ".rsp" then none
          else some e.fileName)
      else pure #[]
    if stashed.isEmpty && saved.isEmpty then
      discard <| report true "no instrumented build left in .lake/build" ""
    else
      restoreObjects
      for exe in saved do restoreExe exe (removeUnsaved := false)
      discard <| report true (s!"an interrupted or --keep run had left instrumented objects in {stashed.size} " ++
        s!"package(s){if saved.isEmpty then "" else s!" and {", ".intercalate saved.toList}"}: the normal build is back") ""
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
    let ccFix ← match ← ccProblem with
      | some p => pure p
      | none => pure s!"{(out.map (·.stderr.take 300 |>.toString)).getD "cc not found"}"
    unless ← report (out.any (·.exitCode == 0)) "C compiler builds leanprof's runtime for this Lean (for run, stat, measure)"
        ccFix do problems := problems + 1
    -- the runtime's self-check, built and linked as `leanprof run` builds a program
    if out.any (·.exitCode == 0) then
      let leanVersion := ((← tryCmd "lean" #["--short-version"]).map (·.stdout.trimAscii.toString)).getD "?"
      match ← selfCheckProbe root with
      | .ok (ops, "") =>
        discard <| report true s!"copy detection works with Lean {leanVersion} ({ops})" ""
      | .ok (_, warning) =>
        discard <| report false warning ""
        problems := problems + 1
      | .error e =>
        discard <| report false s!"copy detection self-check could not run: {e}" ""
        problems := problems + 1
    let probe := tmp.withExtension "c"
    IO.FS.writeFile probe "int f(int x) { return x + 1; }\n"
    let clang ← tryCmd "sh" #["-c", s!"LEANPROF_AUTO=1 {root / "scripts" / "leanprof-cc"} -c {probe} -o {tmp}.o"]
    unless ← report (clang.any (·.exitCode == 0)) "clang with -finstrument-functions-after-inlining (for --auto)"
        s!"install clang: {← installHint "clang"}" do problems := problems + 1
  -- samply: optional, but what `leanprof sample` and `leanprof` with no arguments use
  match ← findSamply with
  | some s =>
    let v := ((← tryCmd s #["--version"]).map (·.stdout.trimAscii.toString)).getD "samply"
    discard <| report true s!"{v}{if s == "samply" then "" else s!" at {s}"} (for `leanprof sample`)" ""
    if let some why ← samplingBlocked then
      discard <| report false "sampling allowed on this machine" s!"{why}\n       (until then `leanprof` with no arguments uses `leanprof stat`)"
  | none =>
    discard <| report false "samply (for `leanprof sample`; without it, `leanprof` with no arguments rebuilds with probes)"
      s!"optional; get it (samply 0.13.1, checksum-verified, into {← leanprofHome}/samply):\n         {← samplyInstallCmd}\n       or: brew install samply / cargo install samply"
  -- objcopy, for `run --core`
  let objcopy ← findObjcopy
  discard <| report objcopy.isSome
    s!"{objcopy.getD "llvm-objcopy"} (for `leanprof run --core`)"
    s!"optional; install it with: {← installHint "objcopy"}"
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

def statCmd (argv : List String) : IO UInt32 := do
  -- allocations and frees are on unless turned off
  let (offAllocs, argv) := (argv.contains "--no-allocs", argv.filter (· != "--no-allocs"))
  let (offFrees, argv) := (argv.contains "--no-frees", argv.filter (· != "--no-frees"))
  let opts ← IO.ofExcept (parseRun {} argv)
  let some exe := opts.exe | throw <| IO.userError (usageFor "stat")
  let allocs := !offAllocs
  let frees := !offFrees
  clearReports opts.json
  let rc ← buildWithShims exe opts.auto allocs (frees := frees) (extraEnv := tinyEnv opts) (deps := opts.deps)
  if rc != 0 then return rc
  let json := opts.json.getD lastReport.toString
  let env := #[("LEANPROF_QUIET", some "1"), ("LEANPROF_STAT", some "1"), ("LEANPROF_JSON", some json),
    ("LEANPROF_TRACE", opts.trace)]
  -- the first launch of a freshly linked binary is slower (on macOS, the
  -- system checks a new binary's signature: 2.3 s for a 106 MB compiler);
  -- launched once first, without running it (leanprof's runtime exits at
  -- load), so the time below is that of a warm start
  let env ← instrumentedEnv exe opts env
  let bin := (← absPath (exePath exe)).toString
  let l0 ← IO.monoNanosNow
  let launchRc ← try spawnWait bin #[] (env.push ("LEANPROF_LAUNCH_ONLY", some "1")) (opts.cwd.map (·))
    catch _ => pure 1
  let firstLaunch := (← IO.monoNanosNow) - l0
  let t0 ← IO.monoNanosNow
  let code ← try spawnWait bin opts.args env (opts.cwd.map (·))
    finally
      unless opts.keep do cleanupInstrumented exe
  let outside := (← IO.monoNanosNow) - t0
  publishReport json
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
  if launchRc == 0 then
    row "" s!"(the first launch of the new binary, {fmtTime firstLaunch.toFloat} to load it, is not included)"
  row "CPU" s!"{fmtTime user} user + {fmtTime sys} system ({fmt2 ((user + sys) / (if wall > 0 then wall else 1))} cores)"
  row "peak memory" s!"{fmtBytes (num mem "peak_rss")} resident, {fmtBytes (num mem "peak_commit")} committed by Lean's allocator"
  let allocSites := getArr j "allocations"
  if allocs then
    let n := allocSites.foldl (fun a s => a + num s "allocs") 0
    let b := allocSites.foldl (fun a s => a + num s "bytes") 0
    let est := allocSites.foldl (fun a s => a + num s "est_ns") 0
    let run := num j "run_ns"
    row "allocations" (s!"{withCommas n.toUInt64.toNat} objects, {fmtBytes b} (by compiled Lean code)" ++
      (if est > 0 then s!", est. {fmtTime est}{if run > 0 then s!" ({fmt2 (est / run * 100)}% of the run)" else ""}" else ""))
  else row "allocations" "not counted (--no-allocs)"
  let copies := (getArr j "copies").filter fun c => num c "shared" + num c "multi_threaded" > 0
  let nc := copies.foldl (fun a c => a + num c "shared" + num c "multi_threaded") 0
  let bc := copies.foldl (fun a c => a + num c "bytes") 0
  let tc := copies.foldl (fun a c => a + num c "copy_ns") 0
  let run := num j "run_ns"
  row "copies" (s!"{withCommas nc.toUInt64.toNat} of shared values, {fmtBytes bc}, {fmtTime tc}" ++
    (if run > 0 && nc > 0 then s!" ({fmt2 (tc / run * 100)}% of the run)" else ""))
  let warning := str ((j.getObjVal? "self_check").toOption.getD Json.null) "warning"
  unless warning.isEmpty do row "" s!"warning: {warning}"
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
        s!"{if (getArr s "too_small").any (·.getStr?.toOption == some "total_ns") then tooSmallLabel else fmtTime (num s "total_ns")}{pct}  {str s "name"}{if pos.isEmpty then "" else s!"  ({pos})"}"
  if allocs || frees || opts.auto.isSome then
    IO.println "\n  times include the probes' cost; `leanprof run` and the JSON report have the details"
  IO.println s!"  report: {json}"
  return code

/-! ## `leanprof` with no arguments: find the workload, profile it cheaply, say what next -/

def shellQuote (a : String) : String :=
  if !a.isEmpty && a.toList.all (fun c => c.isAlphanum || "-_./=:,+@%".contains c) then a
  else "'" ++ a.replace "'" "'\\''" ++ "'"

/-- ` -- ARGS` as typed on a command line, or nothing. -/
def argsText (args : Array String) : String :=
  if args.isEmpty then "" else " -- " ++ " ".intercalate (args.toList.map shellQuote)

/-- How to run `exe` the way `leanprof EXE` does: by name, unless the name is a command. -/
def startCommand (exe : String) : String :=
  if (commands.any (·.1 == exe)) then s!"leanprof sample {shellQuote exe}" else s!"leanprof {shellQuote exe}"

def printFindings (findings : Array String) (next : Array (String × String)) : IO Unit := do
  IO.println "\nleanprof: top findings"
  if findings.isEmpty then IO.println "  nothing stands out in this run"
  for (f, i) in findings.toList.zipIdx do
    IO.println s!"  {i + 1}. {f}"
  IO.println "\nnext steps"
  let w := next.foldl (fun m (c, _) => max m c.length) 0
  for (c, what) in next do
    IO.println s!"  {c.pushn ' ' (w - c.length)}   {what}"

/-- Findings of a sampled report: the project's functions that took the most
CPU, and runtime work (copies, allocation, closures) worth an exact count. -/
def sampleFindings (exe : String) (args : Array String) : IO (Array String × Array (String × String)) := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile lastReport))
  let total := num j "wall_ns"
  let a := argsText args
  let share (x : Float) := if total > 0 then x / total * 100 else 0
  let cat (c : String) := (getArr j "runtime").foldl (fun s r => if str r "category" == c then s + num r "self_ns" else s) 0
  let mut cands : Array (Float × String) := #[]
  let copies := cat "copying non-exclusive values"
  if share copies ≥ 1 then
    cands := cands.push (copies, s!"{fmt2 (share copies)}% of CPU copies arrays or strings that were still shared: " ++
      s!"`leanprof run {exe}{a}` finds each copy site, `leanprof explain` says why and gives the fix")
  let alloc := cat "allocation" + cat "freeing objects (reference counts reaching zero)"
  if share alloc ≥ 10 then
    cands := cands.push (alloc, s!"{fmt2 (share alloc)}% of CPU allocates and frees objects: " ++
      s!"`leanprof run --allocs {exe}{a}` counts allocations per function")
  let closures := cat "applying closures"
  if share closures ≥ 5 then
    cands := cands.push (closures, s!"{fmt2 (share closures)}% of CPU applies closures: " ++
      s!"`leanprof run --counters {exe}{a}` counts closure applications per function")
  let own := (getArr j "scopes").filter (num · "own_ns" > 0) |>.qsort (num · "own_ns" > num · "own_ns")
  for s in own.toList.take 3 do
    let x := num s "own_ns"
    if share x < 1 then continue
    let self := num s "self_ns"
    let parts := (if share self ≥ 1 then [s!"its own code {fmt2 (share self)}%"] else []) ++
      ((getArr s "own_top").toList.filter (fun l => share (num l "ns") ≥ 1) |>.map fun l =>
        let n := str l "name"
        -- a C++ name without its parameter list
        let n := if (n.splitOn " (in ").length == 1 then (n.splitOn "(").head! else n
        s!"{if n.length > 50 then (n.take 50).toString ++ "…" else n} {fmt2 (share (num l "ns"))}%")
    cands := cands.push (x, s!"{fmt2 (share x)}% of CPU in {str s "name"} ({str s "pos"})" ++
      (if parts.isEmpty then "" else s!": {", ".intercalate parts}"))
  let findings := (cands.qsort (·.1 > ·.1)).toList.take 3 |>.toArray |>.map (·.2)
  let findings := if total < 20e6 then
      findings.push s!"only {fmtTime total} of CPU was sampled: a larger input (`{startCommand exe} -- ARGS`) gives steadier numbers"
    else findings
  return (findings, #[
    (s!"leanprof run {exe}{a}", "exact: copies of shared values, tasks, waits (rebuilds with probes, puts your build back)"),
    ("leanprof explain", "after run: why each copy happened, and the fix in Lean"),
    (s!"leanprof fix --exe {exe}{a}", "apply that fix on a git branch, test, measure, commit it only if it helps"),
    (s!"leanprof run --auto {exe}{a}", "every function's time and exact call count"),
    (s!"samply load .lake/leanprof/{exe}.json", "flame graph with Lean names")])

/-- Findings of a `stat` report: the costliest copy sites, then the hottest scopes. -/
def statFindings (exe : String) (args : Array String) : IO (Array String × Array (String × String)) := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile lastReport))
  let a := argsText args
  let run := num j "run_ns"
  let copies := (getArr j "copies").filter (fun c => num c "shared" + num c "multi_threaded" > 0)
    |>.qsort (num · "copy_ns" > num · "copy_ns")
  let mut findings : Array String := #[]
  for c in copies.toList.take 3 do
    let n := num c "shared" + num c "multi_threaded"
    let pos := str c "where"
    findings := findings.push (s!"{withCommas n.toUInt64.toNat} {if n == 1 then "copy" else "copies"} of a shared {str c "kind"} in {str c "function"}" ++
      s!"{if pos.isEmpty then "" else s!" ({pos})"}, {fmtTime (num c "copy_ns")}" ++
      s!"{if run > 0 then s!" ({fmt2 (num c "copy_ns" / run * 100)}% of the run)" else ""}")
  let allocs := getArr j "allocations"
  let est := allocs.foldl (fun s x => s + num x "est_ns") 0
  if let .ok f := j.getObjVal? "frees" then
    if findings.size < 3 && run > 0 && num f "free_ns" / run ≥ 0.1 then
      findings := findings.push (s!"freeing objects takes {fmt2 (num f "free_ns" / run * 100)}% of the run (longest pause " ++
        s!"{fmtTime (num f "max_ns")}): `leanprof run --frees {exe}{a}` says where each cascade starts")
  if findings.size < 3 && run > 0 && est / run ≥ 0.1 then
    findings := findings.push s!"allocation takes about {fmt2 (est / run * 100)}% of the run: `leanprof run --allocs {exe}{a}` lists it per function"
  return (findings, #[
    (s!"leanprof run {exe}{a}", "the same counts with every copy site, task and wait listed"),
    ("leanprof explain", if copies.isEmpty then "why each copy happened (none in this run)" else "why each copy happened, and the fix in Lean"),
    (s!"leanprof fix --exe {exe}{a}", "apply that fix on a git branch, test, measure, commit it only if it helps"),
    (s!"leanprof run --auto {exe}{a}", "every function's time and exact call count"),
    ("leanprof doctor", "what `leanprof` needs to sample instead, with no rebuild")])

/-- Findings of a compile-time report: the costliest declarations. -/
def elabFindings : IO (Array String × Array (String × String)) := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile ((".lake" : FilePath) / "leanprof" / "elab.json")))
  let total := (getArr j "files").foldl (fun s f => s + num f "total_ns") 0
  let decls := (getArr j "scopes").qsort (num · "total_ns" > num · "total_ns")
  let mut findings : Array String := #[]
  for d in decls.toList.take 3 do
    let x := num d "total_ns"
    if x <= 0 then continue
    let phases := [("elaboration", num d "elab_ns"), ("kernel", num d "kernel_ns"),
      ("compiler", num d "compile_ns"), ("linters", num d "lint_ns")]
    let (ph, px) := phases.foldl (fun b p => if p.2 > b.2 then p else b) ("", 0)
    let name := str d "name"
    let name := if name.length > 60 then (name.take 60).toString ++ "…" else name
    findings := findings.push (s!"{fmtTime x}{if total > 0 then s!" ({fmt2 (x / total * 100)}%)" else ""} in {name} " ++
      s!"({str d "pos"}), {fmt2 (if x > 0 then px / x * 100 else 0)}% {ph}")
  let slowest := (getArr j "files").qsort (num · "total_ns" > num · "total_ns")
  let file := (slowest[0]?.map (str · "file")).getD "FILE.lean"
  return (findings, #[
    (s!"leanprof elab --heartbeats {shellQuote file}", "exact (heartbeats, nearly the same on every run) for the slowest file"),
    (s!"leanprof elab --counts {shellQuote file}", "what isDefEq and whnf unfolded, instances tried, simp lemmas"),
    ("leanprof html", "the project view: folder, module, declaration, term, with source")])

def startCmd (pick : Option String) (args : Array String) : IO UInt32 := do
  let some targets ← projectTargets | do
    IO.println usage
    IO.println "\nIn a Lake project (a directory with lakefile.lean or lakefile.toml), `leanprof` with no arguments profiles it."
    return 0
  let choice : Leanprof.Workload.Choice := match pick with
    | some e => .exe e "named on the command line"
    | none => Leanprof.Workload.choose targets
  match choice with
  | .nothing =>
    IO.eprintln "leanprof: the lakefile declares no lean_exe or lean_lib to profile; name a program: leanprof sample PATH -- ARGS"
    return 2
  | .ambiguous exes test =>
    IO.println s!"leanprof: this project has {exes.size} executables; pick the one to profile (with its arguments):"
    for e in exes do IO.println s!"  {startCommand e} -- ARGS"
    if let some t := test then IO.println s!"the tests (test driver):\n  {startCommand t}"
    unless targets.libs.isEmpty do
      IO.println "compile time of the libraries:\n  leanprof elab --project --compact"
    return 2
  | .elab =>
    IO.println s!"leanprof: no executable in this project; profiling compile time of its {if targets.libs.size == 1 then "library" else "libraries"} ({", ".intercalate targets.libs.toList})"
    IO.println "  leanprof elab --project --compact   (builds the package, then elaborates each module with timing)"
    (← IO.getStdout).flush
    let rc ← elabCmd ["--project", "--compact", "--top", "5"]
    if rc != 0 then return rc
    let (f, n) ← elabFindings
    printFindings f n
    return 0
  | .exe exe why =>
    IO.println s!"leanprof: profiling `{exe}`{if args.isEmpty then " with no arguments" else s!" {" ".intercalate (args.toList.map shellQuote)}"} ({why})"
    (← IO.getStdout).flush
    let rc ← spawnWait "lake" #["build", exe] #[]
    if rc != 0 then
      IO.eprintln s!"leanprof: `lake build {exe}` failed"
      return rc
    let samply ← findSamply
    let blocked ← samplingBlocked
    let mut useStat := samply.isNone || blocked.isSome
    if let some why := blocked then
      IO.println s!"leanprof: cannot sample here: {why}"
    else if samply.isNone then
      IO.println s!"leanprof: samply is not installed, so `{exe}` is rebuilt with probes (leanprof stat); to sample with no rebuild, get samply:\n  {← samplyInstallCmd}"
    let mut code : UInt32 := 0
    (← IO.getStdout).flush
    if !useStat then
      IO.println s!"  leanprof sample --top 8 {exe}{argsText args}   (samply, no rebuild with probes)"
      code ← sample (["--top", "8", exe] ++ (if args.isEmpty then [] else "--" :: args.toList))
      unless ← lastReport.pathExists do
        IO.println "leanprof: sampling failed; counting with probes instead (leanprof stat)"
        (← IO.getStdout).flush
        useStat := true
    if useStat then
      IO.println s!"  leanprof stat {exe}{argsText args}"
      (← IO.getStdout).flush
      code ← statCmd ([exe] ++ (if args.isEmpty then [] else "--" :: args.toList))
      unless ← lastReport.pathExists do return if code == 0 then 1 else code
    let (f, n) ← if useStat then statFindings exe args else sampleFindings exe args
    printFindings f n
    if code != 0 then
      IO.println s!"\n`{exe}` exited with code {code}{if args.isEmpty then s!"; if it needs arguments: {startCommand exe} -- ARGS" else ""}"
    return code

/-- The command `argv` names. (Its own definition: Lean before 4.28 types a `try`
around this `match` by its first `return`, as a `Nat`.) -/
def dispatchCmd (argv : List String) : IO UInt32 := do
  match argv with
  | [] => startCmd none #[]
  | "--" :: rest => startCmd none rest.toArray
  | ["help"] | ["--help"] | ["-h"] =>
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
  | "measure-pair" :: rest => measurePairCmd rest
  | "judge" :: rest => judgeCmd rest
  | "compare" :: rest => compare rest
  | "report-md" :: rest => reportMd rest
  | "sample" :: rest => sample rest
  | "elab" :: rest => elabCmd rest
  | "build" :: rest =>
    Leanprof.Build.hooks.set { guard := guardSignals, interrupted := checkInterrupted }
    Leanprof.Fix.runner.set { output := guardedOutput, interrupted := checkInterrupted }
    Leanprof.Build.buildCmd (usageFor "build") rest
  | "__build-shim" :: rest => Leanprof.BuildShim.shimMain rest
  | "explain" :: rest =>
    Leanprof.Explain.explainCmd rest fun args env => do spawnWait (← IO.appPath).toString args env
  | "fix" :: rest =>
    -- a signal ends the current step; `fix` then removes its worktree
    guardSignals 0
    Leanprof.Fix.runner.set { output := guardedOutput, interrupted := checkInterrupted }
    Leanprof.Fix.fixCmd rest fun args cwd => do
      Leanprof.Fix.capture (← IO.appPath).toString args #[("LEANPROF_QUIET", some "1")] (cwd := some cwd)
  | "experiment" :: rest =>
    -- a signal ends the current step; the worktrees stay for the next try
    guardSignals 0
    Leanprof.Fix.runner.set { output := guardedOutput, interrupted := checkInterrupted }
    Leanprof.Experiment.experimentCmd rest fun args cwd => do
      Leanprof.Fix.capture (← IO.appPath).toString args #[("LEANPROF_QUIET", some "1")] (cwd := some cwd)
  | "html" :: rest => LeanprofHtml.htmlCmd (usageFor "html") rest
  | "top" :: rest => LeanprofLive.topCmd rest
  | "dump" :: rest => LeanprofLive.dumpCmd rest
  | "mcp" :: rest => LeanprofLive.mcpCmd rest
  | name :: rest =>
    -- `leanprof EXE [-- ARGS]`: the no-argument flow for an executable of this project
    let exes := ((← projectTargets).map (·.exes)).getD #[]
    if !name.startsWith "-" && exes.contains name then
      startCmd (some name) (match rest with | "--" :: r => r.toArray | r => r.toArray)
    else if name.startsWith "-" then
      IO.eprintln usage
      return 2
    else
      IO.eprintln s!"leanprof: `{name}` is neither a command nor an executable of this project{if exes.isEmpty then "" else s!" ({", ".intercalate exes.toList})"}; `leanprof help` lists the commands"
      return 2

def dispatch (argv : List String) : IO UInt32 := do
  try dispatchCmd argv
  catch e =>
    let s ← caughtSignal
    if s != 0 then return 128 + s  -- said by `main`
    IO.eprintln s!"leanprof: {e}"
    return 2

def main (argv : List String) : IO UInt32 := do
  let rc ← dispatch argv
  -- a signal caught while a child ran (c/cli.c): the build is back; exit as killed
  let s ← caughtSignal
  if s != 0 then
    IO.eprintln s!"leanprof: interrupted (signal {s}); the project's normal build is back"
    return 128 + s
  return rc
