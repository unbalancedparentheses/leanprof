import Lake
open Lake DSL System

package leanprof where
  version := v!"0.1.0"

/-- Flags that route the runtime's copy, task-spawn and blocking-wait paths
through leanprof's shims. Add them to `moreLeancArgs` of any executable whose
copies and tasks you want observed. -/
def copyFlags : Array String :=
  #["copy_expand_array_nonlinear", "copy_sarray_nonlinear", "copy_string_nonlinear",
    "array_push", "byte_array_push", "float_array_push",
    "string_push", "string_append", "string_utf8_set",
    "task_spawn_core", "io_as_task", "io_wait", "task_get"].map
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

/-- Link flags so the report can name the functions that copied. -/
def linkFlags : Array String := #["-rdynamic"]

@[default_target] lean_lib Leanprof

lean_exe copybug where
  root := `Examples.CopyBug
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

@[test_driver] lean_exe tests where
  root := `Tests.Main
  moreLeancArgs := copyFlags ++ allocFlags ++ counterFlags
  moreLinkArgs := linkFlags

target leanprof_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "leanprof.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "leanprof.c"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString]
  let incTrace ← computeTrace (pkg.dir / "c" / "counters.inc.c")
  buildO oFile srcJob weakArgs #["-fPIC", "-O2", "-Wall"] "cc" (return (← getLeanTrace).mix incTrace)

extern_lib leanprof_c pkg := do
  let o ← pkg.target ``leanprof_o |>.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "leanprof_c") #[o]

lean_exe overhead where
  root := `Examples.Overhead

/-- `lake exe leanprof run|compare`. -/
lean_exe leanprof where
  root := `LeanprofCli
  supportInterpreter := false

lean_exe tasks where
  root := `Examples.Tasks
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

lean_exe minimal where
  root := `Examples.Minimal
