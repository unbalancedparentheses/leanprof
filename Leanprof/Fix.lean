import Lean.Data.Json
import Leanprof.Explain
import Leanprof.Judge

/-!
# `leanprof fix`: apply the fix `explain` prints, prove it, commit it

`explain` names the cause of a copy and, for the causes it recognises with
certainty, prints the fix as Lean code with the program's own names
(`fix_code`). For three of them the code replaces source lines one for one,
so applying it is mechanical:

* `nested-array-element`: `xs := xs.set! i (xs[i]!.push v)` becomes
  `xs := xs.modify i (·.push v)`;
* `map-value-reinserted`: `let v := m.getD k d` … `m := m.insert k (v.push x)`
  becomes `m := m.alter k fun v? => …` (`modify` for `get!`), the read line
  removed, or the insert becomes `(m.erase k).insert k …`;
* `loop-over-updated-array`: `for x in xs do` becomes
  `for i in [0:xs.size] do` followed by `let x := xs[i]!`.

The others are not mechanical, and `fix` says why: `stored-then-updated`
changes what is stored (the code reading it must change too),
`multi-threaded-global` moves code before and after a loop, and the general
causes have no code.

This module plans the edits (pure, tested in `Tests/Main.lean`) and runs the
proof: on a new git branch, build, run the tests, compare the program's
output with the original's, `measure` both versions (exact copies and
allocations), time both plain binaries with `measure-pair`, and `judge`.
KEEP commits the edit with that evidence in the message; DISCARD removes the
branch and says why. The working tree is left as it was in both cases.
-/

namespace Leanprof.Fix
open Lean System
open Leanprof.Explain (has trim codeOf indentOf jstr jarr jnum dropChars dropRightChars)

/-! ## Edits -/

/-- Replace `count` lines from line `first` (1-based) by `lines`. -/
structure Edit where
  first : Nat
  count : Nat
  lines : Array String
  deriving Inhabited, Repr, BEq

/-- One way to apply a finding's fix: one alternative of its `fix_code`. -/
structure Plan where
  cause : String
  file : String
  /-- the `fix_code` alternative this plan applies -/
  code : String
  /-- what the edit does, for the commit's subject -/
  what : String
  edits : Array Edit
  deriving Inhabited

/-- `src` with `edits` (non-overlapping) applied. -/
def applyEdits (src : Array String) (edits : Array Edit) : Array String := Id.run do
  let es := edits.qsort (·.first < ·.first)
  let mut out : Array String := #[]
  let mut i := 1
  for e in es do
    while i < e.first && i ≤ src.size do
      out := out.push src[i - 1]!
      i := i + 1
    out := out ++ e.lines
    i := e.first + e.count
  while i ≤ src.size do
    out := out.push src[i - 1]!
    i := i + 1
  return out

/-- A unified diff of `edits` on `file` (lines `src`), `ctx` lines of context. -/
def unifiedDiff (file : String) (src : Array String) (edits : Array Edit) (ctx : Nat := 3) : String := Id.run do
  let es := edits.qsort (·.first < ·.first)
  if es.isEmpty then return ""
  -- a trailing newline leaves an empty last element: not a line
  let n := if src.back? == some "" then src.size - 1 else src.size
  -- edits whose contexts touch go in one hunk
  let mut groups : Array (Array Edit) := #[]
  for e in es do
    match groups.back? with
    | some g =>
      let last := g.back!
      if e.first ≤ last.first + last.count + 2 * ctx then groups := groups.pop.push (g.push e)
      else groups := groups.push #[e]
    | none => groups := groups.push #[e]
  let mut out := s!"--- a/{file}\n+++ b/{file}\n"
  let mut offset : Int := 0
  for g in groups do
    let first := g[0]!.first
    let last := g.back!
    let lo := if first > ctx then first - ctx else 1
    let hi := min n (last.first + last.count - 1 + ctx)
    let mut body := ""
    let mut oldN := 0
    let mut newN := 0
    let mut i := lo
    let mut delta : Int := 0
    for e in g do
      while i < e.first do
        body := body ++ s!" {src[i - 1]!}\n"; oldN := oldN + 1; newN := newN + 1; i := i + 1
      for k in [0:e.count] do
        body := body ++ s!"-{src[e.first - 1 + k]!}\n"
      for l in e.lines do
        body := body ++ s!"+{l}\n"
      oldN := oldN + e.count
      newN := newN + e.lines.size
      delta := delta + e.lines.size - e.count
      i := e.first + e.count
    while i ≤ hi do
      body := body ++ s!" {src[i - 1]!}\n"; oldN := oldN + 1; newN := newN + 1; i := i + 1
    let newLo := (Int.ofNat lo + offset).toNat
    out := out ++ s!"@@ -{lo},{oldN} +{newLo},{newN} @@\n" ++ body
    offset := offset + delta
  return out

/-! ## Plans for the recognised causes -/

/-- The comment at the end of a source line, with the space before it. -/
def commentOf (l : String) : String :=
  match l.splitOn "--" with
  | c :: rest@(_ :: _) =>
    let sp := String.ofList ((c.toList.reverse.takeWhile (· == ' ')).reverse)
    (if sp.isEmpty then " " else sp) ++ "--" ++ "--".intercalate rest
  | _ => ""

/-- Brackets balance in `s` (outside string literals). -/
def balanced (s : String) : Bool := Id.run do
  let mut d : Int := 0
  let mut inStr := false
  for c in s.toList do
    if inStr then
      if c == '"' then inStr := false
      continue
    if c == '"' then inStr := true
    else if c == '(' || c == '[' || c == '{' then d := d + 1
    else if c == ')' || c == ']' || c == '}' then d := d - 1
    if d < 0 then return false
  return d == 0

def natsOf (j : Json) (k : String) : Array Nat := (jarr j k).filterMap (·.getNat?.toOption)

def strsOf (j : Json) (k : String) : Array String := (jarr j k).filterMap (·.getStr?.toOption)

/-- Line `l` (1-based) of `src`. -/
def lineAt (src : Array String) (l : Nat) : String := if l > 0 then src[l - 1]?.getD "" else ""

/-- The declaration's line from a finding's `where` (`file:line`). -/
def declLine (f : Json) : Nat :=
  match (jstr f "where").splitOn ":" with
  | [_, l] => l.toNat?.getD 0
  | _ => 0

/-- Why a cause has no mechanical edit. -/
def notMechanical (cause : String) (hasCode : Bool) : String :=
  match cause with
  | "stored-then-updated" =>
    "the fix changes what is stored (lengths instead of whole versions), so the code that reads it must change " ++
    "too: apply it by hand"
  | "multi-threaded-global" =>
    "the fix adds code before and after the loop, which explain does not locate: apply it by hand"
  | _ => if hasCode then s!"no mechanical edit for `{cause}` yet"
    else s!"explain prints no code for `{cause}`, only advice"

/-- The edits that apply each alternative of a finding's `fix_code` to the
source lines `src` of its file, or why there is none. -/
def plansFor (f : Json) (src : Array String) : Except String (Array Plan) := do
  let cause := jstr f "cause"
  let file := jstr f "file"
  let lines := natsOf f "lines"
  let code := strsOf f "fix_code"
  if file.isEmpty then throw "the finding has no source file"
  if file.startsWith "/" || file.startsWith ".lake" then
    throw s!"the code is in a dependency ({file}), not in this project"
  if code.isEmpty || lines.isEmpty then throw (notMechanical cause !code.isEmpty)
  let mut plans : Array Plan := #[]
  let mut skipped : Array String := #[]
  match cause with
  | "nested-array-element" =>
    -- each code line rewrites one source line (`C.set! I (C[I]!.op V)`):
    -- together they are the fix; each alone is tried after them
    let mut single : Array Plan := #[]
    for alt in code do
      match lines.find? fun l => Explain.modifyRewrite (lineAt src l) == some alt with
      | some l =>
        let old := lineAt src l
        single := single.push {
          cause := cause, file := file, code := alt, what := "Array.modify",
          edits := #[{ first := l, count := 1, lines := #[indentOf old ++ alt ++ commentOf old] }] }
      | none => skipped := skipped.push s!"`{alt}` does not rewrite a line of {file} (changed since the report?)"
    if single.size > 1 then
      plans := plans.push {
        cause := cause, file := file, code := "\n".intercalate (single.map (·.code)).toList,
        what := s!"Array.modify ({single.size} lines)", edits := single.flatMap (·.edits) }
      plans := plans ++ single.map fun p => { p with what := s!"Array.modify (line {p.edits[0]!.first} only)" }
    else plans := single
  | "map-value-reinserted" =>
    let dl := declLine f
    if dl == 0 || dl > src.size then throw "the finding has no declaration line"
    let decl := Explain.declLines src (dl - 1)
    let some u := Explain.findMapUse decl
      | throw s!"the read and the insert are no longer in {file} (changed since the report?)"
    let ins := lineAt src u.insertLine
    unless balanced (codeOf ins) do
      throw s!"the insert at line {u.insertLine} continues on the next line: apply the fix by hand"
    for alt in code do
      let erase := (codeOf alt).startsWith (u.pre ++ "(" ++ u.map ++ ".erase ")
      let replaceInsert : Edit := { first := u.insertLine, count := 1, lines := #[indentOf ins ++ alt ++ commentOf ins] }
      if erase then
        plans := plans.push {
          cause := cause, file := file, code := alt, what := s!"erase the key of `{u.map}` before inserting",
          edits := #[replaceInsert] }
        continue
      -- `alter`/`modify` read the value themselves: the read line goes, if
      -- nothing else uses the variable it binds
      let rd := codeOf (lineAt src u.readLine)
      unless rd.startsWith "let " do
        skipped := skipped.push s!"`{alt}`: the value is read by `{rd}`, not a `let` that can be removed"
        continue
      let others := decl.filter fun (n, l) => n != u.readLine && n != u.insertLine && Explain.countWord (codeOf l) u.value > 0
      unless others.isEmpty do
        skipped := skipped.push s!"`{alt}`: `{u.value}` is also used at line {others[0]!.1}"
        continue
      let fn := if has alt ".alter " then "alter" else "modify"
      plans := plans.push {
        cause := cause, file := file, code := alt, what := s!"`{u.map}.{fn}` instead of reading and inserting back",
        edits := #[{ first := u.readLine, count := 1, lines := #[] }, replaceInsert] }
  | "loop-over-updated-array" =>
    let some fl := lines[0]? | throw "the finding has no loop line"
    let forLine := lineAt src fl
    let t := codeOf forLine
    unless t.startsWith "for " && t.endsWith " do" do throw s!"line {fl} is not `for … in … do` (changed since the report?)"
    if has ((t.splitOn " in ").head!) ":" then throw s!"the loop at line {fl} binds a membership proof: apply the fix by hand"
    -- the body's indentation, from its first line
    let bodyIndent := ((src.extract fl src.size).find? (fun l => !(codeOf l).isEmpty)).map indentOf |>.getD (indentOf forLine ++ "  ")
    for alt in code do
      match alt.splitOn "\n" with
      | [hd, bind] =>
        plans := plans.push {
          cause := cause, file := file, code := alt, what := "loop over the indices",
          edits := #[{ first := fl, count := 1, lines := #[indentOf forLine ++ hd ++ commentOf forLine, bodyIndent ++ trim bind] }] }
      | _ => skipped := skipped.push s!"unexpected code `{alt}`"
  | _ => throw (notMechanical cause true)
  if plans.isEmpty then throw ("; ".intercalate skipped.toList)
  return plans

/-! ## The command -/

structure Opts where
  exe : Option String := none
  args : Array String := #[]
  report : String := ".lake/leanprof/report.json"
  test : Option String := none
  checkOutput : Option String := none
  finding : Option Nat := none
  dryRun : Bool := false
  runs : Nat := 5
  pairs : Nat := 30
  deps : Bool := true
  branch : Option String := none
  allowOverloaded : Bool := false
  top : Nat := 20
  all : Bool := false

partial def parseOpts (o : Opts) : List String → Except String Opts
  | [] => .ok o
  | "--exe" :: e :: rest => parseOpts { o with exe := some e } rest
  | "--report" :: f :: rest => parseOpts { o with report := f } rest
  | "--test" :: c :: rest => parseOpts { o with test := some c } rest
  | "--check-output" :: f :: rest => parseOpts { o with checkOutput := some f } rest
  | "--finding" :: n :: rest => do
    let some k := n.toNat? | throw "--finding takes a number (as `fix --dry-run` lists them)"
    parseOpts { o with finding := some k } rest
  | "--dry-run" :: rest => parseOpts { o with dryRun := true } rest
  | "--runs" :: n :: rest => parseOpts { o with runs := max 1 n.toNat! } rest
  | "--pairs" :: n :: rest => do
    let some k := n.toNat? | throw "--pairs must be a number from 6 to 1000"
    unless k ≥ 6 && k ≤ 1000 do throw "--pairs must be a number from 6 to 1000"
    parseOpts { o with pairs := k } rest
  | "--no-deps" :: rest => parseOpts { o with deps := false } rest
  | "--branch" :: b :: rest => parseOpts { o with branch := some b } rest
  | "--allow-overloaded" :: rest => parseOpts { o with allowOverloaded := true } rest
  | "--top" :: n :: rest => parseOpts { o with top := n.toNat! } rest
  | "--all" :: rest => parseOpts { o with all := true } rest
  | "--" :: rest => .ok { o with args := o.args ++ rest.toArray }
  | a :: _ => .error s!"unknown argument {a}"

/-- Run `cmd`, capturing its output; a missing program is exit code 127. -/
def capture (cmd : String) (args : Array String) (env : Array (String × Option String) := #[]) :
    IO IO.Process.Output := do
  try IO.Process.output { cmd, args, env, stdin := .null }
  catch e => return { exitCode := 127, stdout := "", stderr := toString e }

def git (args : Array String) : IO String := do
  let out ← capture "git" args
  unless out.exitCode == 0 do
    throw <| IO.userError s!"git {" ".intercalate args.toList} failed: {trim out.stderr}"
  return trim out.stdout

/-- The last lines of `s`, indented, for showing why a step failed. -/
def tailOf (s : String) (n : Nat := 15) : String :=
  let ls := (s.splitOn "\n").filter (fun l => !(trim l).isEmpty)
  "\n".intercalate ((ls.drop (ls.length - n)).map ("    " ++ ·))

def shellQuote (s : String) : String :=
  if !s.isEmpty && s.toList.all (fun c => c.isAlphanum || "-_./=:,+@%".toList.contains c) then s
  else "'" ++ s.replace "'" "'\\''" ++ "'"

/-- `n` with thousands separators. -/
def groupDigits (n : Nat) : String := Judge.groupDigits n

/-- A branch name from a function and a cause (`leanprof-fix/groupBy-map-value-reinserted`). -/
def branchName (function cause : String) : String :=
  let fn := ((function.splitOn " (in ").head!).splitOn "." |>.getLast? |>.getD "fix"
  let clean := String.ofList (fn.toList.map fun c => if c.isAlphanum || c == '-' || c == '_' then c else '-')
  s!"leanprof-fix/{clean}-{cause}"

/-- The verdict's lines, indented. -/
def verdictLines (v : Judge.Verdict) : String :=
  "\n".intercalate (((v.render.splitOn "\n").filter (fun l => !(trim l).isEmpty)).map ("  " ++ ·))

/-- What `fix` found for each finding: a plan or why not. -/
def listFindings (findings : Array Json) (src : String → IO (Array String)) :
    IO (Array (Nat × Json × Except String (Array Plan))) := do
  let mut out := #[]
  for h : i in [0:findings.size] do
    let f := findings[i]
    let file := jstr f "file"
    let lines ← if file.isEmpty then pure #[] else src file
    out := out.push (i + 1, f, plansFor f lines)
  return out

def fmtNs (ns : Float) : String :=
  if ns < 1e3 then s!"{ns.toUInt64} ns"
  else if ns < 1e6 then s!"{Explain.fmt2 (ns / 1e3)} µs"
  else s!"{Explain.fmt2 (ns / 1e6)} ms"

/-- One line naming a finding. -/
def describe (k : Nat) (f : Json) : String :=
  let ls := natsOf f "lines"
  s!"{k}. {jstr f "cause"} in {jstr f "function"} ({jstr f "file"}" ++
    (if ls.isEmpty then ")" else s!" {Explain.showLines ls})") ++
    s!", {groupDigits (jnum f "copies").toUInt64.toNat} copies, {fmtNs (jnum f "copy_ns")} copying"

/-- What the program printed (or wrote to `checkOutput`), run without probes
the way `lake exe` runs it, and its exit code. -/
def plainRun (exe : String) (args : Array String) (checkOutput : Option String) : IO (UInt32 × String) := do
  if let some f := checkOutput then
    if ← (f : FilePath).pathExists then IO.FS.removeFile f
  let out ← capture "lake" (#["env", ((".lake" : FilePath) / "build" / "bin" / exe).toString] ++ args)
  match checkOutput with
  | some f =>
    if ← (f : FilePath).pathExists then
      let b ← IO.FS.readBinFile f
      return (out.exitCode, (String.fromUTF8? b).getD s!"(binary, {b.size} bytes, {hashOf b})")
    else return (out.exitCode, "(missing)")
  | none => return (out.exitCode, out.stdout)
where
  hashOf (b : ByteArray) : String := Id.run do
    let mut h : UInt64 := 14695981039346656037
    for x in b do h := (h ^^^ x.toUInt64) * 1099511628211
    return toString h

/-- The first line where two outputs differ, for saying how the output changed. -/
def firstDifference (a b : String) : String := Id.run do
  let (as, bs) := ((a.splitOn "\n").toArray, (b.splitOn "\n").toArray)
  for i in [0:max as.size bs.size] do
    if as[i]? != bs[i]? then
      let cut (s : String) := String.ofList (s.toList.take 200)
      return s!"line {i + 1}: `{cut (as[i]?.getD "(none)")}` became `{cut (bs[i]?.getD "(none)")}`"
  return "same lines"

/-- Wrap a paragraph at 72 columns for a commit message. -/
def para (s : String) : String := Explain.wrap s "" 72

/-- `leanprof fix`. `runSelf` runs another leanprof command (`run`,
`measure`, `measure-pair`), capturing its output. Exit code 0: KEEP (or
`--dry-run` printed a fix); 1: DISCARD, or no finding has a mechanical fix. -/
def fixCmd (argv : List String) (runSelf : Array String → IO IO.Process.Output) : IO UInt32 := do
  let o ← IO.ofExcept (parseOpts {} argv)
  let dir : FilePath := ".lake" / "leanprof" / "fix"
  IO.FS.createDirAll dir
  let logPath := dir / "log.txt"
  IO.FS.writeFile logPath ""
  let log (title : String) (out : IO.Process.Output) : IO Unit := do
    let h ← IO.FS.Handle.mk logPath .append
    h.putStr s!"== {title} (exit code {out.exitCode})\n{out.stdout}{out.stderr}\n"
  -- refuse before profiling, not after
  unless o.dryRun do
    unless (← capture "git" #["rev-parse", "--is-inside-work-tree"]).exitCode == 0 do
      throw <| IO.userError "not in a git repository: fix commits the change on a new branch (--dry-run only prints it)"
    if o.exe.isNone then
      throw <| IO.userError "--exe EXE is needed to build, test and measure the fix (--dry-run works from the last report)"
    let dirty ← git #["status", "--porcelain", "--untracked-files=no"]
    unless dirty.isEmpty do
      throw <| IO.userError s!"the working tree has uncommitted changes; commit or stash them first:\n{dirty}"
  if let some exe := o.exe then
    IO.println s!"leanprof fix: profiling {exe} (leanprof run)"
    let out ← runSelf (#["run", "--json", o.report, exe, "--"] ++ o.args)
    log "leanprof run" out
    unless out.exitCode == 0 && (← (o.report : FilePath).pathExists) do
      IO.eprintln s!"leanprof fix: `leanprof run {exe}` failed (exit code {out.exitCode}):\n{tailOf (out.stdout ++ out.stderr)}"
      return 2
  let (findings, tiny) ← Explain.findingsOf o.report o.top o.all
  -- with --all too: only sites that copied shared values (not only constants)
  let findings := findings.filter fun f => jnum f "shared" + jnum f "multi_threaded" > 0
  let tinyNote := if tiny > 0 then
      s!" ({tiny} site(s) that copied only empty or tiny values left out; --all considers them)" else ""
  if findings.isEmpty then
    IO.println s!"leanprof fix: no copies of shared values in {o.report}: nothing to fix{tinyNote}"
    return 1
  let srcCache ← IO.mkRef ({} : Std.HashMap String (Array String))
  let readSrc (file : String) : IO (Array String) := do
    if let some s := (← srcCache.get).get? file then return s
    let s ← if ← (file : FilePath).pathExists then pure ((← IO.FS.readFile file).splitOn "\n").toArray else pure #[]
    srcCache.modify (·.insert file s)
    return s
  let listed ← listFindings findings readSrc
  IO.println s!"leanprof fix: {findings.size} finding(s) in {o.report}, costliest first{tinyNote}:"
  for (k, f, r) in listed do
    IO.println s!"  {describe k f}"
    match r with
    | .ok ps => IO.println s!"     mechanical fix: {ps.size} alternative(s)"
    | .error e => IO.println (Explain.wrap s!"     not mechanical: {e}" "       ")
  let chosen := match o.finding with
    | some k => listed[k - 1]?
    | none => listed.find? fun (_, _, r) => r matches .ok _
  let some (k, f, .ok plans) := chosen
    | match o.finding, chosen with
      | some k, some (_, _, .error e) =>
        IO.println s!"\nleanprof fix: finding {k} has no mechanical fix: {e}"; return 1
      | some k, _ => IO.println s!"\nleanprof fix: there is no finding {k} (1 to {listed.size})"; return 1
      | none, _ =>
        IO.println ("\nleanprof fix: none of these findings has a mechanical fix (reasons above); " ++
          "`leanprof explain` describes each")
        return 1
  let file := jstr f "file"
  let src ← readSrc file
  IO.println s!"\nleanprof fix: finding {k}, {jstr f "cause"} in {jstr f "function"}"
  IO.println (Explain.wrap s!"  why: {jstr f "why"}" "       ")
  for h : i in [0:plans.size] do
    IO.println s!"\nalternative {i + 1} of {plans.size}: {plans[i].what}"
    IO.print (unifiedDiff file src plans[i].edits)
  if o.dryRun then return 0
  let exe := o.exe.get!
  let testCmd ← match o.test with
    | some t => pure (some t)
    | none => do
      if (← capture "lake" #["check-test"]).exitCode == 0 then pure (some "lake test") else pure none
  let testsText := match testCmd with
    | some t => s!"`{t}`"
    | none => "none (no --test CMD and no Lake test driver)"
  let build : IO (Except String Unit) := do
    let out ← capture "lake" #["build", exe]
    log s!"lake build {exe}" out
    return if out.exitCode == 0 then .ok () else .error (tailOf (out.stdout ++ out.stderr))
  let runTests : IO (Except String Unit) := do
    let some t := testCmd | return .ok ()
    let out ← capture "sh" #["-c", t]
    log t out
    return if out.exitCode == 0 then .ok () else .error (tailOf (out.stdout ++ out.stderr))
  let checkArgs := match o.checkOutput with | some f => #["--check-output", f] | none => #[]
  let measure (out : FilePath) : IO (Except String Judge.Summary) := do
    let r ← runSelf (#["measure", "--runs", toString o.runs] ++ (if o.deps then #[] else #["--no-deps"]) ++
      checkArgs ++ #["--out", out.toString, exe, "--"] ++ o.args)
    log s!"leanprof measure into {out}" r
    if r.exitCode != 0 then return .error (tailOf (r.stdout ++ r.stderr))
    let j ← IO.ofExcept (Json.parse (← IO.FS.readFile out))
    return Judge.Summary.ofJson j
  let binPath : FilePath := ".lake" / "build" / "bin" / exe
  let keepBinary (to : FilePath) : IO Unit := do
    let out ← capture "cp" #["-p", binPath.toString, to.toString]
    unless out.exitCode == 0 do throw <| IO.userError s!"could not copy {binPath}: {out.stderr}"
  -- the original must build and pass its tests, or nothing can be checked
  IO.println s!"\nleanprof fix: the original: build, tests ({testsText}), output, measure ({o.runs} runs)"
  if let .error e := ← build then
    IO.eprintln s!"leanprof fix: {exe} does not build before any change:\n{e}"; return 2
  if let .error e := ← runTests then
    IO.eprintln s!"leanprof fix: the tests fail before any change, so a fix cannot be checked:\n{e}"; return 2
  let (baseCode, baseOut) ← plainRun exe o.args o.checkOutput
  keepBinary (dir / "base-bin")
  let mut base : Judge.Summary := {}
  match ← measure (dir / "base.json") with
  | .ok s => base := s
  | .error e => IO.eprintln s!"leanprof fix: measuring the original failed:\n{e}"; return 2
  IO.println s!"  copies {groupDigits base.copies}, exit code {baseCode}, time median {Judge.fmtMs base.median}"
  -- the branch starts where the user is
  let origBranch ← git #["rev-parse", "--abbrev-ref", "HEAD"]
  let orig ← if origBranch == "HEAD" then git #["rev-parse", "HEAD"] else pure origBranch
  let mut branch := o.branch.getD (branchName (jstr f "function") (jstr f "cause"))
  if o.branch.isNone then
    let stem := branch
    let mut n := 2
    while (← capture "git" #["rev-parse", "--verify", "--quiet", s!"refs/heads/{branch}"]).exitCode == 0 do
      branch := s!"{stem}-{n}"; n := n + 1
  discard <| git #["checkout", "-q", "-b", branch]
  let original ← IO.FS.readFile file
  -- a reference: `finally` does not see the updates of a `let mut` made in `try`
  let keptRef ← IO.mkRef (none : Option String)
  let reasons ← IO.mkRef (#[] : Array String)
  try
    for h : i in [0:plans.size] do
      let plan := plans[i]
      let tag := s!"alternative {i + 1} ({plan.what})"
      IO.println s!"\nleanprof fix: {tag} on branch {branch}"
      IO.FS.writeFile file ("\n".intercalate (applyEdits src plan.edits).toList)
      let fail (why : String) : IO Unit := do
        IO.println (Explain.wrap s!"  DISCARD: {why}" "    ")
        IO.FS.writeFile file original
      if let .error e := ← build then
        fail s!"it does not build:\n{e}"; reasons.modify (·.push <| s!"{tag}: it does not build"); continue
      IO.println "  builds"
      if let .error e := ← runTests then
        fail s!"the tests fail ({testsText}):\n{e}"; reasons.modify (·.push <| s!"{tag}: the tests fail"); continue
      if testCmd.isSome then IO.println s!"  tests pass ({testsText})"
      let (code, out) ← plainRun exe o.args o.checkOutput
      if code != baseCode then
        let why := s!"the exit code changed: {baseCode} -> {code}"
        fail why; reasons.modify (·.push <| s!"{tag}: {why}"); continue
      if out != baseOut then
        let why := s!"the output changed ({o.checkOutput.getD "stdout"}), {firstDifference baseOut out}"
        fail why; reasons.modify (·.push <| s!"{tag}: {why}"); continue
      IO.println s!"  output identical ({o.checkOutput.getD "stdout"}, {out.utf8ByteSize} bytes)"
      keepBinary (dir / "candidate-bin")
      let mut new : Judge.Summary := {}
      match ← measure (dir / "new.json") with
      | .ok s => new := s
      | .error e =>
        fail s!"measuring it failed:\n{e}"; reasons.modify (·.push <| s!"{tag}: measuring it failed"); continue
      let exact := Judge.judge base new
      IO.println s!"  leanprof judge (measure, {o.runs} runs each):\n{verdictLines exact}"
      unless exact.keep do
        let why := "`judge` of the two measure summaries says DISCARD: " ++
          (if exact.worse.isEmpty then "nothing improved beyond noise" else "; ".intercalate exact.worse.toList)
        fail why; reasons.modify (·.push <| s!"{tag}: {why}"); continue
      let pairOut ← runSelf (#["measure-pair", "--base", (dir / "base-bin").toString,
        "--candidate", (dir / "candidate-bin").toString, "--runs", toString o.pairs,
        "--out", (dir / "paired.json").toString] ++ checkArgs ++ #["--"] ++ o.args)
      log "leanprof measure-pair" pairOut
      if pairOut.exitCode != 0 then
        fail s!"measure-pair failed:\n{tailOf (pairOut.stdout ++ pairOut.stderr)}"
        reasons.modify (·.push <| s!"{tag}: measure-pair failed"); continue
      let pj ← IO.ofExcept (Json.parse (← IO.FS.readFile (dir / "paired.json")))
      let paired ← IO.ofExcept (Judge.judgePaired pj 1 o.allowOverloaded)
      IO.println s!"  leanprof judge (measure-pair, at most {o.pairs} pairs of plain binaries):\n{verdictLines paired}"
      unless paired.worse.isEmpty do
        let why := "the plain binaries: " ++ "; ".intercalate paired.worse.toList
        fail why; reasons.modify (·.push <| s!"{tag}: {why}"); continue
      -- KEEP: commit with the evidence
      let short := ((jstr f "function").splitOn " (in ").head!
      let argsText := if o.args.isEmpty then "" else " -- " ++ " ".intercalate (o.args.toList.map shellQuote)
      let msg := s!"{short}: {plan.what} (leanprof fix)\n\n" ++
        para (s!"leanprof explain: {groupDigits (jnum f "shared" + jnum f "multi_threaded").toUInt64.toNat} copies of shared values in " ++
          s!"{jstr f "function"} ({file} {Explain.showLines (natsOf f "lines")}), cause `{jstr f "cause"}`: " ++
          jstr f "why") ++ "\n\n" ++
        s!"The fix explain prints, applied:\n\n    {"\n    ".intercalate (plan.code.splitOn "\n")}\n\n" ++
        s!"Evidence (leanprof fix --exe {exe}{argsText}):\n" ++
        s!"- tests: {testsText}{if testCmd.isSome then ", passed before and after" else ""}\n" ++
        s!"- output: identical before and after ({o.checkOutput.getD "stdout"}, {out.utf8ByteSize} bytes, " ++
          s!"exit code {code})\n" ++
        s!"- leanprof measure ({o.runs} runs of each, with probes), leanprof judge:\n{verdictLines exact}\n" ++
        s!"- leanprof measure-pair (at most {o.pairs} pairs of plain binaries, AB/BA order, stopped when settled), leanprof judge:\n" ++
          s!"{verdictLines paired}\n"
      IO.FS.writeFile (dir / "commit-message.txt") msg
      discard <| git #["commit", "-q", "-F", (dir / "commit-message.txt").toString, "--", file]
      keptRef.set <| some (← git #["rev-parse", "--short", "HEAD"])
      break
  finally
    if (← keptRef.get).isNone then IO.FS.writeFile file original
    let back ← capture "git" #["checkout", "-q", orig]
    if back.exitCode != 0 then
      IO.eprintln s!"leanprof fix: could not go back to {orig} (still on {branch}): {trim back.stderr}"
    else if (← keptRef.get).isNone then discard <| capture "git" #["branch", "-q", "-D", branch]
  match ← keptRef.get with
  | some sha =>
    IO.println s!"\nKEEP: committed {sha} on branch {branch}; your checkout is back on {orig}, unchanged."
    IO.println s!"  see it: git show {branch}    take it: git merge {branch}"
    IO.println s!"  (the commit message holds the evidence; the steps' output is in {logPath})"
    return 0
  | none =>
    IO.println s!"\nDISCARD: no alternative was kept, branch {branch} deleted; your checkout is back on {orig}, unchanged."
    for r in ← reasons.get do IO.println (Explain.wrap s!"  - {r}" "    ")
    IO.println s!"  (the steps' output is in {logPath})"
    return 1

end Leanprof.Fix
