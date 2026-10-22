import Lake
open Lake DSL System

package leanprof where
  version := v!"0.1.0"

/-- Flags that route the runtime's copy paths through leanprof's shims.
Add them to `moreLeancArgs` of any executable whose copies you want counted. -/
def copyFlags : Array String :=
  #["copy_expand_array_nonlinear", "copy_sarray_nonlinear", "copy_string_nonlinear",
    "array_push", "byte_array_push", "float_array_push",
    "string_push", "string_append", "string_utf8_set"].map
    fun f => s!"-Dlean_{f}=leanprof_{f}"

/-- Link flags so the report can name the functions that copied. -/
def linkFlags : Array String := #["-rdynamic"]

@[default_target] lean_lib Leanprof

lean_exe copybug where
  root := `Examples.CopyBug
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

@[test_driver] lean_exe tests where
  root := `Tests.Main
  moreLeancArgs := copyFlags
  moreLinkArgs := linkFlags

target leanprof_o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "leanprof.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "leanprof.c"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString]
  buildO oFile srcJob weakArgs #["-fPIC", "-O2", "-Wall"] "cc" getLeanTrace

extern_lib leanprof_c pkg := do
  let o ← pkg.target ``leanprof_o |>.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "leanprof_c") #[o]

lean_exe overhead where
  root := `Examples.Overhead

/-- `lake exe leanprof run|compare`. -/
lean_exe leanprof where
  root := `LeanprofCli
  supportInterpreter := false
