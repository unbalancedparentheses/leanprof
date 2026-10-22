/-!
# Runtime entry points

Thin bindings to `c/leanprof.c`. The reference bodies keep the definitions
meaningful in proofs and in the interpreter; compiled code calls the C side.
-/

namespace Leanprof

/-- Time `f ()` under the label `site`. `site` must be a string literal: the
runtime keys its tables by the literal's address. -/
@[extern "leanprof_scope"]
def scope {α : Type u} (site : @& String) (f : Unit → α) : α := f ()

/-- Open a scope on the current thread. Pair every call with `exit`. -/
@[extern "leanprof_enter"]
def enter (site : @& String) : BaseIO Unit := pure ()

/-- Close the innermost scope on the current thread. -/
@[extern "leanprof_exit"]
def exit : BaseIO Unit := pure ()

/-- Time a monadic action under `site`. The scope closes on exceptions too. -/
@[inline] def scopeM {m : Type → Type v} {α : Type} [Monad m] [MonadFinally m] [MonadLiftT BaseIO m]
    (site : @& String) (x : m α) : m α := do
  enter site
  tryFinally x exit

end Leanprof

namespace Leanprof

/-- Copies of shared or multi-threaded values recorded so far, on all
threads. Copies of compile-time constants are not counted. Only code built
with `copyFlags` is observed. -/
@[extern "leanprof_copies"]
opaque copies : BaseIO Nat

/-- Completed calls of scopes labelled `site`, on all threads. -/
@[extern "leanprof_calls"]
opaque calls (site : @& String) : BaseIO Nat

/-- Scopes currently open on this thread. -/
@[extern "leanprof_depth"]
opaque depth : BaseIO Nat

/-- The name leanprof reports for a C symbol. -/
@[extern "leanprof_demangle"]
opaque demangle (sym : @& String) : String

/-- Run `x` and fail if it copied a shared or multi-threaded value. -/
def expectNoCopies (x : IO α) : IO α := do
  let before ← copies
  let r ← x
  let n := (← copies) - before
  if n > 0 then throw <| IO.userError s!"leanprof: expected no copies, got {n}"
  return r

end Leanprof
