import Lean.Data.Json
import Leanprof.Fix
import Leanprof.Experiment
import Leanprof.ElabWhy

/-!
# `leanprof fix --elab`: compile-time fixes, applied and checked

`leanprof elab --why` records, for each `simp` call, Lean's own list of the
lemmas it used (`tactic.simp.trace`, what `simp?` prints) and the call's
whole source range. Replacing `simp` by `simp only [those lemmas]` is
mechanical, and whether it helps is measurable exactly: the proof must
still check and the heartbeats must go down.

`fix --elab` takes the costliest such calls, writes the edits as one commit
on top of HEAD (git plumbing with a separate index: the checkout is not
touched), and judges that commit with `leanprof experiment` (library mode):
the build of the package (the proofs are checked again), the
proof-preservation guard on the changed modules and their dependents, the
tests, and the compile heartbeats of those modules (exact). An edit that
makes its file fail to build, or its declaration dearer, is dropped and the
rest tried again (at most `--rounds` times). A KEEP becomes a commit with
the evidence in its message on a new local branch; nothing is pushed.

The edits are pure (`applyEdits`, `errorPositions`, `blame`): tested in
`Tests/Main.lean`.
-/

namespace Leanprof.FixElab
open Lean System
open Leanprof.Explain (jstr jnum jarr trim wrap has)
open Leanprof.Fix (capture gitRaw git tailOf shellQuote)

/-- One `simp` call to replace: where (lines from 1, columns from 0, in
characters, as Lean's messages give them), the call as written, the
replacement, and what it cost. -/
structure SimpEdit where
  file : String
  line : Nat
  col : Nat
  endLine : Nat
  endCol : Nat
  original : String
  replacement : String
  amount : Float
  /-- the `compare` key of the declaration it is in (`file name`) -/
  key : String := ""
  deriving Inhabited, Repr

def SimpEdit.range (e : SimpEdit) : String := s!"{e.file}:{e.line}:{e.col + 1}-{e.endLine}:{e.endCol + 1}"

/-- The edits of an `elab --why` report's `simp_suggestions` that can be applied
mechanically (`not_applicable` empty), costliest first, each with the key of the
declaration it is in. -/
def editsOf (r : Json) : Array SimpEdit := Id.run do
  let scopes := jarr r "scopes"
  let keyOf (file : String) (line : Nat) : String := Id.run do
    let mut best := 0
    let mut key := ""
    for sc in scopes do
      let (f, l) := ElabWhy.splitPos (jstr sc "pos")
      if f == file && l ≤ line && l ≥ best then
        best := l
        key := jstr sc "key"
    return key
  let mut out := #[]
  for s in jarr r "simp_suggestions" do
    unless (jstr s "not_applicable").isEmpty do continue
    let some (f, l, c, el, ec) := ElabWhy.splitRange (jstr s "range") | continue
    if c == 0 || ec == 0 then continue
    out := out.push {
      file := f, line := l, col := c - 1, endLine := el, endCol := ec - 1
      original := jstr s "original", replacement := jstr s "suggestion", amount := jnum s "amount"
      key := keyOf f l }
  return out.qsort fun a b => a.amount > b.amount || (a.amount == b.amount && a.range < b.range)

/-- `src` (a file's text) with `edits` (all in that file, not overlapping) applied: each
range must still hold its `original` text. The replacement is laid out within 100
columns (`ElabWhy.layout`). -/
def applyEdits (src : String) (edits : Array SimpEdit) : Except String String := do
  let mut lines := (src.splitOn "\n").toArray
  -- from the last edit up, so the positions of the others stay valid
  let es := edits.qsort fun a b => a.line > b.line || (a.line == b.line && a.col > b.col)
  for e in es do
    let at_ (i : Nat) : List Char := (lines[i - 1]?.getD "").toList
    if e.line == 0 || e.endLine < e.line || e.endLine > lines.size then
      throw s!"{e.range}: outside the file"
    let pre := String.ofList ((at_ e.line).take e.col)
    let post := String.ofList ((at_ e.endLine).drop e.endCol)
    let cur := if e.line == e.endLine then String.ofList (((at_ e.line).drop e.col).take (e.endCol - e.col))
      else "\n".intercalate ([String.ofList ((at_ e.line).drop e.col)] ++
        (List.range (e.endLine - e.line - 1)).map (fun k => String.ofList (at_ (e.line + 1 + k))) ++
        [String.ofList ((at_ e.endLine).take e.endCol)])
    unless cur == e.original do
      throw s!"{e.range}: the source is no longer `{e.original}` (it reads `{cur}`): profile again"
    let text := pre ++ ElabWhy.layout e.replacement e.col ++ post
    lines := lines.extract 0 (e.line - 1) ++ (text.splitOn "\n").toArray ++ lines.extract e.endLine lines.size
  return "\n".intercalate lines.toList

/-- `e` as an edit of whole lines (`Fix.Edit`), for a diff: the lines it touches
and what they become. -/
def lineEdit (lines : Array String) (e : SimpEdit) : Fix.Edit :=
  let at_ (i : Nat) : List Char := (lines[i - 1]?.getD "").toList
  let text := String.ofList ((at_ e.line).take e.col) ++ ElabWhy.layout e.replacement e.col ++
    String.ofList ((at_ e.endLine).drop e.endCol)
  { first := e.line, count := e.endLine - e.line + 1, lines := (text.splitOn "\n").toArray }

/-- The source positions (`File.lean:12:4`) a build log names: (path, line). -/
def errorPositions (log : String) : Array (String × Nat) := Id.run do
  let mut out := #[]
  for w in (log.splitOn "\n").flatMap (·.splitOn " ") do
    let parts := w.splitOn ":"
    if parts.length < 3 then continue
    let some i := (List.range parts.length).find? fun i => (parts[i]!).endsWith ".lean" | continue
    let some l := parts[i + 1]? |>.bind (·.toNat?) | continue
    -- `././Foo/Bar.lean` as `Foo/Bar.lean`
    let path := ":".intercalate (parts.take (i + 1))
    let path := String.ofList (path.toList.dropWhile fun c => c == '.' || c == '/')
    unless out.contains (path, l) do out := out.push (path, l)
  return out

/-- The edits to drop for errors at `errs`: in the same file, the edit that starts
closest above the error (it is in the declaration that failed). -/
def blame (edits : Array SimpEdit) (errs : Array (String × Nat)) : Array Nat := Id.run do
  let mut out := #[]
  for (path, l) in errs do
    let mut best : Option Nat := none
    for h : i in [0:edits.size] do
      let e := edits[i]
      let same := e.file == path || e.file.endsWith ("/" ++ path) || path.endsWith ("/" ++ e.file)
      if same && e.line ≤ l then
        match best with
        | some j => if edits[j]!.line < e.line then best := some i
        | none => best := some i
    if let some j := best then
      unless out.contains j do out := out.push j
  return out

/-- The declarations whose heartbeats went up, from the notes of a heartbeat
verdict (`compile KEY: 1.00 kHB -> 2.00 kHB`). -/
def dearer (notes : Array String) : Array String := notes.filterMap fun n => do
  guard (n.startsWith "compile ")
  let body := (n.drop 8).toString
  let parts := body.splitOn ": "
  guard (parts.length ≥ 2)
  let key := ": ".intercalate (parts.dropLast)
  let nums := (parts.getLast!.splitOn " -> ").map fun x => ((x.splitOn " ").head!.replace "," "")
  let num (s : String) : Option Float := do
    let ps := s.splitOn "."
    let i ← ps[0]!.toNat?
    let f := (ps[1]?.bind (·.toNat?)).getD 0
    let d := (ps[1]?.map (·.length)).getD 0
    return i.toFloat + f.toFloat / (10 : Float) ^ d.toFloat
  match nums with
  | [a, b] => do
    let x ← num a
    let y ← num b
    guard (y > x)
    return key
  | _ => none

/-! ## The command -/

structure Opts where
  files : Array String := #[]
  report : String := ".lake/leanprof/elab.json"
  top : Nat := 10
  dryRun : Bool := false
  test : Option String := none
  noTest : Bool := false
  branch : Option String := none
  rounds : Nat := 4

partial def parseOpts (o : Opts) : List String → Except String Opts
  | [] => .ok o
  | "--report" :: f :: rest => parseOpts { o with report := f } rest
  | "--top" :: n :: rest => match n.toNat? with
    | some k => parseOpts { o with top := max 1 k } rest
    | none => .error "--top takes a number"
  | "--dry-run" :: rest => parseOpts { o with dryRun := true } rest
  | "--test" :: c :: rest => parseOpts { o with test := some c } rest
  | "--no-test" :: rest => parseOpts { o with noTest := true } rest
  | "--branch" :: b :: rest => parseOpts { o with branch := some b } rest
  | "--rounds" :: n :: rest => match n.toNat? with
    | some k => parseOpts { o with rounds := max 1 k } rest
    | none => .error "--rounds takes a number"
  | a :: rest =>
    if a.startsWith "-" then .error s!"unknown argument {a} (fix --elab)"
    else parseOpts { o with files := o.files.push a } rest

/-- The tree of HEAD with `contents` (path relative to the repository's top ↦ text)
in place of those files, as a commit with parent HEAD: made with a separate index,
so the checkout, its index and its stash are not touched. -/
def commitFiles (top : FilePath) (dir : FilePath) (contents : Array (String × String)) (msg : String) :
    IO String := do
  let idx := dir / "index"
  if ← idx.pathExists then IO.FS.removeFile idx
  let env := #[("GIT_INDEX_FILE", some idx.toString)]
  let g (args : Array String) : IO String := do
    let out ← capture "git" (#["-c", "core.hooksPath=/dev/null"] ++ args) env (cwd := top)
    unless out.exitCode == 0 do throw <| IO.userError s!"git {" ".intercalate args.toList} failed: {trim out.stderr}"
    return trim out.stdout
  discard <| g #["read-tree", "HEAD"]
  for (path, text) in contents do
    let tmp := dir / "blob.tmp"
    IO.FS.writeFile tmp text
    let blob ← g #["hash-object", "-w", tmp.toString]
    let mode := ((← g #["ls-files", "-s", "--", path]).splitOn " ").head!
    discard <| g #["update-index", "--cacheinfo", s!"{if mode.isEmpty then "100644" else mode},{blob},{path}"]
    IO.FS.removeFile tmp
  let tree ← g #["write-tree"]
  let msgFile := dir / "message.txt"
  IO.FS.writeFile msgFile msg
  let c ← g #["commit-tree", tree, "-p", "HEAD", "-F", msgFile.toString]
  IO.FS.removeFile idx
  return c

def describeEdit (e : SimpEdit) (hb : Bool) : String :=
  s!"{e.range}  {ElabWhy.fmtAmt hb e.amount}  `{ElabWhy.collapse e.original}` -> `{e.replacement}`"

def fixElabCmd (argv : List String) (runSelf : Array String → FilePath → IO IO.Process.Output) : IO UInt32 := do
  let o ← IO.ofExcept (parseOpts {} argv)
  let dir : FilePath := ".lake" / "leanprof" / "fix"
  IO.FS.createDirAll dir
  let logPath := dir / "log.txt"
  IO.FS.writeFile logPath ""
  let log (title : String) (out : IO.Process.Output) : IO Unit := do
    let h ← IO.FS.Handle.mk logPath .append
    h.putStr s!"== {title} (exit code {out.exitCode})\n{out.stdout}{out.stderr}\n"
  let cwd ← IO.currentDir
  unless o.dryRun do
    unless (← gitRaw #["rev-parse", "--is-inside-work-tree"]).exitCode == 0 do
      throw <| IO.userError "not in a git repository: fix --elab commits the change on a new branch (--dry-run only prints it)"
    let dirty ← git #["status", "--porcelain", "--untracked-files=no"]
    unless dirty.isEmpty do
      throw <| IO.userError s!"the working tree has uncommitted changes; commit or stash them first:\n{dirty}"
  -- the report: Lean's `simp only` lists, from `elab --why`
  let report ← if o.files.isEmpty then pure o.report else do
    let out := dir / "elab-why.json"
    IO.println s!"leanprof fix --elab: profiling {o.files.size} file(s) (leanprof elab --heartbeats --why)"
    let r ← runSelf (#["elab", "--heartbeats", "--why", "--out", out.toString] ++ o.files) cwd
    log "leanprof elab --heartbeats --why" r
    unless r.exitCode == 0 && (← out.pathExists) do
      IO.eprintln s!"leanprof fix --elab: `leanprof elab` failed (exit code {r.exitCode}):\n{tailOf (r.stdout ++ r.stderr)}"
      return 2
    pure out.toString
  unless ← (report : FilePath).pathExists do
    throw <| IO.userError s!"no report at {report}: run `leanprof elab --heartbeats --why FILE.lean...` first, or give the files"
  let r ← IO.ofExcept (Json.parse (← IO.FS.readFile report))
  unless (r.getObjValAs? Bool "why").toOption.getD false do
    throw <| IO.userError s!"{report} was made without --why, so it has no `simp only` lists: run `leanprof elab --heartbeats --why FILE.lean...`, or give the files"
  let hb := jstr r "unit" == "heartbeats"
  let all := jarr r "simp_suggestions"
  let skipped := all.filter fun s => !(jstr s "not_applicable").isEmpty
  -- calls in this package, still as the report saw them
  let mut edits : Array SimpEdit := #[]
  let mut stale : Array String := #[]
  for e in editsOf r do
    if e.file.startsWith ".lake/" || e.file.startsWith "/" then continue
    unless ← (e.file : FilePath).pathExists do continue
    match applyEdits (← IO.FS.readFile e.file) #[e] with
    | .ok _ => if e.amount > 0 then edits := edits.push e
    | .error why => stale := stale.push why
  let picked := (edits.toList.take o.top).toArray
  IO.println (s!"leanprof fix --elab: {all.size} `simp` call(s) with Lean's `simp only` list in {report}; " ++
    s!"{picked.size} to try, costliest first (`--top {o.top}`):")
  for e in picked do IO.println s!"  {describeEdit e hb}"
  unless skipped.isEmpty do
    IO.println s!"  not mechanical: {skipped.size} (`leanprof explain --report {report}` says why for the costly ones)"
  for s in stale do IO.println (wrap s!"  stale: {s}" "    ")
  if picked.isEmpty then
    IO.println "leanprof fix --elab: no `simp` call to replace"
    return 1
  -- the edits, file by file
  let byFile (es : Array SimpEdit) : IO (Except String (Array (String × String))) := do
    let files : List String := (es.map (·.file)).toList.eraseDups
    let mut out : Array (String × String) := #[]
    for f in files do
      match applyEdits (← IO.FS.readFile f) (es.filter (·.file == f)) with
      | .ok t => out := out.push (f, t)
      | .error e => return .error e
    return .ok out
  if o.dryRun then
    if let .error e ← byFile picked then
      IO.println s!"leanprof fix --elab: {e}"; return 1
    for f in ((picked.map (·.file)).toList.eraseDups : List String) do
      let a := ((← IO.FS.readFile f).splitOn "\n").toArray
      IO.println ("\n" ++ Fix.unifiedDiff f a ((picked.filter (·.file == f)).map (lineEdit a)))
    return 0
  -- paths relative to the repository's top, for the commit
  let top : FilePath ← IO.FS.realPath (← git #["rev-parse", "--show-toplevel"])
  let pre ← git #["rev-parse", "--show-prefix"]
  let head ← git #["rev-parse", "HEAD"]
  -- the experiment: its base is HEAD, judged by compile heartbeats
  let id := s!"fix-elab-{(← IO.monoNanosNow) / 1000000}"
  IO.println s!"\nleanprof fix --elab: checking with `leanprof experiment` ({id}): build, proof-preservation guard, tests, heartbeats"
  let startArgs := #["experiment", "start", "--id", id] ++
    (if o.noTest then #["--no-test"] else match o.test with | some t => #["--test", t] | none => #[])
  let st ← runSelf startArgs cwd
  log "leanprof experiment start" st
  unless st.exitCode == 0 do
    IO.eprintln s!"leanprof fix --elab: `leanprof experiment start` failed:\n{tailOf (st.stdout ++ st.stderr)}"
    return 2
  let expDir := Experiment.experimentsDir cwd / id
  let cleanup : IO Unit := do
    Experiment.removeWorktree (expDir / "base")
    Experiment.removeWorktree (expDir / "candidate")
  let mut cur := picked
  let mut kept : Option (String × Json) := none
  let mut round := 0
  let mut lastReasons : Array String := #[]
  let mut lastVerdict := "DISCARD"
  while round < o.rounds && !cur.isEmpty && kept.isNone do
    round := round + 1
    let texts ← match ← byFile cur with
      | .ok t => pure t
      | .error e => IO.println s!"leanprof fix --elab: {e}"; break
    let rel := texts.map fun (f, t) => (pre ++ f, t)
    let cand ← commitFiles top dir rel s!"leanprof fix --elab: simp only, {cur.size} call(s) (candidate)"
    IO.println s!"\nround {round}: {cur.size} edit(s), candidate {cand.take 12}"
    let tr ← runSelf #["experiment", "try", cand, "--json", "--id", id] cwd
    log s!"leanprof experiment try (round {round})" tr
    let ev := (Json.parse tr.stdout).toOption.getD Json.null
    let verdict := jstr ev "verdict"
    let reasons := ((ev.getObjVal? "reasons" >>= Json.getArr?).toOption.getD #[]).filterMap (·.getStr?.toOption)
    lastReasons := reasons
    lastVerdict := if verdict.isEmpty then "ERROR" else verdict
    IO.println s!"  {if verdict.isEmpty then "ERROR" else verdict}"
    for x in reasons.toList.take 6 do IO.println (wrap s!"  - {x}" "    ")
    if verdict == "KEEP" then
      kept := some (cand, ev)
      break
    if verdict != "DISCARD" then break
    -- what to drop: the edits in declarations that no longer build, or that got dearer
    let tryN := jnum ev "try"
    let logText ← do
      let p := expDir / "tries" / toString tryN.toUInt64 / "log.txt"
      if ← p.pathExists then IO.FS.readFile p else pure ""
    let mut drop := blame cur (errorPositions ("\n".intercalate reasons.toList ++ "\n" ++ logText))
    let notes := ((ev.getObjVal? "heartbeats" >>= (·.getObjVal? "notes") >>= Json.getArr?).toOption.getD #[]).filterMap (·.getStr?.toOption)
    let up := dearer notes
    for h : i in [0:cur.size] do
      if up.contains cur[i].key && !drop.contains i then drop := drop.push i
    if drop.isEmpty then break
    IO.println (s!"  dropping {drop.size} edit(s): " ++ ", ".intercalate (drop.toList.map fun i => cur[i]!.range))
    cur := (cur.toList.zipIdx.filter fun (_, i) => !drop.contains i).map (·.1) |>.toArray
  cleanup
  match kept with
  | none =>
    IO.println s!"\n{lastVerdict}: no set of edits was kept and no branch was created; your checkout is unchanged."
    IO.println s!"  evidence: {expDir}/tries/*/evidence.json; log: {logPath}"
    return 1
  | some (cand, ev) =>
    -- the commit, with the evidence in its message, on a new branch
    let steps := ev
    let hbStep := (steps.getObjVal? "heartbeats").toOption.getD Json.null
    let guard := (steps.getObjVal? "guard").toOption.getD Json.null
    let files := (cur.map (·.file)).toList.eraseDups
    let subject := s!"simp only at {cur.size} call(s) in {", ".intercalate (files.take 3)}{if files.length > 3 then ", ..." else ""}"
    let msg := s!"{subject}\n\n" ++
      "Each `simp` is replaced by Lean's own list of the lemmas it used (`simp?`, `tactic.simp.trace`),\n" ++
      "so it no longer searches the whole simp set:\n\n" ++
      "\n".intercalate (cur.toList.map fun e => s!"  {e.range}: {ElabWhy.collapse e.original} -> {e.replacement}") ++
      s!"\n\nleanprof fix --elab, checked by leanprof experiment {id} (try {(jnum ev "try").toUInt64}): KEEP against {head.take 12}\n" ++
      s!"  build      ok\n  guard      {jstr guard "status"}: {(jarr guard "modules").size} module(s) audited\n" ++
      s!"  heartbeats {ElabWhy.fmtAmt true (jnum hbStep "base_total")} -> {ElabWhy.fmtAmt true (jnum hbStep "candidate_total")} " ++
      s!"in the changed modules and their dependents\n" ++
      "\n".intercalate (lastReasons.toList.map ("- " ++ ·)) ++ "\n"
    let tree ← git #["rev-parse", s!"{cand}^\{tree}"]
    let msgFile := dir / "message.txt"
    IO.FS.writeFile msgFile msg
    let sha ← git #["commit-tree", tree, "-p", head, "-F", msgFile.toString]
    let stem := o.branch.getD s!"leanprof-fix/simp-only-{((files.head!.splitOn "/").getLast!.replace ".lean" "")}"
    let mut branch := stem
    if o.branch.isNone then
      let mut n := 2
      while (← gitRaw #["rev-parse", "--verify", "--quiet", s!"refs/heads/{branch}"]).exitCode == 0 do
        branch := s!"{stem}-{n}"; n := n + 1
    discard <| git #["branch", branch, sha]
    IO.println s!"\nKEEP: committed {sha.take 12} on branch {branch} ({cur.size} edit(s)); your checkout is unchanged."
    IO.println s!"  heartbeats {ElabWhy.fmtAmt true (jnum hbStep "base_total")} -> {ElabWhy.fmtAmt true (jnum hbStep "candidate_total")}"
    IO.println s!"  see it: git show {branch}    take it: git merge {branch}"
    return 0

end Leanprof.FixElab
