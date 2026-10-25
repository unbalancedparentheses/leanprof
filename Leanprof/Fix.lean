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
  `xs := xs.modify i (·.push v)` (the same index, written the same way, on
  both sides);
* `map-value-reinserted`: `let v := m.getD k d` … `m := m.insert k (v.push x)`
  becomes `m := m.alter k fun v? => …` (`modify` for `get!`), the read line
  removed, or the insert becomes `(m.erase k).insert k …`;
* `loop-over-updated-array`: `for x in xs do` becomes
  `for i in [0:xs.size] do` followed by `let x := xs[i]!`, only when the
  body provably changes no element it has not visited yet
  (`loopRewriteUnsafe`).

Each rewrite is applied only when its text shows it computes the same
values on every input: the output comparison covers one workload, so it
checks the edit, it does not prove it.

The others are not mechanical, and `fix` says why: `stored-then-updated`
changes what is stored (the code reading it must change too),
`multi-threaded-global` moves code before and after a loop, and the general
causes have no code.

This module plans the edits (pure, tested in `Tests/Main.lean`) and runs the
checks in a git worktree of HEAD (`.lake/leanprof/fix/worktree`), never in
the user's checkout: build, run the tests, compare the program's output
with the original's, `measure` both versions (exact copies and
allocations), time both plain binaries with `measure-pair`, and `judge`.
KEEP commits the edit in the worktree with that evidence in the message and
gives the user's repository a branch pointing at it; DISCARD says why. The
worktree is removed in both cases, and after INT, TERM or HUP (`Runner`).
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

/-- Why replacing `for x in c do` (line `fl`) by a loop over the indices
reading `c[i]!` could change what the loop computes, or `none` when it
provably cannot.

`for x in c` visits the elements `c` had when the loop started; `c[i]!`
reads the current array. They agree when the body never changes an element
it has not visited yet and never shrinks `c`. That is what this checks, on
the text, in the one shape it can be sure of:

* the line before the loop is `let mut j := 0`, the body's last line is
  `j := j + 1`, and the body has no other assignment to `j`, no `continue`
  and no nested block (every line at the body's indentation), so `j` is the
  index of the element being visited;
* the only assignments to `c` are `c := c.set! j E`, `c := c.set j E`,
  `c := c.modify j F` (the element just visited) and `c := c.push E`
  (beyond the visited range); other lines may read `c` but not bind it.

Anything else is refused: the output comparison only covers the workload
`fix` runs, so it cannot be the proof. -/
def loopRewriteUnsafe (src : Array String) (fl : Nat) (c : String) : Option String := Id.run do
  let forLine := lineAt src fl
  let ind := (indentOf forLine).length
  -- the counter: the nearest non-blank line before the loop
  let prev := ((src.extract 0 (fl - 1)).toList.reverse.find? fun l => !(codeOf l).isEmpty).getD ""
  let pc := codeOf prev
  let j := trim (dropRightChars (dropChars pc 8) 5)
  unless (indentOf prev).length == ind && pc == s!"let mut {j} := 0" &&
      !j.isEmpty && j.toList.all Explain.isIdentChar && !has j "." && j != c do
    return some s!"the line before the loop is not `let mut j := 0`, a counter of the elements visited"
  let body := (src.extract fl src.size).toList.takeWhile fun l => (codeOf l).isEmpty || (indentOf l).length > ind
  let body := (body.filter fun l => !(codeOf l).isEmpty).toArray
  let some first := body[0]? | return some "the loop has no body"
  let bi := (indentOf first).length
  if body.any (fun l => (indentOf l).length != bi) then
    return some "the loop body has nested blocks"
  unless codeOf body.back! == s!"{j} := {j} + 1" do
    return some s!"the loop body does not end with `{j} := {j} + 1`"
  for l in body.pop do
    let t := codeOf l
    let ts := Explain.tokens t
    if ts.contains "continue" || ts.contains "fun" || ts.contains "do" then
      return some s!"`{t}`: the body has `continue`, `fun` or `do`"
    let update := [".set! ", ".set ", ".modify "].any fun op => t.startsWith s!"{c} := {c}{op}{j} " &&
      (Explain.splitTop (dropChars t (c.length + 4))).size == 3 && balanced t
    let push := t.startsWith s!"{c} := {c}.push " && (Explain.splitTop (dropChars t (c.length + 4))).size == 2 &&
      balanced t && Explain.countWord t j == 0
    if update || push then continue
    if Explain.countWord t j > 0 then
      return some s!"`{t}` uses `{j}` other than as the index of an update of `{c}`"
    if Explain.countWord t c > 0 then
      -- a read of `c` is fine; anything that could rebind it is not
      let binder := ((dropChars t 4).splitOn " := ").head!
      let name := dropChars binder (if binder.startsWith "mut " then 4 else 0)
      let readOnly := t.startsWith "let " && (t.splitOn ":=").length == 2 && !has t "←" && !has t "<-" &&
        !name.isEmpty && name.toList.all Explain.isWordChar && name != c
      unless readOnly do return some s!"`{t}` may change `{c}`"
  return none

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
    let c := trim (dropRightChars (" in ".intercalate ((t.splitOn " in ").drop 1)) 3)
    if let some why := loopRewriteUnsafe src fl c then
      throw (s!"reading `{c}[i]!` instead of the elements the loop started with gives the same values only " ++
        s!"when the body changes no element it has not visited yet, which fix cannot show here ({why}): " ++
        "apply the fix by hand if it holds")
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
  pairs : Nat := 20
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

/-- How `fix` runs a program and waits for it, and how it stops after a
signal. The command line (`LeanprofCli.lean`) installs a runner that passes
INT, TERM and HUP on to the child and a check that throws once one was
caught (`c/cli.c`), so that `fix`'s cleanup runs; the defaults are plain
`IO.Process.output` and no check. -/
structure Runner where
  output : IO.Process.SpawnArgs → IO IO.Process.Output := IO.Process.output
  interrupted : IO Unit := pure ()

instance : Inhabited Runner := ⟨{}⟩

initialize runner : IO.Ref Runner ← IO.mkRef {}

/-- Run `cmd` (in `cwd`), capturing its output; a missing program is exit
code 127. Throws, before or after the child, if a signal was caught
(`stop := false`, for the cleanup itself: it runs anyway). -/
def capture (cmd : String) (args : Array String) (env : Array (String × Option String) := #[])
    (cwd : Option FilePath := none) (stop := true) : IO IO.Process.Output := do
  let r ← runner.get
  if stop then r.interrupted
  let out ← try r.output { cmd, args, env, cwd, stdin := .null }
    catch e => pure { exitCode := 127, stdout := "", stderr := toString e }
  if stop then r.interrupted
  return out

def git (args : Array String) (cwd : Option FilePath := none) : IO String := do
  let out ← capture "git" args (cwd := cwd)
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
the way `lake exe` runs it in the project `cwd`, and its exit code. -/
def plainRun (cwd : FilePath) (exe : String) (args : Array String) (checkOutput : Option String) :
    IO (UInt32 × String) := do
  let at_ (f : String) : FilePath := if (f : FilePath).isAbsolute then f else cwd / f
  if let some f := checkOutput then
    if ← (at_ f).pathExists then IO.FS.removeFile (at_ f)
  let out ← capture "lake" (#["env", ((".lake" : FilePath) / "build" / "bin" / exe).toString] ++ args) (cwd := cwd)
  match checkOutput with
  | some f =>
    if ← (at_ f).pathExists then
      let b ← IO.FS.readBinFile (at_ f)
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

/-- Why the project cannot be checked in a git worktree: a path dependency
(`lake-manifest.json`) given relative to the project that leads out of the
repository, which the worktree's copy of the path would not reach. -/
def outsidePathDeps (cwd top : FilePath) : IO (Option String) := do
  let m := cwd / "lake-manifest.json"
  unless ← m.pathExists do return none
  let some j := (Json.parse (← IO.FS.readFile m)).toOption | return none
  let top ← IO.FS.realPath top
  for p in jarr j "packages" do
    unless jstr p "type" == "path" do continue
    let d : FilePath := jstr p "dir"
    if d.isAbsolute then continue
    let r ← try IO.FS.realPath (cwd / d) catch _ => pure (cwd / d)
    unless r.toString.startsWith (top.toString ++ "/") do
      return some (s!"the path dependency {jstr p "name"} ({d}) is outside the git repository, so a git " ++
        "worktree of it would not find it: apply the fix by hand (--dry-run prints it)")
  return none

/-- `leanprof fix`. `runSelf args cwd` runs another leanprof command
(`run`, `measure`, `measure-pair`) in `cwd`, capturing its output. Exit
code 0: KEEP (or `--dry-run` printed a fix); 1: DISCARD, or no finding has a
mechanical fix. -/
def fixCmd (argv : List String) (runSelf : Array String → FilePath → IO IO.Process.Output) : IO UInt32 := do
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
    let out ← runSelf (#["run", "--json", o.report, exe, "--"] ++ o.args) (← IO.currentDir)
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
  -- everything from here runs in a git worktree of HEAD, never in the
  -- user's checkout: an interruption, a crash or a test that writes files
  -- cannot leave the candidate there. On KEEP the checkout gets the branch.
  let cwd ← IO.currentDir
  let absDir := cwd / dir
  let top : FilePath := ← git #["rev-parse", "--show-toplevel"]
  let pre ← git #["rev-parse", "--show-prefix"]
  let head ← git #["rev-parse", "HEAD"]
  unless (← capture "git" #["ls-files", "--error-unmatch", "--", file]).exitCode == 0 do
    IO.eprintln s!"leanprof fix: {file} is not committed: fix checks the edit in a git worktree of HEAD"; return 2
  if let some why ← outsidePathDeps cwd top then
    IO.eprintln s!"leanprof fix: {why}"; return 2
  let wtRoot := absDir / "worktree"
  -- a worktree left by a run that was killed (SIGKILL cannot be caught)
  discard <| capture "git" #["worktree", "remove", "--force", wtRoot.toString]
  if ← wtRoot.pathExists then IO.FS.removeDirAll wtRoot
  discard <| capture "git" #["worktree", "prune"]
  let wt := if pre.isEmpty then wtRoot else wtRoot / pre
  let removeWorktree : IO Unit := do
    let r ← capture "git" #["worktree", "remove", "--force", wtRoot.toString] (stop := false)
    if r.exitCode != 0 then
      try IO.FS.removeDirAll wtRoot catch _ => pure ()
      discard <| capture "git" #["worktree", "prune"] (stop := false)
  -- a reference: `finally` does not see the updates of a `let mut` made in `try`
  let keptRef ← IO.mkRef (none : Option (String × String))
  let reasons ← IO.mkRef (#[] : Array String)
  let wtFile := wt / file
  try
    discard <| git #["worktree", "add", "--detach", "-q", wtRoot.toString, head]
    -- the dependencies as they are (no download, no rebuild); the
    -- project's own build as a starting point
    if ← (cwd / ".lake" / "packages").pathExists then
      IO.FS.createDirAll (wt / ".lake")
      discard <| capture "ln" #["-s", (cwd / ".lake" / "packages").toString, (wt / ".lake" / "packages").toString]
    if ← (cwd / ".lake" / "build").pathExists then
      IO.FS.createDirAll (wt / ".lake")
      let c ← capture "cp" #["-cRp", (cwd / ".lake" / "build").toString, (wt / ".lake" / "build").toString]
      if c.exitCode != 0 then
        if ← (wt / ".lake" / "build").pathExists then IO.FS.removeDirAll (wt / ".lake" / "build")
        discard <| capture "cp" #["-Rp", (cwd / ".lake" / "build").toString, (wt / ".lake" / "build").toString]
    let testCmd ← match o.test with
      | some t => pure (some t)
      | none => do
        if (← capture "lake" #["check-test"] (cwd := wt)).exitCode == 0 then pure (some "lake test") else pure none
    let testsText := match testCmd with
      | some t => s!"`{t}`"
      | none => "none (no --test CMD and no Lake test driver)"
    let build : IO (Except String Unit) := do
      let out ← capture "lake" #["build", exe] (cwd := wt)
      log s!"lake build {exe}" out
      return if out.exitCode == 0 then .ok () else .error (tailOf (out.stdout ++ out.stderr))
    let runTests : IO (Except String Unit) := do
      let some t := testCmd | return .ok ()
      let out ← capture "sh" #["-c", t] (cwd := wt)
      log t out
      return if out.exitCode == 0 then .ok () else .error (tailOf (out.stdout ++ out.stderr))
    let checkArgs := match o.checkOutput with | some f => #["--check-output", f] | none => #[]
    let measure (out : FilePath) : IO (Except String Judge.Summary) := do
      let r ← runSelf (#["measure", "--runs", toString o.runs] ++ (if o.deps then #[] else #["--no-deps"]) ++
        checkArgs ++ #["--out", out.toString, exe, "--"] ++ o.args) wt
      log s!"leanprof measure into {out}" r
      if r.exitCode != 0 then return .error (tailOf (r.stdout ++ r.stderr))
      let j ← IO.ofExcept (Json.parse (← IO.FS.readFile out))
      return Judge.Summary.ofJson j
    let binPath : FilePath := wt / ".lake" / "build" / "bin" / exe
    let keepBinary (to : FilePath) : IO Unit := do
      let out ← capture "cp" #["-p", binPath.toString, to.toString]
      unless out.exitCode == 0 do throw <| IO.userError s!"could not copy {binPath}: {out.stderr}"
    -- the original must build and pass its tests, or nothing can be checked
    IO.println s!"\nleanprof fix: the original, in a git worktree of HEAD ({dir / "worktree"}): build, tests ({testsText}), output, measure ({o.runs} runs)"
    if let .error e := ← build then
      throw <| IO.userError s!"{exe} does not build before any change (in a worktree of HEAD: untracked files are not in it):\n{e}"
    if let .error e := ← runTests then
      throw <| IO.userError s!"the tests fail before any change, so a fix cannot be checked:\n{e}"
    let (baseCode, baseOut) ← plainRun wt exe o.args o.checkOutput
    keepBinary (absDir / "base-bin")
    let base ← match ← measure (absDir / "base.json") with
      | .ok s => pure s
      | .error e => throw <| IO.userError s!"measuring the original failed:\n{e}"
    IO.println s!"  copies {groupDigits base.copies}, exit code {baseCode}, time median {Judge.fmtMs base.median}"
    let original ← IO.FS.readFile wtFile
    for h : i in [0:plans.size] do
      let plan := plans[i]
      let tag := s!"alternative {i + 1} ({plan.what})"
      IO.println s!"\nleanprof fix: {tag}"
      let candidate := "\n".intercalate (applyEdits src plan.edits).toList
      IO.FS.writeFile wtFile candidate
      let fail (why : String) : IO Unit := do
        IO.println (Explain.wrap s!"  DISCARD: {why}" "    ")
        IO.FS.writeFile wtFile original
      if let .error e := ← build then
        fail s!"it does not build:\n{e}"; reasons.modify (·.push <| s!"{tag}: it does not build"); continue
      IO.println "  builds"
      if let .error e := ← runTests then
        fail s!"the tests fail ({testsText}):\n{e}"; reasons.modify (·.push <| s!"{tag}: the tests fail"); continue
      if testCmd.isSome then IO.println s!"  tests pass ({testsText})"
      let (code, out) ← plainRun wt exe o.args o.checkOutput
      if code != baseCode then
        let why := s!"the exit code changed: {baseCode} -> {code}"
        fail why; reasons.modify (·.push <| s!"{tag}: {why}"); continue
      if out != baseOut then
        let why := s!"the output changed ({o.checkOutput.getD "stdout"}), {firstDifference baseOut out}"
        fail why; reasons.modify (·.push <| s!"{tag}: {why}"); continue
      IO.println s!"  output identical ({o.checkOutput.getD "stdout"}, {out.utf8ByteSize} bytes)"
      keepBinary (absDir / "candidate-bin")
      let mut new : Judge.Summary := {}
      match ← measure (absDir / "new.json") with
      | .ok s => new := s
      | .error e =>
        fail s!"measuring it failed:\n{e}"; reasons.modify (·.push <| s!"{tag}: measuring it failed"); continue
      let exact := Judge.judge base new
      IO.println s!"  leanprof judge (measure, {o.runs} runs each):\n{verdictLines exact}"
      unless exact.keep do
        let why := "`judge` of the two measure summaries says DISCARD: " ++
          (if exact.worse.isEmpty then "nothing improved beyond noise" else "; ".intercalate exact.worse.toList)
        fail why; reasons.modify (·.push <| s!"{tag}: {why}"); continue
      let pairOut ← runSelf (#["measure-pair", "--base", (absDir / "base-bin").toString,
        "--candidate", (absDir / "candidate-bin").toString, "--runs", toString o.pairs,
        "--out", (absDir / "paired.json").toString] ++ checkArgs ++ #["--"] ++ o.args) wt
      log "leanprof measure-pair" pairOut
      if pairOut.exitCode != 0 then
        fail s!"measure-pair failed:\n{tailOf (pairOut.stdout ++ pairOut.stderr)}"
        reasons.modify (·.push <| s!"{tag}: measure-pair failed"); continue
      let pj ← IO.ofExcept (Json.parse (← IO.FS.readFile (absDir / "paired.json")))
      let paired ← IO.ofExcept (Judge.judgePaired pj 1 o.allowOverloaded)
      IO.println s!"  leanprof judge (measure-pair, {o.pairs} pairs of plain binaries):\n{verdictLines paired}"
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
        s!"- leanprof measure-pair ({o.pairs} pairs of plain binaries, AB/BA order), leanprof judge:\n" ++
          s!"{verdictLines paired}\n"
      IO.FS.writeFile (absDir / "commit-message.txt") msg
      discard <| git #["commit", "-q", "-F", (absDir / "commit-message.txt").toString, "--", file] (cwd := wt)
      let sha ← git #["rev-parse", "HEAD"] (cwd := wt)
      keptRef.set (some (sha, plan.what))
      break
    -- the branch, in the user's repository, only for a kept commit
    if let some (sha, _) ← keptRef.get then
      let mut branch := o.branch.getD (branchName (jstr f "function") (jstr f "cause"))
      if o.branch.isNone then
        let stem := branch
        let mut n := 2
        while (← capture "git" #["rev-parse", "--verify", "--quiet", s!"refs/heads/{branch}"]).exitCode == 0 do
          branch := s!"{stem}-{n}"; n := n + 1
      discard <| git #["branch", branch, sha]
      keptRef.set (some (← git #["rev-parse", "--short", sha], branch))
  finally
    removeWorktree
  match ← keptRef.get with
  | some (sha, branch) =>
    IO.println s!"\nKEEP: committed {sha} on branch {branch}; your checkout is unchanged (the checks ran in a git worktree)."
    IO.println s!"  see it: git show {branch}    take it: git merge {branch}"
    IO.println s!"  (the commit message holds the evidence; the steps' output is in {logPath})"
    return 0
  | none =>
    IO.println s!"\nDISCARD: no alternative was kept and no branch was created; your checkout is unchanged."
    for r in ← reasons.get do IO.println (Explain.wrap s!"  - {r}" "    ")
    IO.println s!"  (the steps' output is in {logPath})"
    return 1

end Leanprof.Fix
