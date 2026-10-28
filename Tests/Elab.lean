import LeanprofElab

/-! Tests of `leanprof elab`'s trace reading (LeanprofElab.lean), on traces in
the format `lean --json -Dtrace.profiler=true` prints. -/

open Leanprof.Elab

namespace Tests.Elab

/-- An `isDefEq` that unfolds `Foo.bar` (and inside that, `Foo.bar` again and
`Foo.baz`), an instance tried, and a simp rewrite after its unification. -/
def sample : String := "[Elab.command] [0.010000] ✅️ theorem t : x = y := by simp
  [Meta.isDefEq] [0.006000] ✅️ Foo.bar 1 =?= 2
    [Meta.isDefEq.delta.unfoldLeft] Foo.bar
    [Meta.isDefEq] [0.005000] ✅️ Foo.baz 1 =?= 2
      [Meta.isDefEq.delta.unfoldLeft] Foo.bar
      [Meta.isDefEq] [0.001000] ✅️ 1 =?= 2
      [Meta.isDefEq.delta.unfoldRight] Foo.baz
      [Meta.isDefEq] [0.002000] ✅️ 3 =?= 2
  [Meta.synthInstance.apply] [0.001500] ✅️ apply @instAddNat to Add Nat
  [Meta.isDefEq] [0.000700] ✅️ ?a + ?b =?= x + y
  [Meta.Tactic.simp.rewrite] Nat.add_comm:1000:
        x + y
      ==>
        y + x
  [Meta.whnf] [0.000300] ✅️ Non-easy whnf: ?n + ?m = ?m + ?n"

def diag : String := "[diag] Diagnostics
  [reduction] unfolded declarations (max: 5, num: 2):
    [reduction] Foo.bar ↦ 5
    [reduction] outParam ↦ 2
  [kernel] unfolded declarations (max: 9, num: 1):
    [kernel] Nat.rec ↦ 9
  use `set_option diagnostics.threshold <num>` to control threshold for reporting counters"

def simpDiag : String := "[simp] Diagnostics
  [simp] used theorems (max: 1, num: 1):
    [simp] eq_self ↦ 1
  [simp] tried theorems (max: 3, num: 2):
    [simp] Nat.add_comm ↦ 3, succeeded: 1
    [simp] Nat.add_eq_left ↦ 2 ❌️
  use `set_option diagnostics.threshold <num>` to control threshold for reporting counters"

def near (x y : Float) : Bool := (x - y).abs < 1e-9

/-- A trace of `4 * n` operations in one message, as one declaration's trace
can be: `isDefEq` checks whose descriptions need JSON escapes (quotes,
backslashes, tabs, control characters), unfolds, and steps with long
descriptions that are never reported. -/
def bigTrace (n : Nat) : String := Id.run do
  let long := String.ofList (List.replicate 300 'x')
  let mut s := "[Elab.command] [90000000] ✅️ def big : String := \"q\\\\\""
  for i in [0:n] do
    s := s ++ s!"\n  [Meta.isDefEq] [{100 + i % 7}] ✅️ f{i % 50} ?m.{i} \"x\"\t=?= g «α» \\ \x01 y"
    s := s ++ s!"\n    [Meta.isDefEq.delta.unfoldLeft] Foo.f{i % 13}"
    s := s ++ s!"\n    [Meta.isDefEq] [{40 + i % 3}] ✅️ a =?= b"
    s := s ++ s!"\n  [Elab.app] [20] ✅️ {long}"
  return s

/-- What the report is made of, to compare two accumulators. -/
def summary (a : Acc) : String :=
  let sorted (xs : Array String) := (xs.qsort (· < ·)).toList
  toString (a.grand, sorted (a.byClass.toArray.map fun (k, x) => s!"{k} {x}"),
    sorted (a.ops.toArray.map fun ((c, t), o) => s!"{c} {t} {o.count} {o.total} {o.maxOne} {o.firstAt}"),
    sorted (a.consts.toArray.map fun (k, c) => s!"{k} {c.kind} {c.cost} {c.count} {c.sites.size} {sorted (c.diag.toArray.map toString)}"),
    sorted (a.lines.toArray.map fun (k, c) => s!"{k} {c.total} {c.elaboration} {c.name} {c.top} {c.consts.size}"))

def run (check : String → Bool → String → StateT Nat IO Unit) : StateT Nat IO Unit := do
  let nodes := parseTrace sample
  check "elab: untimed unfold and simp lines are part of the tree"
    (nodes.size == 12 && nodes[2]!.cls == "Meta.isDefEq.delta.unfoldLeft" && !nodes[2]!.timed &&
      nodes[2]!.parent == some 1) s!"nodes={nodes.size}"
  check "elab: a description that looks like a timed line is not one"
    ((traceLine "      [x] [6] ++ xs").isNone && (traceLine "  [Meta.whnf] [0.5] ✅️ e").isSome) ""
  check "elab: a simp rewrite's description is one node" (nodes[10]!.text.startsWith "Nat.add_comm:1000:") ""
  let at_ := attributions nodes
  let cost (n : String) : Float := at_.foldl (fun s (c, _, x) => if c == n then s + x.getD 0 else s) 0
  let times (n : String) : Nat := (at_.filter (·.1 == n)).size
  -- unfolding Foo.bar costs the comparison after it (5 ms); its nested unfold of
  -- Foo.bar is counted but not charged again
  check "elab: an unfold is charged the comparison after it, once per nest"
    (near (cost "Foo.bar") 0.005 && times "Foo.bar" == 2) s!"cost={cost "Foo.bar"} times={times "Foo.bar"}"
  check "elab: a nested unfold of another constant is charged too" (near (cost "Foo.baz") 0.002)
    s!"cost={cost "Foo.baz"}"
  check "elab: an instance tried is charged its attempt" (near (cost "instAddNat") 0.0015) ""
  check "elab: a simp rewrite is charged the unification before it" (near (cost "Nat.add_comm") 0.0007)
    s!"cost={cost "Nat.add_comm"}"
  check "elab: whnf of notation names no constant" ((at_.filter (·.2.1 == "whnf")).isEmpty) ""
  let d := parseDiag diag
  check "elab: diagnostics counts" (d == #[("Foo.bar", "unfolds", 5), ("outParam", "unfolds", 2), ("Nat.rec", "kernel", 9)])
    s!"{d}"
  let s := parseDiag simpDiag
  check "elab: simp diagnostics, with failures"
    (s == #[("eq_self", "simp_used", 1), ("Nat.add_comm", "simp_tried", 3), ("Nat.add_comm", "simp_failed", 2),
      ("Nat.add_eq_left", "simp_tried", 2), ("Nat.add_eq_left", "simp_failed", 2)]) s!"{s}"
  check "elab: diagnostics messages are recognized" (isDiagMessage diag && isDiagMessage simpDiag && !isDiagMessage sample) ""
  check "elab: module globs" (globMatch "Batteries.Data.*".toList "Batteries.Data.List.Lemmas".toList &&
    !globMatch "Batteries.Data.*".toList "Batteries.Tactic.Alias".toList && globMatch "*Lemmas".toList "A.Lemmas".toList) ""
  check "elab: private and numeric names" (parseName "_private.Foo.0.Foo.bar" == .str (.str (.num (.str (.str .anonymous "_private") "Foo") 0) "Foo") "bar" &&
    userName "_private.Foo.0.Foo.bar" == "Foo.bar" && parseName "«a.b».c" == .str (.str .anonymous "a.b") "c") ""
  let src := #["theorem t : True := by", "  simp [foo,  bar]", "  omega"].map squash
  check "elab: tactics are found in the source by their text"
    (findTactic src "simp [foo, bar]" 1 == some 2 && findTactic src "omega" 2 == some 3 && findTactic src "decide" 1 == none) ""
  -- never in comments (concrete: `simp` placed at a comment saying "simply"); a
  -- description `pp.oneline` cut is matched by its first line
  let src2 := (codeOnly #["theorem t : True := by", "  -- this simply works", "  /- first a doc",
    "     with simp -/", "  first", "  | simp", "  | omega"]).map squash
  check "elab: tactics are not found in comments"
    (findTactic src2 "simp" 1 == some 6 && findTactic src2 "first [...]" 1 == some 5) s!"{src2}"
  -- `theorem Foo.bar` is elaborated as `namespace Foo theorem bar end`: Lean traces the
  -- inner command, then the outer one (including the inner's time) at the same position
  let msg (data : String) (col : Nat) : Lean.Json := Lean.Json.mkObj [("data", .str data),
    ("pos", Lean.Json.mkObj [("line", (3 : Nat)), ("column", col)])]
  let a := ({} : Acc).addMessage "F.lean" 1 (msg "[Elab.command] [100] ✅️ theorem bar : True := trivial" 0)
  let a := a.addMessage "F.lean" 1 (msg "[Elab.command] [104] ✅️ theorem Foo.bar : True := trivial" 0)
  let a := a.addMessage "F.lean" 1 (msg "[Elab.command] [7] ✅️ def c := 1" 30)
  check "elab: a command and the command it expands into are not counted twice"
    (near a.grand 111 && near ((a.lines.get? "F.lean:3").map (·.total) |>.getD 0) 111) s!"grand={a.grand}"
  -- `--cache`: a file's result written and read back is the same result, to the bit
  let b := a.addMessage "F.lean" 1e9 (msg sample 40)
  let fc : FileCost := { module := "F", total := 0.1, wallNs := 7, errors := 1, firstError := "3: x" }
  let sr : SrcRange := { range := "3:0-3:9", line := 3, kind := "k", text := "simp" }
  let rc : RangeCost := { total := 1 / 3, count := 2, tactic := true, src := sr }
  let b := { b with files := #[("F.lean", fc)], ranges := b.ranges.insert "F.lean:3:0-3:9" rc }
  let back := (Lean.Json.parse (Ser.enc b).compress >>= Ser.dec (α := Acc))
  check "elab: a file's result is the same after the cache"
    (match back with
     | .ok c => summary c == summary b && c.grand.toBits == b.grand.toBits && c.files.size == 1 &&
         (c.files[0]?.map (·.2.firstError)) == some "3: x" && ((c.ranges.get? "F.lean:3:0-3:9").map (·.total.toBits)) == some (1 / 3 : Float).toBits
     | .error _ => false) (match back with | .ok _ => "" | .error e => e)
  -- exact source ranges: the driver's source nodes (a tactic sequence, a tactic whose
  -- macro expansion has its range, a term nested on the same line)
  check "elab: a source node's description"
    (parseSrcRange "@12:3-12:40 Lean.Parser.Tactic.simp | simp [a | b]" ==
      some { range := "12:3-12:40", line := 12, kind := "Lean.Parser.Tactic.simp", text := "simp [a | b]" } &&
     parseSrcRange "omega" == none && shortKind "Lean.Parser.Tactic.omega" == "omega") ""
  -- the driver for another Lean is built from the source compiled into the command,
  -- linked against that Lean's core shared libraries, kept by commit, source and Lean directory
  if let some disk ← (try some <$> IO.FS.readFile "LeanprofElabDriver.lean" catch _ => pure none) then
    check "elab: the driver source compiled into the command is LeanprofElabDriver.lean" (driverSource == disk) ""
  let flags ← sharedLibFlags ((← Lean.findSysroot) / "lib" / "lean")
  check "elab: a driver is linked against Lean's core shared libraries"
    (flags.contains "-lleanshared" && flags.contains "-lInit_shared" && !flags.contains "-lLake_shared") s!"{flags}"
  let d1 ← cachedDriverDir "/a/lean" "0123456789abcdef"
  let d2 ← cachedDriverDir "/b/lean" "0123456789abcdef"
  let d3 ← cachedDriverDir "/a/lean" "0123456789abcdef"
  check "elab: drivers are cached by Lean commit and directory"
    (d1 == d3 && d1 != d2 && (d1.fileName.getD "").startsWith "0123456789ab-" && d1.parent.bind (·.fileName) == some "drivers")
    s!"{d1} {d2}"
  check "elab: a command named without the `set_option … in` and `open … in` before it"
    (dropInPrefix "set_option maxHeartbeats 400000 in open Foo Bar in theorem t : True := trivial" ==
      "theorem t : True := trivial" && dropInPrefix "open Foo" == "open Foo" &&
     dropInPrefix "variable (W' : C R) in\ndef f := 1" == "def f := 1" &&
     dropInPrefix "variable (W' : C R)" == "variable (W' : C R)") ""
  -- with the driver, `variable (W') in /-- long doc -/ def f` is one command: named after `f`
  let src := #["", "", "variable (W') in", "/-- A doc comment longer than the description that is kept of the", "command. -/",
    "noncomputable def negDblY (P : Fin 3 → R) : R :="]
  let w := ({ src } : Acc).addMessage "F.lean" 1 (msg "[Elab.command] [5] ✅️ variable (W') in\n  /-- A doc comment longer than" 0)
  check "elab: a declaration under `variable … in` and a long doc comment is named after the declaration"
    ((((w.lines.get? "F.lean:3").map (·.name)).getD "").startsWith "noncomputable def negDblY")
    (((w.lines.get? "F.lean:3").map (·.name)).getD "")
  -- `pp.oneline` (concrete's Check.lean: a 1.74 GB message without it): a command cut
  -- to `mutual [...]` is named from the source, and different terms cut to the same
  -- first line (`term do [...]`) are not counted as repeated work
  let src := #["", "", "mutual", "def f : Nat := 1"]
  let cut := "[Elab.command] [100] ✅️ mutual [...]
  [Elab.step] [40] ✅️ expected type: Nat, term do [...]
  [Elab.step] [40] ✅️ expected type: Nat, term do [...]
  [Meta.synthInstance] [5] ✅️ OfNat Nat 1
  [Meta.synthInstance] [5] ✅️ OfNat Nat 1"
  let o := ({ src } : Acc).addMessage "F.lean" 1 (msg cut 0)
  check "elab: a command pp.oneline cut is named from the source"
    ((((o.lines.get? "F.lean:3").map (·.name)).getD "") == "mutual def f : Nat := 1")
    (((o.lines.get? "F.lean:3").map (·.name)).getD "")
  check "elab: cut descriptions are not repeated work, whole ones are"
    ((o.ops.toList.map (·.1.1)) == ["Meta.synthInstance"]) s!"{o.ops.toList.map (·.1)}"
  let drv := "[Elab.command] [100] ✅️ theorem t : True := by skip; trivial
  [Leanprof.tactic] [60] ✅️ @2:3-3:10 Lean.Parser.Tactic.tacticSeq | skip; trivial
    [Leanprof.tactic] [10] ✅️ @2:3-2:7 Lean.Parser.Tactic.skip | skip
    [Leanprof.tactic] [45] ✅️ @3:3-3:10 Lean.Parser.Tactic.trivial | trivial
      [Leanprof.tactic] [40] ✅️ @3:3-3:10 Lean.Parser.Tactic.exact | trivial
        [Meta.isDefEq] [30] ✅️ True =?= True
        [Leanprof.term] [2] ✅️ @3:5-3:10 Lean.Parser.Term.app | ivial"
  let e := ({ exact := true } : Acc).addMessage "F.lean" 1 (msg drv 0)
  let rc (k : String) : Float := ((e.ranges.get? s!"F.lean:{k}").map (·.total)).getD (-1)
  check "elab: exact ranges, once per range, without tactic sequences"
    (near (rc "2:3-2:7") 10 && near (rc "3:3-3:10") 45 && near (rc "3:5-3:10") 2 && rc "2:3-3:10" == -1 &&
      e.ranges.size == 3) s!"{e.ranges.toList.map fun (k, c) => (k, c.total)}"
  check "elab: tactics by line from exact ranges, the outermost on each line"
    ((e.tactics.get? "F.lean:2").map (·.1) == some 10 && (e.tactics.get? "F.lean:3").map (·.1) == some 45 &&
      e.tacticRanges.get? "F.lean:3" == some "F.lean:3:3-3:10") s!"{e.tactics.toList}"
  check "elab: source nodes are transparent in self time per kind"
    (near (e.byClass.getD "Elab.command" 0) 70 && near (e.byClass.getD "Meta.isDefEq" 0) 30 &&
      !e.byClass.contains "Leanprof.tactic") s!"{e.byClass.toList}"
  -- `variable (k) in theorem t ...` (lines 3-4) is elaborated as `section variable (k)
  -- theorem t ... end`: the inner commands are at their own positions, the outer one spans them
  let pos (l c : Nat) : Lean.Json := Lean.Json.mkObj [("line", l), ("column", c)]
  let msg2 (data : String) (l c l' c' : Nat) : Lean.Json := Lean.Json.mkObj [("data", .str data),
    ("pos", pos l c), ("endPos", pos l' c')]
  let b := ({} : Acc).addMessage "F.lean" 1 (msg2 "[Elab.command] [1] ✅️ section" 3 19 3 21)
  let b := b.addMessage "F.lean" 1 (msg2 "[Elab.command] [2] ✅️ variable (k : Nat)" 3 0 3 18)
  let b := b.addMessage "F.lean" 1 (msg2 "[Elab.command] [100] ✅️ theorem t : True := trivial" 4 0 4 30)
  let b := b.addMessage "F.lean" 1 (msg2 "[Elab.command] [1] ✅️ end" 3 19 3 21)
  let b := b.addMessage "F.lean" 1 (msg2 "[Elab.command] [110] ✅️ variable (k : Nat) in theorem t : True := trivial" 3 0 4 30)
  let b := b.addMessage "F.lean" 1 (msg2 "[Elab.command] [5] ✅️ def c := 1" 6 0 6 10)
  check "elab: a command wrapped in `variable ... in` is not counted twice, and keeps its cost on its line"
    (near b.grand 115 && near ((b.lines.get? "F.lean:4").map (·.total) |>.getD 0) 100 &&
      near ((b.lines.get? "F.lean:3").map (·.total) |>.getD 0) 10) s!"grand={b.grand}"
  let c := ({} : Acc).addMessage "F.lean" 1 (msg2 "[Elab.command] [1] ✅️ variable (W')" 8 0 8 3)
  let c := c.addMessage "F.lean" 1 (msg2 "[Elab.command] [50] ✅️ def dblX (P : Nat) : Nat := P" 8 0 9 10)
  check "elab: a line is named after the command on it that declares something"
    (((c.lines.get? "F.lean:8").map (·.name)).getD "" == "def dblX (P : Nat) : Nat := P") ""
  -- a declaration whose doc comment is longer than the description kept: named from the source
  let src := #["variable (k) in", "/-- A long doc", "comment. -/", "def foo (n : Nat) : Nat := n"]
  let d := ({ src } : Acc).addMessage "F.lean" 1 (msg2 "[Elab.command] [1] ✅️ section" 2 0 2 3)
  let d := d.addMessage "F.lean" 1 (msg2 "[Elab.command] [50] ✅️ /--\n    A long doc" 2 0 4 30)
  check "elab: a declaration with a long doc comment is named after the declaration"
    (((d.lines.get? "F.lean:2").map (·.name)).getD "" == "def foo (n : Nat) : Nat := n")
    (((d.lines.get? "F.lean:2").map (·.name)).getD "")
  let src := #["variable {k : Nat}", "", "variable (k) in", "/-- A long documentation comment that goes on for a while, longer than the text leanprof keeps of", "a description, so that its end is not in it.", "", "More text here. -/", "def foo (n : Nat) : Nat := (List.range (n + k)).foldl (· + ·) 0"]
  let e := ({ src } : Acc).addMessage "F.lean" 1 (msg2 "[Elab.command] [0.000027] ✅️ section" 3 13 3 15)
  let e := e.addMessage "F.lean" 1 (msg2 "[Elab.command] [0.000080] ✅️ variable (k)\n  [Elab.step] [0.000046] ✅️ expected type: Type, term\n      Nat" 3 0 3 12)
  let e := e.addMessage "F.lean" 1 (msg2 "[Elab.command] [0.000016] ✅️ failed to pretty print term (use 'set_option pp.rawOnError true' for raw representation)" 3 13 3 15)
  let e := e.addMessage "F.lean" 1 (msg2 "[Elab.command] [0.001639] ✅️ /--\n    A long documentation comment that goes on for a while, longer than the text leanprof keeps of\n    a description, so that its end is not in it.\n    \n    More text here. -/\n  def foo (n : Nat) : Nat :=\n    (List.range (n + k)).foldl (fun x1 x2 => x1 + x2) 0" 4 0 8 63)
  check "elab: a declaration whose kept text ends with its doc comment is named from the source"
    ((((e.lines.get? "F.lean:4").map (·.name)).getD "").startsWith "def foo (n : Nat)")
    (((e.lines.get? "F.lean:4").map (·.name)).getD "")
  check "elab: digit groups" (groupDigits 10000 == "10,000" && groupDigits 1234567 == "1,234,567" && groupDigits 999 == "999") ""
  check "elab: leading constants" (leadingConst "@instFoo to X" == some "instFoo" && leadingConst "inst✝ to X" == none &&
    leadingConst "?m.1 x" == none && leadingConst "Size α" == some "Size") ""
  -- declarations in the source are qualified with their namespace: a bare `def run`
  -- or `private def operation` elsewhere is not `Id.run` or `Other.operation`
  let ns := namespacesOf "import X\nnamespace A.B\ndef run := 1\nnoncomputable section\nprivate def op := 2\nend\nend A.B\ndef top := 3"
  check "elab: namespaces by line" (ns == #["", "A.B", "A.B", "A.B", "A.B", "A.B", "", ""]) s!"{ns}"
  let decls : Std.HashMap String Nat := ({} : Std.HashMap String Nat) |>.insert "A.B.run" 3 |>.insert "A.B.op" 5 |>.insert "top" 8
  check "elab: declarations found by qualified name, not by their last component"
    (findDecl? decls "A.B.run" == some 3 && findDecl? decls "Root.A.B.op" == some 5 && findDecl? decls "top" == some 8 &&
      findDecl? decls "Id.run" == none && findDecl? decls "Other.op" == none && findDecl? decls "B.run" == none) ""
  -- Lean's `--json` output with a multi-megabyte message (one line), a diagnostics
  -- message, an error, a line that is not JSON and a last message without a newline:
  -- read as it streams in, the report is the one from parsing each line whole
  let big := bigTrace 20000
  let msgs : Array Lean.Json := #[
    Lean.Json.mkObj [("data", .str big), ("pos", Lean.Json.mkObj [("line", (3 : Nat)), ("column", (0 : Nat))]),
      ("severity", "information")],
    Lean.Json.mkObj [("data", .str diag), ("pos", Lean.Json.mkObj [("line", (9 : Nat)), ("column", (0 : Nat))]),
      ("severity", "information")],
    Lean.Json.mkObj [("data", .str "unknown identifier 'x'"), ("severity", "error")],
    msg "[Elab.command] [7] ✅️ def c := 1" 30]
  let lines := msgs.map (·.compress)
  let out := "\n".intercalate (lines.toList.take 3) ++ "\nnot json {\"data\":\"x\n" ++ lines[3]!
  let whole := lines.foldl (fun a l => match Lean.Json.parse l with
    | .ok m => a.addMessage "F.lean" 1 m
    | .error _ => a) ({} : Acc)
  for chunk in [7, 1048576] do
    let buf ← IO.mkRef ({ data := out.toUTF8 } : IO.FS.Stream.Buffer)
    let acc ← IO.mkRef ({} : Acc)
    let errors ← IO.mkRef 0
    let kept ← IO.mkRef 0  -- bytes of descriptions kept from the big message
    readMessages (IO.FS.Stream.ofBuffer buf) (chunk := chunk) fun m p => do
      if str m "severity" == "error" then errors.modify (· + 1)
      if let .trace nodes := p then
        if nodes.size > 1000 then kept.set (nodes.foldl (· + ·.text.utf8ByteSize) 0)
      acc.modify (·.addParsed "F.lean" 1 m p)
    let a ← acc.get
    check s!"elab: a {big.utf8ByteSize / 1000000} MB message read as it streams in ({chunk}-byte reads) gives the same report"
      (summary a == summary whole && (← errors.get) == 1 && near a.grand (90000000 + 7) &&
        (a.consts.get? "Foo.bar").any (·.diag.contains "unfolds"))
      s!"grand={a.grand} errors={← errors.get}"
    check s!"elab: descriptions that are never reported are not kept ({chunk}-byte reads)"
      ((← kept.get) * 4 < big.utf8ByteSize) s!"kept={← kept.get} of {big.utf8ByteSize}"

end Tests.Elab
