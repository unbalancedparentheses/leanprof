import Lean.Data.Json
import Leanprof.Fix
import Leanprof.Experiment
import Leanprof.ElabWhy
import Leanprof.FixElab
import Leanprof.Contract

/-!
# `leanprof fix --elab --project`: project-wide compile-time interventions, checked

`elab --project --counts` records, for every constant, how often the elaborator
and the kernel unfolded it, how often each instance and simp lemma was tried and
used, and in which files and declarations. This module turns that into
**hypotheses**: changes to one declaration that would change work done in many
files (a definition made `@[irreducible]` or `@[reducible]`, an instance at a
lower priority, a `@[simp]` attribute removed, Lean's inferred termination
measures stated, a shortcut instance), each with its evidence.

The evidence is stated for what it is. What the report attributes to a constant
is inclusive and overlaps (unfolding `f` can unfold `g`, and both are charged),
so it is not what the change would save, and per-declaration costs add up to
more than the build's wall time when Lean elaborates in parallel. Candidates are
therefore ranked by exact counts and breadth (files, then the count), never by a
sum of attributed heartbeats, and nothing is projected: each candidate is
applied and measured.

**Verification**: each mechanical candidate becomes one commit on top of HEAD
(git plumbing, the checkout untouched), judged by `leanprof experiment try
--keep-base` against the same base: the build of the package, the
proof-preservation guard on the changed module and every module importing it,
the tests, and the compile heartbeats of those modules (per declaration and per
module). Then the plain `lake build` of those modules is timed in both
worktrees (their build outputs removed first), alternating base and candidate.
The verdict is the experiment's (the heartbeat total of the affected modules
must go down by more than 1% and 1,000), downgraded to INCONCLUSIVE when every
timed candidate build is slower than every base build. A KEEP becomes a commit
with the evidence on a new local branch; nothing is pushed.

The hypotheses and the edits are pure (`hypotheses`, `declKeyword`,
`dropSimpAttr`, `addPriority`, `appendLine`): tested in `Tests/Main.lean`.
-/

namespace Leanprof.ProjectFix
open Lean System
open Leanprof.Explain (jstr jnum jarr trim wrap)
open Leanprof.Fix (capture gitRaw git tailOf)

/-- One project-wide intervention and the evidence for it. -/
structure Candidate where
  /-- `irreducible`, `reducible`, `instance-priority`, `simp-attr`, `termination`, `shortcut-instance` -/
  kind : String
  /-- the constant, or the instance problem -/
  target : String
  /-- `file:line` of its declaration (empty for a batch) -/
  defined : String := ""
  /-- the exact count it is ranked by, and what that counts -/
  count : Nat := 0
  countWhat : String := ""
  /-- in how many files, and at how many sites, the work was observed -/
  files : Nat := 0
  sites : Nat := 0
  /-- what the report attributes to it: inclusive and overlapping, not a saving -/
  amount : Float := 0
  observed : Array String := #[]
  suggested : String := ""
  /-- declarations (`file:line name`) where it was observed, at most 8 -/
  decls : Array String := #[]
  fileList : Array String := #[]
  /-- empty: mechanical; else why it is a hypothesis only -/
  notMechanical : String := ""
  /-- for `termination`: the edits -/
  edits : Array FixElab.SimpEdit := #[]
  deriving Inhabited

def Candidate.mechanical (c : Candidate) : Bool := c.notMechanical.isEmpty

/-- Thresholds for a hypothesis: work seen in at least `minFiles` files and counted
at least `minCount` times. -/
def minFiles : Nat := 2
def minCount : Nat := 10

/-- A name Lean generated (`_proof_1`, `match_2`, `eq_1`, `_sizeOf_1`, private names):
no source to edit. -/
def generatedName (n : String) : Bool :=
  (n.splitOn ".").any fun p => p.startsWith "_" || p.startsWith "match_" || p.startsWith "proof_" ||
    p.startsWith "eq_" || p == "eq_def" || p.startsWith "«"

def plural (n : Nat) (w : String) : String := s!"{n} {w}{if n == 1 then "" else "s"}"

def natOf (j : Json) (k : String) : Nat := (jnum j k).toUInt64.toNat

/-- The declarations (`file:line name`) whose lines are among `keys`, from the
report's scopes, at most `n`. -/
def declsAt (scopes : Array Json) (keys : Array String) (n : Nat := 8) : Array String := Id.run do
  let mut out := #[]
  for sc in scopes do
    if out.size ≥ n then break
    let p := jstr sc "pos"
    if keys.contains p then
      let name := ((jstr sc "key").splitOn " ").drop 1 |> " ".intercalate
      out := out.push s!"{p} {if name.isEmpty then String.ofList ((jstr sc "name").toList.take 60) else name}"
  return out

/-- Whether `name` occurs in `text` as a whole name (not inside a longer one). -/
def mentions (text name : String) : Bool :=
  let parts := text.splitOn name
  parts.length > 1 && (List.range (parts.length - 1)).any fun i =>
    let before := (parts[i]!).toList.getLast?.getD ' '
    let after := (parts[i + 1]!).toList.head?.getD ' '
    let isName (c : Char) := c.isAlphanum || c == '_' || c == '.' || c == '\''
    !isName before && !isName after

/-- The candidates an `elab --project` report supports, ranked: by the number of
files the work was observed in, then by the exact count. `inProject f` says
whether a source file (relative to the package) belongs to the package. -/
def hypotheses (r : Json) (inProject : String → Bool) (declares : String → String → Bool := fun _ _ => true) :
    Array Candidate := Id.run do
  let hb := jstr r "unit" == "heartbeats"
  let amt (x : Float) := ElabWhy.fmtAmt hb x
  let scopes := jarr r "scopes"
  let overlap := "inclusive and overlapping: it contains the work under it, which other constants are charged too; not what the change would save"
  -- names mentioned by failed instance searches, by file
  let failed : Array (String × String) := scopes.flatMap fun sc =>
    (jarr sc "instances_failed").map fun f => ((ElabWhy.splitPos (jstr sc "pos")).1, jstr f "problem")
  let mut out : Array Candidate := #[]
  for c in jarr r "constants" do
    let name := jstr c "name"
    let wh := jstr c "where"
    let file := (ElabWhy.splitPos wh).1
    if name.isEmpty || file.isEmpty || !inProject file || generatedName name then continue
    -- `diagnostics` prints names relative to the namespaces open where they were used
    -- (`Affine` for `WeierstrassCurve.Affine`): the report located such a name by the one
    -- declaration of the profiled files whose name ends so, and edits use that name
    let bySuffix := (c.getObjValAs? Bool "located_by_suffix").toOption.getD false
    let printed := name
    let name := if bySuffix then jstr c "declared_as" else name
    if name.isEmpty then continue
    -- the source there must declare it (`declares`: the file's text at that line); a name
    -- found by its end must not be `protected` (Lean never prints those by their end alone)
    unless declares wh (if bySuffix then printed else name) do continue
    let suffixNote := if bySuffix then
        #[s!"`diagnostics` names it `{printed}` (relative to an open namespace); the one declaration of the profiled files whose name ends so is `{name}`"]
      else #[]
    let files := natOf c "files"
    let sites := natOf c "sites"
    let keys := (jarr c "site_keys").filterMap (·.getStr?.toOption)
    let fileList := (jarr c "site_files").map (jstr · "file")
    let decls := declsAt scopes keys
    let where_ := s!"from {plural sites "site"} in {plural files "file"}"
    let kind := jstr c "kind"
    let base : Candidate := {
      kind := "", target := name, defined := wh, files := files, sites := sites, amount := jnum c "amount",
      decls := decls, fileList := fileList }
    let attributed := suffixNote ++
      (if jnum c "amount" > 0 then #[s!"the report attributes {amt (jnum c "amount")} to it ({overlap})"] else #[])
    -- definitions unfolded across files
    let unfolds := natOf c "unfolds"
    let kernel := natOf c "kernel"
    if (kind == "unfold" || kind == "whnf" || unfolds > 0) && files ≥ minFiles && unfolds + kernel ≥ minCount then
      let failedIn := (failed.filter fun (_, p) => mentions p name).map (·.1)
      let failedFiles := (failedIn.toList.eraseDups).length
      let counted := s!"the elaborator unfolded it {unfolds}× and the kernel {kernel}× (`diagnostics`, exact), {where_}"
      if failedFiles ≥ minFiles then
        out := out.push { base with
          kind := "reducible", count := failedIn.size, countWhat := "failed instance searches naming it"
          observed := #[s!"{failedIn.size} instance searches that failed name it, in {failedFiles} files: instance search sees through reducible definitions only", counted] ++ attributed
          suggested := s!"`attribute [reducible] {name}` at the end of {file}, so instance search in the modules importing it can unfold it" }
      else
        out := out.push { base with
          kind := "irreducible", count := unfolds + kernel, countWhat := "unfoldings (elaborator and kernel)"
          observed := #[counted] ++ attributed
          suggested := s!"`attribute [irreducible] {name}` at the end of {file}: the modules importing it no longer unfold it while unifying (its own file is unchanged); proofs that need its definition then say so (`unfold {name}`, `simp [{name}]`). Lean's `{name}.eq_def` is the unfold lemma" }
    -- instances tried across files, rarely used
    let used := natOf c "instances"
    let tried := natOf c "count"
    if kind == "instance" && files ≥ minFiles && tried ≥ minCount && used * 2 < tried then
      out := out.push { base with
        kind := "instance-priority", count := tried, countWhat := "times tried"
        observed := #[s!"tried {tried}× {where_}, used {used}× (`diagnostics`)"] ++ attributed
        suggested := s!"`instance (priority := low)` for {name}, so instance search tries the others first" }
    -- simp lemmas tried often, rarely used
    let sTried := natOf c "simp_tried"
    let sUsed := natOf c "simp_used"
    if sTried ≥ minCount && files ≥ minFiles && sUsed * 10 ≤ sTried then
      out := out.push { base with
        kind := "simp-attr", count := sTried - sUsed, countWhat := "failed simp attempts"
        observed := #[s!"`simp` tried it {sTried}× and used it {sUsed}× (`diagnostics`, exact), {where_}"] ++ attributed
        suggested := s!"remove `simp` from its attributes: every `simp` stops trying it; " ++
          (if sUsed == 0 then "no call in this profile used it" else s!"the {sUsed} uses then need it named (`simp [{name}]`)") }
  -- Lean's inferred termination measures, all at once
  let terms := (FixElab.editsOf r).filter fun e => e.kind == "termination" && inProject e.file
  unless terms.isEmpty do
    let files := (terms.toList.map (·.file)).eraseDups
    let runs := (jarr r "repeated").filter fun x => jstr x "op" == "decreasing_tactic" || jstr x "op" == "[Elab.step] decreasing_tactic"
    out := out.push {
      kind := "termination", target := s!"{terms.size} recursive declarations", count := terms.size,
      countWhat := "declarations whose measure Lean searched for", files := files.length, sites := terms.size,
      amount := terms.foldl (· + ·.amount) 0, fileList := files.toArray, edits := terms
      decls := (terms.toList.take 8).toArray.map fun e => s!"{e.file}:{e.line} {e.key}"
      observed := #[s!"{terms.size} declarations without `termination_by` in {plural files.length "file"}: Lean tries measures until one works, running `decreasing_tactic` for each"] ++
        (runs.toList.take 1).toArray.map (fun x => s!"`decreasing_tactic` ran {natOf x "count"}× in {plural (natOf x "files") "file"} in all") ++
        #[s!"their `decreasing_tactic` calls cost {amt (terms.foldl (· + ·.amount) 0)} (each declaration's own; these do not overlap one another)"]
      suggested := "state each measure Lean found (`showInferredTerminationBy`) after its declaration" }
  -- instance problems solved again and again across files
  for x in jarr r "repeated" do
    unless jstr x "class" == "Meta.synthInstance" do continue
    let files := natOf x "files"
    let n := natOf x "count"
    if files < minFiles || n < minCount then continue
    let byFile := jarr x "by_file"
    out := out.push {
      kind := "shortcut-instance", target := jstr x "op", count := n, countWhat := "instance searches",
      files, sites := n, amount := jnum x "total", fileList := byFile.map (jstr · "file")
      observed := #[s!"the search `{jstr x "op"}` ran {n}× in {files} files, first at {jstr x "first_at"}",
        s!"the report attributes {amt (jnum x "total")} to these searches ({overlap})"]
      suggested := s!"a shortcut instance `instance : {jstr x "op"} := inferInstance` in a module all {files} files import"
      notMechanical := "where to declare it is a choice for a person; a new instance can also change the terms statements elaborate to, which the proof-preservation guard compares" }
  return out.qsort fun a b => a.files > b.files || (a.files == b.files && (a.count > b.count ||
    (a.count == b.count && (a.kind < b.kind || (a.kind == b.kind && a.target < b.target)))))

/-! ## The edits (pure) -/

def declKeywords : List String :=
  ["def", "abbrev", "theorem", "lemma", "instance", "structure", "class", "inductive", "opaque", "axiom", "example"]

/-- Commands that are not declarations. -/
def stopWords : List String :=
  ["namespace", "section", "end", "open", "variable", "universe", "set_option", "import", "module", "attribute",
   "mutual", "export", "#check", "#eval", "deriving"]

/-- The keyword of the declaration that starts on `line` (from 1) and the line it is on:
the first token among `declKeywords` in the lines from there (at most 15), past its doc
comment and attributes. -/
def declKeyword (lines : Array String) (line : Nat) : Option (String × Nat) := Id.run do
  let mut inComment := false
  for i in [line - 1:min lines.size (line + 14)] do
    let t := trim lines[i]!
    if inComment then
      if (t.splitOn "-/").length > 1 then inComment := false
      continue
    if t.startsWith "--" then continue
    if t.startsWith "/-" then
      unless ((t.drop 2).toString.splitOn "-/").length > 1 do inComment := true
      continue
    -- attributes on the line: skip what is inside `@[...]`
    let mut depth := 0
    let mut word : List Char := []
    let mut words : Array String := #[]
    for ch in (t ++ " ").toList do
      if ch == '[' then depth := depth + 1
      if ch == ']' && depth > 0 then depth := depth - 1
      if ch.isWhitespace || ch == '(' || ch == ':' then
        unless word.isEmpty do words := words.push (String.ofList word.reverse)
        word := []
      else if depth == 0 && ch != ']' then word := ch :: word
    for w in words do
      if declKeywords.contains w then return some (w, i + 1)
    -- `variable (x) in`, `open Foo in`, `set_option o v in`: the same command goes on
    if t.endsWith " in" then continue
    -- another command, or a blank line: the declaration does not start on `line`
    if t.isEmpty || (words[0]?.any stopWords.contains) || (t.startsWith "public section") ||
        (t.startsWith "noncomputable section") then
      return none
  return none

/-- Whether the declaration on `line` declares `name`: the identifier after its keyword is
`name` or the end of it (`Foo.bar` in `namespace Foo`), or it is an `instance` with none. -/
def declares (lines : Array String) (line : Nat) (name : String) : Bool := Id.run do
  let some (kw, i) := declKeyword lines line | return false
  -- a protected declaration is printed with its namespace: a one-part name is another constant
  if (name.splitOn ".").length == 1 && ((lines.extract (line - 1) i).toList.any fun l => (l.splitOn "protected ").length > 1) then
    return false
  let ws := ((lines[i - 1]!.splitOn kw).drop 1 |> kw.intercalate).splitOn " " |>.filter (· != "")
  let id := (ws.head?.getD "").replace "_root_." ""
  let named := !id.isEmpty && !id.startsWith "(" && !id.startsWith ":" && !id.startsWith "[" && !id.startsWith "{"
  if kw == "instance" && !named then return true
  return named && (name == id || name.endsWith ("." ++ id))

/-- The lines with `simp` taken out of the declaration's attribute list `@[...]` (on the
lines from `line` to the keyword's line); `@[simp]` alone goes entirely. -/
def dropSimpAttr (lines : Array String) (line : Nat) : Option (Array String) := do
  let (_, kw) ← declKeyword lines line
  let mut found : Option (Array String) := none
  for i in [line - 1:kw] do
    if found.isSome then break
    let l := lines[i]!
    let parts := l.splitOn "@["
    if parts.length != 2 then continue
    let rest := parts[1]!
    let inner := (rest.splitOn "]").head!
    if (inner.splitOn "[").length > 1 || (inner.splitOn "(").length > 1 then continue
    let items := (inner.splitOn ",").map trim
    unless items.contains "simp" do continue
    let kept := items.filter (· != "simp")
    let after := ((rest.splitOn "]").drop 1 |> "]".intercalate)
    let newLine := if kept.isEmpty then
        let a := String.ofList (after.toList.dropWhile (· == ' '))
        let pre := parts[0]!
        if (trim (pre ++ a)).isEmpty then "" else pre ++ a
      else s!"{parts[0]!}@[{", ".intercalate kept}]{after}"
    -- an attribute line of its own that becomes empty is removed
    if (trim newLine).isEmpty then
      found := some (lines.extract 0 i ++ lines.extract (i + 1) lines.size)
    else found := some (lines.set! i newLine)
  found

/-- The lines with `instance` of the declaration on `line` at `(priority := low)`;
none if it has a priority already. -/
def addPriority (lines : Array String) (line : Nat) : Option (Array String) := do
  let (kw, i) ← declKeyword lines line
  guard (kw == "instance")
  let l := lines[i - 1]!
  guard ((l.splitOn "priority").length == 1)
  let parts := l.splitOn "instance"
  -- the first `instance` that is a whole word
  let k ← (List.range (parts.length - 1)).find? fun j =>
    let before := (parts[j]!).toList.getLast?.getD ' '
    let after := (parts[j + 1]!).toList.head?.getD ' '
    (before == ' ' || before == ']') && (after == ' ' || after == '\n')
  let newLine := "instance".intercalate (parts.take (k + 1)) ++ "instance (priority := low)" ++
    "instance".intercalate (parts.drop (k + 1))
  return lines.set! (i - 1) newLine

/-- `src` with `line` added at its end, on a line of its own. -/
def appendLine (src line : String) : String :=
  (if src.endsWith "\n" || src.isEmpty then src else src ++ "\n") ++ line ++ "\n"

/-- The new contents of the files a mechanical candidate changes (path relative to the
package ↦ text), given the current text of a file. -/
def editsFor (c : Candidate) (read : String → IO String) : IO (Except String (Array (String × String))) := do
  let (file, line) := ElabWhy.splitPos c.defined
  match c.kind with
  | "irreducible" | "reducible" =>
    let src ← read file
    match declKeyword (src.splitOn "\n").toArray line with
    | some ("abbrev", _) =>
      return .error s!"{c.target} is an `abbrev` (reducible already): Lean does not make it {c.kind} by an attribute"
    | some ("def", i) | some ("opaque", i) =>
      let ls := (src.splitOn "\n").toArray
      -- `@[reducible]` (or `@[irreducible]`) on the declaration already
      let attrs := " ".intercalate ((ls.extract (line - 1) i).toList)
      if (attrs.splitOn "@[reducible").length > 1 || (attrs.splitOn "@[irreducible").length > 1 then
        return .error s!"{c.target} has a reducibility attribute already"
      return .ok #[(file, appendLine src s!"attribute [{c.kind}] {c.target}")]
    | some (k, _) => return .error s!"{c.target} is declared with `{k}`, not `def`"
    | none => return .error s!"no declaration found at {c.defined}"
  | "instance-priority" =>
    let src ← read file
    match addPriority (src.splitOn "\n").toArray line with
    | some ls => return .ok #[(file, "\n".intercalate ls.toList)]
    | none => return .error s!"no `instance` without a priority at {c.defined}"
  | "simp-attr" =>
    let src ← read file
    match dropSimpAttr (src.splitOn "\n").toArray line with
    | some ls => return .ok #[(file, "\n".intercalate ls.toList)]
    | none => return .error s!"no `@[simp]` in the declaration at {c.defined} (an `attribute [simp]` elsewhere is not edited)"
  | "termination" =>
    let files := (c.edits.toList.map (·.file)).eraseDups
    let mut out := #[]
    for f in files do
      match FixElab.applyEdits (← read f) (c.edits.filter (·.file == f)) with
      | .ok t => out := out.push (f, t)
      | .error e => return .error e
    return .ok out
  | k => return .error s!"`{k}` is not applied mechanically"

/-! ## Measuring -/

def median (xs : Array Float) : Float :=
  let s := xs.qsort (· < ·)
  if s.isEmpty then 0 else if s.size % 2 == 1 then s[s.size / 2]! else (s[s.size / 2 - 1]! + s[s.size / 2]!) / 2

/-- The plain build times compared: `worse` when every candidate build was slower than
every base build and the median by more than 2%, `better` the other way round; with fewer
than 3 builds a side, not judged. -/
def buildTimeVerdict (b c : Array Float) : String :=
  if b.isEmpty || c.isEmpty then "not measured"
  else if b.size < 3 || c.size < 3 then "too few runs to judge"
  else
    let (bmin, bmax) := (b.foldl min b[0]!, b.foldl max b[0]!)
    let (cmin, cmax) := (c.foldl min c[0]!, c.foldl max c[0]!)
    if cmin > bmax && median c > median b * 1.02 then "worse"
    else if cmax < bmin && median c < median b * 0.98 then "better"
    else "within noise"

def loadAvg : IO String := do
  let out ← capture "sysctl" #["-n", "vm.loadavg"] (stop := false)
  if out.exitCode == 0 then return trim ((trim out.stdout).replace "{" "" |>.replace "}" "")
  try return trim (← IO.FS.readFile "/proc/loadavg") catch _ => return "?"

/-- The build outputs of module `m` in `dir` (so that `lake build m` rebuilds it). -/
def removeOutputs (dir : FilePath) (m : String) : IO Unit := do
  let rel := m.replace "." "/"
  let stem := (rel.splitOn "/").getLast!
  for sub in [dir / ".lake" / "build" / "lib" / "lean", dir / ".lake" / "build" / "ir"] do
    let parent := (sub / rel).parent.getD sub
    unless ← parent.pathExists do continue
    for e in ← parent.readDir do
      if e.fileName.startsWith (stem ++ ".") then
        unless ← e.path.isDir do IO.FS.removeFile e.path

/-- The fcntl lock other timing runs on the machine hold, as a command prefix. The wrapper
times the command itself once it holds the lock (the wait is not the build's time) and
prints `leanprof-elapsed SECONDS` last on stderr. -/
def lockedCmd (lock : Option String) (cmd : String) (args : Array String) : String × Array String :=
  match lock with
  | none => (cmd, args)
  | some l => ("python3", #["-c",
      "import fcntl,os,subprocess,sys,time\nf=open(os.path.expanduser(sys.argv[1]),'w')\nfcntl.flock(f,fcntl.LOCK_EX)\n" ++
      "t=time.monotonic()\nr=subprocess.call(sys.argv[2:])\nsys.stderr.write('\\nleanprof-elapsed %.6f\\n' % (time.monotonic()-t))\nsys.exit(r)",
      l, cmd] ++ args)

/-- The seconds the lock wrapper measured (`leanprof-elapsed S` on stderr). -/
def lockedElapsed (stderr : String) : Option Float :=
  ((stderr.splitOn "\n").reverse.find? (·.startsWith "leanprof-elapsed ")).bind fun l =>
    let n := (l.drop 17).toString
    match n.splitOn "." with
    | [i, f] => do
      let a ← i.toNat?
      let b ← f.toNat?
      return a.toFloat + b.toFloat / (10 : Float) ^ f.length.toFloat
    | [i] => i.toNat?.map (·.toFloat)
    | _ => none

/-- One timed plain `lake build` of `mods` in `dir`, their outputs removed first. -/
def timeBuild (lock : Option String) (dir : FilePath) (mods : Array String) : IO (Except String Float) := do
  for m in mods do removeOutputs dir m
  -- what the modules import is built already: only `mods` are rebuilt
  let (cmd, args) := lockedCmd lock "lake" (#["build"] ++ mods)
  let t0 ← IO.monoNanosNow
  let out ← capture cmd args (cwd := dir)
  let t := ((← IO.monoNanosNow) - t0).toFloat / 1e9
  if out.exitCode != 0 then return .error (tailOf (out.stdout ++ out.stderr))
  return .ok ((if lock.isSome then lockedElapsed out.stderr else none).getD t)

/-- Per module (file) totals of an `elab` report. -/
def moduleTotals (path : FilePath) : IO (Std.HashMap String Float) := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  return (jarr j "files").foldl (fun m f => m.insert (jstr f "file") (jnum f "total_ns")) {}

/-- Changes of more than 1% and 1,000 heartbeats between two keyed maps: (key, before, after),
largest first. -/
def moved (b n : Std.HashMap String Float) (up : Bool) : Array (String × Float × Float) :=
  let keys := (b.toList.map (·.1) ++ n.toList.map (·.1)).eraseDups.toArray
  let xs := keys.filterMap fun k =>
    let x := b.getD k 0
    let y := n.getD k 0
    if (if up then y - x else x - y) > max (x * 0.01) 1000 then some (k, x, y) else none
  xs.qsort fun a b => (a.2.2 - a.2.1).abs > (b.2.2 - b.2.1).abs || ((a.2.2 - a.2.1).abs == (b.2.2 - b.2.1).abs && a.1 < b.1)

/-! ## The command -/

structure Opts where
  report : Option String := none
  top : Nat := 5
  only : Array Nat := #[]
  dryRun : Bool := false
  test : Option String := none
  noTest : Bool := false
  buildRuns : Nat := 3
  jobs : Option String := none
  lock : Option String := none
  out : String := ".lake/leanprof/fix/project-fixes.json"
  json : Bool := false

partial def parseOpts (o : Opts) : List String → Except String Opts
  | [] => .ok o
  | "--report" :: f :: rest => parseOpts { o with report := some f } rest
  | "--top" :: n :: rest => match n.toNat? with
    | some k => parseOpts { o with top := max 1 k } rest
    | none => .error "--top takes a number"
  | "--only" :: ns :: rest =>
    let xs := (ns.splitOn ",").filterMap fun x => (trim x).toNat?
    if xs.isEmpty then .error "--only takes candidate numbers: 1,3" else parseOpts { o with only := xs.toArray } rest
  | "--dry-run" :: rest => parseOpts { o with dryRun := true } rest
  | "--test" :: c :: rest => parseOpts { o with test := some c } rest
  | "--no-test" :: rest => parseOpts { o with noTest := true } rest
  | "--build-runs" :: n :: rest => match n.toNat? with
    | some k => parseOpts { o with buildRuns := k } rest
    | none => .error "--build-runs takes a number"
  | "--jobs" :: n :: rest => parseOpts { o with jobs := some n } rest
  | "--lock" :: f :: rest => parseOpts { o with lock := some f } rest
  | "--out" :: f :: rest => parseOpts { o with out := f } rest
  | "--json" :: rest => parseOpts { o with json := true } rest
  | a :: _ => .error s!"unknown argument {a} (fix --elab --project)"

def candJson (i : Nat) (c : Candidate) : List (String × Json) :=
  [("rank", toJson i), ("kind", Json.str c.kind), ("target", Json.str c.target), ("defined", Json.str c.defined),
   ("count", toJson c.count), ("count_what", Json.str c.countWhat), ("files", toJson c.files), ("sites", toJson c.sites),
   ("attributed", toJson c.amount), ("attributed_note", Json.str "inclusive and overlapping; not a saving"),
   ("observed", toJson c.observed), ("suggested", Json.str c.suggested), ("declarations", toJson c.decls),
   ("in_files", toJson c.fileList), ("mechanical", Json.bool c.mechanical),
   ("not_mechanical", Json.str c.notMechanical)]

def printCandidate (i : Nat) (c : Candidate) (shared : String) : IO Unit := do
  IO.println s!"\n  {i}. {c.kind}  {c.target}{if c.defined.isEmpty then "" else s!"  ({c.defined})"}"
  IO.println s!"     ranked by: {plural c.files "file"}, {c.count} {c.countWhat}"
  for x in c.observed do IO.println (wrap s!"     observed   {x}" "                ")
  unless c.decls.isEmpty do
    IO.println (wrap s!"     observed   in {", ".intercalate (c.decls.toList.take 5)}{if c.decls.size > 5 then ", ..." else ""}" "                ")
  unless shared.isEmpty do IO.println (wrap s!"     overlap    {shared}" "                ")
  IO.println (wrap s!"     suggested  {c.suggested}{if c.mechanical then " [mechanical]" else ""}" "                ")
  unless c.mechanical do IO.println (wrap s!"     not tried  {c.notMechanical}" "                ")

/-- The body of `leanprof fix --elab --project`: writes `o.out` as it goes. -/
def fixProjectBody (o : Opts) (runSelf : Array String → FilePath → IO IO.Process.Output) : IO UInt32 := do
  let dir : FilePath := ".lake" / "leanprof" / "fix"
  IO.FS.createDirAll dir
  let logPath := dir / "project-log.txt"
  IO.FS.writeFile logPath ""
  let log (title : String) (out : IO.Process.Output) : IO Unit := do
    let h ← IO.FS.Handle.mk logPath .append
    h.putStr s!"== {title} (exit code {out.exitCode})\n{out.stdout}{out.stderr}\n"
  let cwd ← IO.currentDir
  unless o.dryRun do
    unless (← gitRaw #["rev-parse", "--is-inside-work-tree"]).exitCode == 0 do
      throw <| IO.userError "not in a git repository: fix --elab --project commits each kept change on a new branch (--dry-run only lists them)"
    let dirty ← git #["status", "--porcelain", "--untracked-files=no"]
    unless dirty.isEmpty do
      throw <| IO.userError s!"the working tree has uncommitted changes; commit or stash them first:\n{dirty}"
  let report ← match o.report with
    | some r => pure r
    | none => do
      let out := dir / "project.json"
      IO.println "leanprof fix --elab --project: profiling the package (leanprof elab --project --heartbeats --counts --why)"
      let r ← runSelf (#["elab", "--project", "--heartbeats", "--counts", "--why", "--out", out.toString] ++
        (match o.jobs with | some j => #["--jobs", j] | none => #[])) cwd
      log "leanprof elab --project" r
      unless r.exitCode == 0 && (← out.pathExists) do
        IO.eprintln s!"leanprof fix --elab --project: `leanprof elab --project` failed (exit code {r.exitCode}):\n{tailOf (r.stdout ++ r.stderr)}"
        return 2
      pure out.toString
  let r ← IO.ofExcept (Json.parse (← IO.FS.readFile report))
  unless (r.getObjValAs? Bool "project").toOption.getD false do
    IO.println s!"leanprof fix --elab --project: note: {report} is not a project report; cross-file evidence needs `elab --project`"
  unless (r.getObjValAs? Bool "counts").toOption.getD false do
    IO.println s!"leanprof fix --elab --project: note: {report} was made without --counts: no exact unfold, instance or simp counts"
  unless (r.getObjValAs? Bool "complete").toOption.getD true do
    IO.println s!"leanprof fix --elab --project: note: the profile stopped at an error in some file; what follows it is not counted"
  let inProject (f : String) : Bool := !f.startsWith "/" && !f.startsWith ".lake/" && f.endsWith ".lean"
  let mut known : Std.HashSet String := {}
  for f in (jarr r "files").map (jstr · "file") do known := known.insert f
  -- the package's sources, read once each
  let mut sources : Std.HashMap String (Array String) := {}
  for f in known.toList do
    if inProject f then
      if let some t ← (try some <$> IO.FS.readFile f catch _ => pure none) then
        sources := sources.insert f (t.splitOn "\n").toArray
  let srcs := sources
  let cands := hypotheses r (fun f => inProject f && known.contains f) fun wh name =>
    let (f, l) := ElabWhy.splitPos wh
    (srcs.get? f).any (declares · l name)
  -- a candidate whose edit cannot be made (an `abbrev` made irreducible) is a hypothesis only
  let readRel (f : String) : IO String := IO.FS.readFile f
  let cands ← cands.mapM fun c => do
    unless c.mechanical do return c
    match ← editsFor c readRel with
    | .ok _ => return c
    | .error e => return { c with notMechanical := e }
  IO.println s!"leanprof fix --elab --project: {cands.size} candidate(s) from {report}"
  IO.println ("  ranked by the files the work was seen in, then its exact count. The heartbeats a constant is " ++
    "charged overlap (inclusive costs, and CPU totals of parallel elaboration exceed wall time): they are evidence, not savings.")
  -- the files two candidates share
  let sharedText (i : Nat) : String := Id.run do
    let c := cands[i]!
    let mut best := (0, 0)
    for h : j in [0:cands.size] do
      if j == i then continue
      let n := (c.fileList.filter cands[j].fileList.contains).size
      if n > best.1 then best := (n, j + 1)
    if best.1 == 0 then "" else s!"{best.1} of its files also show #{best.2} ({cands[best.2 - 1]!.kind} {String.ofList (cands[best.2 - 1]!.target.toList.take 50)}): their effects may overlap"
  for h : i in [0:cands.size] do
    if i ≥ 25 then
      IO.println s!"\n  ... {cands.size - 25} more in {o.out}"; break
    printCandidate (i + 1) cands[i] (sharedText i)
  -- which to try
  let chosen : Array Nat := if !o.only.isEmpty then o.only.filter (fun k => k ≥ 1 && k ≤ cands.size) |>.map (· - 1)
    else ((List.range cands.size).filter (cands[·]!.mechanical) |>.take o.top).toArray
  let mut results : Array Json := #[]
  let writeOut (results : Array Json) : IO Unit := do
    if let some p := (o.out : FilePath).parent then IO.FS.createDirAll p
    IO.FS.writeFile o.out ((Json.mkObj [("schema", Contract.schema "fix-project"), ("leanprof", Json.str "fix-project"),
      ("dry_run", Json.bool o.dryRun),
      ("report", Json.str report), ("ranking", Json.str "files where the work was observed, then the exact count; attributed heartbeats overlap and are not savings"),
      ("candidates", Json.arr ((cands.toList.zipIdx.map fun (c, i) => Json.mkObj (candJson (i + 1) c)).toArray)),
      ("tried", Json.arr results)]).pretty ++ "\n")
  if chosen.isEmpty then
    writeOut #[]
    IO.println "\nleanprof fix --elab --project: no mechanical candidate to try"
    return 1
  if o.dryRun then
    for k in chosen do
      let c := cands[k]!
      match ← editsFor c readRel with
      | .error e => IO.println s!"\n#{k + 1} {c.kind} {c.target}: not applicable: {e}"
      | .ok files =>
        IO.println s!"\n#{k + 1} {c.kind} {c.target}:"
        if c.kind == "termination" then
          for f in ((c.edits.toList.map (·.file)).eraseDups : List String) do
            let a := ((← IO.FS.readFile (f : String)).splitOn "\n").toArray
            IO.println (Fix.unifiedDiff f a ((c.edits.filter (·.file == f)).map (FixElab.lineEdit a)))
          continue
        for (f, t) in files do
          let a := ((← IO.FS.readFile f).splitOn "\n").toArray
          let b := (t.splitOn "\n").toArray
          -- one hunk: the lines from the first difference to the last
          let pre := (List.range (min a.size b.size)).find? (fun i => a[i]! != b[i]!) |>.getD (min a.size b.size)
          let suf := (List.range (min a.size b.size - pre)).find? (fun i => a[a.size - 1 - i]! != b[b.size - 1 - i]!) |>.getD (min a.size b.size - pre)
          IO.println s!"--- a/{f}\n+++ b/{f}\n@@ -{pre + 1} +{pre + 1} @@"
          for x in a.extract pre (a.size - suf) do IO.println s!"-{x}"
          for x in b.extract pre (b.size - suf) do IO.println s!"+{x}"
    writeOut #[]
    return 0
  -- the experiment: one base (HEAD), each candidate judged against it
  let top : FilePath ← IO.FS.realPath (← git #["rev-parse", "--show-toplevel"])
  let pre ← git #["rev-parse", "--show-prefix"]
  let head ← git #["rev-parse", "HEAD"]
  let id := s!"fix-project-{(← IO.monoNanosNow) / 1000000}"
  IO.println s!"\nleanprof fix --elab --project: trying {chosen.size} candidate(s) with `leanprof experiment` ({id}), each against {head.take 12}"
  let st ← runSelf (#["experiment", "start", "--id", id] ++
    (if o.noTest then #["--no-test"] else match o.test with | some t => #["--test", t] | none => #[])) cwd
  log "leanprof experiment start" st
  unless st.exitCode == 0 do
    IO.eprintln s!"leanprof fix --elab --project: `leanprof experiment start` failed:\n{tailOf (st.stdout ++ st.stderr)}"
    return 2
  let expDir := Experiment.experimentsDir cwd / id
  let bdir := Experiment.under (expDir / "base") pre
  let cdir := Experiment.under (expDir / "candidate") pre
  let mut kept := 0
  let mut summary : Array String := #[]
  for k in chosen do
    let c := cands[k]!
    IO.println s!"\n#{k + 1} {c.kind} {c.target}"
    let base := candJson (k + 1) c
    let files ← match ← editsFor c readRel with
      | .ok f => pure f
      | .error e =>
        IO.println s!"  not applicable: {e}"
        results := results.push (Json.mkObj (base ++ [("verdict", Json.str "NOT_APPLICABLE"), ("reasons", toJson #[e])]))
        summary := summary.push s!"  #{k + 1} {c.kind} {c.target}: not applicable"
        continue
    let rel := files.map fun (f, t) => (pre ++ f, t)
    let cand ← FixElab.commitFiles top dir rel s!"leanprof fix --elab --project: {c.kind} {c.target} (candidate)"
    let tr ← runSelf #["experiment", "try", cand, "--json", "--keep-base", "--id", id] cwd
    log s!"leanprof experiment try ({c.kind} {c.target})" tr
    let ev := (Json.parse tr.stdout).toOption.getD Json.null
    let mut verdict := if (jstr ev "verdict").isEmpty then "ERROR" else jstr ev "verdict"
    let mut outcome := if (jstr ev "outcome").isEmpty then "measurement_failed" else jstr ev "outcome"
    let mut reasons := ((ev.getObjVal? "reasons" >>= Json.getArr?).toOption.getD #[]).filterMap (·.getStr?.toOption)
    if verdict == "ERROR" && reasons.isEmpty then reasons := #[tailOf (tr.stdout ++ tr.stderr) 6]
    let hbStep := (ev.getObjVal? "heartbeats").toOption.getD Json.null
    let guard := (ev.getObjVal? "guard").toOption.getD Json.null
    let modules := (jarr guard "modules").filterMap (·.getStr?.toOption)
    let mut extra : List (String × Json) := [("evidence", ev), ("modules", toJson modules)]
    -- per module and per declaration, from the two heartbeat profiles
    let bRep := jstr hbStep "base_report"
    let cRep := jstr hbStep "candidate_report"
    if !bRep.isEmpty && !cRep.isEmpty then
      let bm ← moduleTotals bRep
      let cm ← moduleTotals cRep
      let bd ← Experiment.heartbeatsOf bRep
      let cd ← Experiment.heartbeatsOf cRep
      let (bt, ct) := (Experiment.hbTotal bd, Experiment.hbTotal cd)
      let dearer := moved bd cd true
      let cheaper := moved bd cd false
      let mDearer := moved bm cm true
      let mCheaper := moved bm cm false
      let row (x : String × Float × Float) := Json.mkObj [("key", Json.str x.1), ("base", toJson x.2.1), ("candidate", toJson x.2.2)]
      extra := extra ++ [("heartbeats_base", toJson bt), ("heartbeats_candidate", toJson ct),
        ("modules_dearer", Json.arr (mDearer.map row)), ("modules_cheaper", Json.arr (mCheaper.map row)),
        ("declarations_dearer", Json.arr (dearer.map row)), ("declarations_cheaper", toJson cheaper.size),
        ("declarations_cheaper_top", Json.arr ((cheaper.toList.take 10).toArray.map row))]
      let pct := if bt > 0 then (ct - bt) / bt * 100 else 0
      IO.println s!"  heartbeats {ElabWhy.fmtAmt true bt} -> {ElabWhy.fmtAmt true ct} ({if pct ≥ 0 then "+" else ""}{Judge.fmt2 pct}%) in {bm.size} module(s): {mCheaper.size} cheaper, {mDearer.size} dearer; declarations: {cheaper.size} cheaper, {dearer.size} dearer"
      for (key, x, y) in dearer.toList.take 5 do
        IO.println s!"    dearer  {key}: {ElabWhy.fmtAmt true x} -> {ElabWhy.fmtAmt true y}"
      for (key, x, y) in cheaper.toList.take 3 do
        IO.println s!"    cheaper {key}: {ElabWhy.fmtAmt true x} -> {ElabWhy.fmtAmt true y}"
    -- the plain build of the affected modules, timed in both worktrees
    let built := (← (ev.getObjVal? "build" >>= (·.getObjValAs? Bool "ok")).toOption.getD false |> pure)
    if built && o.buildRuns > 0 && !modules.isEmpty && (← cdir.pathExists) && (← bdir.pathExists) then
      let load0 ← loadAvg
      let mut bs : Array Float := #[]
      let mut cs : Array Float := #[]
      let mut err : Option String := none
      for i in [0:o.buildRuns] do
        -- ABBA order: drift on the machine hits both sides alike
        let order := if i % 2 == 0 then [true, false] else [false, true]
        for isBase in order do
          match ← timeBuild o.lock (if isBase then bdir else cdir) modules with
          | .ok t => if isBase then bs := bs.push t else cs := cs.push t
          | .error e => err := some e
      let load1 ← loadAvg
      let tv := buildTimeVerdict bs cs
      extra := extra ++ [("build_seconds_base", toJson bs), ("build_seconds_candidate", toJson cs),
        ("build_time", Json.str tv), ("load_avg", toJson #[load0, load1])]
      if let some e := err then extra := extra ++ [("build_time_error", Json.str e)]
      IO.println s!"  plain lake build of {modules.size} module(s): median {Judge.fmt2 (median bs)} s -> {Judge.fmt2 (median cs)} s ({bs.size} runs each, {tv}; load {load0} / {load1})"
      if verdict == "KEEP" && tv == "worse" then
        verdict := "INCONCLUSIVE"
        outcome := "insufficient_evidence"
        reasons := reasons.push "the heartbeats went down, but every timed build of the candidate was slower than every build of the base"
    -- a build that fails: Lean's errors, which Lake prints before its last lines
    if reasons.any (·.startsWith "it does not build") || reasons.any (·.startsWith "a module that imports the change does not build") then
      let p := expDir / "tries" / toString (jnum ev "try").toUInt64 / "log.txt"
      let logText ← if ← p.pathExists then IO.FS.readFile p else pure ""
      let errs := (logText.splitOn "\n").filter fun l => ((trim l).startsWith "error:") && !((trim l).startsWith "error: build failed")
      unless errs.isEmpty do
        -- Lake's last lines (which modules built) say less than Lean's errors
        reasons := reasons.map fun r => if r.startsWith "it does not build" || r.startsWith "a module that imports the change"
          then (r.splitOn "\n").head! else r
        reasons := reasons ++ ((errs.eraseDups.take 3).toArray.map fun l => s!"Lean: {String.ofList ((trim l).toList.take 300)}")
    IO.println s!"  {verdict}"
    (← IO.getStdout).flush
    for x in reasons.toList.take 4 do IO.println (wrap s!"  - {String.ofList (x.toList.take 600)}" "    ")
    let mut branch := ""
    if verdict == "KEEP" then
      let short := ((c.target.splitOn ".").getLast!.replace " " "-").toList.filter (fun ch => ch.isAlphanum || ch == '-' || ch == '_') |> String.ofList
      let stem := if c.kind == "termination" then "leanprof-fix/project-termination" else s!"leanprof-fix/project-{c.kind}-{short}"
      branch := stem
      let mut n := 2
      while (← gitRaw #["rev-parse", "--verify", "--quiet", s!"refs/heads/{branch}"]).exitCode == 0 do
        branch := s!"{stem}-{n}"; n := n + 1
      let msg := s!"{c.kind}: {c.target}\n\n{c.suggested}\n\nEvidence (elab --project --counts):\n" ++
        "\n".intercalate (c.observed.toList.map ("  " ++ ·)) ++
        s!"\n\nleanprof fix --elab --project, checked by leanprof experiment {id} (try {(jnum ev "try").toUInt64}): KEEP against {head.take 12}\n" ++
        s!"  build      ok\n  guard      {jstr guard "status"}: {modules.size} module(s) audited\n" ++
        s!"  heartbeats {ElabWhy.fmtAmt true (jnum hbStep "base_total")} -> {ElabWhy.fmtAmt true (jnum hbStep "candidate_total")} in the changed modules and their dependents\n" ++
        "\n".intercalate (reasons.toList.map ("- " ++ ·)) ++ "\n"
      let msgFile := dir / "message.txt"
      IO.FS.writeFile msgFile msg
      let tree ← git #["rev-parse", s!"{cand}^\{tree}"]
      let sha ← git #["commit-tree", tree, "-p", head, "-F", msgFile.toString]
      discard <| git #["branch", branch, sha]
      kept := kept + 1
      IO.println s!"  committed {sha.take 12} on branch {branch}"
    results := results.push (Json.mkObj (base ++ [("verdict", Json.str verdict), ("outcome", Json.str outcome), ("reasons", toJson reasons),
      ("candidate_commit", Json.str cand), ("branch", Json.str branch)] ++ extra))
    summary := summary.push s!"  #{k + 1} {c.kind} {c.target}: {verdict}{if branch.isEmpty then "" else s!" ({branch})"}"
    writeOut results
  Experiment.removeWorktree (expDir / "base")
  Experiment.removeWorktree (expDir / "candidate")
  writeOut results
  IO.println s!"\nleanprof fix --elab --project: {kept} of {chosen.size} kept; your checkout is unchanged."
  for s in summary do IO.println s
  IO.println s!"  evidence: {o.out}; log: {logPath}"
  return if kept > 0 then 0 else 1

/-- `leanprof fix --elab --project`: the evidence in `.lake/leanprof/fix/project-fixes.json`
(`--out`; schemas/fix-project.schema.json), also after an error, with its `status` and
`exit_code`; `--json` prints it, with the steps on stderr. -/
def fixProjectCmd (argv : List String) (runSelf : Array String → FilePath → IO IO.Process.Output) : IO UInt32 := do
  let o ← IO.ofExcept (parseOpts {} argv)
  let out ← IO.getStdout
  if o.json then discard <| IO.setStdout (← IO.getStderr)
  let finish (rc : UInt32) (err : Option String) : IO Json := do
    if o.json then discard <| IO.setStdout out
    let prev := match ← (try some <$> IO.FS.readFile o.out catch _ => pure none) with
      | some t => (Json.parse t).toOption.getD (Json.mkObj [])
      | none => Json.mkObj []
    let prev := if (prev.getObjValAs? String "leanprof").toOption == some "fix-project" then prev
      else Json.mkObj [("schema", Contract.schema "fix-project"), ("leanprof", Json.str "fix-project"),
        ("dry_run", Json.bool o.dryRun), ("candidates", Json.arr #[]), ("tried", Json.arr #[])]
    let tried := (prev.getObjValD "tried").getArr?.toOption.getD #[]
    let status := if err.isSome then "error" else if o.dryRun && rc == 0 then "dry_run"
      else if tried.any (jstr · "verdict" == "KEEP") then "kept"
      else if tried.isEmpty then "nothing_to_try" else "none_kept"
    let j := (prev.setObjVal! "exit_code" (toJson rc.toNat)).setObjVal! "status" (Json.str status)
    let j := match err with | some e => j.setObjVal! "error" (Json.str e) | none => j
    if let some p := (o.out : FilePath).parent then IO.FS.createDirAll p
    IO.FS.writeFile o.out (j.pretty ++ "\n")
    if o.json then IO.println j.pretty
    return j
  -- a document from an earlier run must not pass for this one's
  if ← (o.out : FilePath).pathExists then IO.FS.removeFile o.out
  let rc ← try fixProjectBody o runSelf
    catch e =>
      discard <| finish 2 (some (toString e))
      throw e
  discard <| finish rc none
  return rc

end Leanprof.ProjectFix
