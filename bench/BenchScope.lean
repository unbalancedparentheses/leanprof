import Leanprof
import LeanProfiler

/-!
One workload source, three builds. `WlPlain.lean` is the workload program;
`WlProf.lean` and `WlSpans.lean` are symbolic links to it, so all three
compile the same code as different modules, and these macros expand by the
module they are in:

| module | `scope! "f" e` | `span! "f" act` |
|---|---|---|
| `WlPlain` | `e` | `act` |
| `WlProf` | `profile! "f" e` | `act` |
| `WlSpans` | `e` | `LeanProfiler.span "f" act` |

The plain build is the baseline, and also what `leanprof run --auto`,
`leanprof sample` and samply see (no annotations). `WlProf` is the program
annotated with `profile!`, which `leanprof run` and its `--allocs`,
`--counters` and `--frees` modes run. LeanProfiler only has `IO` spans, so
`WlSpans` times phases and tasks, not pure inner functions.
-/

open Lean

syntax (name := benchScope) "scope! " str ppSpace term : term
syntax (name := benchSpan) "span! " term:max ppSpace term:max : term

macro_rules
  | `(scope! $s $e) => do
    if (← MonadQuotation.getMainModule).getRoot == `WlProf then `(profile! $s $e) else `($e)

macro_rules
  | `(span! $s $act) => do
    if (← MonadQuotation.getMainModule).getRoot == `WlSpans then `(LeanProfiler.span $s $act) else `($act)
