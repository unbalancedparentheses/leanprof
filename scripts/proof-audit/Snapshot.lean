import Lean

/-! Standalone declaration evidence collector. Run with the target project's
`lake env lean --run .../Snapshot.lean MODULE...` after building those modules.
No changes to leanprof's CLI or the target project's sources are needed. -/
open Lean

namespace Leanprof.ProofAudit

/-- Binder spelling and source metadata do not change a proposition. Everything
else is retained; this is structural evidence, not pretty-printed source. -/
partial def canonical : Expr → Expr
  | .mdata _ e => canonical e
  | .app f a => .app (canonical f) (canonical a)
  | .lam _ t b bi => .lam .anonymous (canonical t) (canonical b) bi
  | .forallE _ t b bi => .forallE .anonymous (canonical t) (canonical b) bi
  | .letE _ t v b nd => .letE .anonymous (canonical t) (canonical v) (canonical b) nd
  | .proj n i e => .proj n i (canonical e)
  | e => e

def exprText (e : Expr) : String := reprStr (canonical e)

def kind : ConstantInfo → String
  | .axiomInfo _ => "axiom"
  | .defnInfo _ => "definition"
  | .thmInfo _ => "theorem"
  | .opaqueInfo _ => "opaque"
  | .quotInfo _ => "quotient"
  | .inductInfo _ => "inductive"
  | .ctorInfo _ => "constructor"
  | .recInfo _ => "recursor"

/-- Reduction-relevant metadata, including constructor and recursor rules. -/
def extra : ConstantInfo → String
  | .defnInfo v => reprStr v.safety
  | .inductInfo v => reprStr (v.numParams, v.numIndices, v.all, v.ctors,
      v.numNested, v.isRec, v.isReflexive)
  | .ctorInfo v => reprStr (v.induct, v.cidx, v.numParams, v.numFields)
  | .recInfo v => reprStr (v.all, v.numParams, v.numIndices, v.numMotives,
      v.numMinors, v.k, v.rules.map fun r => (r.ctor, r.nfields, exprText r.rhs))
  | .quotInfo v => match v.kind with
    | .type => "type" | .ctor => "ctor" | .lift => "lift" | .ind => "ind"
  | _ => ""

def externText (env : Environment) (n : Name) : Option String :=
  (getExternAttrData? env n).map fun d => reprStr <| d.entries.map fun e =>
    match e with
    | .adhoc b => ("adhoc", b, "")
    | .inline b p => ("inline", b, p)
    | .standard b f => ("standard", b, f)
    | .opaque => ("opaque", Name.anonymous, "")

structure Escape where
  implementedBy : Option String
  extern : Option String
  isUnsafe : Bool
  isPartial : Bool
  deriving ToJson

def escape (env : Environment) (ci : ConstantInfo) : Escape := {
  implementedBy := (Compiler.getImplementedBy? env ci.name).map Name.toString
  extern := externText env ci.name
  isUnsafe := ci.isUnsafe
  isPartial := ci.isPartial
}

/-- Dependencies needed to interpret a declaration's type/definition. Proof
bodies are deliberately excluded: proof changes are checked by axiom sets. -/
def dependencies (ci : ConstantInfo) : Array Name := Id.run do
  let mut ns := ci.type.getUsedConstants
  if let some v := (if kind ci == "theorem" then none else ci.value? true) then ns := ns ++ v.getUsedConstants
  match ci with
  | .inductInfo v => ns := ns ++ v.all.toArray ++ v.ctors.toArray
  | .ctorInfo v => ns := ns.push v.induct
  | .recInfo v =>
    ns := ns ++ v.all.toArray
    for r in v.rules do ns := ns.push r.ctor ++ r.rhs.getUsedConstants
  | _ => pure ()
  return ns

structure Declaration where
  name : String
  kind : String
  type : String
  levels : String
  value : Option String
  extra : String
  isUnsafe : Bool
  isPartial : Bool
  implementedBy : Option String
  extern : Option String
  dependencies : Array String
  axioms : Array String
  deriving ToJson

def record (env : Environment) (ci : ConstantInfo) : CoreM Declaration := do
  return {
    name := ci.name.toString, kind := kind ci, type := exprText ci.type
    levels := reprStr ci.levelParams
    value := (if kind ci == "theorem" then none else ci.value? true).map exprText, extra := extra ci
    isUnsafe := ci.isUnsafe, isPartial := ci.isPartial
    implementedBy := (Compiler.getImplementedBy? env ci.name).map Name.toString
    extern := externText env ci.name
    dependencies := (dependencies ci).map Name.toString
    axioms := (← collectAxioms ci.name).map Name.toString
  }

def snapshot (modules : Array Name) : IO Json := do
  initSearchPath (← findSysroot)
  unsafe enableInitializersExecution
  let env ← importModules (modules.map fun n => { module := n }) {} (loadExts := true)
  let mut roots : Array Name := #[]
  let mut escapes : List (String × Json) := []
  for (n, ci) in env.constants.toList do
    let e := escape env ci
    if e.implementedBy.isSome || e.extern.isSome || e.isUnsafe || e.isPartial then
      escapes := (n.toString, toJson e) :: escapes
    if let some idx := env.getModuleIdxFor? n then
      if modules.contains env.header.moduleNames[idx]! then roots := roots.push n
  roots := roots.qsort Name.lt
  let action : CoreM Json := do
    let mut pending := roots
    let mut seen : NameSet := {}
    let mut declarations : Array Declaration := #[]
    while !pending.isEmpty do
      let n := pending.back!
      pending := pending.pop
      if seen.contains n then continue
      seen := seen.insert n
      let some ci := env.find? n | throwError "missing dependency {n}"
      let d ← record env ci
      declarations := declarations.push d
      pending := pending ++ dependencies ci
      -- Axioms' types must be preserved too, not just their names.
      pending := pending ++ (← collectAxioms n)
    return Json.mkObj [
      ("schema", toJson (1 : Nat)), ("leanVersion", toJson Lean.versionString),
      ("leanGithash", toJson Lean.githash),
      ("modules", toJson (modules.map Name.toString)),
      ("roots", toJson (roots.map Name.toString)),
      ("runtimeEscapes", Json.mkObj escapes),
      ("declarations", toJson (declarations.qsort fun a b => a.name < b.name))]
  let (j, _) ← action.toIO { fileName := "<proof-audit>", fileMap := default, maxRecDepth := 10000 } { env }
  return j

end Leanprof.ProofAudit

def main (args : List String) : IO UInt32 := do
  if args.isEmpty then
    IO.eprintln "usage: lake env lean --run Snapshot.lean MODULE..."
    return 2
  try
    let j ← Leanprof.ProofAudit.snapshot (args.toArray.map String.toName)
    IO.println j.compress
    return 0
  catch e =>
    IO.eprintln s!"proof audit snapshot failed: {e}"
    return 2
