import Lean.Data.Json
import Leanprof.Core
import Leanprof.Explain

/-!
# `leanprof explain --static`: likely copies, without running anything

`explain` reads the C that Lake keeps in `.lake/build/ir` (Lean's IR after
reference counting, one statement per line) to say why a copy that a run
counted happened. This module runs the same analysis on every operation that
copies a shared value (`Array.push`, `set`, `String.append`, ...) in every
compiled function of a package, and flags the ones where the IR shows that
another reference is alive at the update:

* in the function itself (explain's causes: an element still held by its
  array, a value read from a hash map or an `IO.Ref` that still holds it, a
  value stored elsewhere or used after the update, a field of a structure that
  is kept);
* in a caller, one call deep or more: a function that updates its parameter
  in place, called with a value the caller still holds (a loop that keeps the
  array it iterates over, a value used after the call). Calls of a few core
  functions that update their argument (`Array.append`, ...) count too;
* in a global `IO.Ref` or `Std.Mutex` made by `initialize`: what it holds is
  multi-threaded and never updated in place.

A flag is a likely copy on some path through the function, not a proof and
not a cost. `--report` (by default the last report, when there is one) says
which flags a run confirmed, with their copies and bytes, and, for a report of
`run --auto`, which flagged functions never ran.
-/

namespace Leanprof.StaticCopies
open Lean System Leanprof.Explain

/-! ## Reading every function of the emitted C -/

/-- Whether line `l` starts the definition of a C function. -/
def isFunHeader (l : String) : Bool :=
  l.endsWith "{" && !l.startsWith " " && has l "(" && !l.startsWith "{" &&
    (l.startsWith "LEAN_EXPORT" || l.startsWith "static" || l.startsWith "lean_object" || l.startsWith "uint")

/-- Every function defined in an emitted C file, except module initializers,
`_init_` thunks of constants and `_boxed` wrappers (which only unbox and call). -/
def functionsOf (file : FilePath) (lines : Array String) : Array CFun := Id.run do
  let mut out := #[]
  for h : i in [0:lines.size] do
    let l := lines[i]
    unless isFunHeader l do continue
    let f := parseFun file lines i
    if f.name.isEmpty || f.name.startsWith "_init_" || f.name.startsWith "initialize_" ||
       f.name.endsWith "___boxed" then continue
    out := out.push f
  return out

/-- A C variable: `v_x_12_` (Lean 4.30 and later) or `x_12` (before). -/
def isVar (s : String) : Bool := s.startsWith "v_" || s.startsWith "x_"

/-- The statement defining `v`; none for a parameter (a loop assigns its
parameters their next values before `goto _start`). -/
def defOf (f : CFun) (v : String) : Option Stmt :=
  if f.params.contains v then none else f.stmts.find? (·.lhs == v)

/-- `v` with plain copies (`v = w;`) followed back. -/
partial def resolve (f : CFun) (v : String) (fuel : Nat := 8) : String :=
  match defOf f v with
  | some d => if d.fn == "" && isVar d.rhs && fuel > 0 then resolve f d.rhs (fuel - 1) else v
  | none => v

/-- A module-level variable holding a value made by `initialize` (an
`IO.Ref`, a `Std.Mutex`): a symbol of the program, not a closed term, which
Lean emits as `..._closed_N`, nor a boxed scalar. -/
def isGlobalObj (text : String) : Bool :=
  (text.startsWith "l_" || text.startsWith "lp_") && !has text "_closed_" && !has text "("

/-- The global a variable holds, when it is one. -/
def globalOf (f : CFun) (v : String) : Option String :=
  match defOf f (resolve f v) with
  | some d => if d.fn == "" && isGlobalObj (cleanArg d.rhs) then some (cleanArg d.rhs) else none
  | none => none

/-- Runtime calls that store their argument `i` in a container. -/
def stores (s : Stmt) (i : Nat) : Bool :=
  match s.fn with
  | "lean_ctor_set" | "lean_closure_set" => i == 2
  | "lean_st_ref_set" | "lean_st_ref_swap" => i == 1
  | "lean_array_push" => i == 1
  | "lean_array_set" | "lean_array_fset" | "lean_array_uset" => i == 2
  | _ => false

def isSet (fn : String) : Bool :=
  fn == "lean_array_set" || fn == "lean_array_fset" || fn == "lean_array_uset"

/-- The array `c` gives up its reference to the element read by `read` before
`op`: the slot is overwritten (`Array.modify` puts a placeholder in it first),
or the array is released. -/
def takenOut (f : CFun) (c : String) (read op : Stmt) : Bool :=
  f.stmts.any fun t => t.idx > read.idx && t.idx < op.idx && compatible t op && t.args[0]? == some c &&
    (isSet t.fn || isDec t)

/-- An empty array (`Array.mkEmpty`, `#[]` with a capacity): copying it copies
no elements. -/
def knownEmpty (f : CFun) (v : String) : Bool :=
  match defOf f (resolve f v) with
  | some d => d.fn.startsWith "lean_mk_empty" || d.fn == "l_Array_mkEmpty" || d.fn == "l_Array_emptyWithCapacity"
  | none => false

/-- Explain's analysis of `fd` shows a second reference to the updated value
at the update, in this function. -/
def localEvidence (f : CFun) (fd : Finding) : Bool :=
  match fd.holder with
  | .storedBy u =>
    -- the container it was stored in is released before the update
    let c := if u.fn == "lean_ctor_set" || u.fn == "lean_closure_set" then u.args[0]?.getD "" else u.lhs
    fd.strength ≥ 2 && !f.stmts.any fun t => isDec t && t.args[0]? == some c && t.idx > u.idx &&
      t.idx < fd.op.idx && compatible t fd.op
  | .usedAfter _ | .inParent _ _ _ => fd.strength ≥ 2
  | .inArray c _ _ =>
    match defOf f (resolve f fd.var) with
    | some rd => !takenOut f c rd fd.op
    | none => fd.strength ≥ 2
  | .inMap rd putBack =>
    putBack.isSome && !f.stmts.any fun t => t.idx > rd.idx && t.idx < fd.op.idx && has t.fn "erase" &&
      t.args.any (rd.args.contains ·)
  | .inRef _ => true
  | _ => false

/-! ## Updates of parameters, and the callers that keep another reference -/

/-- A function updates its parameter `param` in place (or field `field` of it,
or, `viaRef`, the contents of the `IO.Ref` it is) at statement `idx` of
function `sym`. -/
structure Upd where
  param : Nat
  field : Option Nat := none
  viaRef : Bool := false
  sym : String
  idx : Nat
  deriving Inhabited, BEq

/-- Core functions, compiled into Lean's own libraries (no C in the package),
that update an array argument in place: (C symbol, argument). -/
def coreUpdates : List (String × Nat × String) := [
  ("l_Array_append___redArg", 0, "Array.append (++)"), ("l_Array_append", 1, "Array.append (++)"),
  ("l_Array_append___rarg", 0, "Array.append (++)"),
  ("l_Array_appendList___redArg", 0, "Array.appendList (++)"), ("l_Array_appendList", 1, "Array.appendList (++)"),
  ("l_Array_appendList___rarg", 0, "Array.appendList (++)"),
  ("l_Array_reverse___redArg", 0, "Array.reverse"), ("l_Array_reverse", 1, "Array.reverse"),
  ("l_Array_reverse___rarg", 0, "Array.reverse")]

/-- Index of parameter `v` of `f`. -/
def paramIdx (f : CFun) (v : String) : Option Nat := f.params.findIdx? (· == v)

/-- The parameter (and field of it) that `v` is, in `f`. -/
def paramPath (f : CFun) (v : String) : Option (Nat × Option Nat) :=
  let v := resolve f v
  match paramIdx f v with
  | some i => some (i, none)
  | none =>
    match defOf f v with
    | some d =>
      if d.fn == "lean_ctor_get" then
        match paramIdx f (resolve f (d.args[0]?.getD "")), (d.args[1]?.getD "").toNat? with
        | some i, some k => some (i, some k)
        | _, _ => none
      else none
    | none => none

/-- The updates of parameters in `f` that `f` itself shows no second reference for. -/
def paramUpdates (f : CFun) (flagged : Nat → Bool) : Array Upd := Id.run do
  let mut out := #[]
  for op in f.stmts do
    let some (_, opName) := opInfo op.fn | continue
    unless op.args.size > 0 do continue
    if flagged op.idx then continue
    let v := resolve f op.args[0]!
    -- incremented here (explain's analysis found the increment): a local second
    -- reference, judged by `localEvidence`
    if (analyzeOp f op opName).strength ≥ 2 then continue
    match paramPath f v with
    | some (i, fld) => out := out.push { param := i, field := fld, sym := f.name, idx := op.idx }
    | none =>
      match defOf f v with
      | some d =>
        if d.fn == "lean_st_ref_take" then
          if let some i := paramIdx f (resolve f (d.args[0]?.getD "")) then
            out := out.push { param := i, viaRef := true, sym := f.name, idx := op.idx }
      | none => pure ()
  return out

/-- At call `s` of `f`, `w` is passed (directly, or stored in `chain` by
`lean_ctor_set` into the argument) while `f` or something else still holds
another reference to it: an increment before the call, and another use at or
after the call (a later read, a release, another argument), a store elsewhere,
or no release of the extra reference before the call. -/
def retainedAt (f : CFun) (s : Stmt) (argIdx : Nat) (w : String) (chain : Option Stmt) : Bool := Id.run do
  let incs := f.stmts.filter fun t => isInc t && t.args[0]? == some w && t.idx < s.idx && compatible t s
  if incs.isEmpty then return false
  let n := incs.foldl (fun acc t => acc + (if t.fn.endsWith "_n" then (t.args[1]?.bind (·.toNat?)).getD 1 else 1)) 0
  let first := incs[0]!.idx
  let mut drops := 0
  for t in f.stmts do
    if isInc t || !compatible t s then continue
    if chain.any (·.idx == t.idx) then continue
    if t.idx == s.idx then
      -- passed again, as another argument
      if t.args.toList.zipIdx.any fun (a, i) => a == w && i != argIdx then return true
      continue
    unless mentions t w do continue
    if t.idx > s.idx then return true
    if t.idx < first then continue
    if t.args.toList.zipIdx.any fun (a, i) => a == w && stores t i then return true
    if isDec t || t.args.toList.zipIdx.any fun (a, i) => a == w && consumes t.fn i then drops := drops + 1
  -- loop parameters stay held by the next iteration; borrowed ones by the caller
  return drops < n

/-! ## Flags -/

/-- How a flag's second reference is known. -/
inductive Via where
  /-- This function's IR. -/
  | here
  /-- The value was taken out of the global `IO.Ref` or `Std.Mutex` `global`. -/
  | global (global : String)
  /-- Caller `g` passes the value at call `call` while keeping another reference. -/
  | caller (g : CFun) (call : Stmt) (value : String)
  deriving Inhabited

structure Site where
  f : CFun
  fd : Finding
  kind : String
  via : Via := .here
  deriving Inhabited

/-- A pseudo-update for explain's analysis: the call `s`, with the argument
`w` that the callee updates in front. -/
def asUpdate (s : Stmt) (w : String) : Stmt := { s with args := #[w] ++ s.args.filter (· != w) }

structure Scan where
  sites : Array Site := #[]
  /-- Updates of empty arrays (`Array.mkEmpty`): they copy no elements, not flagged. -/
  empty : Nat := 0
  functions : Nat := 0
  updates : Nat := 0
  deriving Inhabited

/-- Flag the updates of `funs` that are likely to copy. -/
def scan (funs : Array CFun) : Scan := Id.run do
  let bySym : Std.HashMap String CFun := funs.foldl (fun m f => m.insert f.name f) {}
  let mut sites : Array Site := #[]
  let mut empty := 0
  let mut updates := 0
  let mut flagged : Std.HashSet (String × Nat) := {}
  -- this function's IR
  for f in funs do
    for kind in ["Array", "ScalarArray", "String"] do
      for fd in analyzeFun f kind do
        updates := updates + 1
        let v := resolve f fd.var
        if kind == "Array" && knownEmpty f v then
          if localEvidence f fd then empty := empty + 1
          continue
        -- taken out of a global `IO.Ref`: multi-threaded, whatever the IR shows
        match defOf f v with
        | some d =>
          if (d.fn == "lean_st_ref_take" || d.fn == "lean_st_ref_get") then
            if let some g := globalOf f (d.args[0]?.getD "") then
              sites := sites.push { f, fd := { fd with strength := 3 }, kind, via := .global g }
              flagged := flagged.insert (f.name, fd.op.idx)
              continue
        | none => pure ()
        if localEvidence f fd then
          sites := sites.push { f, fd, kind }
          flagged := flagged.insert (f.name, fd.op.idx)
  -- parameters updated in place, and their callers
  let mut upds : Std.HashMap String (Array Upd) := {}
  for f in funs do
    let us := paramUpdates f fun i => flagged.contains (f.name, i)
    if !us.isEmpty then upds := upds.insert f.name us
  let site? (u : Upd) : Option (CFun × Stmt) := do
    let g ← bySym.get? u.sym
    let op ← g.stmts[u.idx]?
    return (g, op)
  -- callers, a few levels up (each level adds the callers' own parameters)
  for _ in [0:4] do
    let mut added := false
    for f in funs do
      for s in f.stmts do
        if s.fn.isEmpty || s.fn.startsWith "lean_" then continue
        let calleeUpds := (upds.getD s.fn #[]) ++ (upds.getD (s.fn ++ "___boxed") #[])
        for u in calleeUpds do
          let some a := s.args[u.param]? | continue
          if flagged.contains (u.sym, u.idx) then continue
          let some (g, op) := site? u | continue
          let some (kind, opName) := opInfo op.fn | continue
          -- the value the callee updates, in the caller
          let (w, chain) : String × Option Stmt := match u.field with
            | none => (resolve f a, none)
            | some k =>
              match f.stmts.find? fun t => t.fn == "lean_ctor_set" && t.args[0]? == some a &&
                  t.args[1]? == some (toString k) && t.idx < s.idx with
              | some t => (resolve f (t.args[2]?.getD ""), some t)
              | none => ("", none)
          if w.isEmpty then continue
          if u.viaRef then
            if let some glob := globalOf f w then
              let fd := analyzeOp g op opName
              sites := sites.push { f := g, fd := { fd with strength := 3 }, kind, via := .global glob }
              flagged := flagged.insert (u.sym, u.idx)
            else if let some i := paramIdx f w then
              let nu := { u with param := i }
              if !(upds.getD f.name #[]).contains nu then
                upds := upds.insert f.name ((upds.getD f.name #[]).push nu); added := true
            continue
          if retainedAt f s u.param w chain then
            if kind == "Array" && knownEmpty f w then empty := empty + 1; continue
            let fd := analyzeOp g op opName
            sites := sites.push { f := g, fd := { fd with strength := 2 }, kind, via := .caller f s w }
            flagged := flagged.insert (u.sym, u.idx)
          else if u.field.isNone then
            if let some (i, fld) := paramPath f w then
              let nu := { u with param := i, field := fld }
              if !(upds.getD f.name #[]).contains nu then
                upds := upds.insert f.name ((upds.getD f.name #[]).push nu); added := true
    if !added then break
  -- closures run on a global's contents (`mutex.atomically (modify ...)`):
  -- a closure whose code updates its `IO.Ref` argument, passed with a global
  for f in funs do
    for s in f.stmts do
      if s.fn.isEmpty || s.fn.startsWith "lean_" then continue
      let some glob := s.args.findSome? (globalOf f ·) | continue
      for a in s.args do
        let some d := defOf f (resolve f a) | continue
        unless d.fn == "lean_alloc_closure" do continue
        -- `lean_alloc_closure((void*)(SYM___boxed), arity, fixed)`
        let lam := String.ofList (((d.text.splitOn "(void*)(").getD 1 "").toList.takeWhile
          fun c => c.isAlphanum || c == '_')
        let lam := if lam.endsWith "___boxed" then dropRightChars lam 8 else lam
        for u in upds.getD lam #[] do
          unless u.viaRef do continue
          if flagged.contains (u.sym, u.idx) then continue
          let some (g, op) := site? u | continue
          let some (kind, opName) := opInfo op.fn | continue
          sites := sites.push { f := g, fd := { analyzeOp g op opName with strength := 3 }, kind, via := .global glob }
          flagged := flagged.insert (u.sym, u.idx)
  -- calls of core functions that update an argument
  for f in funs do
    for s in f.stmts do
      let some (_, i, opName) := coreUpdates.find? (·.1 == s.fn) | continue
      let some a := s.args[i]? | continue
      let w := resolve f a
      updates := updates + 1
      if retainedAt f s i w none then
        if knownEmpty f w then empty := empty + 1; continue
        let op := asUpdate s w
        let fd := { analyzeOp f op opName with var := w, strength := 2 }
        sites := sites.push { f, fd, kind := "Array", via := .caller f s w }
  return { sites, empty, functions := funs.size, updates }

/-! ## Source positions -/

/-- `_private.Mod.Name.0.foo.bar` is `foo.bar`. -/
def stripPrivate (n : String) : String :=
  if !n.startsWith "_private." then n else
  let parts := (dropChars n 9).splitOn "."
  match parts.findIdx? (fun p => !p.isEmpty && p.all Char.isDigit) with
  | some i => ".".intercalate (parts.drop (i + 1))
  | none => n

/-- Declarations of a module and their lines, from its `.ilean` (Lake writes
`"decls":{"Name":[l0,c0,l1,c1,selL0,selC0,selL1,selC1]}`, 0-based). -/
def readDecls (ilean : FilePath) : IO (Std.HashMap String Nat) := do
  unless ← ilean.pathExists do return {}
  let some j := (Json.parse (← IO.FS.readFile ilean)).toOption | return {}
  let some (.obj kvs) := (j.getObjVal? "decls").toOption | return {}
  let mut out := {}
  for (k, v) in kvs.toArray do
    let some arr := v.getArr?.toOption | continue
    let nums := arr.filterMap fun x => x.getNat?.toOption
    let line := if nums.size ≥ 5 then nums[4]! else nums[0]?.getD 0
    out := out.insert (stripPrivate k) (line + 1)
  return out

/-- The declaration a compiled function belongs to: `foo (in List.foldl)` is
`foo`, specialized at it. -/
def userDecl (fn : String) : String := (fn.splitOn " (in ").head!

/-- The line of `decl` (or of the declaration it is nested in: `foo.go`). -/
partial def declLine (decls : Std.HashMap String Nat) (decl : String) : Option (String × Nat) :=
  match decls.get? decl with
  | some l => some (decl, l)
  | none =>
    let parts := decl.splitOn "."
    if parts.length ≤ 1 then none else declLine decls (".".intercalate parts.dropLast)

/-- The package-relative source file of `module`: its path, or one directory
down (a library's `srcDir`). -/
def sourceFile (root : FilePath) (module : String) : IO (Option String) := do
  let rel := String.intercalate "/" (module.splitOn ".") ++ ".lean"
  if ← (root / rel).pathExists then return some rel
  for e in ← root.readDir do
    if e.fileName.startsWith "." then continue
    if ← e.path.isDir then
      if ← (e.path / rel).pathExists then return some (e.fileName ++ "/" ++ rel)
  return none

/-! ## The command -/

structure Opts where
  modules : Array String := #[]
  deps : Bool := false
  build : Bool := true
  report : Option String := none
  noReport : Bool := false
  out : String := ".lake/leanprof/static.json"
  json : Bool := false
  deriving Inhabited

partial def parseOpts (o : Opts) : List String → Except String Opts
  | [] => .ok o
  | "--static" :: rest => parseOpts o rest
  | "--deps" :: rest => parseOpts { o with deps := true } rest
  | "--no-build" :: rest => parseOpts { o with build := false } rest
  | "--report" :: f :: rest => parseOpts { o with report := some f } rest
  | "--no-report" :: rest => parseOpts { o with noReport := true } rest
  | "--out" :: f :: rest => parseOpts { o with out := f } rest
  | "--json" :: rest => parseOpts { o with json := true } rest
  | a :: rest =>
    if a.startsWith "-" then .error s!"unknown argument {a} (explain --static takes [--deps] [--no-build] [--report FILE | --no-report] [--out FILE] [--json] [MODULE...])"
    else parseOpts { o with modules := o.modules.push a } rest

/-- The C files to scan: (package root, file, module). -/
partial def cFilesIn (root irDir : FilePath) (rel : List String := []) : IO (Array (FilePath × FilePath × String)) := do
  unless ← irDir.isDir do return #[]
  let mut out := #[]
  for e in ← irDir.readDir do
    if ← e.path.isDir then out := out ++ (← cFilesIn root e.path (rel ++ [e.fileName]))
    else if e.fileName.endsWith ".c" then
      out := out.push (root, e.path, ".".intercalate (rel ++ [dropRightChars e.fileName 2]))
  return out

def selected (mods : Array String) (m : String) : Bool :=
  mods.isEmpty || mods.any fun x => m == x || m.startsWith (x ++ ".")

/-- Runtime evidence for a flag from a report: (status, copies, bytes). A
report counts copies per function, so the copies are those of the function
with the update (`fnName`, C symbol `sym`), or of `others` (the caller of a
flag known from one, where the C compiler may have inlined the update). -/
def runtimeOf (report : Option Json) (fnName sym kind : String) (others : Array String := #[]) :
    String × Nat × Nat := Id.run do
  let some j := report | return ("", 0, 0)
  let rows := (jarr j "copies").filter fun c =>
    jstr c "kind" == kind && (jstr c "function" == fnName || jstr c "symbol" == sym ||
      jstr c "symbol" == sym ++ "___boxed" || others.contains (jstr c "function"))
  let copies := rows.foldl (fun n c => n + (jnum c "shared" + jnum c "multi_threaded").toUInt64.toNat) 0
  let bytes := rows.foldl (fun n c => n + (jnum c "bytes").toUInt64.toNat) 0
  if copies > 0 then return ("confirmed", copies, bytes)
  let scopes := jarr j "scopes"
  let auto := scopes.any fun s => (s.getObjValAs? Bool "auto").toOption == some true
  if !auto then return ("not-seen", 0, 0)
  if scopes.any (jstr · "name" == fnName) then return ("ran-no-copies", 0, 0)
  if (jarr j "untimed").any (·.getStr?.toOption == some fnName) then return ("not-seen", 0, 0)
  return ("never-ran", 0, 0)

def runtimeText : String × Nat × Nat → String
  | ("confirmed", n, b) => s!"confirmed at run time: {n} {if n == 1 then "copy" else "copies"}, {fmtBytes b.toFloat} in this function"
  | ("ran-no-copies", _, _) => "ran, no copies counted"
  | ("never-ran", _, _) => "never ran"
  | ("not-seen", _, _) => "no copies counted (the report does not say whether it ran: `leanprof run --auto` does)"
  | _ => ""

/-- The updated value as the source names it: its name in the C (Lean 4.30
and later name variables after the source), else the receiver of the update on
one of the flag's source lines, else what the IR says it is. -/
def valueName (f : CFun) (v opName : String) (decl : Array (Nat × String)) (lines : Array Nat) : String := Id.run do
  if let some n := sourceName v then
    if !genericNames.contains n then return n
  for l in lines do
    let some (_, text) := decl.find? (·.1 == l) | continue
    for r in receivers opName (codeOf text) do
      match r with
      | .name n => return n
      | .elem c => return s!"{c}[…]"
      | .other => pure ()
  return display f v

/-- One flag, explained: the text to print and its JSON entry. -/
structure Flag where
  file : String
  line : Nat
  decl : String
  fnName : String
  sym : String
  kind : String
  op : String
  value : String
  ex : Explained
  evidence : String
  via : String := ""
  runtime : String × Nat × Nat := ("", 0, 0)
  deriving Inhabited

def Flag.json (fl : Flag) : Json :=
  let (st, n, b) := fl.runtime
  Json.mkObj [("file", fl.file), ("line", fl.line), ("where", s!"{fl.file}:{fl.line}"), ("declaration", fl.decl),
    ("function", fl.fnName), ("symbol", fl.sym), ("kind", fl.kind), ("operation", fl.op), ("value", fl.value),
    ("cause", fl.ex.cause), ("why", fl.ex.why), ("fix", fl.ex.fix), ("fix_code", Json.arr (fl.ex.code.map toJson)),
    ("lines", Json.arr ((dedup fl.ex.lines).qsort (· < ·) |>.map toJson)), ("strength", fl.ex.strength),
    ("confidence", confidence fl.ex), ("evidence", fl.evidence), ("via", fl.via),
    ("runtime", Json.mkObj [("status", st), ("copies", n), ("bytes", b)])]

/-- Explain one flagged site. `src`/`decl` are the source of the declaration
the update is in; `callerSrc` that of the caller, for flags known from one. -/
def explainSite (s : Site) (fnName : String) (src : Array String) (decl : Array (Nat × String))
    (callerDecl : Array (Nat × String)) (callerName : String) : Explained × String := Id.run do
  let ex := explainFinding s.f s.fd s.kind 0 decl fnName
  match s.via with
  | .here => return (ex, "")
  | .global g =>
    let (why, fix, code, ls) := (mtGlobalExplained src decl s.kind).getD
      (s!"the {s.kind} is taken out of `{Leanprof.demangle g}`, a global made by `initialize`: Lean marks what it holds " ++
        "as multi-threaded, because any thread can reach it, and never updates a multi-threaded value in place, " ++
        "even when it holds the only reference.",
       "Update a value that only this thread can see, and publish it once: a local `IO.mkRef` (or a `let mut`) " ++
        "updated in place, then store it in the global when it is complete.", "", #[])
    let ls := if ls.isEmpty then ex.lines else ls
    let code := if code.isEmpty then #[] else #[code]
    return ({ ex with why, fix, code, lines := ls, matched := !ls.isEmpty, cause := "multi-threaded-global", strength := 3 },
      s!"global `{Leanprof.demangle g}`")
  | .caller g call w =>
    let via := s!"caller {callerName}"
    -- a loop over the array it updates, or a map over a shared array: the callee's own account
    if ex.cause == "loop-over-updated-array" || ex.cause == "map-over-shared-array" then
      return ({ ex with strength := 2 }, via)
    let opName := if g.name == s.f.name then s.fd.opName else s!"{s.fd.opName} in `{userDecl fnName}`"
    let pf := analyzeOp g (asUpdate call w) opName
    let pex := explainFinding g { pf with op := { pf.op with cline := call.cline } } s.kind 0 callerDecl callerName
    if ["stored-then-updated", "used-after-update", "nested-array-element", "map-value-reinserted",
        "field-of-kept-structure", "io-ref-read", "loop-over-updated-array"].contains pex.cause then
      return ({ pex with strength := 2, cline := ex.cline, lines := pex.lines ++ ex.lines }, via)
    let v := display g w
    let callee := Leanprof.demangle call.fn
    let loopParam := (paramIdx g w).isSome && has callerName "loop"
    -- the caller's lines that call the declaration with the update
    let calleeDecl := lastComponent (userDecl fnName)
    let callLines := if userDecl fnName == userDecl callerName then #[]
      else callerDecl.filterMap fun (n, l) => if wordIn (codeOf l) calleeDecl then some n else none
    return ({ ex with
      lines := ex.lines ++ callLines, matched := !(ex.lines ++ callLines).isEmpty,
      why := s!"`{v}` is passed to `{callee}`, which updates it in place ({s.fd.opName}), while the caller " ++
        s!"`{userDecl callerName}` still holds another reference to it" ++
        (if loopParam then " (it is the loop's own state, kept for the next iteration or after the loop)" else "") ++
        s!" (C line {call.cline}: `{call.text}`), so the update copies the {s.kind}.",
      fix := "Pass the only reference: finish every other use of the value before the call (read what you " ++
        "need from it first), or, when the old value must stay, build the result separately instead of " ++
        "updating a copy of it.",
      code := #[], cause := "shared-by-caller", strength := 2 }, via)

def explainStatic (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseOpts {} argv)
  let root : FilePath := "."
  if o.build then
    let args := #["build"] ++ o.modules
    let r ← IO.Process.output { cmd := "lake", args }
    if r.exitCode != 0 then
      IO.eprintln (r.stdout ++ r.stderr)
      throw <| IO.userError s!"`lake {" ".intercalate args.toList}` failed; fix the build, or pass --no-build to scan what was built"
  let mut files := (← cFilesIn root (root / ".lake" / "build" / "ir")).filter fun (_, _, m) => selected o.modules m
  if o.deps then
    let pkgs := root / ".lake" / "packages"
    if ← pkgs.isDir then
      for e in ← pkgs.readDir do
        files := files ++ (← cFilesIn e.path (e.path / ".lake" / "build" / "ir"))
  if files.isEmpty then
    throw <| IO.userError ("no emitted C in .lake/build/ir" ++
      (if o.modules.isEmpty then "" else s!" for {", ".intercalate o.modules.toList}") ++
      ": build the package with `lake build` first")
  -- every function, and where it came from
  let mut funs : Array CFun := #[]
  let mut moduleOf : Std.HashMap String (FilePath × String) := {}
  let mut stale : Array String := #[]
  for (pkg, file, m) in files do
    let lines := ((← IO.FS.readFile file).splitOn "\n").toArray
    for f in functionsOf file lines do
      funs := funs.push f
      moduleOf := moduleOf.insert f.name (pkg, m)
    if let some rel ← sourceFile pkg m then
      let srcM ← (pkg / rel).metadata
      let cM ← file.metadata
      if srcM.modified.sec > cM.modified.sec then stale := stale.push (pkg / rel).toString
  let result := scan funs
  -- the report to check the flags against
  let reportPath := o.report.getD ".lake/leanprof/report.json"
  let report : Option Json ← if o.noReport then pure none
    else if ← (reportPath : FilePath).pathExists then
      match Json.parse (← IO.FS.readFile reportPath) with
      | .ok j => pure (if (j.getObjValAs? Bool "sampled").toOption == some true then none else some j)
      | .error _ => pure none
    else if o.report.isSome then throw <| IO.userError s!"no report at {reportPath}"
    else pure none
  -- source of each module, read once
  let mut srcCache : Std.HashMap String (Array String) := {}
  let mut declCache : Std.HashMap String (Std.HashMap String Nat) := {}
  let mut flags : Array Flag := #[]
  let mut seen : Std.HashSet String := {}
  for s in result.sites do
    let some (pkg, m) := moduleOf.get? s.f.name | continue
    let fnName := Leanprof.demangle s.f.name
    let rel? ← sourceFile pkg m
    let file := match rel? with
      | some r => if pkg == root then r else (pkg / r).toString
      | none => s!"{m} (no source found)"
    let ileanPath := pkg / ".lake" / "build" / "lib" / "lean" / (String.intercalate "/" (m.splitOn ".") ++ ".ilean")
    let decls ← match declCache.get? ileanPath.toString with
      | some d => pure d
      | none => do
        let d ← readDecls ileanPath
        declCache := declCache.insert ileanPath.toString d
        pure d
    let src ← match srcCache.get? file with
      | some l => pure l
      | none => do
        let l ← if let some r := rel? then (do return ((← IO.FS.readFile (pkg / r)).splitOn "\n").toArray) else pure #[]
        srcCache := srcCache.insert file l
        pure l
    let declOf (name : String) : Array (Nat × String) × Nat :=
      match declLine decls (userDecl name) with
      | some (_, l) => if l > 0 && l ≤ src.size then (declLines src (l - 1), l) else (#[], 0)
      | none => (#[], 0)
    let (decl, dl) := declOf fnName
    let (callerDecl, callerName) := match s.via with
      | .caller g _ _ =>
        let n := Leanprof.demangle g.name
        ((declOf n).1, n)
      | _ => (#[], "")
    let (ex, via) := explainSite s fnName src decl callerDecl callerName
    let lines := dedup ex.lines
    let line := lines[0]?.getD dl
    let rel := let r := s.f.file.toString; if r.startsWith "./" then dropChars r 2 else r
    let evidence := s!"{rel}:{ex.cline} `{s.fd.op.text}`" ++
      (match s.fd.incLine with | some l => s!", second reference at {rel}:{l}" | none => "")
    let key := s!"{file}:{line}:{ex.cause}:{ex.why}"
    if seen.contains key then continue
    seen := seen.insert key
    let declName := ((declLine decls (userDecl fnName)).map (·.1)).getD (userDecl fnName)
    flags := flags.push {
      file, line, decl := declName, fnName, sym := s.f.name, kind := s.kind, op := s.fd.opName,
      value := (match s.via with
        | .global g => userDecl (Leanprof.demangle g)
        | _ => valueName s.f s.fd.var s.fd.opName decl lines), ex := { ex with lines }, evidence, via,
      runtime := runtimeOf report fnName s.f.name s.kind (if callerName.isEmpty then #[] else #[callerName]) }
  flags := flags.qsort fun a b => a.file < b.file || (a.file == b.file && a.line < b.line)
  let confirmed := flags.filter (·.runtime.1 == "confirmed")
  let modules := (files.map (·.2.2)).foldl (fun (acc : Array String) m => if acc.contains m then acc else acc.push m) #[]
  let summary := Json.mkObj [
    ("static", true), ("modules", modules.size), ("functions", result.functions), ("updates", result.updates),
    ("flags", Json.arr (flags.map (·.json))), ("suppressed_empty", result.empty),
    ("report", if report.isSome then toJson reportPath else Json.null),
    ("confirmed", confirmed.size), ("stale_sources", Json.arr (stale.map toJson))]
  IO.FS.createDirAll ((o.out : FilePath).parent.getD ".")
  IO.FS.writeFile o.out (summary.compress ++ "\n")
  if o.json then
    IO.println summary.pretty
    return 0
  IO.println (s!"leanprof explain --static: {flags.size} likely {if flags.size == 1 then "copy" else "copies"} in " ++
    s!"{modules.size} module(s) ({result.functions} compiled functions, {result.updates} updates that copy a " ++
    "shared value), from the compiler's IR; nothing was run" ++
    (if report.isSome then s!"; {confirmed.size} confirmed by {reportPath}" else "") ++ "\n")
  unless stale.isEmpty do
    IO.println s!"  note: {stale.size} source file(s) changed since they were compiled ({stale[0]!}{if stale.size > 1 then ", ..." else ""}): rebuild for current results\n"
  for fl in flags do
    let rt := runtimeText fl.runtime
    IO.println (s!"{fl.file}:{fl.line}  {fl.decl}  {fl.op} of `{fl.value}`" ++ (if rt.isEmpty then "" else s!"  [{rt}]"))
    IO.println (wrap s!"  why: {fl.ex.why}" "       ")
    unless fl.ex.fix.isEmpty do IO.print (wrap s!"  fix: {fl.ex.fix}" "       " ++ "\n" ++ codeBlock fl.ex.code)
    let ls := (dedup fl.ex.lines).qsort (· < ·)
    unless ls.isEmpty do IO.println s!"  where: {fl.file} {showLines ls}"
    IO.println s!"  evidence: {fl.evidence}{if fl.via.isEmpty then "" else s!" (second reference: {fl.via})"}"
    IO.println s!"  confidence: {confidence fl.ex}\n"
  if result.empty > 0 then
    IO.println s!"{result.empty} update(s) of empty arrays (`Array.mkEmpty`) that copy no elements are not shown."
  IO.println "A flag is a likely copy when that path runs, not a measurement: `leanprof run EXE` counts the copies."
  return 0

end Leanprof.StaticCopies
