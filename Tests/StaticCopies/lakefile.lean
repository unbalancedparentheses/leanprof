import Lake
open Lake DSL
package staticCopies
require leanprof from "../.."

def copyFlags := #["-Dlean_array_push=leanprof_array_push",
  "-Dlean_array_set=leanprof_array_set", "-Dlean_array_fset=leanprof_array_fset",
  "-Dlean_array_uset=leanprof_array_uset",
  "-Dlean_copy_expand_array_nonlinear=leanprof_copy_expand_array_nonlinear"]

lean_lib Cases where
  moreLeancArgs := copyFlags

lean_exe checkCopies where
  root := `Main
  moreLeancArgs := copyFlags
  moreLinkArgs := #["-rdynamic"]
