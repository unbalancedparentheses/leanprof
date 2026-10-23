module

/-!
# Runtime entry points

Thin bindings to `c/leanprof.c`. The reference bodies keep the definitions
meaningful in proofs and in the interpreter; compiled code calls the C side.
-/

public section
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

/-- Total time in scopes named `site` (outermost calls, with leanprof's own
overhead removed), in nanoseconds, on all threads. -/
@[extern "leanprof_total_ns"]
opaque totalNs (site : @& String) : BaseIO Float

/-- Measured cost of one scope's bookkeeping, in nanoseconds; this is what the
report subtracts per nested scope. -/
@[extern "leanprof_overhead_ns"]
opaque overheadNs : BaseIO Float

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

namespace Leanprof

/-- `file:line` of a declaration as the report shows it, from the `.ilean`
files under `LEANPROF_ILEAN_DIR` (default `.lake/build/lib/lean`), or `""`. -/
@[extern "leanprof_where"]
opaque whereIs (decl : @& String) : BaseIO String

end Leanprof

namespace Leanprof

/-- Resolve `whereIs` against another binary's symbols (its module
initializers say which modules it links), instead of this process's. -/
@[extern "leanprof_set_symbols"]
opaque setSymbols (names : @& Array String) : BaseIO Unit

end Leanprof

namespace Leanprof

/-- Allocations made by compiled Lean code so far, on all threads. Counted
only in builds with `allocFlags` (or `LEANPROF_ALLOCS=1` through the
wrapper); otherwise 0. -/
@[extern "leanprof_allocs"]
opaque allocs : BaseIO Nat

/-- Run `x` and fail if it made more than `n` allocations. -/
def expectAllocsAtMost (n : Nat) (x : IO α) : IO α := do
  let before ← allocs
  let r ← x
  let made := (← allocs) - before
  if made > n then throw <| IO.userError s!"leanprof: expected at most {n} allocations, got {made}"
  return r

end Leanprof

namespace Leanprof

/-! Frees and memory (see `docs/guide/memory.md`). -/

/-- Objects freed so far by cascades started in compiled Lean code, on all
threads. Counted only in builds with `freeFlags` (or `LEANPROF_FREES=1`
through the wrapper); otherwise 0. -/
@[extern "leanprof_frees"]
opaque frees : BaseIO Nat

/-- The most memory Lean's allocator (mimalloc) has had committed so far, in
bytes. Takes a sample, so it also updates the timeline's memory track. -/
@[extern "leanprof_peak_memory"]
opaque peakMemory : BaseIO Nat

end Leanprof
