import Lean.Elab.Term
import Leanprof.Core

/-!
# `profile!`

`profile! "label" e` times `e`. For a monadic `e` (any monad with
`MonadFinally` and a `BaseIO` lift, such as `IO` or `StateT σ IO`) it times
running the action; otherwise it times evaluating the pure value.

With `set_option leanprof.enabled false` it elaborates to plain `e`, so
annotations cost nothing in builds without profiling.
-/

namespace Leanprof
open Lean Elab Term Meta

register_option leanprof.enabled : Bool := {
  defValue := true
  descr := "expand `profile!` to profiling code; when false it expands to the bare term"
}

/-- Is `type` an application `m α` for a monad `scopeM` supports? -/
private def monadicHead? (type : Expr) : TermElabM (Option Expr) := do
  let type ← whnfR type
  let .app m _ := type | return none
  let ok (cls : Name) (args : Array Expr) : TermElabM Bool := do
    try
      let inst ← mkAppM cls args
      return (← trySynthInstance inst) matches .some _
    catch _ => return false
  if (← ok ``Monad #[m]) && (← ok ``MonadFinally #[m]) && (← ok ``MonadLiftT #[mkConst ``BaseIO, m]) then
    return some m
  return none

syntax (name := profileTerm) "profile! " str ppSpace term : term

@[term_elab profileTerm] def elabProfile : TermElab := fun stx expected? => do
  let `(profile! $label:str $body) := stx | throwUnsupportedSyntax
  unless leanprof.enabled.get (← getOptions) do
    return ← elabTerm body expected?
  let e ← elabTerm body expected?
  let type ← instantiateMVars (← inferType e)
  if (← monadicHead? type).isSome then
    elabTerm (← `(Leanprof.scopeM $label $(← exprToSyntax e))) expected?
  else
    elabTerm (← `(Leanprof.scope $label fun _ => $(← exprToSyntax e))) expected?

end Leanprof
