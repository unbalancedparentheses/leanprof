import Lean.Data.Json
import Leanprof.Contract

/-!
# `leanprof explain`: why a value was shared when it was copied

The copy report names the function that copied and why the value was not
exclusive (`shared`, `multi-threaded`). This module finds *where the extra
reference comes from*, statically, from the code the Lean compiler emitted.

Lake keeps the C it compiles in `.lake/build/ir/**/*.c`. That C is Lean's IR
after reference-count insertion, one statement per line, with the IR's
variable names (`v_acc_12_`, field projections named after the field). For a
copy site the report gives the C symbol of the function that copied, so we can
read that function's body and, for each operation that can copy (`Array.push`,
`set`, `String.append`, ...), look at its updated operand:

* where it comes from: a field of a structure (`lean_ctor_get`), an element of
  an array (`lean_array_get_borrowed`), an `IO.Ref` (`lean_st_ref_get`), a
  constant, or a parameter;
* the `lean_inc` that takes a second reference and the statement it is for:
  stored in another array, stored in a constructor, passed to a function, or
  still used after the update.

IR has no source positions, so the source lines are found by matching the
declaration's text against the shape of what the IR shows (the receiver of
`.push`, the container of `xs[i]!.push`, the field of `s.f ++`). Explanations
say which parts come from the IR (reliable) and which from text matching.

The optional dynamic record (`LEANPROF_WHY=1`, see `c/explain.inc.c`) adds,
per copy site, the C line of the last reference-count increment that made the
copied value shared; it is read from `.lake/leanprof/why.json`.
-/

namespace Leanprof.Explain
open Lean System

/-! ## Small string helpers -/

def has (s pat : String) : Bool := (s.splitOn pat).length > 1

def trim (s : String) : String := s.trimAscii.toString

def dropChars (s : String) (n : Nat) : String := String.ofList (s.toList.drop n)

def dropRightChars (s : String) (n : Nat) : String :=
  let l := s.toList
  String.ofList (l.take (l.length - n))

def isIdentChar (c : Char) : Bool :=
  c.isAlphanum || c == '_' || c == '\'' || c == '.' || c.val > 127

def hexVal (c : Char) : Option Nat :=
  if c.isDigit then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else none

def hexNum (cs : List Char) : Option Nat :=
  cs.foldlM (fun acc c => (hexVal c).map (acc * 16 + ·)) 0

/-- Source name of an emitted C variable: `v_as_x27_256_` is `as'`. Temporaries
(`v___x_12_`) and names the compiler invents give `none`. -/
def sourceName (v : String) : Option String := Id.run do
  unless v.startsWith "v_" && v.endsWith "_" do return none
  let mut body := (dropChars v 2).toList
  body := body.dropLast   -- the trailing `_`
  -- drop the numeric suffix `_123`
  let rev := body.reverse
  let digits := rev.takeWhile Char.isDigit
  if digits.isEmpty then return none
  body := (rev.drop (digits.length + 1)).reverse
  if body.isEmpty || body.head? == some '_' then return none
  -- `_xHH` and `_uHHHH` escapes
  let rec decode : List Char → List Char
    | '_' :: 'x' :: a :: b :: rest =>
      match hexNum [a, b] with
      | some n => Char.ofNat n :: decode rest
      | none => '_' :: decode ('x' :: a :: b :: rest)
    | '_' :: 'u' :: a :: b :: c :: d :: rest =>
      match hexNum [a, b, c, d] with
      | some n => Char.ofNat n :: decode rest
      | none => '_' :: decode ('u' :: a :: b :: c :: d :: rest)
    | c :: rest => c :: decode rest
    | [] => []
  let name := String.ofList (decode body)
  if name.startsWith "isShared" || name.startsWith "reuseFailAlloc" then none else some name

/-- Names that the compiler gives to anonymous constructor fields or binders:
real in the IR, useless for finding the source line. -/
def genericNames : List String :=
  ["fst", "snd", "a", "b", "x", "y", "val", "head", "tail", "self", "s", "r", "f", "w", "c", "h",
   "as", "as'", "i", "j", "k", "n", "m", "res", "out", "init"]

/-! ## Emitted C -/

/-- One statement of an emitted C function. -/
structure Stmt where
  idx : Nat
  cline : Nat                      -- 1-based line in the C file
  guards : List String := []       -- enclosing branches, outermost first ("if@120:T")
  lhs : String := ""               -- assigned variable
  fn : String := ""                -- called function
  args : Array String := #[]
  rhs : String := ""               -- right-hand side, `return`/`goto` operand
  ret : Bool := false
  text : String := ""
  deriving Inhabited, Repr

structure CFun where
  name : String
  file : FilePath
  params : Array String
  stmts : Array Stmt
  conds : Std.HashMap String String := {}   -- "if@120" ↦ condition
  deriving Inhabited

/-- Split `a, f(b, c), d` at top-level commas. -/
def splitArgs (s : String) : Array String := Id.run do
  let mut out : Array String := #[]
  let mut cur : List Char := []
  let mut depth := 0
  for c in s.toList do
    if c == '(' then depth := depth + 1
    if c == ')' then depth := depth - 1
    if c == ',' && depth == 0 then
      out := out.push (trim (String.ofList cur.reverse))
      cur := []
    else cur := c :: cur
  let last := trim (String.ofList cur.reverse)
  if !last.isEmpty then out := out.push last
  return out

/-- Strip `&`, casts and parentheses around an argument. -/
partial def cleanArg (a : String) : String :=
  let a := trim a
  if a.startsWith "&" then cleanArg (dropChars a 1)
  else if a.startsWith "((lean_object*)(" && a.endsWith "))" then cleanArg (dropRightChars (dropChars a 16) 2)
  else if a.startsWith "(" && a.endsWith ")" then cleanArg (dropRightChars (dropChars a 1) 1)
  else a

/-- `f(a, b)` as `(f, #[a, b])`. -/
def parseCall (s : String) : Option (String × Array String) := do
  let cs := s.toList
  let fn := cs.takeWhile fun c => c.isAlphanum || c == '_'
  guard (!fn.isEmpty)
  let rest := cs.drop fn.length
  guard (rest.head? == some '(' && rest.getLast? == some ')')
  let inner := String.ofList ((rest.drop 1).dropLast)
  return (String.ofList fn, (splitArgs inner).map cleanArg)

/-- Count braces outside string and character literals. -/
def braceDelta (line : String) : Int := Id.run do
  let mut d : Int := 0
  let mut inStr := false
  let mut inChr := false
  let mut esc := false
  for c in line.toList do
    if esc then esc := false; continue
    if (inStr || inChr) && c == '\\' then esc := true; continue
    if inStr then
      if c == '"' then inStr := false
      continue
    if inChr then
      if c == '\'' then inChr := false
      continue
    if c == '"' then inStr := true
    else if c == '\'' then inChr := true
    else if c == '{' then d := d + 1
    else if c == '}' then d := d - 1
  return d

/-- Line index of the definition of C function `sym`, if `lines` has it. -/
def findDef (lines : Array String) (sym : String) : Option Nat :=
  lines.findIdx? fun l => l.endsWith "{" && !l.startsWith " " && has l (" " ++ sym ++ "(") &&
    !l.endsWith ";"

/-- Parse the body of the function defined at `lines[start]`. -/
def parseFun (file : FilePath) (lines : Array String) (start : Nat) : CFun := Id.run do
  let header := lines[start]!
  let name := match (header.splitOn "(").head? with
    | some h => ((h.splitOn " ").getLast?.getD "").replace "*" ""
    | none => ""
  -- up to the last `)`: Lean 4.35 ends the line with `){`, 4.27 with `) {`
  let afterParen := String.intercalate "(" ((header.splitOn "(").drop 1)
  let paramsText := String.intercalate ")" ((afterParen.splitOn ")").dropLast)
  let params := (splitArgs paramsText).filterMap fun p => (p.splitOn " ").getLast?.map (·.replace "*" "")
  let mut stmts : Array Stmt := #[]
  let mut conds : Std.HashMap String String := {}
  -- block stack: the guard each open block adds (none for plain and label blocks)
  let mut stack : Array (Option String) := #[]
  let mut pendingIf : Option String := none     -- "if@L" waiting for its `{`
  let mut pendingElse : Option String := none
  let mut lastIf : Option String := none        -- the if whose then-block just closed
  let mut switchGuard : Option String := none
  let mut depth : Int := braceDelta header
  let mut i := start + 1
  while i < lines.size && depth > 0 do
    let raw := lines[i]!
    let t := trim raw
    let cline := i + 1
    i := i + 1
    depth := depth + braceDelta raw
    if t == "{" then
      if let some g := pendingIf then
        stack := stack.push (some (g ++ ":T")); pendingIf := none
      else if let some g := pendingElse then
        stack := stack.push (some (g ++ ":F")); pendingElse := none
      else if let some g := switchGuard then
        stack := stack.push (some g); switchGuard := none
      else stack := stack.push none
      continue
    if t == "}" then
      match stack.back? with
      | some (some g) =>
        lastIf := if g.endsWith ":T" then some (dropRightChars g 2) else none
      | _ => lastIf := none
      stack := stack.pop
      continue
    if t == "else" then pendingElse := lastIf; continue
    if t.startsWith "if (" then
      let key := s!"if@{cline}"
      conds := conds.insert key (dropRightChars (dropChars t 4) 1)
      pendingIf := some key
      continue
    if t.startsWith "switch (" then
      switchGuard := some s!"sw@{cline}"
      if t.endsWith "{" then stack := stack.push (some s!"sw@{cline}"); switchGuard := none
      continue
    if t.startsWith "case " || t.startsWith "default:" then
      -- replace the switch block's guard by this case
      if let some (some g) := stack.back? then
        let base := (g.splitOn "|").head!
        stack := stack.pop.push (some s!"{base}|{t}")
      continue
    if t.endsWith ":" && !has t " " then continue          -- label
    if !t.endsWith ";" then continue
    let body := dropRightChars t 1
    let guards := stack.toList.filterMap id
    let idx := stmts.size
    if body.startsWith "return " then
      stmts := stmts.push { idx, cline, guards, rhs := cleanArg (dropChars body 7), ret := true, text := t }
      continue
    if body.startsWith "goto " then continue
    match body.splitOn " = " with
    | lhs :: rest@(_ :: _) =>
      let lhs := trim lhs
      if has lhs " " then continue                          -- a declaration with an initializer
      let rhs := trim (" = ".intercalate rest)
      let rhs' := if rhs.startsWith "!" then dropChars rhs 1 else rhs
      match parseCall rhs' with
      | some (fn, args) => stmts := stmts.push { idx, cline, guards, lhs, fn, args, rhs, text := t }
      | none => stmts := stmts.push { idx, cline, guards, lhs, rhs := cleanArg rhs, text := t }
    | _ =>
      match parseCall body with
      | some (fn, args) => stmts := stmts.push { idx, cline, guards, fn, args, text := t }
      | none => pure ()
  return { name, file, params, stmts, conds }

/-! ## Operations that copy when their operand is shared -/

/-- Runtime calls that copy their first argument when it is not exclusive, by
report kind, with the Lean-level name shown to users. -/
def copyOps : List (String × String × String) := [
  ("lean_array_push", "Array", "Array.push"),
  ("lean_array_set", "Array", "Array.set"), ("lean_array_fset", "Array", "Array.set"),
  ("lean_array_uset", "Array", "Array.set"), ("lean_array_pop", "Array", "Array.pop"),
  ("lean_array_swap", "Array", "Array.swap"), ("lean_array_fswap", "Array", "Array.swap"),
  ("lean_array_uswap", "Array", "Array.swap"),
  ("lean_byte_array_push", "ScalarArray", "ByteArray.push"),
  ("lean_byte_array_set", "ScalarArray", "ByteArray.set"),
  ("lean_byte_array_fset", "ScalarArray", "ByteArray.set"),
  ("lean_byte_array_uset", "ScalarArray", "ByteArray.set"),
  ("lean_float_array_push", "ScalarArray", "FloatArray.push"),
  ("lean_float_array_set", "ScalarArray", "FloatArray.set"),
  ("lean_float_array_fset", "ScalarArray", "FloatArray.set"),
  ("lean_float_array_uset", "ScalarArray", "FloatArray.set"),
  ("lean_string_push", "String", "String.push"),
  ("lean_string_append", "String", "String.append (++)"),
  ("lean_string_utf8_set", "String", "String.set")]

def opInfo (fn : String) : Option (String × String) :=
  (copyOps.find? (·.1 == fn)).map (·.2)

/-- Whether calling `fn` consumes (takes ownership of) argument `i`. Runtime
accessors borrow; compiled Lean functions are assumed to take ownership. -/
def consumes (fn : String) (i : Nat) : Bool :=
  match fn with
  | "lean_array_push" | "lean_byte_array_push" | "lean_float_array_push" => i ≤ 1
  | "lean_array_set" | "lean_array_fset" | "lean_array_uset" => i == 0 || i == 2
  | "lean_ctor_set" => i == 2
  | "lean_st_ref_set" | "lean_st_ref_swap" => i == 1
  | "lean_io_promise_resolve" | "lean_task_pure" | "lean_mk_thunk" | "lean_io_as_task" | "lean_task_spawn_core" =>
    i == 0
  | _ =>
    if (opInfo fn).isSome then i == 0
    else if fn.startsWith "lean_apply" then true
    else if fn.startsWith "lean_" then false
    else true

def isInc (s : Stmt) : Bool :=
  s.fn == "lean_inc" || s.fn == "lean_inc_ref" || s.fn == "lean_inc_n" || s.fn == "lean_inc_ref_n"

def isDec (s : Stmt) : Bool :=
  s.fn.startsWith "lean_dec" || s.fn == "lean_del_object" || s.fn == "lean_free_object"

/-- `v` is an argument, the returned value, or the aliased value of `s`. -/
def mentions (s : Stmt) (v : String) : Bool :=
  s.args.contains v || s.rhs == v

/-- `a` runs before `b` on every path to `b` (same block or an enclosing one). -/
def dominates (a b : Stmt) : Bool := a.idx < b.idx && a.guards.isPrefixOf b.guards

/-- `a` and `b` can run in the same execution. -/
def compatible (a b : Stmt) : Bool := a.guards.isPrefixOf b.guards || b.guards.isPrefixOf a.guards

/-- The guard that separates `a` from `b` when `a` is in a branch `b` is not in. -/
def firstExtraGuard (a b : Stmt) : Option String :=
  let common := (a.guards.zip b.guards).takeWhile (fun (x, y) => x == y) |>.length
  a.guards[common]?

/-- `a` runs only when a structure being updated was itself shared (the
`isShared` branch of the compiler's reset/reuse). -/
def onlyIfParentShared (f : CFun) (a b : Stmt) : Bool :=
  match firstExtraGuard a b with
  | some g =>
    let key := (g.splitOn ":").head!
    g.endsWith ":F" && has (f.conds.getD key "") "isShared"
  | none => false

/-- Where a variable's value comes from. -/
inductive Origin where
  | field (parent : String) (index : String)
  | elem (container : String) (index : String) (borrowed : Bool)
  | refGet (ref : String)
  | const (text : String)
  | taskResult
  | param (name : String)
  | call (fn : String)
  | fresh
  | unknown
  deriving Inhabited, Repr, BEq

partial def originOf (f : CFun) (v : String) (fuel : Nat := 8) : Origin := Id.run do
  if f.params.contains v then return .param v
  let some d := f.stmts.find? (·.lhs == v) | return .unknown
  if d.fn == "" then
    if d.rhs.startsWith "l_" || d.rhs.startsWith "lp_" || has d.rhs "_closed_" || d.rhs.startsWith "lean_box" then
      return .const d.rhs
    if d.rhs.startsWith "v_" && fuel > 0 then return originOf f d.rhs (fuel - 1)
    return .unknown
  match d.fn with
  | "lean_ctor_get" => return .field d.args[0]! (d.args[1]?.getD "?")
  | "lean_array_get_borrowed" => return .elem (d.args[1]?.getD "?") (d.args[2]?.getD "?") true
  | "lean_array_fget_borrowed" | "lean_array_uget_borrowed" => return .elem d.args[0]! (d.args[1]?.getD "?") true
  | "lean_array_get" => return .elem (d.args[1]?.getD "?") (d.args[2]?.getD "?") false
  | "lean_array_fget" | "lean_array_uget" => return .elem d.args[0]! (d.args[1]?.getD "?") false
  | "lean_st_ref_get" => return .refGet d.args[0]!
  | "lean_obj_once" => return .const (d.args[0]?.getD "")
  | "lean_task_get" | "lean_task_get_own" | "lean_io_wait" => return .taskResult
  | fn =>
    if fn.startsWith "lean_mk_" || fn.startsWith "lean_alloc" || fn.startsWith "lean_mk_empty" ||
       fn == "lean_string_push" || fn == "lean_string_append" || fn == "lean_array_push" then return .fresh
    if fn.startsWith "_init_" then return .const fn
    if (fn.startsWith "l_" || fn.startsWith "lp_") && d.args.isEmpty then return .const fn
    return .call fn

/-- Readable name of a compiled Lean function's C symbol:
`lp_pkg_Foo_Bar_baz` is `Foo.Bar.baz`, `l_Array_push` is `Array.push`. -/
def cDisplay (sym : String) : String := Id.run do
  let parts := if sym.startsWith "l_" then (dropChars sym 2).splitOn "_"
    else if sym.startsWith "lp_" then
      -- skip the package name: its components are lowercase
      ((dropChars sym 3).splitOn "_").dropWhile fun p => p.isEmpty || !(p.toList.head?.any Char.isUpper)
    else [sym]
  let parts := parts.filter (!·.isEmpty)
  if parts.isEmpty then return sym
  return ".".intercalate parts

/-- Readable name of a C variable: its source name, or what it is. -/
partial def display (f : CFun) (v : String) (fuel : Nat := 4) : String :=
  match sourceName v with
  | some n => n
  | none =>
    if fuel == 0 then "a temporary" else
    match originOf f v with
    | .elem c i _ => s!"{display f c (fuel - 1)}[{display f i (fuel - 1)}]"
    | .field p k => s!"{display f p (fuel - 1)}.{k}"
    | .refGet r => s!"the contents of {display f r (fuel - 1)}"
    | .const _ => "a constant"
    | .call fn => s!"the result of {cDisplay fn}"
    | _ => "a temporary"

/-- A second reference, as the IR shows it. -/
inductive Holder where
  /-- `v` is consumed by `by` (stored in an array, a constructor, passed on)
  before the update, while the update still needs it. -/
  | storedBy (user : Stmt)
  /-- `v` is still used after the update. -/
  | usedAfter (user : Stmt)
  /-- `v` is an element still held by its array; `putBack` writes the result
  back into the same array. -/
  | inArray (container : String) (index : String) (putBack : Option Stmt)
  /-- `v` is a field of a structure that is kept (reused or rebuilt with it). -/
  | inParent (parent : String) (field : String) (keptBy : Option Stmt)
  | inRef (ref : String)
  /-- `v` (or the structure it is a field of) was read from a hash map by
  `read`, which still holds it; `putBack` inserts the result into the map. -/
  | inMap (read : Stmt) (putBack : Option Stmt)
  | constant
  /-- Nothing in this function: the value arrived shared. -/
  | fromCaller (param : String)
  | unknown
  deriving Inhabited

structure Finding where
  op : Stmt
  opName : String
  var : String
  holder : Holder
  /-- 3: the IR takes a second reference on every path; 2: on some paths;
  1: only when an enclosing structure was itself shared, or not visible. -/
  strength : Nat
  incLine : Option Nat := none
  deriving Inhabited

/-- A hash-map lookup (`getD`, `get!`, `get?`, `find?`, `m[k]!`): the copy
it returns stays in the map. -/
def isMapGet (sym : String) : Bool :=
  ["HashMap", "DHashMap", "TreeMap", "RBMap", "AssocList"].any (has sym ·) &&
  ["_getD", "_get_x21", "_get_x3f", "_find_x3f", "_findD"].any (has sym ·)

/-- The map lookup that `v` was read from: the value it returned, or a field
of it (the `some` of `get?`, a field of a structure stored in the map). -/
partial def mapRead? (f : CFun) (v : String) (fuel : Nat := 3) : Option Stmt := do
  guard (fuel > 0)
  let d ← f.stmts.find? (·.lhs == v)
  if isMapGet d.fn && d.args.size ≥ 2 then return d
  if d.fn == "lean_ctor_get" then mapRead? f (d.args[0]?.getD "") (fuel - 1)
  else if d.fn == "" && d.rhs.startsWith "v_" then mapRead? f d.rhs (fuel - 1)
  else none

/-- Analyze one copying operation. -/
def analyzeOp (f : CFun) (op : Stmt) (opName : String) : Finding := Id.run do
  let v := op.args[0]!
  let origin := originOf f v
  -- read out of a hash map that still holds it, and (usually) inserted back
  if let some rd := mapRead? f v then
    let putBack := f.stmts.find? fun s => s.idx > op.idx && has s.fn "insert" && compatible s op &&
      s.args[0]?.any (rd.args.contains ·)
    return { op, opName, var := v, holder := .inMap rd putBack, strength := if putBack.isSome then 3 else 2 }
  let parent? := match origin with
    | .field p _ => some p
    | .elem c _ false => some c
    | _ => none
  -- an increment of a field followed by a release of its structure moves
  -- ownership (the structure is freed if it was exclusive): not a second reference
  let isTransfer (inc : Stmt) : Bool := match parent? with
    | some p => f.stmts.any fun d => isDec d && d.args[0]? == some p && d.idx > inc.idx && d.idx < op.idx &&
        compatible d op
    | none => false
  let incs := f.stmts.filter fun s => isInc s && s.args[0]? == some v && s.idx < op.idx && compatible s op &&
    !isTransfer s
  let incs := incs.filter (dominates · op) ++ incs.filter (!dominates · op)
  let parentOnly := f.stmts.any fun s => isInc s && s.args[0]? == some v && s.idx < op.idx &&
    onlyIfParentShared f s op
  let laterUses := f.stmts.filter fun u =>
    u.idx > op.idx && mentions u v && !isInc u && !isDec u && compatible u op
  let base : Finding := { op, opName, var := v, holder := .unknown, strength := 1 }
  for inc in incs do
    let strength := if dominates inc op then 3 else 2
    let found := { base with strength, incLine := inc.cline }
    -- the use the increment was inserted for: the next one that uses `v`
    let next := f.stmts.find? fun u => u.idx > inc.idx && mentions u v && !isInc u && !isDec u
    let some u := next | continue
    let storesV := u.args.toList.zipIdx.any fun (a, i) => a == v && consumes u.fn i
    match origin with
    | .field p k =>
      if u.fn == "lean_ctor_set" || u.idx == op.idx || !compatible u op then
        let kept := f.stmts.find? fun s => s.fn == "lean_ctor_set" && s.args[2]? == some v
        return { found with holder := .inParent p k kept }
    | .elem c i _ =>
      if u.idx == op.idx then
        let putBack := f.stmts.find? fun s => s.idx > op.idx && s.args[0]? == some c &&
          (s.fn == "lean_array_set" || s.fn == "lean_array_fset" || s.fn == "lean_array_uset") &&
          s.args[2]? == some op.lhs
        return { found with holder := .inArray c i putBack }
    | .refGet r =>
      if u.idx == op.idx then return { found with holder := .inRef r }
    | _ => pure ()
    if u.idx < op.idx && storesV && compatible u op then
      return { found with holder := .storedBy u }
    if let some later := laterUses[0]? then
      return { found with holder := .usedAfter later }
  -- no second reference taken in this function
  match origin with
  | .elem c i false => return { base with holder := .inArray c i none, strength := 3 }
  | .refGet r => return { base with holder := .inRef r, strength := 3 }
  | .const _ => return { base with holder := .constant, strength := 1 }
  | .param p => return { base with holder := .fromCaller p, strength := 1 }
  | .field p k =>
    match originOf f p with
    | .param q => return { base with holder := .fromCaller q, strength := if parentOnly then 0 else 1 }
    | _ => return { base with holder := .inParent p k none, strength := if parentOnly then 0 else 1 }
  | _ => return { base with strength := 0 }

/-- The copying operations of `f` for a report kind, analyzed. -/
def analyzeFun (f : CFun) (kind : String) : Array Finding :=
  f.stmts.filterMap fun s =>
    match opInfo s.fn with
    | some (k, name) => if k == kind && s.args.size > 0 then some (analyzeOp f s name) else none
    | none => none

/-! ## Finding the emitted C -/

/-- Directories with emitted C: this package's and each dependency's. -/
def irDirs (root : FilePath := ".") : IO (Array FilePath) := do
  let mut dirs := #[root / ".lake" / "build" / "ir"]
  let pkgs := root / ".lake" / "packages"
  if ← pkgs.isDir then
    for e in ← pkgs.readDir do
      dirs := dirs.push (e.path / ".lake" / "build" / "ir")
  return dirs.filter fun _ => true

partial def cFiles (dir : FilePath) : IO (Array FilePath) := do
  unless ← dir.isDir do return #[]
  let mut out := #[]
  for e in ← dir.readDir do
    if ← e.path.isDir then out := out ++ (← cFiles e.path)
    else if e.fileName.endsWith ".c" then out := out.push e.path
  return out

/-- A cache of C files read so far. -/
abbrev CCache := Std.HashMap String (Array String)

def readLines (cache : IO.Ref CCache) (p : FilePath) : IO (Array String) := do
  if let some ls := (← cache.get).get? p.toString then return ls
  let ls := ((← IO.FS.readFile p).splitOn "\n").toArray
  cache.modify (·.insert p.toString ls)
  return ls

/-- Find and parse the C function `sym`; `hint` is the declaration's source
file, whose C file is tried first. -/
def findFun (cache : IO.Ref CCache) (sym : String) (hint : String) : IO (Option CFun) := do
  let sym := if sym.startsWith "_lean_main" then "main" else sym
  let mut files : Array FilePath := #[]
  for d in ← irDirs do
    if hint.endsWith ".lean" then
      let p := d / (dropRightChars hint 5 ++ ".c")
      if ← p.pathExists then files := files.push p
  for d in ← irDirs do
    files := files ++ (← cFiles d)
  for p in files do
    let lines ← readLines cache p
    if let some i := findDef lines sym then return some (parseFun p lines i)
  return none

/-- The function containing C line `line` of `file`. -/
def funAtLine (cache : IO.Ref CCache) (file : FilePath) (line : Nat) : IO (Option CFun) := do
  unless ← file.pathExists do return none
  let lines ← readLines cache file
  let mut i := min line lines.size
  while i > 0 do
    i := i - 1
    let l := lines[i]!
    if l.endsWith "{" && !l.startsWith " " && has l "(" && !l.startsWith "{" &&
       (l.startsWith "LEAN_EXPORT" || l.startsWith "static" || l.startsWith "lean_object" || l.startsWith "uint") then
      return some (parseFun file lines i)
  return none

/-! ## Source lines -/

/-- Tokens of a source line: identifiers (with dots), brackets and operators. -/
def tokens (line : String) : Array String := Id.run do
  let mut out : Array String := #[]
  let mut cur : List Char := []
  let mut sym : List Char := []
  let flushSym (out : Array String) (sym : List Char) :=
    if sym.isEmpty then out else out.push (String.ofList sym.reverse)
  -- stop at a line comment
  let cs := ((line.splitOn "--").head!).toList
  for c in cs do
    if isIdentChar c then
      out := flushSym out sym; sym := []
      cur := c :: cur
    else
      if !cur.isEmpty then out := out.push (String.ofList cur.reverse); cur := []
      if c == ' ' || c == '\t' then out := flushSym out sym; sym := []
      else if c == '(' || c == ')' || c == '[' || c == ']' || c == ',' || c == '{' || c == '}' then
        out := flushSym out sym; sym := []
        out := out.push (String.singleton c)
      else sym := c :: sym
  if !cur.isEmpty then out := out.push (String.ofList cur.reverse)
  return flushSym out sym

/-- How the updated value appears in a source line. -/
inductive Recv where
  | name (n : String)            -- `acc.push x`, `s.namePrefix ++ t`
  | elem (container : String)    -- `xs[i]!.push x`
  | other
  deriving BEq, Inhabited

/-- Method suffixes and operators that perform each operation in source. -/
def surface (opName : String) : List String × List String :=
  if opName.endsWith ".push" then ([".push", ".pushn"], [])
  else if opName.startsWith "String.append" || opName.startsWith "Array.append" then ([".append"], ["++", "++="])
  else if opName.endsWith ".pop" then ([".pop", ".back", ".popWhile"], [])
  else if opName.endsWith ".swap" then ([".swap", ".swapAt", ".reverse"], [])
  else ([".set", ".modify", ".uset", ".setIfInBounds", ".insertAt", ".insertIdx", ".swapAt", ".setD"], [])

/-- Receivers of `opName` in a source line. -/
def receivers (opName : String) (line : String) : Array Recv := Id.run do
  let (suffixes, ops) := surface opName
  let ts := tokens line
  let mut out := #[]
  for h : i in [0:ts.size] do
    let t := ts[i]
    let prevElem : Unit → Recv := fun _ => Id.run do
      -- `c[i]!` or `c[i]` just before position i
      let mut j := i
      if j > 0 && (ts[j-1]! == "!" || ts[j-1]! == "?") then j := j - 1
      if j > 0 && ts[j-1]! == "]" then
        let mut depth := 0
        let mut k := j
        while k > 0 do
          k := k - 1
          if ts[k]! == "]" then depth := depth + 1
          if ts[k]! == "[" then
            depth := depth - 1
            if depth == 0 then break
        if k > 0 && (ts[k-1]!.toList.all isIdentChar) then return .elem ts[k-1]!
      return .other
    for suf in suffixes do
      if t.endsWith suf && t != suf then
        out := out.push (.name (dropRightChars t suf.length))
      else if t == suf || t.startsWith (suf ++ "!") then
        out := out.push (prevElem ())
      else if t.startsWith "Array" && t.endsWith suf then
        out := out.push (if let some n := ts[i+1]? then .name n else .other)
    for o in ops do
      if t == o then
        if i > 0 && ts[i-1]!.toList.all isIdentChar then out := out.push (.name ts[i-1]!)
        else out := out.push (prevElem ())
  return out

/-- Lines of a declaration: from its first line to the next top-level command. -/
def declLines (src : Array String) (start : Nat) : Array (Nat × String) := Id.run do
  let starters := ["def ", "theorem ", "private ", "protected ", "partial ", "@[", "/-", "instance",
    "structure ", "inductive ", "namespace ", "end ", "section", "open ", "abbrev ", "noncomputable",
    "unsafe ", "lemma ", "class ", "macro", "syntax", "#", "set_option", "attribute", "public ",
    "meta ", "example", "opaque ", "initialize", "builtin_initialize", "variable", "mutual"]
  let mut out := #[]
  let mut i := start
  while i < src.size do
    let l := src[i]!
    if i > start && !l.startsWith " " && starters.any (fun p => l.startsWith p) then break
    out := out.push (i + 1, l)
    i := i + 1
  return out

def wordIn (line w : String) : Bool := (tokens line).any fun t => t == w || t.endsWith ("." ++ w)

def receiverName : Recv → Option String
  | .name n => some n
  | _ => none

/-- Last component of a dotted name. -/
def lastComponent (n : String) : String := ((n.splitOn ".").getLast?).getD n

/-- A located explanation for one finding. -/
structure Explained where
  why : String
  fix : String
  lines : Array Nat     -- source lines to point at: the update, then the second reference
  matched : Bool        -- the lines were found by text matching
  strength : Nat
  cline : Nat           -- the update's line in the C file
  /-- The recognised cause, for machines (`nested-array-element`, `map-value-reinserted`, ...). -/
  cause : String := ""
  /-- The fix as Lean code with the program's own names: alternatives, each one or more lines. -/
  code : Array String := #[]
  deriving Inhabited

def showLines (ls : Array Nat) : String :=
  match ls.toList with
  | [l] => s!"line {l}"
  | l => "lines " ++ ", ".intercalate (l.map toString)

def code (decl : Array (Nat × String)) (l : Nat) : String :=
  match decl.find? (·.1 == l) with
  | some (_, s) => s!"`{trim ((s.splitOn "--").head!)}`"
  | none => ""

def dedup (xs : Array Nat) : Array Nat := xs.foldl (fun acc x => if acc.contains x then acc else acc.push x) #[]

def dedupS (xs : Array String) : Array String :=
  xs.foldl (fun acc x => if acc.contains x then acc else acc.push x) #[]

/-- `R` when `line` has `R.op … n` (n stored by the operation `opName`). -/
def storedWith (opName : String) (line : String) (n : String) : Option String := Id.run do
  let (suffixes, _) := surface opName
  let ts := tokens line
  for h : i in [0:ts.size] do
    let t := ts[i]
    for suf in suffixes do
      if t.endsWith suf && t != suf && (ts.extract (i + 1) ts.size).contains n then
        return some (dropRightChars t suf.length)
  return none

/-- `C.set! I (C[I]!.op V)` rewritten as `C.modify I (·.op V)`. The element
read must be at the same index, written the same way: `C.set! i (C[j]!.op V)`
updates `C[j]` into slot `i`, which `modify` cannot express, so it has no
rewrite. -/
def modifyRewrite (line : String) : Option String := do
  let t := trim ((line.splitOn "--").head!)
  let (lhs, rhs) := match t.splitOn " := " with
    | [l, r] => (l ++ " := ", r)
    | _ => ("", t)
  let setTok ← [".set! ", ".set "].find? (has rhs ·)
  let c := (rhs.splitOn setTok).head!
  guard (c.toList.all isIdentChar && !c.isEmpty)
  let afterSet := dropChars rhs (c.length + setTok.length)
  let idx := (afterSet.splitOn " (").head!
  let inner := dropChars afterSet (idx.length + 2)
  guard (!idx.isEmpty && inner.startsWith (c ++ "[" ++ idx ++ "]") && inner.endsWith ")")
  let rest := dropChars inner (c.length + idx.length + 2)
  let rest := if rest.startsWith "!" || rest.startsWith "?" then dropChars rest 1 else rest
  guard (rest.startsWith ".")
  return s!"{lhs}{c}.modify {idx} (·{dropRightChars rest 1})"

/-! ### Rewriting source lines into fixes -/

/-- Split at top-level spaces, keeping bracketed groups and string literals whole. -/
def splitTop (s : String) : Array String := Id.run do
  let mut out : Array String := #[]
  let mut cur : List Char := []
  let mut depth : Int := 0
  let mut inStr := false
  for c in s.toList do
    if inStr then
      cur := c :: cur
      if c == '"' then inStr := false
      continue
    if c == '"' then inStr := true
    if c == '(' || c == '[' || c == '{' then depth := depth + 1
    if c == ')' || c == ']' || c == '}' then depth := depth - 1
    if c == ' ' && depth == 0 then
      if !cur.isEmpty then out := out.push (String.ofList cur.reverse)
      cur := []
    else cur := c :: cur
  if !cur.isEmpty then out := out.push (String.ofList cur.reverse)
  return out

def isWordChar (c : Char) : Bool := c.isAlphanum || c == '_' || c == '\'' || c == '?' || c == '!' || c.val > 127

/-- Replace the identifier `w` (not a field `x.w`, not part of a longer name) by `r`. -/
def replaceWord (s w r : String) : String := Id.run do
  let wl := w.toList
  let mut out : List Char := []
  let mut rest := s.toList
  let mut prev : Option Char := none
  while !rest.isEmpty do
    if !wl.isEmpty && rest.take wl.length == wl && !(prev.any fun p => isWordChar p || p == '.') &&
       !((rest.drop wl.length).head?.any isWordChar) then
      out := r.toList.reverse ++ out
      prev := wl.getLast?
      rest := rest.drop wl.length
    else
      out := rest.head! :: out
      prev := rest.head?
      rest := rest.tail
  return String.ofList out.reverse

def countWord (s w : String) : Nat :=
  ((replaceWord s w "\u0001").toList.filter (· == '\u0001')).length

/-- A line without its comment, trimmed. -/
def codeOf (l : String) : String := trim ((l.splitOn "--").head!)

def indentOf (l : String) : String := String.ofList (l.toList.takeWhile (· == ' '))

/-- The code of each line of a declaration: line comments and `/- … -/`
comments (docstrings, across lines) removed, so text matching never takes a
comment for code. -/
def codeLines (decl : Array (Nat × String)) : Array (Nat × String) := Id.run do
  let mut out := #[]
  let mut depth := 0
  for (n, l) in decl do
    let cs := l.toList.toArray
    let mut kept : List Char := []
    let mut i := 0
    while i < cs.size do
      let c := cs[i]!
      let d := cs[i+1]?.getD ' '
      if c == '/' && d == '-' then
        depth := depth + 1; i := i + 2
      else if depth > 0 && c == '-' && d == '/' then
        depth := depth - 1; i := i + 2
      else if depth > 0 then
        i := i + 1
      else if c == '-' && d == '-' then
        break
      else
        kept := c :: kept; i := i + 1
    out := out.push (n, String.ofList kept.reverse)
  return out

/-- A structure update `{ s with … }` on this line of code: a `with` after
an open `{` (not `match … with`, `fun … with` or prose). -/
def isStructUpdate (code : String) : Bool := Id.run do
  let ts := tokens code
  let mut open_ := 0
  for t in ts do
    if t == "{" then open_ := open_ + 1
    else if t == "}" then open_ := open_ - 1
    else if t == "with" && open_ > 0 then return true
  -- `{ s with` written without spaces around the brace
  return (code.splitOn "{").drop 1 |>.any fun r => has ((r.splitOn "}").head!) " with "

/-- The lines that rebuild a structure (`{ s with … }`) worth citing for a
copy of one of its fields: the ones nearest to `near` (the lines updating
the field), at most two; with nothing to anchor them, only when the
declaration has at most two (a long declaration's structure updates are
mostly unrelated to the copy). -/
def keptStructLines (decl : Array (Nat × String)) (near : Array Nat) : Array Nat :=
  let cands := (codeLines decl).filterMap fun (n, c) => if isStructUpdate c then some n else none
  if near.isEmpty then (if cands.size ≤ 2 then cands else #[])
  else
    let dist (n : Nat) := near.foldl (fun m l => min m (if n > l then n - l else l - n)) (n + near.foldl max 0)
    ((cands.qsort fun a b => dist a < dist b).toList.take 2).toArray.qsort (· < ·)

/-- `e` in parentheses unless it already is bracketed. -/
def paren (e : String) : String :=
  if (e.startsWith "(" && e.endsWith ")") || (e.startsWith "{" && e.endsWith "}") then e else s!"({e})"

def unparen (e : String) : String :=
  if e.startsWith "(" && e.endsWith ")" then dropRightChars (dropChars e 1) 1 else e

/-- `M.getD K D`, `M.get! K`, `M.get? K`, `M[K]!`, `M[K]?`: map, key, getter
(`getD`, `get!` or `get?`) and default. -/
def parseMapGet (e : String) : Option (String × String × String × String) := do
  let ws := splitTop (trim e)
  let w0 ← ws[0]?
  for (suf, g) in [(".getD", "getD"), (".findD", "getD"), (".get!", "get!"), (".find!", "get!"),
      (".get?", "get?"), (".find?", "get?")] do
    if w0.endsWith suf && w0 != suf then
      let k ← ws[1]?
      return (dropRightChars w0 suf.length, k, g, if g == "getD" then " ".intercalate (ws.toList.drop 2) else "")
  guard (w0.endsWith "]!" || w0.endsWith "]?")
  let cs := w0.toList
  let i ← cs.findIdx? (· == '[')
  let m := String.ofList (cs.take i)
  guard (!m.isEmpty && m.toList.all isIdentChar)
  return (m, String.ofList (((cs.drop (i + 1)).dropLast).dropLast), if w0.endsWith "!" then "get!" else "get?", "")

/-- A value read out of a map and inserted back, as the source shows it. -/
structure MapUse where
  map : String          -- the map, as written before `.insert` (`groups`, `s.groups`)
  key : String
  value : String        -- the variable bound to the value read
  getter : String       -- `getD`, `get!` or `get?`
  dflt : String
  readLine : Nat
  insertLine : Nat
  pre : String          -- the insert line before the map (`groups := `)
  newValue : String     -- what is inserted back
  deriving Inhabited

/-- Lines reading a map into a variable: `let a := m.getD k d`, `let a := m[k]!`,
`if let some a := m[k]?`, `match m[k]? with | some a => …`. -/
def mapReads (decl : Array (Nat × String)) : Array (Nat × String × String × String × String × String) := Id.run do
  let mut out := #[]
  for h : j in [0:decl.size] do
    let (n, l) := decl[j]
    let t := codeOf l
    let bind : Option (String × String) :=
      if t.startsWith "match " && t.endsWith " with" then
        let e := dropRightChars (dropChars t 6) 5
        -- the variable of the `some` branch
        let v := (decl.extract (j + 1) decl.size).findSome? fun (_, l') =>
          let t' := codeOf l'
          if t'.startsWith "| some " then (splitTop (dropChars t' 7))[0]? else none
        v.map (·, e)
      else
        let t := if t.startsWith "if " then dropChars t 3 else t
        if !t.startsWith "let " then none else
        let t := dropChars t 4
        let t := if t.startsWith "some " then dropChars t 5 else t
        match t.splitOn " := " with
        | lhs :: rest@(_ :: _) =>
          let e := " := ".intercalate rest
          let e := (e.splitOn " | ").head!
          let e := if e.endsWith " then" then dropRightChars e 5 else e
          ((splitTop lhs)[0]?).map (·, e)
        | _ => none
    if let some (v, e) := bind then
      if let some (m, k, g, d) := parseMapGet e then
        out := out.push (n, v, m, k, g, d)
  return out

/-- The first value read out of a map and inserted back into it. -/
def findMapUse (decl : Array (Nat × String)) : Option MapUse := do
  let reads := mapReads decl
  for (rl, v, m, k, g, d) in reads do
    for (il, l) in decl do
      if il ≤ rl then continue
      let t := codeOf l
      let parts := t.splitOn ".insert "
      let some before := parts[0]? | continue
      if parts.length < 2 then continue
      let after := ".insert ".intercalate (parts.drop 1)
      let recvRev := before.toList.reverse.takeWhile isIdentChar
      let recv := String.ofList recvRev.reverse
      if recv.isEmpty || lastComponent recv != lastComponent m then continue
      let ws := splitTop after
      let some key := ws[0]? | continue
      if key != k then continue
      let newValue := " ".intercalate (ws.toList.drop 1)
      if newValue.isEmpty || countWord newValue v == 0 then continue
      return { map := recv, key, value := v, getter := g, dflt := d, readLine := rl, insertLine := il,
               pre := dropRightChars before recv.length, newValue }
  none

/-- The rewrites of a `MapUse` that hand the value over: `alter` (`getD`),
`modify` (`get!`), and erasing the key before updating (all three). -/
def mapRewrites (u : MapUse) : Array String :=
  let erase := s!"{u.pre}({u.map}.erase {u.key}).insert {u.key} {u.newValue}"
  match u.getter with
  | "getD" =>
    let a := u.value ++ "?"
    let body := if countWord u.newValue u.value == 1 then
        s!"some {paren (replaceWord u.newValue u.value s!"({a}.getD {u.dflt})")}"
      else s!"let {u.value} := {a}.getD {u.dflt}; some {paren u.newValue}"
    #[s!"{u.pre}{u.map}.alter {u.key} fun {a} => {body}", erase]
  | "get!" => #[s!"{u.pre}{u.map}.modify {u.key} fun {u.value} => {unparen u.newValue}", erase]
  | _ => #[erase]

/-- `for X in C do` at line `fl`, with `C` updated by the copying operation
inside the loop: (for line, its text, X, C, update line). -/
def loopOverUpdated (decl : Array (Nat × String)) (op : String) :
    Option (Nat × String × String × String × Nat) := do
  for h : j in [0:decl.size] do
    let (fl, l) := decl[j]
    let t := codeOf l
    unless t.startsWith "for " && t.endsWith " do" do continue
    let inner := dropRightChars (dropChars t 4) 3
    let parts := inner.splitOn " in "
    let some x := parts[0]? | continue
    let some c := parts[1]? | continue
    if parts.length != 2 || c.isEmpty || !c.toList.all isIdentChar then continue
    let ind := (indentOf l).length
    -- the loop body: the following lines indented more deeply
    let body := (decl.extract (j + 1) decl.size).toList.takeWhile fun (_, l') =>
      (codeOf l').isEmpty || (indentOf l').length > ind
    if let some (ul, _) := body.find? fun (_, l') => (receivers op l').contains (.name c) then
      return (fl, l, x, c, ul)
  none

/-- An index name not used in the declaration. -/
def freshIndex (decl : Array (Nat × String)) : String :=
  (["i", "j", "k", "idx", "pos"].find? fun n => !decl.any fun (_, l) => (tokens l).contains n).getD "idx"

/-- A global `IO.Ref` or `Std.Mutex` made by `initialize`, used by the
declaration: (name, type, initialize line, initial value, use line, use text). -/
def globalUse (src : Array String) (decl : Array (Nat × String)) :
    Option (String × String × Nat × String × Nat × String) := do
  for h : i in [0:src.size] do
    let t := codeOf src[i]
    let t := if t.startsWith "builtin_initialize " then dropChars t 19
      else if t.startsWith "initialize " then dropChars t 11 else ""
    let parts := t.splitOn " : "
    let some name := parts[0]? | continue
    if parts.length < 2 || name.isEmpty || !name.toList.all isIdentChar then continue
    let rest := " : ".intercalate (parts.drop 1)
    let ty := trim ((rest.splitOn " ← ").head!)
    unless has ty "Ref" || has ty "Mutex" do continue
    let initE := trim (" ← ".intercalate ((rest.splitOn " ← ").drop 1))
    let ws := splitTop initE
    let init := if ws.size == 2 && (ws[0]!.endsWith "mkRef" || ws[0]!.endsWith ".new") then ws[1]! else "…"
    let use := decl.find? fun (_, l) => (tokens l).any fun t => t.startsWith (name ++ ".")
    if let some (ul, ut) := use then
      return (name, ty, i + 1, init, ul, codeOf ut)
  none

/-- `(·.op args)` in `line`, as `buf := buf.op args`. -/
def sectionUpdate (line buf : String) : Option String := do
  let parts := line.splitOn "(·."
  guard (parts.length ≥ 2)
  let after := "(·.".intercalate (parts.drop 1)
  -- up to the matching parenthesis
  let mut depth := 1
  let mut out : List Char := []
  for c in after.toList do
    if c == '(' then depth := depth + 1
    if c == ')' then
      depth := depth - 1
      if depth == 0 then break
    out := c :: out
  guard (depth == 0)
  return s!"{buf} := {buf}.{String.ofList out.reverse}"

/-- Why updates through a global `IO.Ref` or `Std.Mutex` made by `initialize`
copy, and the fix: (why, fix, fix code, source lines), when the declaration
`decl` uses such a global of `src`. -/
def mtGlobalExplained (src : Array String) (decl : Array (Nat × String)) (kind : String) :
    Option (String × String × String × Array Nat) := do
  let (g, ty, il, init, ul, ut) ← globalUse src decl
  let mutex := has ty "Mutex"
  let why := s!"`{g}` is a global `{ty}` made by `initialize` (line {il}): Lean marks what it holds as " ++
    "multi-threaded, because any thread can reach it, and never updates a multi-threaded value in place, " ++
    s!"even when `{g}` holds the only reference. So every update through `{g}` (line {ul}, `{ut}`) copies the " ++
    s!"whole {kind}; `modify`, `take` or `atomically` do not change that."
  let fix := if mutex then
      s!"Collect the updates in a local `let mut` that only this thread sees (updated in place), and merge " ++
      s!"them into `{g}` once, instead of once per update; with several threads, give each its own buffer " ++
      "and merge at the end. (Tested on Lean 4.35 with leanprof's copy counter: no copies per update.)"
    else
      s!"Update a value that only this thread can see, and publish it once: a local `IO.mkRef` (or a " ++
      s!"`let mut`) updated in place, then `{g}.set` when it is complete. If other threads must see every " ++
      "update, give each thread its own buffer and merge them at the end. (Tested on Lean 4.35 with " ++
      "leanprof's copy counter: no copies.)"
  let upd := if mutex then (sectionUpdate ut "buf").getD "buf := …  -- the update, on `buf`"
    else replaceWord ut g "buf"
  let code := if mutex then
      s!"let mut buf := {init}   -- before the loop: private to this thread\n{upd}\n" ++
      s!"{g}.atomically (modify (· ++ buf))   -- after the loop: publish once"
    else
      s!"let buf ← IO.mkRef {init}   -- before the loop: private to this thread\n{upd}\n" ++
      s!"{g}.set (← buf.get)   -- after the loop: publish once"
  return (why, fix, code, dedup #[il, ul])

/-- Code lines of a fix, printed under `fix:`; alternatives separated by `or:`. -/
def codeBlock (code : Array String) : String := Id.run do
  let mut out := ""
  for h : i in [0:code.size] do
    if i > 0 then out := out ++ "       or:\n"
    for l in code[i].splitOn "\n" do
      out := out ++ s!"         {l}\n"
  return out

/-- Fix suggestion and explanation text for a finding, with source lines
found in `decl` (pairs of line number and text). -/
def explainFinding (f : CFun) (fd : Finding) (kind : String) (avgBytes : Float)
    (decl : Array (Nat × String)) (fnText : String := "") : Explained := Id.run do
  let v := display f fd.var
  let op := fd.opName
  let opLines (pred : Recv → Bool) : Array Nat :=
    (codeLines decl).filterMap fun (n, l) => if (receivers op l).any pred then some n else none
  -- `display`'s placeholders ("a temporary": no source names in the C of Lean before 4.30) are not names
  let named (n : String) := !genericNames.contains n && !n.contains ' '
  let base : Explained := { why := "", fix := "", lines := #[], matched := true, strength := fd.strength, cline := fd.op.cline }
  let loop := has fnText "forIn" || has fnText "foldl" || has fnText "fold" || has fnText ".loop"
  -- `for x in xs` over the array the loop updates (in a loop's code)
  let loopFinding? : Option Explained := do
    guard loop
    let (fl, _, x, c, ul) ← loopOverUpdated decl op
    let i := freshIndex decl
    return { base with
      why := s!"`for {x} in {c}` (line {fl}) holds the array the loop started with until the loop ends, so " ++
        s!"the first {op} of `{c}` inside it (line {ul}, {code decl ul}) finds `{c}` shared and copies all of " ++
        "it, once each time the loop runs.",
      fix := s!"Loop over the indices instead: the loop then holds a range, not `{c}`, and every update is in " ++
        s!"place. `{c}[{i}]!` reads the current array, which gives the same values when the body only " ++
        "changes elements it has already visited, or appends.",
      code := #[s!"for {i} in [0:{c}.size] do\n  let {x} := {c}[{i}]!"],
      lines := #[fl, ul], cause := "loop-over-updated-array" }
  match fd.holder with
  | .storedBy u =>
    let target :=
      if u.fn == "lean_ctor_set" then s!"a constructor (a structure, tuple or closure, `{display f u.args[0]!}`)"
      else if (opInfo u.fn).isSome then s!"`{display f u.args[0]!}` ({(opInfo u.fn).get!.2})"
      else s!"a call to `{u.fn}`, which keeps it"
    -- source: the update `X.op …` and a line storing X (`R.push X`, `(…, X)`, `f X`)
    let cands : Array String :=
      if let some n := sourceName fd.var then (if named n then #[n] else #[]) else #[]
    let recvs := decl.foldl (fun acc (_, l) => acc ++ ((receivers op l).filterMap receiverName)) #[]
    let names := if cands.isEmpty then recvs else cands
    let otherArgs := (fd.op.args.toList.drop 1).filterMap sourceName
    let uOp := ((opInfo u.fn).map (·.2)).getD ""
    let mut best : Option (Nat × Nat × Nat × String × String) := none   -- score, update line, store line, name, holder
    for n in dedupS names do
      for (ul, uline) in decl do
        unless (receivers op uline).any (fun r => r == .name n || (receiverName r).any (·.endsWith ("." ++ n))) do continue
        let updScore := 2 + (otherArgs.filter (wordIn uline ·)).length
        for (sl, sline) in decl do
          if sl == ul then continue
          let stored := if uOp.isEmpty then none else storedWith uOp sline n
          let ts := tokens sline
          let asArg := ts.toList.zipIdx.any fun (t, i) => t == n && i > 0 && ts[i+1]? != some ":=" &&
            !(receivers op sline).contains (.name n)
          let storeScore := if stored.isSome then 4 else if asArg then 1 else 0
          if storeScore == 0 then continue
          let score := storeScore + updScore + (if sl < ul then 1 else 0)
          if best.all (·.1 < score) then
            best := some (score, ul, sl, n, stored.getD "")
    match best with
    | some (_, ul, sl, n, into) =>
      let held := if into.isEmpty then target else s!"`{into}`"
      -- `n` only grows by `push` in this declaration: its versions are its prefixes
      let assigns := decl.filterMap fun (_, l) =>
        let ts := tokens l
        (ts.toList.zipIdx.find? fun (t, i) => t == n && ts[i+1]? == some ":=" &&
          !(i > 0 && (ts[i-1]! == "mut" || ts[i-1]! == "let"))).map fun (_, i) => ts[i+2]?.getD ""
      let appendOnly := !into.isEmpty && op.endsWith ".push" && !assigns.isEmpty &&
        assigns.all (· == n ++ ".push")
      let storeLine := ((decl.find? (·.1 == sl)).map (codeOf ·.2)).getD ""
      let general := s!"store `{n}` after its last update, store something smaller than `{n}` (an index, " ++
        "a summary), or, when every version is needed, keep the versions in a persistent structure (`List`, " ++
        s!"`Lean.PersistentArray`) instead of copying `{n}` at each step."
      return { base with
        why := s!"`{n}` is stored in {held} at line {sl} ({code decl sl}) and is updated afterwards at line {ul} " ++
          s!"({code decl ul}): both refer to the same {kind}, so the {op} copies it.",
        fix := if appendOnly then
            s!"`{n}` only grows (by `push`), so each version stored in `{into}` is a prefix of the final " ++
            s!"`{n}`: store its length and rebuild version k as `{n}.extract 0 {into}[k]!` when it is needed. " ++
            "If whole versions must be kept, keep them in a persistent structure (`List`, " ++
            "`Lean.PersistentArray`) instead of copying the array at each step."
          else "Change the order or what is stored: " ++ general,
        code := if appendOnly then #[replaceWord storeLine n s!"{n}.size"] else #[],
        cause := "stored-then-updated",
        lines := #[ul, sl] }
    | none =>
      return { base with
        why := s!"`{v}` is stored in {target} before the {op}, which still needs it, so the update copies it.",
        fix := "Update the value before storing it, or store something smaller.", lines := #[], matched := false, cause := "stored-then-updated" }
  | .inArray c i putBack =>
    let cn := display f c
    -- source lines `C[…]!.op …`, with their containers
    let elems := decl.filterMap fun (n, l) =>
      match (receivers op l).toList.find? (· matches .elem _) with
      | some (.elem k) => if !named cn || k == cn || k.endsWith ("." ++ cn) then some (n, k) else none
      | _ => none
    let ls := elems.map (·.1)
    let shown := if elems.isEmpty then s!"`{cn}[{display f i}]`"
      else ", ".intercalate (elems.toList.map fun (n, k) => s!"`{k}[…]` at line {n}")
    let wb := putBack.isSome || ls.any fun l => (decl.find? (·.1 == l)).any fun (_, s) => has s ".set" || has s ".modify"
    let why := s!"the {kind} updated by {op} is an element read out of an array ({shown}) that still holds it, " ++
      "so the update copies the element" ++ (if wb then " before it is written back with `set`." else ".")
    let rewrites := ls.filterMap fun l => (decl.find? (·.1 == l)).bind fun (_, s) => modifyRewrite s
    let fix := if wb then
        "Use `Array.modify`, which takes the element out of the array before updating it, so the update is " ++
        "in place" ++ (if rewrites.isEmpty then ": `xs := xs.modify i (·.push v)`." else ":")
      else "Take the element out first (`modify`, or `swap` it with an empty value), update it, then put it back."
    let code := if wb then dedupS rewrites else #[]
    return { base with why, fix, code, lines := ls, matched := !ls.isEmpty, cause := "nested-array-element" }
  | .inMap rd putBack =>
    let mapN := display f (rd.args[0]?.getD "")
    let what := match sourceName fd.var with
      | some n => if named n then s!"`{n}`" else s!"the {kind}"
      | none => s!"the {kind}"
    match findMapUse decl with
    | some u =>
      let part := match sourceName fd.var with
        | some n => if named n && n != u.value then s!" (`{n}` is a field of it)" else ""
        | none => ""
      let how := match u.getter with
        | "getD" => "`alter` takes the value out of its bucket before calling the function, so the update is in " ++
          "place; erasing the key before updating also drops the map's reference."
        | "get!" => "`modify` (the key is present, as `get!` assumes) takes the value out of its bucket before " ++
          "calling the function, so the update is in place; erasing the key before updating also drops the " ++
          "map's reference."
        | _ => "erase the key before updating it, so that the map no longer refers to the value and the " ++
          "update is in place."
      return { base with
        why := s!"`{u.value}` is read out of `{u.map}` at line {u.readLine} ({code decl u.readLine}){part}, and the " ++
          s!"map still holds it while the {op} updates it, so the update copies the {kind} before it is inserted " ++
          s!"back at line {u.insertLine} ({code decl u.insertLine}).",
        fix := "Let the map hand over its only reference: " ++ how ++
          s!" ({if u.getter == "get?" then "Tested" else "Both tested"} on Lean 4.35 with leanprof's copy " ++
          "counter: no copies.)",
        code := mapRewrites u, lines := #[u.readLine, u.insertLine], cause := "map-value-reinserted" }
    | none =>
      return { base with
        why := s!"{what} comes out of a hash map (`{mapN}`) that still holds it" ++
          (if putBack.isSome then ", and the result is inserted back" else "") ++
          s!", so the {op} copies the {kind}.",
        fix := "Take the value out of the map before updating it: `m.alter k fun v? => some …` or " ++
          "`m.modify k fun v => …` hand over the map's reference; or `m.erase k` before updating and insert " ++
          "the result back.",
        lines := #[], matched := false, cause := "map-value-reinserted" }
  | .inParent p k kept =>
    -- Lean before 4.30 keeps a loop's variables in one tuple, which the array is then a field of
    if sourceName fd.var |>.isNone then
      if let some e := loopFinding? then return e
    let fname := match sourceName fd.var with
      | some n => n
      | none => s!"field {k}"
    let ls := opLines fun r => match r with
      | .name n => n == fname || n.endsWith ("." ++ fname)
      | _ => false
    let withLines := keptStructLines decl ls
    let keptBy := match kept with
      | some _ => "rebuilt with the same field"
      | none => "kept"
    let why := s!"`{fname}` is a field of a structure (`{display f p}`) that is {keptBy}" ++
      (if withLines.isEmpty then "" else s!" at {showLines withLines} ({code decl withLines[0]!})") ++
      s!", so the structure and the {op} both refer to the {kind}: the update copies it."
    let small := avgBytes > 0 && avgBytes < 256
    let fix :=
      if kind == "String" && op.startsWith "String.append" then
        "The result is a new string while the field keeps the old one, so a copy is needed: this is the cost " ++
        "of building the result" ++ (if small then s!", here {avgBytes.toUInt64} bytes per copy (cheap)." else ".") ++
        " If the field itself should grow in place, take it out of the structure first (set the field to `\"\"`, " ++
        "append, store it back)."
      else s!"Take `{fname}` out of the structure before updating it: set the field to an empty value, " ++
        "update the value you took out, and store it back. `modify fun s => { s with f := s.f.push v }` is " ++
        "in place only when nothing else holds `s`."
    return { base with why, fix, lines := ls ++ withLines, matched := !(ls ++ withLines).isEmpty, cause := "field-of-kept-structure" }
  | .usedAfter u =>
    let ls := match sourceName fd.var with
      | some n => if named n then opLines (· == .name n) else #[]
      | none => #[]
    return { base with
      why := s!"`{v}` is still used after the {op} (C line {u.cline}: `{u.text}`), so the old value must " ++
        "survive and the update copies it.",
      fix := "Do the later read before the update (compute what it needs first), or update a separate value.",
      lines := ls, matched := !ls.isEmpty, cause := "used-after-update" }
  | .inRef r =>
    return { base with
      why := s!"the {kind} was read from an `IO.Ref` (`{display f r}`), which still holds it, so the {op} copies it.",
      fix := "Use `ref.modify (·.push x)` or `ref.modifyGet`: they take the value out of the reference before " ++
        "updating it.",
      lines := opLines fun _ => true, cause := "io-ref-read" }
  | .constant =>
    return { base with
      why := s!"the {kind} is a constant (a literal or closed term); the first {op} copies it.",
      fix := "Usually harmless: it happens once per constant.", lines := opLines fun _ => true, cause := "constant" }
  | .fromCaller p =>
    let pn := display f p
    if has fnText "mapMUnsafe" || has fnText "mapMonoM" || has fnText "Array.mapM" then
      let ls := decl.filterMap fun (n, l) =>
        if (tokens l).any (fun t => t.endsWith ".map" || t.endsWith ".mapM" || t.endsWith ".mapIdx" ||
          t.endsWith ".mapIdxM" || t.endsWith ".filterMap") then some n else none
      return { base with
        why := "`Array.map`/`mapM` writes its results into the input array when nothing else refers to it. " ++
          "Here the input array is still referenced by the caller (typically it is a field of a structure that " ++
          "stays alive, as in `{ s with items := s.items.map f }` with `s` shared or used later), so the first " ++
          "write copies the array: one copy per `map` call, not per element.",
        fix := "Usually fine: one copy costs about as much as building the new array. To map in place, take the " ++
          "array out of its structure first (`let items := s.items; let s := { s with items := #[] }`).",
        lines := ls, matched := !ls.isEmpty, cause := "map-over-shared-array" }
    if let some e := loopFinding? then return e
    let ls := opLines fun r => match r with
      | .name n => n == pn || lastComponent n == pn
      | _ => false
    let why :=
      if loop then s!"nothing in the loop takes another reference to `{v}`: the loop's state (`{pn}`) is shared " ++
        "when it arrives, from where the loop starts (the initial value of a `let mut` that is still referenced " ++
        "elsewhere, such as a structure field or a variable used after the loop) or from the caller."
      else s!"nothing in this function takes another reference to `{v}`: it arrives shared through `{pn}` " ++
        "from the caller."
    return { base with
      why
      fix := "Look for the caller (or the code before the loop) that keeps another reference to the value it " ++
        "passes. `leanprof explain --why EXE` records where the second reference was taken.",
      lines := ls, matched := !ls.isEmpty, cause := "shared-on-entry" }
  | .unknown =>
    let why := s!"the IR shows no second reference to `{v}` in this function."
    return { base with why, lines := #[], cause := "unknown" }

/-! ## Dynamic records (`LEANPROF_WHY=1`) -/

structure ShareRecord where
  copySym : String
  fn : String          -- demangled name of the function that took the reference
  where_ : String      -- its declaration's file:line
  file : String        -- C file and line of the increment
  line : Nat
  count : Nat
  deriving Inhabited

def jstr (j : Json) (k : String) : String := (j.getObjVal? k >>= Json.getStr?).toOption.getD ""
def jnum (j : Json) (k : String) : Float :=
  match j.getObjVal? k with
  | .ok (.num n) => n.toFloat
  | _ => 0
def jarr (j : Json) (k : String) : Array Json := (j.getObjVal? k >>= Json.getArr?).toOption.getD #[]

def loadWhy (path : FilePath) : IO (Array ShareRecord) := do
  unless ← path.pathExists do return #[]
  let some j := (Json.parse (← IO.FS.readFile path)).toOption | return #[]
  return (jarr j "shares").map fun s =>
    { copySym := jstr s "copy_symbol", fn := jstr s "function", where_ := jstr s "where",
      file := jstr s "file", line := (jnum s "line").toUInt64.toNat, count := (jnum s "count").toUInt64.toNat }

/-- Describe the increment at a recorded C line: which variable, and what the
reference is for. -/
def describeShare (cache : IO.Ref CCache) (r : ShareRecord) : IO String := do
  let at_ := if r.where_.isEmpty then "" else s!" ({r.where_})"
  let some f ← funAtLine cache r.file r.line | return s!"in {r.fn}{at_}"
  let some inc := f.stmts.find? (·.cline == r.line) | return s!"in {r.fn}{at_}"
  let some v := inc.args[0]? | return s!"in {r.fn}{at_}"
  let next := f.stmts.find? fun u => u.idx > inc.idx && mentions u v && !isInc u && !isDec u
  let what := match next with
    | some u =>
      if u.fn == "lean_ctor_set" then
        match originOf f v with
        | .field p _ => s!"kept as a field of the structure rebuilt from `{display f p}`"
        | _ => "stored in a constructor (a structure, tuple or closure)"
      else if let some (_, n) := opInfo u.fn then
        if u.args[0]? == some v then
          match originOf f v with
          | .elem c _ _ => s!"taken out of `{display f c}`, which still holds it, for {n}"
          | .field p _ => s!"taken from a structure (`{display f p}`) that keeps it, for {n}"
          | _ => s!"kept while it is updated by {n}"
        else s!"stored in `{display f u.args[0]!}` by {n}"
      else if u.ret then "returned"
      else if u.fn.isEmpty then s!"passed on as `{display f u.lhs}`"
      else s!"passed to `{cDisplay u.fn}`"
    | none => "kept"
  -- the source line, when the variable has a name to look for
  let mut line := ""
  if let some n := sourceName v then
    if let [file, l] := r.where_.splitOn ":" then
      if let some start := l.toNat? then
        if ← (file : FilePath).pathExists then
          let src := ((← IO.FS.readFile file).splitOn "\n").toArray
          let decl := if start > 0 && start ≤ src.size then declLines src (start - 1) else #[]
          let hits := decl.filter fun (_, s) => (tokens s).any fun t => t.endsWith ("." ++ n ++ ".map") ||
            t.endsWith ("." ++ n) || t == n
          if let some (ln, s) := hits[0]? then
            line := s!", line {ln}: `{trim s}`" ++ (if hits.size > 1 then s!" (or {hits.size - 1} more)" else "")
  return s!"`{display f v}` {what} in {r.fn}{at_}{line}"

/-! ## The command -/

structure Opts where
  report : String := ".lake/leanprof/report.json"
  why : String := ".lake/leanprof/why.json"
  out : String := ".lake/leanprof/explain.json"
  top : Nat := 10
  all : Bool := false
  /-- Print the findings as JSON on stdout instead of text. -/
  json : Bool := false
  run : Option String := none
  args : Array String := #[]

partial def parseOpts (o : Opts) : List String → Except String Opts
  | [] => .ok o
  | "--report" :: f :: rest => parseOpts { o with report := f } rest
  | "--top" :: n :: rest => parseOpts { o with top := n.toNat! } rest
  | "--out" :: f :: rest => parseOpts { o with out := f } rest
  | "--all" :: rest => parseOpts { o with all := true } rest
  | "--json" :: rest => parseOpts { o with json := true } rest
  | "--why" :: exe :: rest => parseOpts { o with run := some exe } rest
  | "--" :: rest => .ok { o with args := o.args ++ rest.toArray }
  | a :: _ => .error s!"unknown argument {a}"

def fmtBytes (b : Float) : String :=
  if b < 1024 then s!"{b.toUInt64} B"
  else if b < 1048576 then s!"{(b / 1024).toUInt64} KiB"
  else s!"{(b / 1048576 * 10).round.toUInt64.toNat / 10}.{(b / 1048576 * 10).round.toUInt64.toNat % 10} MiB"

def confidence (e : Explained) : String :=
  let ir := match e.strength with
    | 3 => "high: the IR takes a second reference on every path to the update"
    | 2 => "medium: the IR takes the second reference on some paths only"
    | 1 => "low: the second reference is not taken in this function"
    | _ => "low: no second reference visible in this function (at most when an enclosing structure was itself shared)"
  ir ++ (if e.lines.isEmpty then "; no source line matched"
    else if e.matched then "; source lines matched by text, not positions" else "")

/-- Wrap `s` at `width` columns, indenting continuation lines. -/
def wrap (s : String) (indent : String) (width : Nat := 100) : String := Id.run do
  let lead := String.ofList (s.toList.takeWhile (· == ' '))
  let mut out := lead
  let mut col := lead.length
  let mut first := true
  for w in (dropChars s lead.length).splitOn " " do
    if w.isEmpty then continue
    if !first && col + w.length + 1 > width then
      out := out ++ "\n" ++ indent
      col := indent.length
    else if !first then
      out := out ++ " "; col := col + 1
    out := out ++ w
    col := col + w.length
    first := false
  return out

/-- `x` with two decimals. -/
def fmt2 (x : Float) : String :=
  let v := (x.abs * 100).round.toUInt64.toNat
  s!"{v / 100}.{if v % 100 < 10 then "0" else ""}{v % 100}"

/-- A copy row's time; one too small to measure (`too_small`) is shown as
such, never as 0. -/
def copyTime (c : Json) : String :=
  let small := (jarr c "too_small").any (·.getStr?.toOption == some "copy_ns")
  let ns := jnum c "copy_ns"
  if small then "< 1 clock tick"
  else if ns < 1e3 then s!"{ns.toUInt64} ns"
  else if ns < 1e6 then s!"{fmt2 (ns / 1e3)} µs"
  else s!"{fmt2 (ns / 1e6)} ms"

/-- A share in percent: two decimals below 1%, one above. -/
def fmtPct (p : Float) : String :=
  if p < 1 then s!"{fmt2 p}%"
  else
    let v := (p * 10).round.toUInt64.toNat
    s!"{v / 10}.{v % 10}%"

/-- What a copy row costs, for ranking: its time copying. -/
def copyCost (c : Json) : Float := jnum c "copy_ns"

/-- Explain one copy site of the report: the text to print and the JSON entry
for the editor. -/
def explainSite (cache : IO.Ref CCache) (c : Json) (shares : Array ShareRecord) (runNs : Float := 0) :
    IO (String × Json) := do
  let sym := jstr c "symbol"
  let kind := jstr c "kind"
  let wherePos := jstr c "where"
  let shared := jnum c "shared"
  let mt := jnum c "multi_threaded"
  let persistent := jnum c "persistent"
  let copies := jnum c "copies"
  let avg := if copies > 0 then jnum c "bytes" / copies else 0
  let header := s!"{jstr c "function"}  {if wherePos.isEmpty then "(no position)" else wherePos}\n  " ++
    s!"{kind} copies: {shared.toUInt64} shared" ++ (if mt > 0 then s!", {mt.toUInt64} multi-threaded" else "") ++
    (if persistent > 0 then s!", {persistent.toUInt64} of a constant" else "") ++
    s!"; {fmtBytes (jnum c "bytes")}, {copyTime c} copying" ++
    (if runNs > 0 then s!", {fmtPct (jnum c "copy_ns" / runNs * 100)} of the run" else "")
  let mut out := header ++ "\n"
  let mut entries : Array Json := #[]
  -- source of the declaration
  let (file, line) := match wherePos.splitOn ":" with
    | [p, l] => (p, l.toNat?.getD 0)
    | _ => ("", 0)
  let src ← if !file.isEmpty && (← (file : FilePath).pathExists) then
      pure ((← IO.FS.readFile file).splitOn "\n").toArray else pure #[]
  let decl := if line > 0 && line ≤ src.size then declLines src (line - 1) else #[]
  let site := fun (cause why fix : String) (code : Array String) (lines : Array Nat) (conf : String) (strength : Nat) =>
    Json.mkObj [("symbol", sym), ("function", jstr c "function"), ("scope", jstr c "scope"), ("where", wherePos), ("kind", kind),
      ("cause", cause), ("why", why), ("fix", fix), ("fix_code", Json.arr (code.map toJson)),
      ("file", file), ("lines", Json.arr ((lines.qsort (· < ·)).map toJson)), ("confidence", conf), ("strength", (strength : Json)),
      ("copies", (copies.toUInt64.toNat : Json)), ("shared", (shared.toUInt64.toNat : Json)),
      ("multi_threaded", (mt.toUInt64.toNat : Json)), ("bytes", (jnum c "bytes").toUInt64.toNat),
      ("copy_ns", (jnum c "copy_ns").toUInt64.toNat),
      -- what fixing the site saves at most: the measured time spent copying (plus the copies' allocation)
      ("estimated_cost_ns", (jnum c "copy_ns").toUInt64.toNat)]
  let mut mtGlobal := false
  if mt > 0 && mt * 10 < shared then
    -- a few copies of values that other threads could see: say so, not why all copied
    out := out ++ s!"  ({mt.toUInt64} of the copies were of values shared with other threads; the others are explained below)\n"
  else if mt > 0 then
    match mtGlobalExplained src decl kind with
    | some (why, fix, code, ls) =>
      mtGlobal := true
      out := out ++ wrap s!"  why (multi-threaded): {why}" "       " ++ "\n"
      out := out ++ wrap s!"  fix: {fix}" "       " ++ "\n" ++ codeBlock #[code]
      out := out ++ s!"  where: {file} {showLines ls}\n"
      entries := entries.push (site "multi-threaded-global" why fix #[code] ls
        "high: the copies are counted as multi-threaded; global matched by text" 3)
    | none =>
      let why := "the value was reachable from more than one thread (a `Task` result or argument, a global " ++
        "`IO.Ref`/`Mutex`, or an `initialize` value). Lean marks such values and never updates them in place, " ++
        "even with a single reference."
      let fix := "build the value in the thread that updates it and publish it once, keep per-thread state, or " ++
        "use a structure meant for sharing (`Lean.PersistentArray`, `Std.HashMap` rebuilt per thread)."
      out := out ++ wrap s!"  why (multi-threaded): {why} fix: {fix}" "    " ++ "\n"
      entries := entries.push (site "multi-threaded" why fix #[] #[] "medium: the copies are counted as multi-threaded" 2)
  -- static analysis of the copying function
  let mut staticIncs : Array (String × Nat) := #[]
  -- every copy was of a multi-threaded global, explained above: the IR has nothing to add
  let fn? ← if sym.isEmpty || (mtGlobal && shared == 0) then pure none else findFun cache sym file
  match fn? with
  | none =>
    if mtGlobal && shared == 0 then pure () else
    out := out ++ s!"  no emitted C found for {sym} (precompiled library code is not available)\n"
  | some f =>
    let mut findings := analyzeFun f kind
    -- clang may have inlined a small helper: look one call deep
    if findings.isEmpty then
      for s in f.stmts do
        if (s.fn.startsWith "l_" || s.fn.startsWith "lp_") && s.fn != f.name then
          if let some g ← findFun cache s.fn file then
            findings := findings ++ analyzeFun g kind
    let maxS := findings.foldl (fun m x => max m x.strength) 0
    let shown := findings.filter (·.strength == maxS)
    let shown := if shown.any (!·.holder matches .unknown) then shown.filter (!·.holder matches .unknown) else shown
    let hidden := findings.size - shown.size
    let rel := let r := f.file.toString; if r.startsWith "./" then dropChars r 2 else r
    if shown.isEmpty then
      out := out ++ s!"  no {kind} update found in {f.name} ({rel}); the copy happened in code it calls\n"
    let mut seen : Array String := #[]
    for fd in findings do
      if let some l := fd.incLine then staticIncs := staticIncs.push (rel, l)
    for fd in shown do
      let ex := explainFinding f fd kind avg decl (jstr c "function")
      if seen.contains ex.why then continue
      seen := seen.push ex.why
      let lines := dedup ex.lines
      out := out ++ wrap s!"  why: {ex.why}" "       " ++ "\n"
      unless ex.fix.isEmpty do out := out ++ wrap s!"  fix: {ex.fix}" "       " ++ "\n" ++ codeBlock ex.code
      unless lines.isEmpty do out := out ++ s!"  where: {file} {showLines (lines.qsort (· < ·))}\n"
      out := out ++ s!"  evidence: {rel}:{ex.cline} `{fd.op.text}`" ++
        (match fd.incLine with | some l => s!", second reference at {rel}:{l}" | none => "") ++ "\n"
      out := out ++ s!"  confidence: {confidence { ex with lines }}\n"
      entries := entries.push (site ex.cause ex.why ex.fix ex.code lines (confidence { ex with lines }) ex.strength)
    if hidden > 0 then
      out := out ++ s!"  ({hidden} other update(s) in this function with weaker evidence not shown)\n"
  if persistent > 0 && shared + mt == 0 then
    out := out ++ "  note: every copy was of a constant (a literal, `#[]` from `Array.replicate`, a closed term): " ++
      "harmless unless large.\n"
  else if persistent > 0 then
    out := out ++ wrap (s!"  note: {persistent.toUInt64} copies were of a constant (a literal such as `#[]` or " ++
      "`\"\"`, a closed term, or the shared elements of `Array.replicate n #[]`): the first update of each " ++
      "copies it once, which is expected.") "        " ++ "\n"
  -- dynamic records
  let mine := (shares.filter (·.copySym == sym)).qsort (·.count > ·.count)
  if !mine.isEmpty then
    let cwd := (← IO.currentDir).toString ++ "/"
    let rel (p : String) := if p.startsWith cwd then dropChars p cwd.length else p
    let recorded := mine.foldl (· + ·.count) 0
    out := out ++ s!"  recorded at run time ({recorded} of {(shared).toUInt64} shared copies; where the copied " ++
      "value got its second reference):\n"
    for r in mine.toList.take 3 do
      let same := staticIncs.any fun (file, l) => l == r.line && (r.file.endsWith file || file.endsWith (rel r.file))
      out := out ++ wrap s!"    {r.count}×  {← describeShare cache r}  [{rel r.file}:{r.line}]" "          " ++
        (if same then "\n          (the increment the IR analysis above points to)" else "") ++ "\n"
  -- an `IO.Ref` shared between threads: every value put in it is marked
  -- multi-threaded, so each `modify (·.push x)` copies everything in it
  if mt > 0 && (out.splitOn "lean_st_ref_take").length > 1 then
    out := out ++ wrap ("  the value comes out of an `IO.Ref` that more than one thread uses: `IO.Ref.set` " ++
      "marks what it stores multi-threaded, so every `ref.modify (·.push x)` copies the whole array, " ++
      "quadratic in the number of pushes between drains. fix: cons onto a `List` in the reference " ++
      "(reverse it when draining), or keep a buffer per thread.") "    " ++ "\n"
  return (out, Json.arr entries)

/-- The copy sites of a report that `explain` explains, costliest first (time
copying, then bytes), and how many it leaves out because they copied only
empty or tiny values (`tiny`; `all` keeps them, and copies of constants). -/
def rankedSites (j : Json) (all : Bool := false) : Array Json × Nat :=
  let isTiny (c : Json) := (c.getObjValAs? Bool "tiny").toOption.getD false
  let candidates := (jarr j "copies").filter fun c => all || jnum c "shared" + jnum c "multi_threaded" > 0
  let sites := (candidates.filter fun c => all || !isTiny c).qsort fun a b =>
    if copyCost a != copyCost b then copyCost a > copyCost b else jnum a "bytes" > jnum b "bytes"
  (sites, candidates.size - sites.size)

/-- The findings of the `top` costliest copy sites of the report at `report`,
as `explain --json` prints them (each with its site's `rank`), and how many sites were
left out for copying only empty or tiny values (`all` keeps them, as `explain --all`). -/
def findingsOf (report : String) (top : Nat := 10) (all : Bool := false) : IO (Array Json × Nat) := do
  unless ← (report : FilePath).pathExists do
    throw <| IO.userError s!"no report at {report}: run `leanprof run EXE` first"
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile report))
  if (j.getObjValAs? Bool "sampled").toOption.getD false then
    throw <| IO.userError s!"the report at {report} is from `leanprof sample`, which counts no copies"
  let runNs := if jnum j "run_ns" > 0 then jnum j "run_ns" else jnum j "wall_ns"
  let cache ← IO.mkRef ({} : CCache)
  let mut entries : Array Json := #[]
  let mut rank : Nat := 0
  let (sites, tiny) := rankedSites j all
  for c in sites.toList.take top do
    rank := rank + 1
    let (_, js) ← explainSite cache c #[] runNs
    if let .arr a := js then entries := entries ++ a.map (·.setObjVal! "rank" (rank : Json))
  return (entries, tiny)

def explainCmd (argv : List String) (runLeanprof : Array String → Array (String × Option String) → IO UInt32) :
    IO UInt32 := do
  let o ← IO.ofExcept (parseOpts {} argv)
  if let some exe := o.run then
    -- profile again with the reference-count increments recorded
    let rc ← runLeanprof (#["run", "--json", o.report, exe, "--"] ++ o.args)
      #[("LEANPROF_WHY", some "1"), ("LEANPROF_WHY_JSON", some o.why)]
    if rc != 0 then return rc
  unless ← (o.report : FilePath).pathExists do
    throw <| IO.userError s!"no report at {o.report}: run `leanprof run EXE` first"
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile o.report))
  -- `leanprof sample` writes the same file (for `#leanprof`) without counting copies
  if (j.getObjValAs? Bool "sampled").toOption.getD false then
    throw <| IO.userError (s!"the report at {o.report} is from `leanprof sample`, which counts no copies: " ++
      "run `leanprof run EXE` again, or pass --report FILE with a report of `leanprof run`")
  let shares ← if o.run.isSome || (← (o.why : FilePath).pathExists) then loadWhy o.why else pure #[]
  let (sites, tiny) := rankedSites j o.all
  if sites.isEmpty then
    if o.json then IO.println (Json.mkObj [("schema", Contract.schema "explain"), ("report", o.report), ("sites", 0), ("findings", Json.arr #[]), ("tiny_sites", toJson tiny)]).pretty
    else IO.println ("leanprof explain: the report has no copies of shared values" ++
      (if tiny > 0 then s!" other than {tiny} site(s) of empty or tiny values (--all explains them)" else ""))
    return 0
  let runNs := if jnum j "run_ns" > 0 then jnum j "run_ns" else jnum j "wall_ns"
  let cache ← IO.mkRef ({} : CCache)
  let mut entries : Array Json := #[]
  unless o.json do
    IO.println (s!"leanprof explain: why {min o.top sites.size} of {sites.size} copy sites copied, costliest first " ++
      s!"(from {o.report})" ++
      (if tiny > 0 then s!"; {tiny} site(s) that copied only empty or tiny values not shown (--all)" else "") ++ "\n")
  let mut rank : Nat := 0
  for c in sites.toList.take o.top do
    rank := rank + 1
    let (text, js) ← explainSite cache c shares runNs
    unless o.json do IO.println text
    if let .arr a := js then entries := entries ++ a.map (·.setObjVal! "rank" (rank : Json))
  -- source lines are matched against the files as they are now: a file that
  -- changed since the report may no longer have them where they were
  let mut stale : Array (String × String) := #[]
  for f in (entries.map (jstr · "file")).toList.eraseDups do
    if f.isEmpty then continue
    if let some why ← Contract.staleSource o.report j f then stale := stale.push (f, why)
  entries := entries.map fun e => e.setObjVal! "stale" (Json.bool (stale.any (·.1 == jstr e "file")))
  unless o.json do
    for (f, why) in stale do
      IO.println s!"warning: {f} {why}: the lines above may not be the ones measured (profile again)"
  IO.FS.createDirAll ((o.out : FilePath).parent.getD ".")
  IO.FS.writeFile o.out ((Json.arr entries).compress ++ "\n")
  if o.json then
    IO.println (Json.mkObj [("schema", Contract.schema "explain"), ("report", o.report), ("sites", sites.size),
      ("shown", toJson (min o.top sites.size)), ("tiny_sites", toJson tiny), ("findings", Json.arr entries),
      ("stale_sources", Json.arr (stale.map fun (f, w) => Json.mkObj [("file", Json.str f), ("reason", Json.str w)])),
      ("provenance", (j.getObjVal? "provenance").toOption.getD Json.null)]).pretty
  return 0

end Leanprof.Explain
