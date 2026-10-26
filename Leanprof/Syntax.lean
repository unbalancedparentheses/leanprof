module

public import Leanprof.Core
public meta import Lean.Elab.Term

/-!
# `profile!`

`profile! "name" e` times `e`, and records where the annotation is. For a monadic `e` (any monad with
`MonadFinally` and a `BaseIO` lift, such as `IO` or `StateT σ IO`) it times
running the action; otherwise it times evaluating the pure value.

With `set_option leanprof.enabled false` it elaborates to plain `e`, so
annotations cost nothing in builds without profiling.
-/

public meta section
namespace Leanprof
open Lean Elab Term Meta

register_option leanprof.enabled : Bool := {
  defValue := true
  descr := "expand `profile!` to profiling code; when false it expands to the bare term"
}

/-- Is `type` an application `m α` for a monad `scopeM` supports? -/
def monadicHead? (type : Expr) : TermElabM (Option Expr) := do
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

/-- The runtime label: the name, then `\x1f` and the source position, which the
report shows in its `where` column. Lean before 4.31 writes the `\x1f` into the C
code as a hex escape, `\x1f`, which C reads on through the next hex digits (the
`E` of `Examples/`): there the position starts with `./`, which the runtime
drops. -/
def labelWithPos (name : String) (stx : Syntax) : TermElabM String := do
  let file := (← getMainModule).toString.replace "." "/" ++ ".lean"
  let some pos := stx.getPos? | return name
  let line := (← getFileMap).toPosition pos |>.line
  let hexEscape := Lean.version.major == 4 && Lean.version.minor < 31
  return s!"{name}\x1f{if hexEscape then "./" else ""}{file}:{line}"

/-- The `exitPure` variant for a value of type `type`: scalars keep their
unboxed representation. -/
def exitPureFor (type : Expr) : Name :=
  match type.constName? with
  | some ``UInt8 => ``Leanprof.exitPureUInt8
  | some ``Bool => ``Leanprof.exitPureBool
  | some ``UInt16 => ``Leanprof.exitPureUInt16
  | some ``UInt32 => ``Leanprof.exitPureUInt32
  | some ``Char => ``Leanprof.exitPureChar
  | some ``UInt64 => ``Leanprof.exitPureUInt64
  | some ``USize => ``Leanprof.exitPureUSize
  | some ``Float => ``Leanprof.exitPureFloat
  | some ``Float32 => ``Leanprof.exitPureFloat32
  | _ => ``Leanprof.exitPure

@[term_elab profileTerm] def elabProfile : TermElab := fun stx expected? => do
  let `(profile! $name:str $body) := stx | throwUnsupportedSyntax
  unless leanprof.enabled.get (← getOptions) do
    return ← elabTerm body expected?
  let label := Syntax.mkStrLit (← labelWithPos name.getString stx)
  let e ← elabTerm body expected?
  let type ← instantiateMVars (← inferType e)
  if (← monadicHead? type).isSome then
    elabTerm (← `(Leanprof.scopeM $label $(← exprToSyntax e))) expected?
  else
    -- no closure: `enterPure` before the term, `exitPure` after it (see Core)
    let exit := mkIdent (exitPureFor (← whnfR type))
    let fast ← `(let site := $label; let tok := Leanprof.enterPure site site; $exit tok $(← exprToSyntax e))
    try
      withoutErrToSorry <| elabTermEnsuringType fast type
    catch _ =>
      elabTerm (← `(Leanprof.scope $label fun _ => $(← exprToSyntax e))) expected?

end Leanprof
