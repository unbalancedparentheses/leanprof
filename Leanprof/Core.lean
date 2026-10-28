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

/-! What `profile!` compiles a pure term to:
`let s := site; let t := enterPure s s; exitPure t e`. No closure is built
and nothing is boxed (a pure `scope` allocates a closure, and boxes a scalar
result such as a `UInt64`, inside the timed region). Scalar results pass
through a variant that takes and returns them unboxed.

The compiler must not move `enterPure` past the term. `never_extract` keeps
it from merging two `enter`s of one label or hoisting them as constants, and
the token makes `exit` depend on `enter`. But `floatLetIn` moves a `let` into
the one branch that uses it, and `exit` sits after the term's last branch
(even a structure projection is one): a plain token was moved there, so the
term ran before its scope opened. It never moves a `let` that uses a variable
already passed as an owned argument, so `enterPure` takes the label twice,
first owned and then borrowed. The tests check that the work stays inside. -/

/-- Open a scope for a pure term (see above); `site` and `key` are the same
label. -/
@[extern "leanprof_enter_pure", never_extract]
def enterPure (site : String) (key : @& String) : UInt64 := let _ := site; let _ := key; 0

/-- Close the scope `enterPure` opened, passing the term's value through. -/
@[extern "leanprof_exit_pure", never_extract]
def exitPure {α : Sort u} (_tok : UInt64) (a : α) : α := a

@[extern "leanprof_exit_pure_u8", never_extract, inherit_doc exitPure]
def exitPureUInt8 (_tok : UInt64) (a : UInt8) : UInt8 := a
@[extern "leanprof_exit_pure_u8", never_extract, inherit_doc exitPure]
def exitPureBool (_tok : UInt64) (a : Bool) : Bool := a
@[extern "leanprof_exit_pure_u16", never_extract, inherit_doc exitPure]
def exitPureUInt16 (_tok : UInt64) (a : UInt16) : UInt16 := a
@[extern "leanprof_exit_pure_u32", never_extract, inherit_doc exitPure]
def exitPureUInt32 (_tok : UInt64) (a : UInt32) : UInt32 := a
@[extern "leanprof_exit_pure_u32", never_extract, inherit_doc exitPure]
def exitPureChar (_tok : UInt64) (a : Char) : Char := a
@[extern "leanprof_exit_pure_u64", never_extract, inherit_doc exitPure]
def exitPureUInt64 (_tok : UInt64) (a : UInt64) : UInt64 := a
@[extern "leanprof_exit_pure_usize", never_extract, inherit_doc exitPure]
def exitPureUSize (_tok : UInt64) (a : USize) : USize := a
@[extern "leanprof_exit_pure_f64", never_extract, inherit_doc exitPure]
def exitPureFloat (_tok : UInt64) (a : Float) : Float := a
@[extern "leanprof_exit_pure_f32", never_extract, inherit_doc exitPure]
def exitPureFloat32 (_tok : UInt64) (a : Float32) : Float32 := a

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

/-- The calls of `site` that were timed. A scope too small to time (its
probes cost about as much as its calls) is timed on about one call in 64
after its first 1,024, and only counted otherwise; its times are the timed
calls' scaled up to all of them. -/
@[extern "leanprof_timed_calls"]
opaque timedCalls (site : @& String) : BaseIO Nat

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

/-- Whether copy detection works in this build: runs a known copy of each
kind (`Array.push`, `String.push`, ...) through the copy flags once and
returns a warning naming the kinds whose copies were not counted, or `""`.
The same check runs at exit; its copies never appear in the report. -/
@[extern "leanprof_self_check"]
opaque selfCheck : BaseIO String

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

/-- Also resolve `whereIs` for Lean's own declarations (`Lean.*`, `Lake.*`,
...) from the toolchain at this prefix (`lean --print-prefix`): its
`lib/lean/*.ilean` files and `src/lean` sources. -/
@[extern "leanprof_set_core_dir"]
opaque setCoreDir (dir : @& String) : BaseIO Unit

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

/-- With retained memory on (`leanprof run --retained`): walk the heap now
and keep the result for the report, as the walks at the peak and at exit
are (the first 8 are kept). A server can call it at a moment worth seeing,
a test at a moment it knows. Does nothing when retained memory is off. -/
@[extern "leanprof_retained_snapshot"]
opaque retainedSnapshot : BaseIO Unit

/-- With retained memory on: bytes of the objects compiled code allocated
that are alive now (as far as leanprof has seen them freed); `none` when
retained memory is off. -/
@[extern "leanprof_retained_live"]
opaque retainedLive : BaseIO (Option Nat)

end Leanprof
