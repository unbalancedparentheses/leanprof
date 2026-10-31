import Lake
open Lake DSL System

package leanprof where
  version := v!"0.1.0"
  description := "Profiler for compiled Lean 4 programs: time per scope, hidden copies of shared arrays and strings, allocations, tasks and compile cost, with exact regression checks for CI"
  keywords := #["profiler", "performance", "devtool", "cli", "benchmarking", "ci"]
  homepage := "https://unbalancedparentheses.github.io/leanprof"
  license := "MIT"
  licenseFiles := #["LICENSE"]
  readmeFile := "README.md"

/-- Flags that route the runtime's copy, task-spawn and blocking-wait paths
through leanprof's shims. Add them to `moreLeancArgs` of any executable whose
copies and tasks you want observed. -/
def copyFlags : Array String :=
  #["copy_expand_array_nonlinear", "copy_expand_array", "copy_sarray_nonlinear", "copy_string_nonlinear",
    "copy_byte_array", "copy_float_array",
    "array_push", "byte_array_push", "float_array_push",
    "string_push", "string_push_cold", "string_append", "string_utf8_set",
    "task_spawn_core", "io_as_task", "io_wait", "task_get",
    "task_map_core", "task_bind_core", "io_map_task", "io_bind_task"].map
    fun f => s!"-Dlean_{f}=leanprof_{f}"

/-- Opt-in allocation counting: route compiled code's allocations through
leanprof (every allocation pays a small cost). -/
def allocFlags : Array String :=
  #["alloc_small_object_core", "alloc_object"].map (fun f => s!"-Dlean_{f}=leanprof_{f}") ++
  #["mi_malloc", "mi_malloc_small"].map (fun f => s!"-D{f}=leanprof_{f}")

/-- Opt-in counters: failed constructor reuse and closure applications, per
function. Force-includes `c/counters.h`, which redirects `lean_is_exclusive`
and `lean_apply_*` in the generated C to leanprof's shims (every check and
application then pays a small cost). Projects depending on leanprof can use
`-include .lake/packages/leanprof/c/counters.h`. -/
def counterFlags : Array String := #["-include", (__dir__ / "c" / "counters.h").toString]
/-- Opt-in free tracking: route compiled code's slow reference-count path
(last references dropped, and every decrement of a multi-threaded object)
through leanprof, which times freeing cascades per call site. -/
def freeFlags : Array String := #["-Dlean_dec_ref_cold=leanprof_dec_ref_cold"]
/-- Opt-in retained memory, with `allocFlags` and `freeFlags`: also route the
runtime calls that make or free objects for compiled code (IO.mkRef and
IO.Ref.set, Array.replicate, Array.mk, Array.toList, String.mk, String.data,
freeing a constructor cell) through leanprof, which then follows each object
to its free. Turned on at run time with `LEANPROF_RETAINED=1`. -/
def retainedFlags : Array String :=
  #["free_object", "st_mk_ref", "st_ref_set", "st_ref_put", "mk_array", "array_mk", "array_to_list",
    "string_mk", "string_data"].map fun f => s!"-Dlean_{f}=leanprof_{f}"

/-- Link flags so the report can name the functions that copied. -/
def linkFlags : Array String := #["-rdynamic"]

@[default_target] lean_lib Leanprof

lean_exe copybug where
  root := `Examples.CopyBug
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

@[test_driver] lean_exe tests where
  root := `Tests.Main
  moreLeancArgs := copyFlags ++ allocFlags ++ counterFlags ++ freeFlags ++ retainedFlags
  moreLinkArgs := linkFlags

target leanprof_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "leanprof.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "leanprof.c"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString]
  -- leanprof.c includes counters.inc.c, memory.inc.c, retained.inc.c,
  -- coverage.inc.c, explain.inc.c and live.inc.c: rebuild when any changes
  let counters ← computeTrace (pkg.dir / "c" / "counters.inc.c")
  let memory ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "memory.inc.c"))
  let retained ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "retained.inc.c"))
  let coverage ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "coverage.inc.c"))
  let explain ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "explain.inc.c"))
  let live ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "live.inc.c"))
  -- LEANPROF_SANITIZE (CI, with LEAN_CC=scripts/leanprof-cc): the runtime
  -- with the same sanitizers as the rest of the program, compiled by clang
  let selfcheck ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "selfcheck.h"))
  let sanitize := (← IO.getEnv "LEANPROF_SANITIZE").getD ""
  let (cc, sanArgs) := if sanitize.isEmpty then ("cc", #[]) else
    ("clang", #[s!"-fsanitize={sanitize}", "-fno-omit-frame-pointer", "-g"])
  -- Apple clang outlines repeated instruction sequences into shared
  -- functions on arm64 even at -O2. With enter and exit inlined into every
  -- probe, the probes the program runs became chains of calls to outlined
  -- pieces (25 in `__cyg_profile_func_exit`) while calibration's copies,
  -- specialized for its internal scopes, stayed straight-line: real probes
  -- cost ~5 ns more than calibration measured, and that time stayed in the
  -- report. Not outlining keeps the two the same code (and cheaper).
  let noOutline := if System.Platform.isOSX then #["-mno-outline"] else #[]
  buildO oFile srcJob weakArgs (#["-fPIC", "-O2", "-Wall"] ++ noOutline ++ sanArgs) cc
    (return (((((((← getLeanTrace).mix counters).mix memory).mix retained).mix coverage).mix explain).mix live).mix selfcheck)

/-- The runtime's self-check (`c/selfcheck.c`), compiled with `copyFlags` like
the programs it vouches for: at exit, each of its known copies must reach a
shim, or the report warns that copies may be undercounted. -/
target selfcheck_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "selfcheck.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "selfcheck.c"
  let header ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "selfcheck.h"))
  let sanitize := (← IO.getEnv "LEANPROF_SANITIZE").getD ""
  let (cc, sanArgs) := if sanitize.isEmpty then ("cc", #[]) else
    ("clang", #[s!"-fsanitize={sanitize}", "-fno-omit-frame-pointer", "-g"])
  buildO oFile srcJob #["-I", (← getLeanIncludeDir).toString] (#["-fPIC", "-O2", "-Wall"] ++ copyFlags ++ sanArgs) cc
    (return (← getLeanTrace).mix header)

extern_lib leanprof_c pkg := do
  let o ← pkg.target ``leanprof_o |>.fetch
  let sc ← pkg.target ``selfcheck_o |>.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "leanprof_c") #[o, sc]

lean_exe overhead where
  root := `Examples.Overhead

/-- The page `leanprof html` writes, compiled in with `include_str`. -/
input_file htmlCss where
  path := "LeanprofHtml" / "report.css"
  text := true

input_file htmlJs where
  path := "LeanprofHtml" / "report.js"
  text := true

/-- `leanprof html`'s page generator, a library so the command can import it;
`needs` rebuilds it when the page's CSS or script changes. -/
lean_lib LeanprofHtml where
  needs := #[htmlCss, htmlJs]
/-- The proof-preservation auditor (`scripts/proof-audit`), compiled into
`leanprof experiment` with `include_str` and written next to each experiment. -/
input_file auditPy where
  path := "scripts" / "proof-audit" / "audit.py"
  text := true

input_file auditSnapshot where
  path := "scripts" / "proof-audit" / "Snapshot.lean"
  text := true

/-- `leanprof experiment`, a library so `needs` rebuilds it when the auditor changes. -/
lean_lib LeanprofExperiment where
  roots := #[`Leanprof.Experiment]
  needs := #[auditPy, auditSnapshot]

/-- `leanprof top`, `dump` and `mcp`, imported by the command line. -/
lean_lib LeanprofLive

/-- The elab driver's source, compiled into the command with `include_str`: `elab`
builds the driver from it for a project on another Lean. -/
input_file elabDriverSrc where
  path := "LeanprofElabDriver.lean"
  text := true

/-- The driver's memory readings (`--memory`), compiled into the command with
`include_str` like the driver's source, and linked into the bundled driver. -/
input_file memstatSrc where
  path := "c/memstat.c"
  text := true

/-- `leanprof build-memory`'s stand-in for `lean` in a Lake build, compiled into
the command with `include_str` and built with `cc` when first needed. -/
input_file leanwrapSrc where
  path := "c/leanwrap.c"
  text := true

/-- `leanprof build-memory`, a library so `needs` rebuilds it when the wrapper changes. -/
lean_lib LeanprofBuildMem where
  roots := #[`Leanprof.BuildMem, `Tests.BuildMem]
  needs := #[leanwrapSrc]

/-- `leanprof elab`, imported by the command, and its tests (run by `tests`), with those of
why a declaration got more expensive (`Tests/Regress.lean`). -/
lean_lib LeanprofElab where
  roots := #[`LeanprofElab, `LeanprofElabRange, `Tests.Elab, `Tests.Regress, `Tests.ElabWhy]
  needs := #[elabDriverSrc, memstatSrc]

/-- The driver's memory readings (`c/memstat.c`, `--memory`). -/
target memstat_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "memstat.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "memstat.c"
  buildO oFile srcJob #["-I", (← getLeanIncludeDir).toString] #["-fPIC", "-O2", "-Wall"] "cc" getLeanTrace

/-- `leanprof elab`'s in-process Lean frontend: elaborates a file with every term and
tactic timed against its exact source range (LeanprofElabDriver.lean). It runs the
elaborators of the modules it imports, so it needs the interpreter. -/
lean_exe «leanprof-elab-driver» where
  root := `LeanprofElabDriver
  supportInterpreter := true
  moreLinkObjs := #[memstat_o]

/-- The command's own signal handling (`c/cli.c`): an interrupted run puts
the project's normal build back before it exits. -/
target cli_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "cli.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "cli.c"
  buildO oFile srcJob #["-I", (← getLeanIncludeDir).toString] #["-fPIC", "-O2", "-Wall"] "cc" getLeanTrace

/-- `leanprof build`'s shim (Leanprof/BuildShim.lean): runs one toolchain program for
Lake and records when it ran, its peak memory and CPU time. Imports only `Init`. -/
lean_exe «leanprof-build-shim» where
  root := `LeanprofBuildShim
  moreLinkObjs := #[cli_o]

/-- `lake exe leanprof run|compare`. Builds the elab driver and the build shim next to it. -/
lean_exe leanprof where
  root := `LeanprofCli
  supportInterpreter := false
  needs := #[«leanprof-elab-driver», «leanprof-build-shim»]
  moreLinkObjs := #[cli_o]

lean_exe tasks where
  root := `Examples.Tasks
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

lean_exe minimal where
  root := `Examples.Minimal

/-- Compares leanprof's demangler with Lean's on a binary's symbols:
`demangle-check BINARY...`, run from that binary's project directory. -/
lean_exe «demangle-check» where
  root := `Tests.DemangleCheck

lean_exe taskchains where
  root := `Examples.TaskChains
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

lean_exe corecopies where
  root := `Examples.CoreCopies
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

/-- Stress test of the runtime (CI): many threads and tasks, deep recursion,
millions of scopes and copies, with exact counts checked at the end. -/
lean_exe stress where
  root := `Examples.Stress
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

/-- A long-running program for `leanprof top` and the flight recorder:
requests with an occasional slow one. -/
lean_exe server where
  root := `Examples.Server
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

/-- The causes `leanprof explain` recognises, each next to its fix
(`Examples/ExplainPatterns.lean`), and their tests (`Tests/ExplainFixes.lean`,
run by `tests`), which check the diagnosis and count both versions' copies;
`Tests/StaticCopies.lean` checks that `explain --static` flags exactly the
functions that copy. -/
lean_lib ExplainPatterns where
  roots := #[`Examples.ExplainPatterns, `Tests.ExplainFixes, `Tests.StaticCopies]
  moreLeancArgs := copyFlags

/-- A program with known retention (`Examples/Retained.lean`): what
`run --retained` reports for it is checked by `tests`, which runs it as a
child; `retained` runs it on its own. -/
lean_lib RetainedExample where
  roots := #[`Examples.Retained]
  moreLeancArgs := copyFlags ++ allocFlags ++ freeFlags ++ retainedFlags

lean_exe retained where
  root := `Examples.RetainedMain
  moreLeancArgs := copyFlags ++ allocFlags ++ freeFlags ++ retainedFlags
  moreLinkArgs := linkFlags

lean_exe explainpatterns where
  root := `Examples.ExplainPatternsMain
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags
