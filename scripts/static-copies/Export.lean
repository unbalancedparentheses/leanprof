import Lean

/-! Read saved post-RC compiler IR. The target program is not executed.
Run in a built project's Lake environment with the module names to inspect. -/
open Lean
namespace Leanprof.StaticCopies

def obj := Json.mkObj

def arg : IR.Arg → Json
  | .var v => toJson v.idx
  | .erased => Json.null

def param (p : IR.Param) : Json := obj [
  ("id", toJson p.x.idx), ("borrowed", toJson p.borrow), ("type", toJson (toString (format p.ty)))]

def arguments (args : Array IR.Arg) : Json := toJson (args.map arg)

def expression (env : Environment) (e : IR.Expr) : Json :=
  let fields := match e with
    | .fap f ys =>
      let borrowed := (IR.findEnvDecl env f).map fun d => d.params.map (·.borrow)
      [("kind", toJson "call"), ("callee", toJson f.toString),
       ("args", arguments ys), ("borrowed", toJson borrowed)]
    | .ctor c ys => [("kind", toJson "constructor"), ("constructor", toJson c.name.toString), ("args", arguments ys)]
    | .reuse x c _ ys => [("kind", toJson "reuse"), ("receiver", toJson x.idx),
       ("constructor", toJson c.name.toString), ("args", arguments ys)]
    | .proj i x => [("kind", toJson "projection"), ("receiver", toJson x.idx), ("index", toJson i)]
    | .reset _ x => [("kind", toJson "reset"), ("receiver", toJson x.idx)]
    | .isShared x => [("kind", toJson "isShared"), ("receiver", toJson x.idx)]
    | .pap f ys => [("kind", toJson "closure"), ("callee", toJson f.toString), ("args", arguments ys)]
    | .ap x ys => [("kind", toJson "apply"), ("receiver", toJson x.idx), ("args", arguments ys)]
    | _ => [("kind", toJson "other")]
  obj <| fields ++ [("text", toJson (toString (format e)))]

abbrev ExportM := StateM (Array Json)

/-- A flat node table avoids deeply nested JSON and retains precise IR-site IDs. -/
partial def body (env : Environment) (b : IR.FnBody) : ExportM Nat := do
  let id := (← get).size
  modify (·.push Json.null)
  let fields ← match b with
    | .vdecl x ty e next => do
      let next ← body env next
      pure [("kind", toJson "let"), ("result", toJson x.idx), ("type", toJson (toString (format ty))),
        ("expression", expression env e), ("next", toJson next)]
    | .inc x n _ persistent next => do
      let next ← body env next
      pure [("kind", toJson "inc"), ("var", toJson x.idx), ("count", toJson n),
        ("persistent", toJson persistent), ("next", toJson next)]
    | .dec x n _ _ next => do
      let next ← body env next
      pure [("kind", toJson "dec"), ("var", toJson x.idx), ("count", toJson n), ("next", toJson next)]
    | .del x next => do
      let next ← body env next
      pure [("kind", toJson "delete"), ("var", toJson x.idx), ("next", toJson next)]
    | .set x i y next => do
      let next ← body env next
      pure [("kind", toJson "store"), ("holder", toJson x.idx), ("index", toJson i),
        ("value", arg y), ("next", toJson next)]
    | .jdecl j ps value next => do
      let entry ← body env value
      let next ← body env next
      pure [("kind", toJson "join"), ("join", toJson j.idx), ("params", toJson (ps.map param)),
        ("entry", toJson entry), ("next", toJson next)]
    | .jmp j ys => pure [("kind", toJson "jump"), ("join", toJson j.idx), ("args", arguments ys)]
    | .case _ x _ alts => do
      let targets ← alts.mapM fun a => do
        let entry ← body env a.body
        let label := match a with | .ctor c _ => c.name.toString | .default _ => "default"
        return obj [("label", toJson label), ("entry", toJson entry)]
      pure [("kind", toJson "case"), ("var", toJson x.idx), ("alternatives", toJson targets)]
    | .ret x => pure [("kind", toJson "return"), ("value", arg x)]
    | .unreachable => pure [("kind", toJson "unreachable")]
    | _ => do
      let next ← body env b.body
      pure [("kind", toJson "scalar-store"), ("next", toJson next)]
  modify (·.set! id (obj <| ("id", toJson id) :: fields))
  return id

partial def source (env : Environment) (m n : Name) : Json :=
  let ranges := declRangeExt.find? (level := .private) env n <|> declRangeExt.find? (level := .server) env n
  match ranges with
  | some r => obj [("declaration", toJson n.toString), ("module", toJson m.toString),
      ("line", toJson r.selectionRange.pos.line), ("column", toJson r.selectionRange.pos.column),
      ("precision", toJson "declaration")]
  | none => if n.isAnonymous then Json.null else source env m n.getPrefix

def decl (env : Environment) (m : Name) (d : IR.Decl) : Json :=
  match d with
  | .extern .. => obj [("name", toJson d.name.toString), ("external", toJson true)]
  | .fdecl name ps _ b _ =>
    let (entry, nodes) := (body env b).run #[]
    let original := match (name.toString.splitOn "._at_.").getLast? with
      | some s => (s.splitOn ".spec_").head!.toName
      | none => name
    obj [("name", toJson name.toString), ("external", toJson false),
      ("source", source env m original), ("params", toJson (ps.map param)),
      ("entry", toJson entry), ("nodes", toJson nodes)]

def exportModules (names : Array Name) : IO Json := do
  initSearchPath (← findSysroot)
  unsafe enableInitializersExecution
  let env ← importModules (names.map fun m => { module := m, importAll := true, isMeta := true }) {} (loadExts := true)
  let mut modules := #[]
  for m in names do
    let some idx := env.getModuleIdx? m | throw <| IO.userError s!"module not imported: {m}"
    let ir := IR.declMapExt.getModuleIREntries env idx
    let ds := if ir.isEmpty then IR.declMapExt.getModuleEntries env idx else ir
    let ds := ds.qsort fun a b => Name.lt a.name b.name
    modules := modules.push <| obj [("module", toJson m.toString),
      ("declarations", toJson (ds.map (decl env m))),
      ("bodies", toJson (ds.filter (!·.isExtern)).size)]
  return obj [("schema", toJson (1 : Nat)), ("representation", toJson "Lean.IR.post-RC"),
    ("leanVersion", toJson Lean.versionString), ("leanGithash", toJson Lean.githash),
    ("modules", toJson modules)]

end Leanprof.StaticCopies

def main (args : List String) : IO UInt32 := do
  if args.isEmpty then
    IO.eprintln "usage: lake env lean --run Export.lean MODULE..."
    return 2
  try
    IO.println (← Leanprof.StaticCopies.exportModules (args.toArray.map String.toName)).compress
    return 0
  catch e =>
    IO.eprintln s!"static-copy IR export failed: {e}"
    return 2
