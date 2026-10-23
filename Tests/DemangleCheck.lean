import Lean.Compiler.NameDemangling
import Lean.Data.Json
import Leanprof.Core

/-!
# `demangle-check`: leanprof's demangler against Lean's

```
cd PROJECT && /path/to/leanprof/.lake/build/bin/demangle-check [--show N] BINARY...
```

For every `l_`/`lp_` symbol of each binary (from `nm`), compares
`Leanprof.demangle` (the C demangler the reports use) with Lean's own
`Lean.Name.Demangle.demangleSymbol`, after mapping Lean's output to the form
leanprof intends to print (flags, packages and compiler parts dropped,
`g (in f)` for specializations; the mapping is documented in
docs/guide/how-it-works.md). Compiler parts (`isCompilerPart`) are cut from
the first one on; other components starting with `_` are user names
(`Foo._bar`) and are kept, as Lean keeps them. Names are printed like
`Name.toString` (`Foo.«weird name»`), which is also how `.ilean` files key
declarations.

The package of an `lp_` symbol is ambiguous (`lean_x2dcompiler_x2dbackend_Foo`
could be package `lean` and `x2dcompiler...`); Lean takes the shortest split,
which is wrong for packages with escapes. Like leanprof, this uses the
packages in `lake-manifest.json` of the current directory first, and Lean's
rule otherwise. Run it from the project's directory.

Exits 1 if any symbol mismatches.
-/

open Lean

/-- Split `cs` at occurrences of `sep` outside `«»`. -/
partial def splitTop (cs : List Char) (sep : List Char) : List (List Char) :=
  go cs 0 [] []
where
  go : List Char → Nat → List Char → List (List Char) → List (List Char)
    | [], _, cur, acc => (acc.cons cur.reverse).reverse
    | c :: rest, d, cur, acc =>
      if c == '«' then go rest (d + 1) (c :: cur) acc
      else if c == '»' then go rest (d - 1) (c :: cur) acc
      else if d == 0 && sep.isPrefixOf (c :: rest) then
        go ((c :: rest).drop sep.length) d [] (cur.reverse :: acc)
      else go rest d (c :: cur) acc

def flagWords : List String := ["arity↓", "boxed", "impl", "λ", "jp", "closed", "private"]

/-- Drop a trailing ` [flag, ...]` group. -/
def dropFlags (cs : List Char) : List Char :=
  let parts := splitTop cs ['[']
  match parts.getLast? with
  | some last =>
    if cs.getLast? != some ']' || parts.length < 2 then cs else
    if ((String.ofList last.dropLast).splitOn ", ").all (flagWords.contains ·) then
      ((parts.dropLast.intersperse ['[']).flatten.reverse.dropWhile (· == ' ')).reverse
    else cs
  | none => cs

def compilerPrefixes : List String :=
  ["_lam", "_elam", "_closed", "_boxed", "_redArg", "_impl", "_jp", "_override", "_spec",
   "_unsafe_rec", "_regBuiltin", "_auto", "_private"]

def isCompilerPart (s : String) : Bool := compilerPrefixes.any (s.startsWith ·)

/-- Lean strips `_private.<Module>.0.` only at the start of a name. -/
partial def dropPrivate : List (List Char) → List (List Char)
  | [] => []
  | c :: cs =>
    if c == "_private".toList then
      match cs.dropWhile (· != ['0']) with
      | _ :: after@(_ :: _) => dropPrivate after
      | _ => c :: dropPrivate cs
    else c :: dropPrivate cs

/-- Keep the components before the first compiler part. -/
def cutCompiler (cs : List Char) : List Char :=
  let comps := splitTop cs ['.']
  match comps with
  | [] => cs
  | first :: rest =>
    let kept := first :: (dropPrivate rest).takeWhile (fun c => !isCompilerPart (String.ofList c))
    (kept.intersperse ['.']).flatten

/-- Lean's demangled form mapped to what leanprof should print. -/
def normalize (lean : String) : String :=
  let pieces := (splitTop lean.toList " spec at ".toList).map (fun p => cutCompiler (dropFlags p))
  match pieces with
  | base :: ctx :: _ => s!"{String.ofList ctx} (in {String.ofList base})"
  | [base] => String.ofList base
  | [] => lean

/-- `String.Internal.mangle` of the packages in `lake-manifest.json`, longest first. -/
def manifestPackages : IO (Array String) := do
  let some txt ← (some <$> IO.FS.readFile "lake-manifest.json") <|> pure none | return #[]
  let some j := (Json.parse txt).toOption | return #[]
  let unescape (s : String) : String :=
    if s.startsWith "«" && s.endsWith "»" then ((s.drop 1).dropEnd 1).toString else s
  let mut names : Array String := #[]
  if let .ok n := j.getObjValAs? String "name" then names := names.push (unescape n)
  if let .ok (ps : Array Json) := j.getObjValAs? (Array Json) "packages" then
    for p in ps do
      if let .ok n := p.getObjValAs? String "name" then names := names.push (unescape n)
  let mangled := names.map String.Internal.mangle
  return mangled.qsort (fun a b => a.length > b.length)

/-- Lean's rule for `lp_` symbols: the first split whose package is one
mangled component and whose body is a mangled name. -/
def leanSplit (s : String) : Option String := Id.run do
  let cs := s.toList
  for i in [1:cs.length] do
    if cs[i]! == '_' && i + 1 < cs.length then
      let pkg := String.ofList (cs.take i)
      let body := String.ofList (cs.drop (i + 1))
      let validPkg := match Name.demangle? pkg with
        | some (.str .anonymous _) => true
        | _ => false
      if validPkg && (Name.demangle? body).isSome then return some body
  return none

/-- Lean's demangler drops everything from a macro scope `_@` on, including
a specialization's caller (`f._@.M._hyg.2._at_.g.spec_4` is just `f`).
Remove the scopes (`_@` up to the numbers after `_hyg`) before asking it. -/
def withoutMacroScopes (body : String) : String := Id.run do
  let n := Name.demangle body
  let comps := n.componentsRev.reverse
  if !comps.any (· == .str .anonymous "_@") then return body
  let mut out : Name := .anonymous
  let mut inScope := false
  let mut afterHyg := false
  for c in comps do
    match c with
    | .str .anonymous s =>
      if afterHyg then inScope := false; afterHyg := false
      if s == "_@" then inScope := true
      else if inScope && s == "_hyg" then afterHyg := true
      else if !inScope then out := out.str s
    | .num .anonymous k =>
      if !inScope then out := out.num k
    | _ => pure ()
  return (out.mangle "")

/-- What leanprof should print for a symbol, with Lean's raw output. -/
def expected (pkgs : Array String) (sym : String) : Option (String × String) := do
  let s := if sym.startsWith "_" && (sym.startsWith "_l_" || sym.startsWith "_lp_") then (sym.drop 1).toString else sym
  -- `f.cold.1`, `f.isra.0`, `f.llvm.42`: parts of `f` the C compiler split off
  let s := (s.splitOn ".").headD s
  let body ← if s.startsWith "l_" then some (s.drop 2).toString
    else if s.startsWith "lp_" then
      let rest := (s.drop 3).toString
      match pkgs.find? (fun p => rest.startsWith (p ++ "_")) with
      | some p => some (rest.drop (p.length + 1)).toString
      | none => leanSplit rest
    else none
  if body.isEmpty then none
  let lean ← Lean.Name.Demangle.demangleSymbol ("l_" ++ withoutMacroScopes body)
  return (normalize lean, lean)

def symbols (bin : String) : IO (Array String) := do
  let out ← IO.Process.output { cmd := "nm", args := #[bin] }
  if out.exitCode != 0 then throw <| IO.userError s!"nm {bin} failed: {out.stderr}"
  let mut r := #[]
  for line in out.stdout.splitOn "\n" do
    match (line.splitOn " ").getLast? with
    | some w =>
      if w.startsWith "l_" || w.startsWith "lp_" || w.startsWith "_l_" || w.startsWith "_lp_" then r := r.push w
    | none => pure ()
  return r

def main (args : List String) : IO UInt32 := do
  let mut limit := 20
  let mut bins : Array String := #[]
  let mut rest := args
  while !rest.isEmpty do
    match rest with
    | "--show" :: n :: t => limit := n.toNat!; rest := t
    | b :: t => bins := bins.push b; rest := t
    | [] => pure ()
  if bins.isEmpty then
    IO.eprintln "usage: demangle-check [--show N] BINARY...  (run from the project directory)"
    return 2
  let pkgs ← manifestPackages
  let mut failures := 0
  for bin in bins do
    let syms := (← symbols bin).qsort (· < ·)
    let mut checked := 0
    let mut skipped := 0
    let mut bad := 0
    let mut prev := ""
    for sym in syms do
      if sym == prev then continue
      prev := sym
      match expected pkgs sym with
      | none => skipped := skipped + 1
      | some (want, lean) =>
        checked := checked + 1
        let got := Leanprof.demangle sym
        if got != want then
          bad := bad + 1
          if bad ≤ limit then
            IO.println s!"MISMATCH {sym}\n  leanprof: {got}\n  expected: {want}\n  lean:     {lean}"
    IO.println s!"{bin}: {checked} symbols checked, {bad} mismatches, {skipped} skipped"
    failures := failures + bad
  return if failures == 0 then 0 else 1
