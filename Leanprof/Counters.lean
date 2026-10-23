module

/-!
# Counters: constructor reuse and closure applications

Bindings to `c/counters.inc.c`. Counted only in code compiled with
`counterFlags` (or `LEANPROF_COUNTERS=1` through the wrapper); otherwise 0.
-/

public section
namespace Leanprof

/-- Reset/reuse checks that failed on a shared or multi-threaded constructor
value (each one allocated a new cell instead of updating in place), on all
threads. Failures on compile-time constants are not included. -/
@[extern "leanprof_reuse_failures"]
opaque reuseFailures : BaseIO Nat

/-- Reset/reuse checks made so far, successful or not, on all threads. -/
@[extern "leanprof_reuse_checks"]
opaque reuseChecks : BaseIO Nat

/-- Closure applications (`lean_apply_*`) made by compiled code, on all
threads. -/
@[extern "leanprof_closure_applications"]
opaque closureApplications : BaseIO Nat

/-- Run `x` and fail if a constructor could not be reused in place because
the value was shared. -/
def expectNoReuseFailures (x : IO α) : IO α := do
  let before ← reuseFailures
  let r ← x
  let failed := (← reuseFailures) - before
  if failed > 0 then
    throw <| IO.userError s!"leanprof: expected constructors to be reused in place, {failed} reuse checks failed"
  return r

/-- Run `x` and fail if it applied more than `n` closures. -/
def expectClosureApplicationsAtMost (n : Nat) (x : IO α) : IO α := do
  let before ← closureApplications
  let r ← x
  let made := (← closureApplications) - before
  if made > n then throw <| IO.userError s!"leanprof: expected at most {n} closure applications, got {made}"
  return r

end Leanprof
