import Lake
open Lake DSL System

package leanprof where
  version := v!"0.1.0"
  description := "Profiler for compiled Lean 4 programs: time per scope, hidden copies of shared arrays and strings, allocations, tasks and compile cost, with exact regression checks for CI"
  keywords := #["profiler", "performance", "devtool", "cli", "benchmarking", "ci"]
  homepage := "https://github.com/unbalancedparentheses/leanprof/tree/main/docs/guide"
  license := "MIT"
  licenseFiles := #["LICENSE"]
  readmeFile := "README.md"

/-- Flags that route the runtime's copy, task-spawn and blocking-wait paths
through leanprof's shims. Add them to `moreLeancArgs` of any executable whose
copies and tasks you want observed. -/
def copyFlags : Array String :=
  #["copy_expand_array_nonlinear", "copy_sarray_nonlinear", "copy_string_nonlinear",
    "array_push", "byte_array_push", "float_array_push",
    "string_push", "string_append", "string_utf8_set",
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

/-- Link flags so the report can name the functions that copied. -/
def linkFlags : Array String := #["-rdynamic"]

@[default_target] lean_lib Leanprof

lean_exe copybug where
  root := `Examples.CopyBug
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

@[test_driver] lean_exe tests where
  root := `Tests.Main
  moreLeancArgs := copyFlags ++ allocFlags ++ counterFlags ++ freeFlags
  moreLinkArgs := linkFlags

target leanprof_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "leanprof.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "leanprof.c"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString]
  -- leanprof.c includes counters.inc.c, memory.inc.c, coverage.inc.c,
  -- explain.inc.c and live.inc.c: rebuild when any changes
  let counters ← computeTrace (pkg.dir / "c" / "counters.inc.c")
  let memory ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "memory.inc.c"))
  let coverage ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "coverage.inc.c"))
  let explain ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "explain.inc.c"))
  let live ← computeTrace (TextFilePath.mk (pkg.dir / "c" / "live.inc.c"))
  buildO oFile srcJob weakArgs #["-fPIC", "-O2", "-Wall"] "cc"
    (return (((((← getLeanTrace).mix counters).mix memory).mix coverage).mix explain).mix live)

extern_lib leanprof_c pkg := do
  let o ← pkg.target ``leanprof_o |>.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "leanprof_c") #[o]

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
/-- `leanprof top`, `dump` and `mcp`, imported by the command line. -/
lean_lib LeanprofLive

/-- `leanprof elab`, imported by the command, and its tests (run by `tests`). -/
lean_lib LeanprofElab where
  roots := #[`LeanprofElab, `LeanprofElabRange, `Tests.Elab]

/-- `leanprof elab`'s in-process Lean frontend: elaborates a file with every term and
tactic timed against its exact source range (LeanprofElabDriver.lean). It runs the
elaborators of the modules it imports, so it needs the interpreter. -/
lean_exe «leanprof-elab-driver» where
  root := `LeanprofElabDriver
  supportInterpreter := true

/-- `lake exe leanprof run|compare`. Builds the elab driver next to it. -/
lean_exe leanprof where
  root := `LeanprofCli
  supportInterpreter := false
  needs := #[«leanprof-elab-driver»]

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

/-- A long-running program for `leanprof top` and the flight recorder:
requests with an occasional slow one. -/
lean_exe server where
  root := `Examples.Server
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags
