import Lean

/-!
# `leanprof-elab-driver`: Lean's frontend in-process, with exact source ranges

`leanprof elab` runs this instead of `lean --json` when the project's Lean is the
one leanprof was built with. It elaborates one file as `lean` (and `lake`)
would: the module's setup file (options, imports, plugins, shared libraries),
`LEAN_PATH` for imports, asynchronous elaboration, the kernel. Two things differ:

* every term and tactic elaborator (and every macro) is wrapped, in this process
  only, so that each elaboration is timed against the exact source range of the
  syntax it elaborates: a trace node `[Leanprof.term]` or `[Leanprof.tactic]`
  whose text is `@line:col-line:col kind | source`. Lean's own `trace.profiler`
  keeps only the positions of whole commands;
* the traces are kept in memory (`trace.profiler.output`) and printed afterwards
  in the format `lean --json` uses, one message per trace, formatting only the
  descriptions `leanprof elab` reads (and those with `pp` limits).

`--compact` keeps `trace.profiler` on outside the wrapped elaborators (commands,
kernel, compiler, linters) and turns it off inside them: per command, term and
tactic timings, without the internal operations under them (`isDefEq`, `whnf`,
instances), which are what make a full profile slow.

The approach (wrapping the elaborator tables of the environment, retaining the
traces) is the one lean-source-profiler takes (MIT); the code here is written
for leanprof's report format.

Output: Lean's messages as `lean --json` prints them, then the traces. Exit code
3: the imports could not be loaded (leanprof then falls back to `lean`).
-/

open Lean Elab

namespace Leanprof.ElabDriver

/-- Set (in compact mode) where `trace.profiler` is off but source nodes are still recorded. -/
def compactOpt : Name := `leanprof.compact

/-- Terms and tactics that take longer than this are recorded (milliseconds, or heartbeats
with `trace.profiler.useHeartbeats`); 0, the default, records every one. -/
def termThresholdOpt : Name := `leanprof.termThreshold

/-- The trace classes of the source nodes. -/
def tacticCls : Name := `Leanprof.tactic
def termCls : Name := `Leanprof.term

@[extern "lean_internal_get_believer_trust_level"]
opaque believerTrustLevel (_ : Unit) : UInt32

/-- Run `k` and record it as a trace node of class `cls` carrying `stx`'s range (in its
`tag`: start and end byte, and the syntax kind), every time (or, with
`leanprof.termThreshold`, when it takes longer than that). In compact mode `k` runs with
`trace.profiler` off.
Generated syntax without a source range is not recorded: its time stays in the
node around it. -/
@[inline] def withSource {m : Type → Type} {α : Type} [Monad m] [MonadTrace m] [MonadOptions m]
    [MonadWithOptions m] [MonadRef m] [MonadLiftT BaseIO m] [always : MonadAlwaysExcept Exception m]
    [ExceptToTraceResult Exception α] (cls : Name) (stx : Syntax) (k : m α) : m α := do
  let opts ← getOptions
  let compact := opts.getBool compactOpt
  unless compact || trace.profiler.get opts do return ← k
  let some s := stx.getPos? (canonicalOnly := true) | return ← k
  let some e := stx.getTailPos? (canonicalOnly := true) | return ← k
  let hb := trace.profiler.useHeartbeats.get opts
  let _ := always.except
  let old ← getTraces
  modifyTraces fun _ => {}
  let start ← if hb then pure (← IO.getNumHeartbeats).toFloat else pure ((← IO.monoNanosNow).toFloat / 1e9)
  let res ← observing (if compact && trace.profiler.get opts then
    withOptions (·.setBool `trace.profiler false) k else k)
  let stop ← if hb then pure (← IO.getNumHeartbeats).toFloat else pure ((← IO.monoNanosNow).toFloat / 1e9)
  let th : Nat := opts.get termThresholdOpt 0
  if th == 0 || stop - start > (if hb then th.toFloat else th.toFloat / 1000) then
    let data : TraceData := { cls, startTime := start, stopTime := stop, result? := some res.toTraceResult,
                              tag := s!"{s.byteIdx}:{e.byteIdx}:{stx.getKind}" }
    let children := (← getTraces).toArray.map (·.msg)
    modifyTraces fun _ => old.push { ref := stx, msg := .trace data .nil children }
  else
    modifyTraces (old ++ ·)
  MonadExcept.ofExcept res

def wrapTactic (t : Tactic.Tactic) : Tactic.Tactic := fun stx => withSource tacticCls stx (t stx)

def wrapTerm (t : Term.TermElab) : Term.TermElab := fun stx ty => withSource termCls stx (t stx ty)

/-- A macro's expansion, when it has no source range of its own, gets the range of the
syntax it expands: the elaboration of `decreasing_tactic` is then timed where it is written. -/
def wrapMacro (mac : Macro) : Macro := fun stx => do
  let out ← mac stx
  match stx.getPos? (canonicalOnly := true), stx.getTailPos? (canonicalOnly := true) with
  | some s, some e =>
    if (out.getPos? (canonicalOnly := true)).isNone then return out.setInfo (.synthetic s e (canonical := true))
    return out
  | _, _ => return out

/-- The environment with every term and tactic elaborator and every macro wrapped. -/
def instrument (env : Environment) : Environment :=
  let env := Tactic.tacticElabAttribute.ext.modifyState env fun s =>
    { s with table := s.table.fold (init := {}) fun t k es => t.insert k (es.map fun e => { e with value := wrapTactic e.value }) }
  let env := Term.termElabAttribute.ext.modifyState env fun s =>
    { s with table := s.table.fold (init := {}) fun t k es => t.insert k (es.map fun e => { e with value := wrapTerm e.value }) }
  macroAttribute.ext.modifyState env fun s =>
    { s with table := s.table.fold (init := {}) fun t k es => t.insert k (es.map fun e => { e with value := wrapMacro e.value }) }

/-! ## Printing traces as `lean --json` does -/

/-- Classes whose descriptions `leanprof elab` reads (see `keepsText` there). -/
def keepsText (cls : Name) : Bool :=
  let c := cls.toString
  c == "Meta.synthInstance" || c == "Meta.isDefEq" || c == "Meta.whnf" || c == "Meta.isDefEq.delta" ||
    c == "Elab.step" || c.startsWith "Meta.Tactic" || c == "Tactic.simp" || c == "Meta.synthInstance.apply" ||
    c.startsWith "Meta.isDefEq.delta.unfold" || c.startsWith "Elab.async"

/-- Untimed messages that are part of the report (they name a constant). -/
def leafClass (cls : Name) : Bool :=
  cls.toString.startsWith "Meta.isDefEq.delta.unfold" || cls == `Meta.Tactic.simp.rewrite

/-- `msg` with its contexts' pretty-printing bounded: a description is cut to 200
characters anyway, and printing large terms in full is what made traces slow. -/
partial def bounded (fullNames : Bool) : MessageData → MessageData
  | .withContext ctx m =>
    let opts := ctx.opts.set `pp.maxSteps (400 : Nat) |>.set `pp.deepTerms.threshold (8 : Nat)
      |>.setBool `pp.deepTerms false |>.setBool `pp.proofs false |>.setBool `pp.fullNames fullNames
    .withContext { ctx with opts } (bounded fullNames m)
  | .withNamingContext n m => .withNamingContext n (bounded fullNames m)
  | .compose a b => .compose (bounded fullNames a) (bounded fullNames b)
  | .nest n m => .nest n (bounded fullNames m)
  | .group m => .group (bounded fullNames m)
  | .tagged t m => .tagged t (bounded fullNames m)
  | m => m

/-- A description on one line: its lines without their indentation, joined, at most 200 characters. -/
def oneLine (s : String) : String :=
  let parts := (s.splitOn "\n").filterMap fun l =>
    let t := l.trimAscii.toString
    if t.isEmpty then none else some t
  String.ofList ((" ".intercalate parts).toList.take 200)

def describe (fullNames : Bool) (m : MessageData) : IO String := do
  try return oneLine ((← (bounded fullNames m).format).pretty 200)
  catch _ => return ""

/-- Seconds with nine decimals, or heartbeats. -/
def fmtAmount (hb : Bool) (x : Float) : String :=
  let x := if x < 0 then 0 else x
  if hb then toString x.round.toUInt64.toNat
  else
    let ns := (x * 1e9).round.toUInt64.toNat
    let f := toString (ns % 1000000000)
    s!"{ns / 1000000000}.{String.ofList (List.replicate (9 - f.length) '0')}{f}"

structure Ctx where
  fm : FileMap
  src : String
  hb : Bool
  fullNames : Bool
  /-- Describe only commands and source nodes: a compact profile reads nothing else. -/
  compact : Bool
  /-- When the driver started (seconds, the clock of the traces): each timed node is printed
  with its start relative to it, for the timeline. Not with heartbeats. -/
  t0 : Float := 0

/-- The source between two byte positions on one line, at most 100 characters. -/
def excerpt (src : String) (s e : Nat) : String :=
  let t := String.Pos.Raw.extract src ⟨s⟩ ⟨e⟩
  let ws := (t.split Char.isWhitespace).filter (!·.isEmpty) |>.map (·.toString)
  String.ofList ((" ".intercalate ws.toList).toList.take 100)

/-- A source node's description: `@line:col-line:col kind | source` (columns from 1). -/
def rangeText (c : Ctx) (tag : String) : String :=
  match tag.splitOn ":" with
  | s :: e :: kind =>
    let s := s.toNat!
    let e := e.toNat!
    let p := c.fm.toPosition ⟨s⟩
    let q := c.fm.toPosition ⟨e⟩
    s!"@{p.line}:{p.column + 1}-{q.line}:{q.column + 1} {":".intercalate kind} | {excerpt c.src s e}"
  | _ => ""

/-- One trace tree as the lines `lean --json` prints: `[Class] [amount] mark text`,
indented by depth. Untimed nodes other than those that name a constant are left
out, their children kept at their depth. `wrap` puts a description back in the
contexts (environment, local context, names) around it, which it is printed in. -/
partial def render (c : Ctx) (root : Option String) (depth : Nat) (wrap : MessageData → MessageData)
    (out : Array String) : MessageData → IO (Array String)
  | .withContext ctx m => render c root depth (fun x => wrap (.withContext ctx x)) out m
  | .withNamingContext n m => render c root depth (fun x => wrap (.withNamingContext n x)) out m
  | .nest _ m | .group m | .tagged _ m => render c root depth wrap out m
  | .compose a b => do render c root depth wrap (← render c root depth wrap out a) b
  | .trace data body children => do
    let mut out := out
    let indent := String.ofList (List.replicate (2 * depth) ' ')
    let timed := data.startTime != 0 || data.stopTime != 0
    if !timed then
      if leafClass data.cls then
        out := out.push s!"{indent}[{data.cls}] {← describe c.fullNames (wrap body)}"
      for ch in children do out ← render c none depth wrap out ch
      return out
    let text ←
      if data.cls == tacticCls || data.cls == termCls then pure (rangeText c data.tag)
      else if let some r := root then pure r
      else if depth == 0 || (!c.compact && keepsText data.cls) then describe c.fullNames (wrap body)
      else pure ""
    let mark := (data.result?.getD .success).toEmoji
    -- `[amount@start]`: `lean --json` prints the amount only
    let at_ := if c.hb then "" else "@" ++ fmtAmount false (data.startTime - c.t0)
    out := out.push s!"{indent}[{data.cls}] [{fmtAmount c.hb (data.stopTime - data.startTime)}{at_}] {mark} {text}"
    for ch in children do out ← render c none (depth + 1) wrap out ch
    return out
  | _ => return out

/-- Print `lines` as a `lean --json` message at `pos`, with the thread that ran it. -/
def emit (c : Ctx) (pos : String.Pos.Raw) (tid : UInt64) (lines : Array String) : IO Unit := do
  let p := c.fm.toPosition pos
  IO.println (Json.mkObj [("severity", "information"),
    ("pos", Json.mkObj [("line", p.line), ("column", p.column)]), ("tid", toJson tid.toNat),
    ("data", Json.str ("\n".intercalate lines.toList))]).compress

/-- Print one retained trace as a `lean --json` message at `pos`. -/
def emitTrace (c : Ctx) (pos : String.Pos.Raw) (tid : UInt64) (t : TraceElem) : IO Unit := do
  -- a command is described by its source text (what `lean` prints is its syntax, formatted)
  let root := match t.ref.getPos?, t.ref.getTailPos? with
    | some s, some e => if s < e then some (oneLine (String.Pos.Raw.extract c.src s e)) else none
    | _, _ => none
  let isCommand := match t.msg with
    | .withContext _ (.trace d _ _) | .trace d _ _ => d.cls == `Elab.command
    | _ => false
  let lines ← render c (if isCommand then root else none) 0 id #[] t.msg
  unless lines.isEmpty do emit c pos tid lines

/-! ## Running the frontend -/

structure Args where
  compact : Bool := false
  heartbeats : Bool := false
  threshold : Nat := 1
  /-- Terms and tactics under this are not recorded on their own; 0: all of them. -/
  termThreshold : Nat := 0
  defs : Bool := false
  counts : Bool := false
  setup : Option String := none
  file : String := ""

partial def parseArgs (a : Args) : List String → Except String Args
  | [] => if a.file.isEmpty then .error "no file" else .ok a
  | "--compact" :: r => parseArgs { a with compact := true } r
  | "--heartbeats" :: r => parseArgs { a with heartbeats := true } r
  | "--defs" :: r => parseArgs { a with defs := true } r
  | "--counts" :: r => parseArgs { a with counts := true } r
  | "--threshold" :: v :: r => parseArgs { a with threshold := v.toNat! } r
  | "--term-threshold" :: v :: r => parseArgs { a with termThreshold := v.toNat! } r
  | "--setup" :: f :: r => parseArgs { a with setup := some f } r
  | f :: r => if f.startsWith "--" then .error s!"unknown option {f}" else parseArgs { a with file := f } r

def printMessages (log : MessageLog) : IO Unit := do
  for m in log.unreported do
    unless m.isSilent do IO.println (← m.toJson).compress

partial def lastCmd (s : Language.Lean.CommandParsedSnapshot) : Language.Lean.CommandParsedSnapshot :=
  match s.nextCmdSnap? with
  | some n => lastCmd n.get
  | none => s

def run (a : Args) : IO UInt32 := do
  let t0 ← IO.monoNanosNow
  initSearchPath (← findSysroot)
  unsafe enableInitializersExecution
  let input ← IO.FS.readFile a.file
  let inputCtx := Parser.mkInputContext input a.file
  let setup? ← a.setup.mapM ModuleSetup.load
  let mainModule ← match setup? with
    | some s => pure s.name
    | none => try moduleNameOfFileName a.file none catch _ => pure `_stdin
  -- what `lean -D...` sets for `leanprof elab`
  let mut opts : Options := {}
  opts := opts.setBool `trace.profiler true |>.set `trace.profiler.threshold (a.threshold : Nat)
    |>.set `trace.profiler.output ("leanprof" : String)  -- keep the traces; nothing is written
    -- every command, even under the threshold: kernel and compiler work is named after it
    |>.setBool `trace.Elab.command true
  if a.heartbeats then opts := opts.setBool `trace.profiler.useHeartbeats true
  if !a.compact && a.defs then
    for c in [`Meta.isDefEq.delta.unfoldLeft, `Meta.isDefEq.delta.unfoldRight,
              `Meta.isDefEq.delta.unfoldLeftRight, `Meta.Tactic.simp.rewrite] do
      opts := opts.setBool (`trace ++ c) true
    if a.counts then opts := opts.setBool `diagnostics true |>.set `diagnostics.threshold (0 : Nat)
  if let some s := setup? then opts := opts.mergeBy (fun _ _ v => v) s.options.toOptions
  opts := Elab.async.setIfNotSet opts true
  opts := Lean.internal.cmdlineSnapshots.setIfNotSet opts true
  if let some s := setup? then s.dynlibs.forM Lean.loadDynlib
  let (header, parserState, msgs) ← Parser.parseHeader inputCtx
  let header : HeaderSyntax := header
  let (env, msgs) ← processHeaderCore header.startPos (setup?.bind (·.imports?) |>.getD header.imports)
    (setup?.any (·.isModule) || header.isModule) opts msgs inputCtx (trustLevel := believerTrustLevel () + 1)
    (plugins := setup?.map (·.plugins) |>.getD #[]) (leakEnv := true) (mainModule := mainModule)
    (package? := setup?.bind (·.package?)) (arts := setup?.map (·.importArts) |>.getD {})
    (headerStx? := some header)
  printMessages msgs
  if msgs.hasErrors then return 3
  let tImported ← IO.monoNanosNow
  let mut opts' ← Language.Lean.reparseOptions opts
  -- not a registered option: set after Lean checks them
  if a.compact then opts' := opts'.setBool compactOpt true
  if a.termThreshold > 0 then opts' := opts'.set termThresholdOpt a.termThreshold
  let cmdState := Command.mkState (instrument env) {} opts'
  let cmdState := { cmdState with infoState.enabled := true }
  let first ← Language.Lean.processCommands inputCtx parserState cmdState
  let c : Ctx := { fm := inputCtx.fileMap, src := input, hb := a.heartbeats, fullNames := a.defs, compact := a.compact,
                   t0 := t0.toFloat / 1e9 }
  -- messages and traces of each snapshot as it completes, in order
  let lastPos ← IO.mkRef (0 : String.Pos.Raw)
  let errors ← IO.mkRef false
  (Language.toSnapshotTree first.get).forM (m := IO) fun snap => do
    if snap.diagnostics.msgLog.hasErrors then errors.set true
    printMessages snap.diagnostics.msgLog
    for t in snap.traces.traces do
      let pos ← match t.ref.getPos? with
        | some p => lastPos.set p; pure p
        | none => lastPos.get
      emitTrace c pos snap.traces.tid t
  -- the kernel's work on the last declarations
  let _ ← IO.wait (lastCmd first.get).elabSnap.resultSnap.get.cmdState.env.checked
  let tEnd ← IO.monoNanosNow
  -- what the report says about the run (not a message: no `severity`)
  IO.println (Json.mkObj [("leanprof", Json.mkObj [("lean_version", Json.str Lean.versionString),
    ("lean_githash", Json.str Lean.githash), ("imports_ns", toJson (tImported - t0)),
    ("elab_ns", toJson (tEnd - tImported)), ("term_threshold", toJson a.termThreshold)])]).compress
  return if ← errors.get then 1 else 0

/-! ## Where constants are declared

`leanprof elab` looks up the constants behind the work in the environment of the profiled
modules. It can only read `.olean` files of its own Lean; for a project on another Lean it
asks this driver, built with the project's Lean: `--locate REQUEST.json`, where the request
is `{"modules": [...], "names": [...]}`, prints `{"NAME": [module, line, unfoldable]}`. -/

/-- `Foo.bar`, `«a b».c`, `_private.M.0.f` as a `Name`. -/
def parseName (s : String) : Name := Id.run do
  let mut parts : Array String := #[]
  let mut cur := ""
  let mut inQuote := false
  for c in s.toList do
    if c == '«' then inQuote := true
    else if c == '»' then inQuote := false
    else if c == '.' && !inQuote then
      parts := parts.push cur
      cur := ""
    else cur := cur.push c
  parts := parts.push cur
  return parts.foldl (fun n p => match p.toNat? with
    | some k => if p.all Char.isDigit then .num n k else .str n p
    | none => .str n p) .anonymous

def lookup (env : Environment) (names : Array String) (out : Std.HashMap String Json) : Std.HashMap String Json := Id.run do
  let mut out := out
  for s in names do
    if out.contains s then continue
    let n := parseName s
    let ranges? := declRangeExt.find? (level := .server) env n <|> declRangeExt.find? env n <|>
      declRangeExt.find? (level := .server) env n.getPrefix
    let some ranges := ranges? | continue
    let some idx := env.getModuleIdxFor? n | continue
    let some mod := env.header.moduleNames[idx.toNat]? | continue
    let unfoldable := match env.find? n with
      | some (.defnInfo _) | some (.thmInfo _) | some (.opaqueInfo _) => true
      | _ => false
    out := out.insert s (Json.arr #[Json.str (String.ofList mod.toString.toList), toJson ranges.range.pos.line, Json.bool unfoldable])
  return out

def locate (request : String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile request))
  let strs (k : String) : Array String :=
    ((j.getObjVal? k >>= Json.getArr?).toOption.getD #[]).filterMap fun x => x.getStr?.toOption
  let names := strs "names"
  let mut built : Array Import := #[]
  for m in (strs "modules").toList.eraseDups do
    if (← (try some <$> findOLean (parseName m) catch _ => pure none)).isSome then
      built := built.push { module := parseName m }
  let mut out : Std.HashMap String Json := {}
  if !built.isEmpty then
    let joint ← try some <$> importModules built {} (loadExts := false) catch _ => pure none
    if let some env := joint then
      out := lookup env names out
    else
      -- modules that cannot be imported together: one at a time
      for m in built do
        if names.all out.contains then break
        try out ← unsafe withImportModules #[m] {} fun env => pure (lookup env names out)
        catch _ => pure ()
  IO.println (Json.mkObj (out.toList.map fun (k, v) => (k, v))).compress
  return 0

end Leanprof.ElabDriver

def main (args : List String) : IO UInt32 := do
  if args == ["--githash"] then
    IO.println Lean.githash
    return 0
  if let ["--locate", request] := args then
    return ← Leanprof.ElabDriver.locate request
  match Leanprof.ElabDriver.parseArgs {} args with
  | .error e =>
    IO.eprintln s!"leanprof-elab-driver: {e}\nusage: leanprof-elab-driver [--compact] [--heartbeats] [--defs] [--counts] [--threshold N] [--term-threshold N] [--setup FILE] FILE.lean"
    return 2
  | .ok a => Leanprof.ElabDriver.run a
