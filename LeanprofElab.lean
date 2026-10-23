import Lean.Data.Json
import Lean.Environment
import Lean.DeclarationRange
import Lean.Elab.ParseImportsFast
import Lean.Util.Path

/-!
# `leanprof elab`: compile cost per line, declaration, file and definition

Each file is elaborated by `lean --json` with `trace.profiler`, which attaches
to each source position a tree of timed operations printed as indented lines,
`[Class] [amount] mark text` (the amount is seconds, or heartbeats with
`trace.profiler.useHeartbeats`). On top of that leanprof turns on:

* `trace.Meta.isDefEq.delta.unfold{Left,Right,LeftRight}`: an untimed line
  naming the constant `isDefEq` unfolds, followed by the work that unfolding
  caused (the timed operations after it);
* `trace.Meta.Tactic.simp.rewrite`: an untimed line naming each simp lemma that
  rewrote, after the unification that tried it;
* `diagnostics` (with `--counts`; it nearly doubles elaboration time): exact per-command counts of the declarations `whnf` and
  `isDefEq` unfolded, the instances used, the declarations the kernel
  unfolded, and the simp lemmas used and tried;
* `pp.fullNames`, so `Meta.whnf` and `Meta.synthInstance.apply` lines name
  constants in full.

The constants are then looked up in the environment of the profiled modules
(their `.olean` files, through `LEAN_PATH`) for their own `file:line`.

`--project` profiles every built module of the current Lake package, several
files at a time, and aggregates across files.
-/

open Lean System

namespace Leanprof.Elab

/-! ## Formatting and JSON helpers -/

/-- `x` with two decimals. -/
def fmt2 (x : Float) : String :=
  let v := (x.abs * 100).round.toUInt64.toNat
  let frac := v % 100
  s!"{if x < 0 && v > 0 then "-" else ""}{v / 100}.{if frac < 10 then "0" else ""}{frac}"

def groupDigits (n : Nat) : String :=
  if n < 1000 then toString n
  else
    let r := toString (n % 1000)
    groupDigits (n / 1000) ++ "," ++ String.ofList (List.replicate (3 - r.length) '0') ++ r

def str (j : Json) (k : String) : String :=
  (j.getObjVal? k >>= Json.getStr?).toOption.getD ""

def pad (t : String) (w : Nat) : String := t.pushn ' ' (w - t.length)

/-! ## Trace trees -/

/-- One operation in a trace tree, or an untimed message inside one. -/
structure TNode where
  cls : String
  amount : Float           -- seconds or heartbeats, inclusive; 0 for an untimed message
  timed : Bool := true
  /-- The operation's description (its first line, then more up to 160
  characters); kept only where it is read (`keepsText`). -/
  text : String
  depth : Nat
  childSum : Float := 0    -- amounts of its direct children
  /-- The index after its subtree: its children are `i + 1`, then each
  child's `next`, up to this. -/
  next : Nat := 0
  parent : Option Nat := none
  deriving Inhabited

/-- Untimed messages that name a constant: `isDefEq` unfolding it, or simp
rewriting with it. Other untimed lines are continuations of a description. -/
def unfoldClasses : List String :=
  ["Meta.isDefEq.delta.unfoldLeft", "Meta.isDefEq.delta.unfoldRight", "Meta.isDefEq.delta.unfoldLeftRight"]

def leafClass (cls : String) : Bool :=
  unfoldClasses.contains cls || cls == "Meta.Tactic.simp.rewrite"

/-- `[Class] [amount] ...` (or an untimed `[Class] ...` of `leafClass`) at the
start of a trace line, with its indentation. -/
def traceLine (line : String) : Option (Nat × String × Option Float × String) := do
  let cs := line.toList
  let indent := (cs.takeWhile (· == ' ')).length
  let cs := cs.drop indent
  guard (cs.head? == some '[')
  let cls := (cs.drop 1).takeWhile (· != ']')
  let rest := ((cs.drop 1).drop (cls.length + 1)).dropWhile (· == ' ')
  let clsS := String.ofList cls
  if rest.head? != some '[' then
    guard (leafClass clsS)
    return (indent, clsS, none, String.ofList rest)
  let amt := (rest.drop 1).takeWhile (· != ']')
  let ip := amt.takeWhile (· != '.')
  let fp := (amt.dropWhile (· != '.')).drop 1
  match (String.ofList ip).toNat? with
  | none =>
    guard (leafClass clsS)
    return (indent, clsS, none, String.ofList rest)
  | some i =>
    let f := (String.ofList fp).toNat?.getD 0
    let text := ((rest.drop 1).drop (amt.length + 1)).dropWhile (· == ' ')
    -- the status mark (✅️, ❌️, 💥️: a symbol and a variation selector) that every timed
    -- operation has; without it, this is a continuation that happens to look like one
    -- (a description containing `[x] [6]`)
    let text ← match text with
      | _ :: '️' :: ' ' :: t => some t
      | _ => none
    return (indent, clsS, some (i.toFloat + f.toFloat / (10 : Float) ^ fp.length.toFloat), String.ofList text)

/-- Classes whose repeated identical operations are worth reporting. -/
def repeatable (cls : String) : Bool :=
  cls == "Meta.synthInstance" || cls == "Meta.isDefEq" || cls == "Meta.whnf" ||
    cls == "Meta.isDefEq.delta" || cls == "Elab.step" || cls.startsWith "Meta.Tactic" || cls == "Tactic.simp"

/-- Whether a node's description is ever read: those of repeated operations and
tactics (`repeatable`) and of nodes that name a constant (`attributedConst`),
besides the root's. The others are dropped as the trace is read: one
declaration's trace can be gigabytes. -/
def keepsText (cls : String) : Bool :=
  repeatable cls || unfoldClasses.contains cls || cls == "Meta.synthInstance.apply"

/-- A trace being read a line at a time: its nodes so far (index 0 is the
root), the open ones by indentation, and one copy of each class name, shared
by its nodes. -/
structure TraceBuilder where
  nodes : Array TNode := #[]
  stack : Array Nat := #[]
  classes : Std.HashMap String String := {}

/-- One line of a trace: a new node, or more of the last one's description. -/
def TraceBuilder.addLine (b : TraceBuilder) (line : String) : TraceBuilder := Id.run do
  let ⟨nodes, stack, classes⟩ := b
  let mut nodes := nodes
  let mut stack := stack
  let mut classes := classes
  match traceLine line with
  | some (indent, cls, amount, text) =>
    -- an untimed message before any timed root is not part of a tree
    if nodes.isEmpty && amount.isNone then return ⟨nodes, stack, classes⟩
    let i := nodes.size
    while !stack.isEmpty && nodes[stack.back!]!.depth >= indent do
      nodes := nodes.modify stack.back! fun n => { n with next := i }
      stack := stack.pop
    let parent := stack.back?
    let cls ← match classes.get? cls with
      | some c => pure c
      | none => do classes := classes.insert cls cls; pure cls
    let text := if i == 0 || keepsText cls then text else ""
    let x := amount.getD 0
    nodes := nodes.push { cls, amount := x, timed := amount.isSome, text, depth := indent, parent }
    if let some p := parent then
      nodes := nodes.modify p fun n => { n with childSum := n.childSum + x }
    stack := stack.push i
  | none =>
    -- continuation of a multi-line description: part of the operation
    if let some last := stack.back? then
      let n := nodes[last]!
      if (last == 0 || keepsText n.cls) && n.text.length < 160 then
        let t := String.ofList (line.toList.dropWhile (· == ' '))
        if !t.isEmpty then
          nodes := nodes.modify last fun n => { n with text := n.text ++ " " ++ t }
  return ⟨nodes, stack, classes⟩

/-- The nodes of a trace read to its end (every subtree closed). -/
def TraceBuilder.finish (b : TraceBuilder) : Array TNode := Id.run do
  let ⟨nodes, stack, _⟩ := b
  let mut nodes := nodes
  let n := nodes.size
  for i in stack do
    nodes := nodes.modify i fun x => { x with next := n }
  return nodes

/-- Parse one message's trace into nodes (index 0 is the root). -/
def parseTrace (data : String) : Array TNode :=
  ((data.splitOn "\n").foldl TraceBuilder.addLine {}).finish

/-- Merge operations that differ only in metavariable numbers (`?m.123`). -/
def normalizeOp (t : String) : String := Id.run do
  let mut out : List Char := []
  let mut cs := t.toList
  while !cs.isEmpty do
    match cs with
    | '?' :: rest =>
      let name := rest.takeWhile (fun c => c.isAlpha || c == '_')
      let after := rest.drop name.length
      if after.head? == some '.' && ((after.drop 1).head?.map Char.isDigit).getD false then
        out := out ++ '?' :: name ++ ['.', 'n']
        cs := (after.drop 1).dropWhile Char.isDigit
      else
        out := out ++ ['?']
        cs := rest
    | c :: rest =>
      out := out ++ [c]
      cs := rest
    | [] => break
  return String.ofList (out.take 120)

/-- A constant's name at the start of `s` (`Foo.bar`, `«odd name».x`,
`_private.M.0.f`), or none when `s` starts with notation, a variable with a
mark (`inst✝`) or a metavariable. -/
def leadingConst (s : String) : Option String := do
  let tok := (s.toList.dropWhile (· == '@')).takeWhile fun c => !(c == ' ' || c == '(' || c == ')' || c == ',' || c == ':' || c == '\n')
  let first ← tok.head?
  guard (first.isAlpha || first == '_' || first == '«')
  guard (!tok.contains '✝' && !tok.contains '?' && tok != ['_'])
  return String.ofList tok

/-- The constant a cost-attributing node names, with what it is:
`unfold` (isDefEq unfolded it), `simp` (simp rewrote with it), `instance`
(instance search tried it), `whnf` (an application of it was reduced). -/
def attributedConst (n : TNode) : Option (String × String) :=
  if unfoldClasses.contains n.cls then (leadingConst n.text).map (·, "unfold")
  else if n.cls == "Meta.Tactic.simp.rewrite" then
    let t := n.text
    if t.startsWith "unfold " then (leadingConst (t.drop 7).toString).map (·, "simp")
    else (leadingConst t).map (·, "simp")
  else if n.cls == "Meta.synthInstance.apply" && n.text.startsWith "apply " then
    (leadingConst (n.text.drop 6).toString).map (·, "instance")
  else if n.cls == "Meta.whnf" && n.text.startsWith "Non-easy whnf: " then
    (leadingConst (n.text.drop 15).toString).map (·, "whnf")
  else none

/-- Classes of the unification work just before a simp rewrite. -/
def simpWork (cls : String) : Bool :=
  cls == "Meta.isDefEq" || cls == "Meta.isLevelDefEq" || cls == "Meta.synthInstance" ||
    cls.startsWith "Meta.Tactic.simp.discharge"

/-- Every constant credited by one trace tree: (name, kind, cost) where the
cost is the work it caused. A constant nested inside work already credited to
itself is counted (`cost = none`) but not charged again, so costs of the same
constant never overlap; costs of different constants can (unfolding `f` can
unfold `g`). -/
partial def attributions (nodes : Array TNode) : Array (String × String × Option Float) := Id.run do
  if nodes.isEmpty then return #[]
  let mut out := #[]
  -- (node, constants already charged around it)
  let mut todo : Array (Nat × List String) := #[(0, [])]
  while !todo.isEmpty do
    let (i, active) := todo.back!
    todo := todo.pop
    let n := nodes[i]!
    let mut active := active
    if n.timed then
      if let some (c, k) := attributedConst n then
        out := out.push (c, k, if active.contains c then none else some n.amount)
        active := c :: active
    -- untimed children. `isDefEq` traces an unfold of `f` just before comparing the
    -- unfolded terms, a `Meta.isDefEq` right after it: that comparison is the unfold's
    -- cost. An unfold whose comparison was too cheap to record (under the threshold) has
    -- moved up to an ancestor: it is counted, at no cost. A simp rewrite is charged the
    -- unification just before it.
    let mut pending : Float := 0                   -- unification since the last simp step
    let mut unfolded : Option String := none       -- an unfold waiting for its comparison
    let mut next := i + 1
    while next < n.next do
      let j := next
      let c := nodes[j]!
      next := c.next
      if c.timed then
        let mut act := active
        if let some f := unfolded then
          let cost := if c.cls == "Meta.isDefEq" then some c.amount else some 0
          out := out.push (f, "unfold", if active.contains f then none else cost)
          if c.cls == "Meta.isDefEq" then act := f :: act
          unfolded := none
        pending := if simpWork c.cls then pending + c.amount else 0
        todo := todo.push (j, act)
      else
        match attributedConst c with
        | some (name, "unfold") =>
          if let some f := unfolded then
            out := out.push (f, "unfold", if active.contains f then none else some 0)
          unfolded := some name
          pending := 0
        | some (name, k) =>
          out := out.push (name, k, if active.contains name then none else some pending)
          pending := 0
        | none => pure ()
    if let some f := unfolded then
      out := out.push (f, "unfold", if active.contains f then none else some 0)
  return out

/-! ## Diagnostics (exact counts) -/

/-- The counters of one `diagnostics` message: (constant, counter, count).
Counters: `unfolds` (whnf and isDefEq), `instances` (used), `kernel`
(unfolded by the kernel), `simp_used`, `simp_tried`, `simp_failed`.
One line of the message at a time, with the counts so far and the section
the line is in. -/
def diagLine (st : Array (String × String × Nat) × String) (line : String) :
    Array (String × String × Nat) × String := Id.run do
  let (out, sect) := st
  let mut out := out
  let t := line.trimAscii.toString
  unless t.startsWith "[" do return (out, sect)
  let cat := (t.drop 1).takeWhile (· != ']') |>.toString
  let rest := ((t.drop (cat.length + 2)).dropWhile (· == ' ')).toString
  match rest.splitOn " ↦ " with
  | [name, count] =>
    let n := (count.takeWhile Char.isDigit).toString.toNat!
    let ctr := match cat, sect with
      | "reduction", _ => "unfolds"
      | "type_class", _ => "instances"
      | "kernel", _ => "kernel"
      | "simp", s => if s.startsWith "used" then "simp_used" else "simp_tried"
      | _, _ => ""
    if ctr.isEmpty then return (out, sect)
    out := out.push (name, ctr, n)
    if ctr == "simp_tried" then
      let failed :=
        if count.endsWith "❌️" || count.endsWith "❌" then n
        else match count.splitOn "succeeded: " with
          | [_, k] => n - (k.takeWhile Char.isDigit).toString.toNat!
          | _ => 0
      if failed > 0 then out := out.push (name, "simp_failed", failed)
    return (out, sect)
  | _ => return (out, rest)

/-- The counters of one whole `diagnostics` message. -/
def parseDiag (data : String) : Array (String × String × Nat) :=
  ((data.splitOn "\n").foldl diagLine (#[], "")).1

/-- Does a message with this first line look like `diagnostics` output? -/
def diagHeader (line : String) : Bool :=
  line.startsWith "[diag] Diagnostics" || line.startsWith "[simp] Diagnostics" ||
    line.startsWith "[kernel] Diagnostics"

def hasArrow (line : String) : Bool := (line.splitOn " ↦ ").length > 1

def isDiagMessage (data : String) : Bool :=
  diagHeader data && hasArrow data

/-- One message's `data`, read a line at a time: as a trace, and when it
starts like `diagnostics` output, as that too. -/
structure MsgData where
  trace : TraceBuilder := {}
  lines : Nat := 0
  diagHead : Bool := false
  diagArrow : Bool := false
  diag : Array (String × String × Nat) × String := (#[], "")

def MsgData.addLine (d : MsgData) (line : String) : MsgData :=
  let ⟨trace, lines, diagHead, diagArrow, diag⟩ := d
  let diagHead := if lines == 0 then diagHeader line else diagHead
  let (diagArrow, diag) := if diagHead then (diagArrow || hasArrow line, diagLine diag line) else (diagArrow, diag)
  ⟨trace.addLine line, lines + 1, diagHead, diagArrow, diag⟩

/-- A message's `data` as read: `diagnostics` counters, or a trace's nodes. -/
inductive Parsed where
  | diag (counts : Array (String × String × Nat))
  | trace (nodes : Array TNode)

def MsgData.finish (d : MsgData) : Parsed :=
  if d.diagHead && d.diagArrow then .diag d.diag.1 else .trace d.trace.finish

def parseData (data : String) : Parsed :=
  ((data.splitOn "\n").foldl MsgData.addLine {}).finish

/-! ## Accumulated costs -/

structure LineCost where
  total : Float := 0
  elaboration : Float := 0
  kernel : Float := 0
  compile : Float := 0
  lint : Float := 0
  name : String := ""
  top : Array (Float × String) := #[]  -- most expensive nested operations
  consts : Std.HashMap String (String × Float × Nat) := {}  -- constant ↦ (kind, cost, times)
  deriving Inhabited

structure OpCost where
  count : Nat := 0
  total : Float := 0
  maxOne : Float := 0
  firstAt : String := ""

structure ConstCost where
  kind : String := ""
  cost : Float := 0
  count : Nat := 0
  sites : Std.HashSet String := {}
  diag : Std.HashMap String Nat := {}

structure FileCost where
  module : String := ""
  total : Float := 0
  elaboration : Float := 0
  kernel : Float := 0
  compile : Float := 0
  lint : Float := 0
  wallNs : Nat := 0
  errors : Nat := 0

structure Acc where
  lines : Std.HashMap String LineCost := {}
  byClass : Std.HashMap String Float := {}
  ops : Std.HashMap (String × String) OpCost := {}
  consts : Std.HashMap String ConstCost := {}
  files : Array (String × FileCost) := #[]
  grand : Float := 0
  /-- Tactic steps by the source line they are on: (cost, tactic, times). -/
  tactics : Std.HashMap String (Float × String × Nat) := {}
  /-- The file being read, by line, and without whitespace to find tactics in (not merged). -/
  src : Array String := #[]
  srcSq : Array String := #[]
  /-- The largest command traced so far at each `line:column` of the file (not merged). -/
  commandsAt : Std.HashMap String Float := {}

/-- `s` without whitespace. -/
def squash (s : String) : String := String.ofList (s.toList.filter fun c => !c.isWhitespace)

/-- Is this `Elab.step` a tactic (a term's reads `expected type: T, term e`)? -/
def isTacticStep (n : TNode) : Bool :=
  n.cls == "Elab.step" && n.timed && !n.text.startsWith "expected type:" && !n.text.isEmpty

/-- The source line (1-based) at or after `from` whose text contains the
start of tactic `t`, looking at most 400 lines ahead. -/
def findTactic (src : Array String) (t : String) (from_ : Nat) : Option Nat := Id.run do
  let key := String.ofList ((squash t).toList.take 24)
  if key.length < 2 then return none
  for i in [from_ - 1:min src.size (from_ - 1 + 400)] do
    if (src[i]!.splitOn key).length > 1 then return some (i + 1)
  return none
def Acc.addConst (a : Acc) (name kind : String) (cost : Option Float) (site : String) : Acc :=
  let c := a.consts.getD name {}
  let c := { c with kind := if c.kind.isEmpty then kind else c.kind, cost := c.cost + cost.getD 0,
                    count := c.count + 1, sites := c.sites.insert site }
  { a with consts := a.consts.insert name c }

def Acc.addDiag (a : Acc) (name ctr : String) (n : Nat) (site : String) : Acc :=
  let c := a.consts.getD name {}
  let c := { c with diag := c.diag.insert ctr (c.diag.getD ctr 0 + n), sites := c.sites.insert site }
  { a with consts := a.consts.insert name c }

/-- Fold one `lean --json` message of `file` into the accumulator: `m`
without its `data`, which was read into `p`. -/
def Acc.addParsed (a : Acc) (file : String) (scale : Float) (m : Json) (p : Parsed) : Acc := Id.run do
  let ln := ((m.getObjVal? "pos" >>= (·.getObjVal? "line")) >>= Json.getNat?).toOption.getD 0
  let key := s!"{file}:{ln}"
  let mut a := a
  let nodes ← match p with
    | .diag counts =>
      for (name, ctr, n) in counts do
        a := a.addDiag name ctr n key
      return a
    | .trace nodes => pure nodes
  let some root := nodes[0]? | return a
  -- A command Lean expands into others (`theorem Foo.bar` into `namespace Foo theorem bar
  -- end`, `open X in ...`) traces the inner command first and then itself, at the same
  -- position, including the inner one's time: count only what the outer adds.
  let col := ((m.getObjVal? "pos" >>= (·.getObjVal? "column")) >>= Json.getNat?).toOption.getD 0
  let at_ := s!"{ln}:{col}"
  let mut nodes := nodes
  let mut root := root
  if root.cls == "Elab.command" then
    let inner := a.commandsAt.getD at_ 0
    a := { a with commandsAt := a.commandsAt.insert at_ (max inner root.amount) }
    if inner > 0 then
      root := { root with amount := max 0 (root.amount - inner) }
      nodes := nodes.set! 0 root
  let rootAmt := root.amount * scale
  a := { a with grand := a.grand + rootAmt }
  -- per line: total and kind
  let mut c := a.lines.getD key {}
  c := { c with total := c.total + rootAmt }
  let mut f := (a.files.back?.map (·.2)).getD {}
  f := { f with total := f.total + rootAmt }
  if root.cls == "Elab.async" then
    match (nodes[1]?.map (·.cls)) with
    | some "Kernel" => c := { c with kernel := c.kernel + rootAmt }; f := { f with kernel := f.kernel + rootAmt }
    | some "Compiler" => c := { c with compile := c.compile + rootAmt }; f := { f with compile := f.compile + rootAmt }
    | some "Elab.lint" => c := { c with lint := c.lint + rootAmt }; f := { f with lint := f.lint + rootAmt }
    | _ => c := { c with elaboration := c.elaboration + rootAmt }; f := { f with elaboration := f.elaboration + rootAmt }
  else
    c := { c with elaboration := c.elaboration + rootAmt }
    f := { f with elaboration := f.elaboration + rootAmt }
    if root.cls == "Elab.command" && c.name.isEmpty then
      -- Lean sometimes cannot print the command: name it after its source line
      let text := if root.text.startsWith "failed to pretty print" then sourceLine a.src ln else root.text
      c := { c with name := String.ofList ((dropDocComment text).toList.take 60) }
  if !a.files.isEmpty then a := { a with files := a.files.modify (a.files.size - 1) fun (k, _) => (k, f) }
  -- tactic steps, by the line each is on: found in the source after the command's start,
  -- in the order Lean ran them; a step nested in one on the same line is not counted again
  if !a.src.isEmpty then
    let mut lineOf : Array (Option Nat) := Array.replicate nodes.size none
    let mut cursor := max ln 1
    for i in [0:nodes.size] do
      let n := nodes[i]!
      let inherited := n.parent.bind (lineOf[·]!)
      if isTacticStep n then
        if let some l := findTactic a.srcSq n.text cursor then
          lineOf := lineOf.set! i (some l)
          cursor := l
          unless inherited == some l do
            let k := s!"{file}:{l}"
            let (x, t, cnt) := a.tactics.getD k (0, normalizeOp n.text, 0)
            a := { a with tactics := a.tactics.insert k (x + n.amount * scale, t, cnt + 1) }
          continue
      lineOf := lineOf.set! i inherited
  -- self time per class; repeated operations; the line's heaviest nested operations
  for i in [0:nodes.size] do
    let n := nodes[i]!
    unless n.timed do continue
    let self := max 0 (n.amount - n.childSum) * scale
    a := { a with byClass := a.byClass.insert n.cls (a.byClass.getD n.cls 0 + self) }
    if i > 0 && repeatable n.cls then
      -- only the outermost of a nest of the same class
      let nested := Id.run do
        let mut p := n.parent
        let mut found := false
        while true do
          let some q := p | break
          if nodes[q]!.cls == n.cls then found := true; break
          p := nodes[q]!.parent
        return found
      unless nested do
        let k := (n.cls, normalizeOp n.text)
        let o := a.ops.getD k {}
        let amt := n.amount * scale
        let o' : OpCost := { count := o.count + 1, total := o.total + amt, maxOne := max o.maxOne amt,
                             firstAt := if o.firstAt.isEmpty then key else o.firstAt }
        a := { a with ops := a.ops.insert k o' }
        c := { c with top := c.top.push (amt, s!"[{n.cls}] {normalizeOp n.text}") }
  -- the constants behind the work
  for (name, kind, cost) in attributions nodes do
    let cost := cost.map (· * scale)
    a := a.addConst name kind cost key
    let (k0, x, t) := c.consts.getD name (kind, 0, 0)
    c := { c with consts := c.consts.insert name (k0, x + cost.getD 0, t + 1) }
  -- the line's heaviest operations, ignoring those under 1% of it
  c := { c with top := (((c.top.filter (·.1 ≥ c.total * 0.01)).qsort (fun a b => a.1 > b.1)).toList.take 5).toArray }
  { a with lines := a.lines.insert key c }
where
  /-- The source text of 1-based line `ln` and the two after it. -/
  sourceLine (src : Array String) (ln : Nat) : String :=
    " ".intercalate (((src.toList.drop (ln - 1)).take 3).map (·.trimAscii.toString))
  /-- A command's text without its leading doc comment. -/
  dropDocComment (text : String) : String :=
    if text.startsWith "/--" then
      match text.splitOn "-/" with
      | _ :: rest@(_ :: _) => ("-/".intercalate rest).trimAscii.toString
      | _ => text
    else text

/-- Fold one whole `lean --json` message of `file` into the accumulator. -/
def Acc.addMessage (a : Acc) (file : String) (scale : Float) (m : Json) : Acc :=
  a.addParsed file scale m (parseData (str m "data"))

/-- `b` folded into `a`; `b`'s operations count as first seen after `a`'s. -/
def Acc.merge (a b : Acc) : Acc := Id.run do
  let mut r := { a with grand := a.grand + b.grand, files := a.files ++ b.files }
  for (k, (x, t, n)) in b.tactics do
    let (x', t', n') := r.tactics.getD k (0, t, 0)
    r := { r with tactics := r.tactics.insert k (x + x', t', n + n') }
  for (k, c) in b.lines do
    -- lines are per file: no two files share a key
    r := { r with lines := r.lines.insert k c }
  for (k, x) in b.byClass do
    r := { r with byClass := r.byClass.insert k (r.byClass.getD k 0 + x) }
  for (k, o) in b.ops do
    let p := r.ops.getD k {}
    let o' : OpCost := { count := p.count + o.count, total := p.total + o.total, maxOne := max p.maxOne o.maxOne,
                         firstAt := if p.firstAt.isEmpty then o.firstAt else p.firstAt }
    r := { r with ops := r.ops.insert k o' }
  for (k, c) in b.consts do
    let p := r.consts.getD k {}
    let diag := c.diag.fold (fun d ctr n => d.insert ctr (d.getD ctr 0 + n)) p.diag
    let c' : ConstCost := { kind := if p.kind.isEmpty then c.kind else p.kind, cost := p.cost + c.cost,
                            count := p.count + c.count, sites := c.sites.fold (·.insert ·) p.sites, diag }
    r := { r with consts := r.consts.insert k c' }
  return r

/-! ## Running Lean -/

/-- What `lake env` sets: the `lean` to run and the search paths. -/
structure LeanEnv where
  lean : String := "lean"
  sysroot : FilePath := ""
  path : String := ""
  srcPath : String := ""

def leanEnv : IO LeanEnv := do
  let out ← IO.Process.output { cmd := "lake", args := #["env", "env"] }
  let get (k : String) : Option String :=
    (out.stdout.splitOn "\n").findSome? fun l => if l.startsWith (k ++ "=") then some (l.drop (k.length + 1)).toString else none
  match get "LEAN", get "LEAN_SYSROOT", get "LEAN_PATH" with
  | some lean, some sysroot, some path => return { lean, sysroot, path, srcPath := (get "LEAN_SRC_PATH").getD "" }
  | _, _, _ => throw <| IO.userError s!"`lake env` did not give Lean's paths (run leanprof in a Lake project):\n{out.stderr}"

structure Opts where
  heartbeats : Bool := false
  top : Nat := 15
  out : String := ".lake/leanprof/elab.json"
  files : Array String := #[]
  project : Bool := false
  globs : Array String := #[]
  jobs : Nat := 0
  defs : Bool := true      -- attribute cost to the constants behind it
  /-- Operations cheaper than this are not recorded (they still count in their
  parent): milliseconds, or heartbeats with `--heartbeats`. `none`: 1 ms or
  10,000 heartbeats. Recording everything (0) makes large files 50-100 times
  slower to elaborate, mostly printing the trace. -/
  threshold : Option Nat := none
  build : Bool := true
  /-- `--counts`: Lean's `diagnostics` counters (exact unfold, instance and simp counts).
  Off by default: it makes elaboration up to twice as slow. -/
  diagnostics : Bool := false
  /-- Elaborate a built module with Lake's setup file for it. -/
  setup : Bool := true

def Opts.thresholdValue (o : Opts) : Nat :=
  o.threshold.getD (if o.heartbeats then 10000 else 1)

def traceArgs (o : Opts) : Array String := Id.run do
  let mut args := #["--json", "-Dtrace.profiler=true", s!"-Dtrace.profiler.threshold={o.thresholdValue}"]
  if o.heartbeats then args := args.push "-Dtrace.profiler.useHeartbeats=true"
  if o.defs then
    args := args ++ #["-Dweak.trace.Meta.isDefEq.delta.unfoldLeft=true",
      "-Dweak.trace.Meta.isDefEq.delta.unfoldRight=true", "-Dweak.trace.Meta.isDefEq.delta.unfoldLeftRight=true",
      "-Dweak.trace.Meta.Tactic.simp.rewrite=true", "-Dpp.fullNames=true"]
    if o.diagnostics then args := args ++ #["-Ddiagnostics=true", "-Ddiagnostics.threshold=0"]
  return args

/-- A message read by `readMessages`: the JSON without its `data` text, and
`data` as read. None when it is not JSON. -/
def finishMessage (rest : ByteArray) (d : MsgData) : Option (Json × Parsed) := do
  let m ← (String.fromUTF8? rest).bind (Json.parse · |>.toOption)
  return (m, d.finish)

/-- Read Lean's `--json` messages (one per line) from `h` to its end, calling
`f` with each one. A message's `data` text is decoded and parsed a line at a
time as it arrives, never held whole: one declaration's trace can be
gigabytes in a single message. `chunk`: bytes read at a time. -/
def readMessages (h : IO.FS.Stream) (f : Json → Parsed → IO Unit) (chunk : Nat := 1048576) : IO Unit := do
  let key := "\"data\":\"".toUTF8
  let mut rest : ByteArray := .empty  -- the current message without its `data` text
  let mut line : ByteArray := .empty  -- the current line of `data`, decoded
  let mut d : MsgData := {}
  -- 0: outside `data`, 1: inside, 2: after a backslash, 3 to 6: in `\uXXXX`
  let mut mode : Nat := 0
  let mut hex : Nat := 0
  repeat
    let buf ← h.read chunk.toUSize
    if buf.isEmpty then break
    let mut i := 0
    while i < buf.size do
      let b := buf[i]!
      if mode == 1 then
        -- copy the run up to the next quote, backslash or (not JSON) newline
        let mut k := i
        while k < buf.size && buf[k]! != 34 && buf[k]! != 92 && buf[k]! != 10 do k := k + 1
        line := buf.copySlice i line line.size (k - i)
        i := k
        if k < buf.size then
          let c := buf[k]!
          i := k + 1
          if c == 34 then  -- the end of `data`
            d := d.addLine (String.fromUTF8? line |>.getD "")
            line := .empty
            rest := rest.push 34
            mode := 0
          else if c == 92 then mode := 2
          else  -- a raw newline inside a string: not JSON, dropped
            rest := .empty; line := .empty; d := {}; mode := 0
        continue
      i := i + 1
      if mode == 0 then
        if b == 10 then  -- the end of the message
          if let some (m, p) := finishMessage rest d then f m p
          rest := .empty; d := {}
        else
          rest := rest.push b
          let n := rest.size
          if b == 34 && n ≥ key.size && (List.range key.size).all (fun j => rest[n - key.size + j]! == key[j]!) then
            mode := 1
      else if mode == 2 then
        mode := 1
        if b == 110 then  -- `\n`: the next line
          d := d.addLine (String.fromUTF8? line |>.getD "")
          line := .empty
        else if b == 116 then line := line.push 9
        else if b == 114 then line := line.push 13
        else if b == 98 then line := line.push 8
        else if b == 102 then line := line.push 12
        else if b == 117 then mode := 3; hex := 0
        else line := line.push b  -- `"`, `\`, `/`
      else
        hex := hex * 16 + (if b ≤ 57 then b.toNat - 48 else if b ≤ 70 then b.toNat - 55 else b.toNat - 87)
        if mode < 6 then mode := mode + 1
        else
          mode := 1
          -- Lean writes only control characters this way (surrogates: not decoded)
          let c := if 0xD800 ≤ hex && hex < 0xE000 then '\uFFFD' else Char.ofNat hex
          if c == '\n' then
            d := d.addLine (String.fromUTF8? line |>.getD "")
            line := .empty
          else line := line ++ (String.singleton c).toUTF8
  -- a last message without a newline
  if mode == 0 && !rest.isEmpty then
    if let some (m, p) := finishMessage rest d then f m p

/-- Elaborate one file and fold its trace into a fresh accumulator; its
messages are read as Lean prints them, so a large trace is never held whole. -/
partial def profileFile (le : LeanEnv) (o : Opts) (file module : String) : IO Acc := do
  let source ← try IO.FS.readFile file catch _ => pure ""
  let src := (source.splitOn "\n").toArray
  let scale : Float := if o.heartbeats then 1 else 1e9
  -- a built module is elaborated as Lake does: with its setup (module name, the package's
  -- `leanOptions`, the exact imported files)
  let setup : FilePath := ".lake" / "build" / "ir" / (module.replace "." "/" ++ ".setup.json")
  let setupArgs := if o.setup && (← setup.pathExists) then #["--setup", setup.toString] else #[]
  let t0 ← IO.monoNanosNow
  let child ← IO.Process.spawn {
    cmd := le.lean, args := (traceArgs o ++ setupArgs).push file, env := #[("LEAN_PATH", some le.path)],
    stdout := .piped, stderr := .null, stdin := .null }
  let acc ← IO.mkRef ({ files := #[(file, ({ module } : FileCost))], src, srcSq := src.map squash } : Acc)
  readMessages (IO.FS.Stream.ofHandle child.stdout) fun m p => do
    if str m "severity" == "error" then
      acc.modify fun a => { a with files := a.files.modify 0 fun (k, f) => (k, { f with errors := f.errors + 1 }) }
    acc.modify (·.addParsed file scale m p)
  discard child.wait
  let t1 ← IO.monoNanosNow
  let a ← acc.get
  let a := { a with files := a.files.modify 0 fun (k, f) => (k, { f with wallNs := t1 - t0 }), src := #[], srcSq := #[] }
  -- `diagnostics` can make Lean fail where it otherwise does not (4.35: nested inductive
  -- types, "Unknown constant `_nested.…rec`"): then profile the file again without it
  let errors : Nat := (a.files[0]?.map (·.2.errors)).getD 0
  -- a setup Lake wrote before the file was edited (imports changed): without it
  if errors > 0 && !setupArgs.isEmpty then
    let b ← profileFile le { o with setup := false } file module
    if (b.files[0]?.map (·.2.errors)).getD (0 : Nat) < errors then return b
  if errors > 0 && o.defs && o.diagnostics then
    let b ← profileFile le { o with diagnostics := false } file module
    if (b.files[0]?.map (·.2.errors)).getD (0 : Nat) < errors then
      IO.eprintln s!"leanprof: {file}: errors with `diagnostics` on, profiled without it (no exact unfold counts)"
      return b
  return a

/-- Profile `files` with `jobs` Lean processes at a time; results in the order of `files`. -/
def profileAll (le : LeanEnv) (o : Opts) (files : Array (String × String)) (jobs : Nat) : IO (Array Acc) := do
  let next ← IO.mkRef 0
  let results ← IO.mkRef (Array.replicate files.size ({} : Acc))
  let done ← IO.mkRef 0
  let worker : IO Unit := do
    repeat
      let i ← next.modifyGet fun i => (i, i + 1)
      if h : i < files.size then
        let (file, module) := files[i]
        let a ← profileFile le o file module
        results.modify (·.set! i a)
        let d ← done.modifyGet fun d => (d + 1, d + 1)
        if files.size > 1 then
          let f := (a.files[0]?.map (·.2)).getD {}
          IO.eprintln s!"[{d}/{files.size}] {file} ({fmt2 (f.wallNs.toFloat / 1e9)} s{if f.errors > 0 then s!", {f.errors} errors" else ""})"
      else break
  let tasks ← (List.range (max 1 (min jobs files.size))).mapM fun _ => IO.asTask worker (prio := .dedicated)
  for t in tasks do
    match t.get with
    | .ok () => pure ()
    | .error e => throw e
  results.get

/-! ## Where constants are defined -/

/-- A constant's own definition: `file:line` to show, the full path, its module. -/
structure Loc where
  pos : String
  path : String := ""
  module : String := ""
  /-- A definition, theorem or opaque constant (something `whnf` can unfold),
  not a structure, inductive type, constructor or recursor. -/
  unfoldable : Bool := true

/-- `Foo.bar`, `«a b».c`, `_private.M.0.f` as a `Name`. -/
def parseName (s : String) : Name := Id.run do
  -- split on dots outside «»
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

/-- `n` without a `_private.M.0.` prefix. -/
def userName (s : String) : String :=
  if s.startsWith "_private." then (privateToUserName (parseName s)).toString else s

/-- The source file of `mod`, from `LEAN_SRC_PATH`. -/
def sourceOf (le : LeanEnv) (mod : Name) : IO (Option FilePath) := do
  let sp := SearchPath.parse le.srcPath ++ [le.sysroot / "src" / "lean" / "lake", le.sysroot / "src" / "lean"]
  SearchPath.findWithExt sp "lean" mod

/-- `path` as shown: relative to the current directory, or to Lean's sources. -/
def showPath (le : LeanEnv) (cwd : FilePath) (path : FilePath) : String :=
  let p := path.toString
  let src := (le.sysroot / "src" / "lean").toString ++ "/"
  let here := cwd.toString ++ "/"
  if p.startsWith here then (p.drop here.length).toString
  else if p.startsWith src then (p.drop src.length).toString
  else p

/-- Look up `names` in the environment of `modules` (those with an `.olean`):
the line each is declared on, in its module's source. -/
def locate (le : LeanEnv) (modules : Array Name) (names : Array String) : IO (Std.HashMap String Loc) := do
  if names.isEmpty then return {}
  initSearchPath le.sysroot (SearchPath.parse le.path)
  let mut built : Array Import := #[]
  for m in modules.toList.eraseDups do
    if (← (try some <$> findOLean m catch _ => pure none)).isSome then
      built := built.push { module := m }
  if built.isEmpty then return {}
  let cwd ← IO.currentDir
  -- all at once; modules that cannot be imported together (two executables' `main`):
  -- one at a time, until every name is found
  let joint ← try some <$> importModules built {} (loadExts := false) catch _ => pure none
  if let some env := joint then
    return ← lookup le cwd env names {}
  let mut out : Std.HashMap String Loc := {}
  for m in built do
    let rest := names.filter (!out.contains ·)
    if rest.isEmpty then break
    try
      let env ← importModules #[m] {} (loadExts := false)
      out ← lookup le cwd env rest out
    catch e => IO.eprintln s!"leanprof: definitions in {m.module} not located ({e})"
  return out
where
  lookup (le : LeanEnv) (cwd : FilePath) (env : Environment) (names : Array String)
      (out : Std.HashMap String Loc) : IO (Std.HashMap String Loc) := do
    let mut out := out
    let mut srcs : Std.HashMap Name (Option FilePath) := {}
    for s in names do
      let n := parseName s
      let ranges? := declRangeExt.find? (level := .server) env n <|> declRangeExt.find? env n <|>
        -- auxiliary recursors and `match_` functions: the declaration they belong to
        declRangeExt.find? (level := .server) env n.getPrefix
      let some ranges := ranges? | continue
      let some idx := env.getModuleIdxFor? n | continue
      let some mod := env.header.moduleNames[idx.toNat]? | continue
      let src ← match srcs.get? mod with
        | some s => pure s
        | none => do
          let s ← sourceOf le mod
          srcs := srcs.insert mod s
          pure s
      let line := ranges.range.pos.line
      let unfoldable := match env.find? n with
        | some (.defnInfo _) | some (.thmInfo _) | some (.opaqueInfo _) => true
        | _ => false
      match src with
      | some p => out := out.insert s { pos := s!"{showPath le cwd p}:{line}", path := p.toString,
                                        module := mod.toString, unfoldable }
      | none => out := out.insert s { pos := s!"{mod}:{line}", module := mod.toString, unfoldable }
    return out

/-! ## The project -/

/-- Glob over module names: `*` matches any run of characters, `?` one. -/
partial def globMatch (p s : List Char) : Bool :=
  match p, s with
  | [], [] => true
  | '*' :: p', _ => globMatch p' s || (match s with | _ :: s' => globMatch p s' | [] => false)
  | '?' :: p', _ :: s' => globMatch p' s'
  | c :: p', d :: s' => c == d && globMatch p' s'
  | _, _ => false

/-- The root package's built modules with a source file under the package:
`(file, module)`, sorted. -/
partial def projectModules : IO (Array (String × String)) := do
  let lib : FilePath := ".lake" / "build" / "lib" / "lean"
  unless ← lib.isDir do return #[]
  let rec walk (dir : FilePath) (rel : List String) : IO (Array (List String)) := do
    let mut out := #[]
    for e in ← dir.readDir do
      if ← e.path.isDir then out := out ++ (← walk e.path (rel ++ [e.fileName]))
      else if e.fileName.endsWith ".olean" then
        out := out.push (rel ++ [(e.fileName.dropEnd 6).toString])
    return out
  let mut res := #[]
  for parts in ← walk lib [] do
    let file := "/".intercalate parts ++ ".lean"
    if ← (file : FilePath).pathExists then
      res := res.push (file, ".".intercalate parts)
  return res.qsort (·.1 < ·.1)

/-- The module a file is, when it is under the current directory. -/
def moduleOfFile (file : String) : String :=
  let f := if file.startsWith "./" then (file.drop 2).toString else file
  ((f.dropEnd 5).toString.replace "/" ".")

partial def parseOpts (o : Opts) : List String → Except String Opts
  | [] => .ok o
  | "--top" :: v :: rest => parseOpts { o with top := v.toNat! } rest
  | "--heartbeats" :: rest => parseOpts { o with heartbeats := true } rest
  | "--out" :: f :: rest => parseOpts { o with out := f } rest
  | "--project" :: rest => parseOpts { o with project := true } rest
  | "--module-glob" :: g :: rest => parseOpts { o with project := true, globs := o.globs ++ (g.splitOn ",").toArray } rest
  | "--jobs" :: v :: rest => parseOpts { o with jobs := v.toNat! } rest
  | "-j" :: v :: rest => parseOpts { o with jobs := v.toNat! } rest
  | "--no-defs" :: rest => parseOpts { o with defs := false } rest
  | "--counts" :: rest => parseOpts { o with diagnostics := true } rest
  | "--no-build" :: rest => parseOpts { o with build := false } rest
  | "--threshold" :: v :: rest => parseOpts { o with threshold := some v.toNat! } rest
  | f :: rest =>
    if f.startsWith "--" then .error s!"unknown option {f}" else parseOpts { o with files := o.files.push f } rest

/-- The name declared by a command's text (`theorem foo ...` gives `foo`). -/
def declName (text : String) : Option String := Id.run do
  let words := (text.splitOn " ").filter (· != "")
  let kws := ["def", "theorem", "lemma", "abbrev", "instance", "structure", "inductive", "class", "opaque",
    "axiom"]
  for i in [0:words.length] do
    if kws.contains words[i]! then
      if let some w := words[i + 1]? then
        if !(w.startsWith "(" || w.startsWith "[" || w.startsWith "{" || w.startsWith ":" || w.startsWith "⦃") then
          return some w
      return none
  return none

/-- `File.lean:12` as (file, line). -/
def splitPos (k : String) : String × Nat :=
  match k.splitOn ":" with
  | [f, l] => (f, l.toNat!)
  | _ => (k, 0)

/-- Name of the declaration that starts closest above `key` in its file. -/
def ownerName (named : Std.HashMap String (Array (Nat × String))) (key : String) : String := Id.run do
  let (f, l) := splitPos key
  let mut best := 0
  let mut name := ""
  for (l', n) in named.getD f #[] do
    if l' ≤ l && l' ≥ best then
      best := l'
      name := n
  return name

def kindLabel : String → String
  | "unfold" => "isDefEq unfolds"
  | "whnf" => "whnf reduces"
  | "instance" => "instance tried"
  | "simp" => "simp lemma"
  | k => k

/-! ## The command -/

def main (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseOpts {} argv)
  if o.files.isEmpty && !o.project then
    throw <| IO.userError "usage: leanprof elab [--heartbeats] [--project | --module-glob GLOB] [--jobs N] [--counts] [--threshold N] [--no-defs] [--top N] [--out FILE] [FILE.lean...]"
  let tStart ← IO.monoNanosNow
  -- the modules must be built: their imports are read from `.olean` files
  if o.project && o.build then
    IO.eprintln "leanprof: lake build"
    let out ← IO.Process.output { cmd := "lake", args := #["build"] }
    if out.exitCode != 0 then
      IO.eprintln out.stdout
      IO.eprintln out.stderr
      throw <| IO.userError "lake build failed; leanprof elab --project needs the package built"
  let tBuilt ← IO.monoNanosNow
  let le ← leanEnv
  let mut files : Array (String × String) := o.files.map fun f => (f, moduleOfFile f)
  if o.project then
    let mods ← projectModules
    let sel := if o.globs.isEmpty then mods else
      mods.filter fun (_, m) => o.globs.any fun g => globMatch g.toList m.toList
    files := files ++ sel.filter fun (f, _) => !files.any (·.1 == f)
    if files.isEmpty then
      throw <| IO.userError "no modules to profile (none built under .lake/build/lib/lean, or none matches --module-glob)"
  let cores := (System.Platform.Internal.getHardwareConcurrency ()).toNat
  -- each `lean` elaborates with several threads of its own
  let jobs := if o.jobs > 0 then o.jobs else max 1 (cores / 2)
  if files.size > 1 then
    IO.eprintln s!"leanprof: elaborating {files.size} files, {min jobs files.size} at a time"
  let results ← profileAll le o files jobs
  let tProfiled ← IO.monoNanosNow
  let acc := results.foldl Acc.merge {}
  let hb := o.heartbeats
  let fmtAmt (x : Float) : String := if hb then s!"{fmt2 (x / 1000)} kHB" else s!"{fmt2 (x / 1e6)} ms"
  let grand := acc.grand
  let pct (x : Float) := s!"{fmt2 (if grand > 0 then x / grand * 100 else 0)}%"
  -- where the constants are defined
  let mut imports : Array Name := #[]
  for (file, module) in files do
    imports := imports.push (parseName module)
    -- a file that is not built: what it imports
    if let some h ← (try some <$> parseImports' (← IO.FS.readFile file) file catch _ => pure none) then
      imports := imports ++ h.imports.map (·.module)
  let names := acc.consts.toArray.map (·.1)
  let locs ← if o.defs then locate le imports names else pure {}
  -- declarations of the profiled files, by line: for constants defined there (unbuilt
  -- files) and to name kernel and compiler lines
  let mut named : Std.HashMap String (Array (Nat × String)) := {}
  let mut localDecls : Std.HashMap String (String × Bool) := {}  -- declared name ↦ (file:line, unfolds)
  for (k, c) in acc.lines do
    if c.name.isEmpty then continue
    let (f, l) := splitPos k
    named := named.insert f ((named.getD f #[]).push (l, c.name))
    if let some d := declName c.name then
      let unfolds := ["def", "abbrev", "instance", "theorem", "lemma", "opaque"].any fun kw => (c.name.splitOn s!"{kw} ").length > 1
      localDecls := localDecls.insert d (k, unfolds)
  let locOf (s : String) : Option Loc := match locs.get? s with
    | some l => some l
    | none =>
      let u := userName s
      let parts := u.splitOn "."
      -- `Foo.bar` declared as `bar` in `namespace Foo`, or as `Foo.bar`
      (List.range parts.length).findSome? fun i =>
        (localDecls.get? (".".intercalate (parts.drop i))).map fun (k, u) => { pos := k, unfoldable := u }
  -- `whnf` reduces applications of anything (structures, variables): keep only
  -- constants that unfold
  let keep (s : String) (c : ConstCost) : Bool :=
    c.kind != "whnf" || ((locOf s).map (·.unfoldable)).getD false || c.diag.contains "unfolds"
  let consts := (acc.consts.toArray.filter fun (s, c) => keep s c && (c.cost > 0 || !c.diag.isEmpty))
  let sites (s : String) : Nat := ((acc.consts.get? s).map (·.sites.size)).getD 0
  IO.println s!"\nleanprof elab: {files.size} {if files.size == 1 then "file" else "files"}, {fmtAmt grand} {if hb then "(heartbeats, exact)" else "compile time"}"
  IO.println s!"  (operations under {if hb then s!"{groupDigits o.thresholdValue} heartbeats" else s!"{o.thresholdValue} ms"} count in the operation around them; --threshold N to change)"
  IO.println "\n  where compile time went (self, by operation kind)"
  for (cls, x) in ((acc.byClass.toArray.qsort (fun a b => a.2 > b.2 || (a.2 == b.2 && a.1 < b.1))).toList.take o.top) do
    IO.println s!"  {pad (fmtAmt x) 12} {pad (pct x) 8} {cls}"
  -- slowest files
  let fileRows := acc.files.qsort fun a b => a.2.total > b.2.total || (a.2.total == b.2.total && a.1 < b.1)
  if acc.files.size > 1 then
    IO.println s!"\n  slowest files (elab / kernel / compiler / lint; wall time includes loading imports)"
    for (f, c) in fileRows.toList.take o.top do
      IO.println s!"  {pad (fmtAmt c.total) 12} {pad (fmtAmt c.elaboration) 11}/ {pad (fmtAmt c.kernel) 10}/ {pad (fmtAmt c.compile) 10}/ {pad (fmtAmt c.lint) 10} {pad s!"{fmt2 (c.wallNs.toFloat / 1e9)} s" 8} {f}"
  let failed := acc.files.filter (·.2.errors > 0)
  -- costliest lines; kernel and compiler work can sit on a line of its own: name it after
  -- the declaration that starts closest above it
  let lineCosts : Array (String × LineCost) := acc.lines.toArray.map fun (k, c) =>
    if c.name.isEmpty then (k, { c with name := ownerName named k }) else (k, c)
  let rows := (lineCosts.filter (·.2.total > 0)).qsort (fun a b => a.2.total > b.2.total || (a.2.total == b.2.total && a.1 < b.1))
  let lineConsts (c : LineCost) : Array (String × String × Float × Nat) :=
    ((c.consts.toArray.filter fun (s, _) => (acc.consts.get? s).all (keep s)).map fun (s, (k, x, t)) => (s, k, x, t))
      |>.filter (·.2.2.1 > 0) |>.qsort (fun a b => a.2.2.1 > b.2.2.1 || (a.2.2.1 == b.2.2.1 && a.1 < b.1))
  let whereOf (s : String) : String := ((locOf s).map (s!"  ({·.pos})")).getD ""
  IO.println s!"\n  costliest {if acc.files.size > 1 then "declarations" else "lines"} (elab / kernel / compiler / lint)"
  for (k, c) in rows.toList.take o.top do
    IO.println s!"  {pad (fmtAmt c.total) 12} {pad (fmtAmt c.elaboration) 11}/ {pad (fmtAmt c.kernel) 10}/ {pad (fmtAmt c.compile) 10}/ {pad (fmtAmt c.lint) 10} {k}  {c.name.replace "\n" " "}"
    for (amt, op) in c.top.toList.take 3 do
      IO.println s!"      {pad (fmtAmt amt) 12} {String.ofList (op.toList.take 100)}"
    for (s, kind, x, _) in (lineConsts c).toList.take 2 do
      if x ≥ c.total * 0.05 then
        IO.println s!"      {pad (fmtAmt x) 12} {kindLabel kind} {userName s}{whereOf s}"
  -- tactic steps by line
  let tactics := acc.tactics.toArray.qsort fun a b => a.2.1 > b.2.1 || (a.2.1 == b.2.1 && a.1 < b.1)
  if !tactics.isEmpty then
    IO.println "\n  costliest tactic steps, by the line each is on (inclusive: a step contains the steps under it)"
    for (k, (x, t, n)) in tactics.toList.take o.top do
      IO.println s!"  {pad (fmtAmt x) 12} {pad (if n > 1 then s!"{n}×" else "") 6} {k}  {String.ofList ((t.replace "\n" " ").toList.take 80)}"
  -- repeated work
  let reps := (acc.ops.toArray.filter (·.2.count > 1)).qsort (fun a b =>
    a.2.total > b.2.total || (a.2.total == b.2.total && (a.1.1 < b.1.1 || (a.1.1 == b.1.1 && a.1.2 < b.1.2))))
  if !reps.isEmpty then
    IO.println s!"\n  repeated work (the same operation done more than once{if acc.files.size > 1 then ", across files" else ""})"
    for ((cls, op), oc) in reps.toList.take o.top do
      IO.println s!"  {pad (fmtAmt oc.total) 12} {pad s!"{oc.count}×" 6} [{cls}] {String.ofList (op.toList.take 90)}  (first at {oc.firstAt})"
  -- the definitions behind the work
  let byCost := (consts.filter (·.2.cost > 0)).qsort fun a b => a.2.cost > b.2.cost || (a.2.cost == b.2.cost && a.1 < b.1)
  if o.defs && !byCost.isEmpty then
    IO.println "\n  definitions behind the work (the isDefEq/whnf/instance/simp work each caused; overlapping)"
    for (s, c) in byCost.toList.take o.top do
      IO.println s!"  {pad (fmtAmt c.cost) 12} {pad (kindLabel c.kind) 16} {userName s}{whereOf s}, reached from {c.sites.size} {if c.sites.size == 1 then "site" else "sites"}, {c.count}×"
  let counted := (consts.filter fun (_, c) => (c.diag.getD "unfolds" 0) + (c.diag.getD "kernel" 0) > 0).qsort
    fun a b =>
      let x := (a.2.diag.getD "unfolds" 0) + (a.2.diag.getD "kernel" 0)
      let y := (b.2.diag.getD "unfolds" 0) + (b.2.diag.getD "kernel" 0)
      x > y || (x == y && a.1 < b.1)
  if o.defs && !counted.isEmpty then
    IO.println "\n  most unfolded (exact counts from `diagnostics`: elaborator / kernel)"
    for (s, c) in counted.toList.take o.top do
      IO.println s!"  {pad (groupDigits (c.diag.getD "unfolds" 0)) 10} / {pad (groupDigits (c.diag.getD "kernel" 0)) 10} {userName s}{whereOf s}, {c.sites.size} {if c.sites.size == 1 then "site" else "sites"}"
  let simpFailed := (consts.filter fun (_, c) => c.diag.getD "simp_failed" 0 > 0).qsort
    fun a b => a.2.diag.getD "simp_failed" 0 > b.2.diag.getD "simp_failed" 0 ||
      (a.2.diag.getD "simp_failed" 0 == b.2.diag.getD "simp_failed" 0 && a.1 < b.1)
  if o.defs && !simpFailed.isEmpty then
    IO.println "\n  simp lemmas tried most without success (exact counts)"
    for (s, c) in simpFailed.toList.take (min 10 o.top) do
      IO.println s!"  {pad (groupDigits (c.diag.getD "simp_failed" 0)) 10} of {pad (groupDigits (c.diag.getD "simp_tried" 0)) 10} {userName s}{whereOf s}"
  -- for #leanprof and compare
  let constJson (s : String) (kind : String) (amount : Float) (count : Nat) : List (String × Json) :=
    let l := locOf s
    [("name", Json.str (userName s)), ("kind", Json.str kind), ("amount", toJson amount), ("count", toJson count),
     ("sites", toJson (sites s)), ("where", Json.str ((l.map (·.pos)).getD "")),
     ("path", Json.str ((l.map (·.path)).getD ""))]
  let scopes := rows.map fun (k, c) => Json.mkObj [("name", Json.str (c.name.replace "\n" " ")), ("pos", Json.str k),
    -- what `compare` matches on: the declaration, so edits that move lines still compare
    ("key", Json.str ((declName c.name).map (fun d => s!"{(splitPos k).1} {d}") |>.getD k)),
    ("total_ns", toJson c.total), ("elab_ns", toJson c.elaboration), ("kernel_ns", toJson c.kernel),
    ("compile_ns", toJson c.compile), ("lint_ns", toJson c.lint),
    ("top", Json.arr (c.top.map fun (a, op) => Json.mkObj [("amount", toJson a), ("op", Json.str op)])),
    ("unfolded", Json.arr (((lineConsts c).toList.take 5).toArray.map fun (s, kind, x, t) =>
      Json.mkObj (constJson s kind x t)))]
  let repeated := reps.map fun ((cls, op), oc) => Json.mkObj [("class", Json.str cls), ("op", Json.str op),
    ("count", toJson oc.count), ("total", toJson oc.total), ("first_at", Json.str oc.firstAt)]
  let constants := (consts.qsort fun a b => a.2.cost > b.2.cost || (a.2.cost == b.2.cost && a.1 < b.1)).map fun (s, c) =>
    let l := locOf s
    Json.mkObj (constJson s c.kind c.cost c.count ++
      [("module", Json.str ((l.map (·.module)).getD ""))] ++
      (["unfolds", "kernel", "instances", "simp_used", "simp_tried", "simp_failed"].filterMap fun ctr =>
        (c.diag.get? ctr).map fun n => (ctr, toJson n)))
  let fileJson := (acc.files.qsort (·.1 < ·.1)).map fun (f, c) => Json.mkObj [("file", Json.str f),
    ("module", Json.str c.module), ("key", Json.str s!"module {c.module}"),
    ("total_ns", toJson c.total), ("elab_ns", toJson c.elaboration), ("kernel_ns", toJson c.kernel),
    ("compile_ns", toJson c.compile), ("lint_ns", toJson c.lint), ("wall_ns", toJson c.wallNs),
    ("errors", toJson c.errors)]
  if let some dir := (o.out : FilePath).parent then IO.FS.createDirAll dir
  let tEnd ← IO.monoNanosNow
  IO.FS.writeFile o.out
    (Json.mkObj [("version", toJson (3 : Nat)), ("elab", Json.bool true), ("project", Json.bool o.project),
      ("unit", Json.str (if hb then "heartbeats" else "ns")), ("wall_ns", toJson grand),
      ("scopes", Json.arr scopes), ("repeated", Json.arr repeated), ("constants", Json.arr constants),
      ("files", Json.arr fileJson), ("copies", Json.arr #[]),
      -- self cost per operation kind (`leanprof html`'s "operation kinds" table)
      ("kinds", Json.arr ((acc.byClass.toArray.qsort (fun a b => a.2 > b.2)).map fun (cls, x) =>
        Json.mkObj [("class", Json.str cls), ("total", toJson x)])),
      ("tactics", Json.arr (tactics.map fun (k, (x, t, n)) => Json.mkObj [("pos", Json.str k), ("amount", toJson x),
        ("tactic", Json.str t), ("count", toJson n)])),
      ("threshold", toJson o.thresholdValue),
      ("timing", Json.mkObj [("build_ns", toJson (tBuilt - tStart)), ("profile_ns", toJson (tProfiled - tBuilt)),
        ("report_ns", toJson (tEnd - tProfiled)), ("jobs", toJson (min jobs files.size))])]).compress
  if !failed.isEmpty then
    IO.eprintln s!"\nleanprof: {failed.size} files had errors (their costs stop at the error): {", ".intercalate (failed.toList.take 5 |>.map (·.1))}"
  if files.size > 1 then
    IO.println s!"\n{files.size} files in {fmt2 ((tProfiled - tBuilt).toFloat / 1e9)} s ({min jobs files.size} at a time){if o.project && o.build then s!", lake build {fmt2 ((tBuilt - tStart).toFloat / 1e9)} s" else ""}, report {fmt2 ((tEnd - tProfiled).toFloat / 1e9)} s"
  IO.println s!"written to {o.out}; `#leanprof` shows it next to the code"
  return 0

end Leanprof.Elab
