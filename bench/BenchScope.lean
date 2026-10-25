import Leanprof
import LeanProfiler

/-!
One workload source, four builds. `WlPlain.lean` is the workload program;
`WlProf.lean`, `WlSpans.lean` and `WlPhases.lean` are symbolic links to it, so
all four compile the same code as different modules, and these macros expand
by the module they are in:

| module | `scope! "f" e` | `span! "f" act` |
|---|---|---|
| `WlPlain` | `e` | `act` |
| `WlProf` | `profile! "f" e` | `act` |
| `WlSpans` | `e` | `LeanProfiler.span "f" act` |
| `WlPhases` | `e` | `Leanprof.scopeM "f" act` (what `profile! "f" act` is) |

The plain build is the baseline, and also what `leanprof run --auto`,
`leanprof sample` and samply see (no annotations). `WlProf` is the program
annotated with `profile!`, which `leanprof run` and its `--allocs`,
`--counters` and `--frees` modes run. LeanProfiler only has `IO` spans, so
`WlSpans` times phases and tasks, not pure inner functions. `WlPhases` has
leanprof scopes in exactly those places, to compare the two like with like
(`profile!` itself takes a literal label; `scopeM` is what it expands to for
an action, here with the phase's name passed in).
-/

open Lean

syntax (name := benchScope) "scope! " str ppSpace term : term
syntax (name := benchSpan) "span! " term:max ppSpace term:max : term

macro_rules
  | `(scope! $s $e) => do
    if (← MonadQuotation.getMainModule).getRoot == `WlProf then `(profile! $s $e) else `($e)

macro_rules
  | `(span! $s $act) => do
    match (← MonadQuotation.getMainModule).getRoot with
    | `WlSpans => `(LeanProfiler.span $s $act)
    | `WlPhases => `(Leanprof.scopeM $s $act)
    | _ => `($act)
