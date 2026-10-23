import BenchScope
import BenchKernels
import Std.Data.HashMap

/-!
Workloads with known ground truth, for `bench/run.py`.

`wl WORKLOAD [SCALE]` runs one workload (SCALE in percent, default 100) and
prints one line `BENCH_JSON {...}` with the wall time of each phase measured
by the program itself (one clock read before and after each phase, nothing
inside), the exact number of calls each annotated function makes, and, where
known, allocations and copies. Phases run one after another, so in the plain
build the phase times are the ground truth for every tool's share of time.

This file is built three times (see `BenchScope.lean`): `WlProf.lean` and
`WlSpans.lean` are symbolic links to it.
-/

open K

set_option linter.unusedVariables false  -- `span!` drops its name outside WlSpans

namespace W

/-! ## tiny: tight loops of tiny functions -/

@[noinline] def phTinyA (n : Nat) : UInt64 := scope! "phTinyA" (Id.run do
  let mut acc : UInt64 := 0
  for i in [0:n] do
    acc := acc + scope! "tinyA" (tinyA i.toUInt64)
  return acc + 1)

@[noinline] def phTinyB (n : Nat) : UInt64 := scope! "phTinyB" (Id.run do
  let mut acc : UInt64 := 0
  for i in [0:n] do
    acc := acc + scope! "tinyB" (tinyB (acc + i.toUInt64))
  return acc + 1)

/-! ## rec: deep and wide recursion -/

/-- Non-tail recursion `n` deep, a little work per level. -/
@[noinline] def deepRec (n : Nat) (x : UInt64) : UInt64 := scope! "deepRec" (match n with
  | 0 => x
  | n + 1 => spin 8 (deepRec n x) + 1)

@[noinline] def phDeep100 (total : Nat) : UInt64 := scope! "phDeep100" (repeatU (total / 100) (deepRec 100))
@[noinline] def phDeep1k (total : Nat) : UInt64 := scope! "phDeep1k" (repeatU (total / 1000) (deepRec 1000))
@[noinline] def phDeep10k (total : Nat) : UInt64 := scope! "phDeep10k" (repeatU (total / 10000) (deepRec 10000))

/-- Tree recursion with almost nothing per call: 2·F(n+1)-1 calls. -/
@[noinline] def fib (n : Nat) : UInt64 := scope! "fib" (match n with
  | 0 => 0
  | 1 => 1
  | n + 2 => fib n + fib (n + 1))

@[noinline] def phFib (n : Nat) : UInt64 := scope! "phFib" (call fib n)

/-- Calls `fib n` makes: 2·F(n+1)-1. -/
def fibCalls (n : Nat) : Nat := Id.run do
  let mut a := 0
  let mut b := 1
  for _ in [0:n + 1] do
    (a, b) := (b, a + b)
  return 2 * a - 1

/-! ## mix: hot and cold functions, same kernel, work ratio 60:25:10:5 -/

@[noinline] def hot (x : UInt64) : UInt64 := scope! "hot" (spin 600 x + 1)
@[noinline] def warm (x : UInt64) : UInt64 := scope! "warm" (spin 250 x + 1)
@[noinline] def cool (x : UInt64) : UInt64 := scope! "cool" (spin 100 x + 1)
@[noinline] def cold (x : UInt64) : UInt64 := scope! "cold" (spin 50 x + 1)

@[noinline] def phHot (m : Nat) : UInt64 := scope! "phHot" (repeatU m hot)
@[noinline] def phWarm (m : Nat) : UInt64 := scope! "phWarm" (repeatU m warm)
@[noinline] def phCool (m : Nat) : UInt64 := scope! "phCool" (repeatU m cool)
@[noinline] def phCold (m : Nat) : UInt64 := scope! "phCold" (repeatU m cold)

/-! ## alloc: many small allocations -/

@[noinline] def mkPts : Nat → List Pt → List Pt
  | 0, acc => acc
  | n + 1, acc => mkPts n (⟨n.toUInt64, 3⟩ :: acc)

@[noinline] def sumPts (l : List Pt) : UInt64 := l.foldl (fun a p => a + p.x * p.y) 0

/-- `n` points in a list: 2n allocations (each `Pt` and each cons cell). -/
@[noinline] def allocList (n : Nat) : Nat := scope! "allocList" ((sumPts (mkPts n [])).toNat % 2)

@[noinline] def mkTree : Nat → UInt64 → Tree
  | 0, _ => .leaf
  | d + 1, v => .node (mkTree d (v * 2)) v (mkTree d (v * 2 + 1))

@[noinline] def sumTree : Tree → UInt64
  | .leaf => 0
  | .node l v r => sumTree l + v + sumTree r

/-- A complete tree of depth `d`: 2^d - 1 nodes, one allocation each. -/
@[noinline] def allocTree (d : Nat) (s : UInt64) : UInt64 := scope! "allocTree" (sumTree (mkTree d s) + 1)

@[noinline] def phAllocList (reps n : Nat) : UInt64 := scope! "phAllocList" (repeatN reps allocList n).toUInt64

@[noinline] def phAllocTree (reps d : Nat) : UInt64 := scope! "phAllocTree" (repeatU reps (allocTree d))

/-! ## copy: a hidden copy per push, against the same pushes in place -/

/-- Keeps every intermediate array, so each push copies: n-1 copies. -/
@[noinline] def buildShared (n : Nat) : Nat := scope! "buildShared" (Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut history : Array (Array Nat) := #[]
  for i in [0:n] do
    history := history.push acc
    acc := acc.push i
  return acc.size + history.size)

@[noinline] def buildExclusive (n : Nat) : Nat := scope! "buildExclusive" (Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  for i in [0:n] do
    acc := acc.push i
  return acc.size)

@[noinline] def phCopyShared (reps n : Nat) : UInt64 := scope! "phCopyShared" (repeatN reps buildShared n).toUInt64

@[noinline] def phPushExclusive (reps n : Nat) : UInt64 :=
  scope! "phPushExclusive" (repeatN reps buildExclusive n).toUInt64

/-! ## tasks: the same work on 2, 4 and 8 threads, with tiny scopes inside -/

@[inline] def taskBody (n : Nat) (seed : UInt64) : UInt64 := Id.run do
  let mut acc := seed
  for i in [0:n] do
    acc := acc + scope! "taskStep" (spin 4 (acc ^^^ i.toUInt64))
  return acc + 1

@[noinline] def taskWork2 (n : Nat) (s : UInt64) : UInt64 := scope! "taskWork2" (taskBody n s)
@[noinline] def taskWork4 (n : Nat) (s : UInt64) : UInt64 := scope! "taskWork4" (taskBody n s)
@[noinline] def taskWork8 (n : Nat) (s : UInt64) : UInt64 := scope! "taskWork8" (taskBody n s)

/-- Runs `work (n / t)` on `t` dedicated threads; returns the checksum and
the sum of the tasks' own durations (CPU time of the work). -/
def runTasks (name : String) (t n : Nat) (work : Nat → UInt64 → UInt64) : IO (UInt64 × Nat) := do
  let tasks ← (List.range t).mapM fun i => IO.asTask (prio := .dedicated) do
    let t0 ← IO.monoNanosNow
    let r ← span! name (IO.lazyPure fun _ => work (n / t) i.toUInt64)
    return (r, (← IO.monoNanosNow) - t0)
  let mut acc : UInt64 := 0
  let mut cpu := 0
  for task in tasks do
    match ← IO.wait task with
    | .ok (r, ns) => acc := acc + r; cpu := cpu + ns
    | .error e => throw e
  return (acc, cpu)

/-! ## Real programs

Three small programs of the kind people write, not loops built to be
measured. Their phases run one after another; the ground truth for each
phase's time comes from separate runs of the plain build that time only
that phase (`wl WORKLOAD SCALE PHASE`: what the phase needs is built before
the clock starts, and the other phases do not run), so no profiler and no
other phase is in the process when it is measured. Call counts are derived
from the input (the generator counts what it writes), not from the code
that is measured. -/

/-! ### interp: lexer, parser and interpreter for a tiny language

`v0 = 7; v1 = (v0 * 3) + 5; ...`: each statement defines the next variable
from literals and earlier variables, with `+`, `-`, `*` and parentheses. -/

inductive Tok where
  | num (n : UInt64)
  | ident (i : Nat)
  | plus | minus | star | lp | rp | eq | semi
  | eof
  deriving Inhabited

inductive Expr where
  | lit (v : UInt64)
  | var (i : Nat)
  | bin (op : UInt8) (l r : Expr)
  deriving Inhabited

/-- What the generator wrote: tokens, atoms (literals and variable
references), binary operators and parenthesized groups. -/
structure GenCounts where
  tokens : Nat := 0
  atoms : Nat := 0
  bins : Nat := 0
  groups : Nat := 0

/-- A deterministic pseudo-random step (64-bit LCG). -/
@[inline] def lcg (x : UInt64) : UInt64 := x * 6364136223846793005 + 1442695040888963407

/-- An expression over `v0 ..< v(i)` of depth at most `d`, as text: binary
operations below the top are parenthesized, so the parse tree is the one
generated. -/
partial def genExpr (i d : Nat) (seed : UInt64) (top : Bool) (out : String) (c : GenCounts) :
    String × UInt64 × GenCounts :=
  let s := lcg seed
  if d == 0 || (s >>> 40) % 3 == 0 then
    let s' := lcg s
    let c := { c with tokens := c.tokens + 1, atoms := c.atoms + 1 }
    if i > 0 && (s' >>> 33) % 2 == 0 then
      (out ++ "v" ++ toString ((s' >>> 20).toNat % i), s', c)
    else
      (out ++ toString ((s' >>> 24) % 1000), s', c)
  else
    let op := ["+", "-", "*"][((s >>> 35) % 3).toNat]!
    let c := { c with tokens := c.tokens + 1, bins := c.bins + 1 }
    let (out, c) := if top then (out, c) else
      (out ++ "(", { c with tokens := c.tokens + 2, groups := c.groups + 1 })
    let (out, s, c) := genExpr i (d - 1) s false out c
    let (out, s, c) := genExpr i (d - 1) s false (out ++ " " ++ op ++ " ") c
    ((if top then out else out ++ ")"), s, c)

/-- `n` statements and what they contain. -/
def genProgram (n : Nat) : String × GenCounts := Id.run do
  let mut out := ""
  let mut s : UInt64 := 12345
  let mut c : GenCounts := {}
  for i in [0:n] do
    out := out ++ "v" ++ toString i ++ " = "
    let (o, s', c') := genExpr i 5 s true out { c with tokens := c.tokens + 3 }  -- `vi`, `=`, `;`
    out := o ++ ";\n"
    s := s'
    c := c'
  return (out, c)

@[inline] def isDigit (b : UInt8) : Bool := b ≥ 48 && b ≤ 57

/-- The token at `i` (after spaces) and the index after it. -/
@[noinline] def lexToken (b : ByteArray) (i : Nat) : Tok × Nat := scope! "lexToken" (Id.run do
  let mut i := i
  while i < b.size && (b.get! i == 32 || b.get! i == 10) do
    i := i + 1
  if i ≥ b.size then return (.eof, i)
  let ch := b.get! i
  if isDigit ch then
    let mut v : UInt64 := 0
    while i < b.size && isDigit (b.get! i) do
      v := v * 10 + (b.get! i - 48).toUInt64
      i := i + 1
    return (.num v, i)
  if ch == 118 then  -- `v`
    i := i + 1
    let mut v := 0
    while i < b.size && isDigit (b.get! i) do
      v := v * 10 + (b.get! i - 48).toNat
      i := i + 1
    return (.ident v, i)
  let t := match ch with
    | 43 => Tok.plus | 45 => .minus | 42 => .star | 40 => .lp | 41 => .rp | 61 => .eq | _ => .semi
  return (t, i + 1))

/-- All the tokens of `src`. -/
@[noinline] def phLex (src : String) (_ : Nat) : Array Tok := scope! "phLex" (Id.run do
  let b := src.toUTF8
  let mut out : Array Tok := #[]
  let mut i := 0
  repeat
    let (t, j) := lexToken b i
    if let .eof := t then break
    out := out.push t
    i := j
  return out)

mutual
/-- `atom := number | variable | ( expr )` -/
@[noinline] partial def parseAtom (ts : Array Tok) (i : Nat) : Expr × Nat := scope! "parseAtom" (
  match ts[i]! with
  | .num v => (.lit v, i + 1)
  | .ident k => (.var k, i + 1)
  | _ =>  -- `(`
    let (e, j) := parseExpr ts (i + 1)
    (e, j + 1))

/-- `term := atom (* atom)*` -/
@[noinline] partial def parseTerm (ts : Array Tok) (i : Nat) : Expr × Nat := Id.run do
  let (e, j) := parseAtom ts i
  let mut e := e
  let mut j := j
  while j < ts.size && (match ts[j]! with | .star => true | _ => false) do
    let (r, k) := parseAtom ts (j + 1)
    e := .bin 2 e r
    j := k
  return (e, j)

/-- `expr := term ((+|-) term)*` -/
@[noinline] partial def parseExpr (ts : Array Tok) (i : Nat) : Expr × Nat := scope! "parseExpr" (Id.run do
  let (e, j) := parseTerm ts i
  let mut e := e
  let mut j := j
  repeat
    if j ≥ ts.size then break
    match ts[j]! with
    | .plus => let (r, k) := parseTerm ts (j + 1); e := .bin 0 e r; j := k
    | .minus => let (r, k) := parseTerm ts (j + 1); e := .bin 1 e r; j := k
    | _ => break
  return (e, j))
end

/-- Each statement `v = expr ;` in order. -/
@[noinline] def phParse (ts : Array Tok) (_ : Nat) : Array Expr := scope! "phParse" (Id.run do
  let mut out : Array Expr := #[]
  let mut i := 0
  while i + 2 < ts.size do
    let (e, j) := parseExpr ts (i + 2)  -- skip `v =`
    out := out.push e
    i := j + 1  -- `;`
  return out)

@[noinline] partial def evalExpr (env : @& Array UInt64) (e : @& Expr) : UInt64 := scope! "evalExpr" (
  match e with
  | .lit v => v
  | .var k => env[k]!
  | .bin op l r =>
    let a := evalExpr env l
    let b := evalExpr env r
    if op == 0 then a + b else if op == 1 then a - b else a * b)

/-- Runs the program `rounds` times, `v0`'s literal replaced by the round
number in all but the first. -/
@[noinline] def phEval (prog : Array Expr) (rounds : Nat) : UInt64 := scope! "phEval" (Id.run do
  let mut acc : UInt64 := 0
  for r in [0:rounds] do
    let mut env : Array UInt64 := Array.mkEmpty prog.size
    for e in prog do
      env := env.push (evalExpr env e + r.toUInt64)
    acc := acc + env.back!
  return acc)

/-! ### sortmap: sort a shared array, count keys in a hash map, look them up -/

/-- `n` pseudo-random keys below `k`. -/
def genKeys (n k : Nat) : Array UInt64 := Id.run do
  let mut out := Array.mkEmpty n
  let mut s : UInt64 := 99
  for _ in [0:n] do
    s := lcg s
    out := out.push ((s >>> 21) % k.toUInt64)
  return out

/-- Moves `a[i]` down the heap of the first `n` elements. -/
@[noinline] partial def siftDown (a : Array UInt64) (i n : Nat) : Array UInt64 :=
  let l := 2 * i + 1
  if l ≥ n then a else
  let c := if l + 1 < n && a[l + 1]! > a[l]! then l + 1 else l
  if a[c]! > a[i]! then siftDown (a.swapIfInBounds i c) c n else a

/-- Heap sort in place. The caller still holds `a`, so the first swap (in
`siftDown`) copies it: exactly one copy per call. -/
@[noinline] def heapSort (a : Array UInt64) : Array UInt64 := scope! "heapSort" (Id.run do
  let n := a.size
  let mut a := a
  for j in [0:n / 2] do
    a := siftDown a (n / 2 - 1 - j) n
  for j in [0:n - 1] do
    let e := n - 1 - j
    a := siftDown (a.swapIfInBounds 0 e) 0 e
  return a)

/-- Sorts the keys `reps` times; the keys stay with the caller. -/
@[noinline] def phSort (keys : Array UInt64) (reps : Nat) : UInt64 := scope! "phSort" (Id.run do
  let mut acc : UInt64 := 0
  for r in [0:reps] do
    let s := heapSort keys
    acc := acc + s[r % s.size]! + s.back!
  return acc)

@[noinline] def bump (m : Std.HashMap UInt64 Nat) (k : UInt64) : Std.HashMap UInt64 Nat :=
  scope! "bump" (m.insert k (m.getD k 0 + 1))

/-- How many times each key occurs. -/
@[noinline] def phCount (keys : Array UInt64) (_ : Nat) : Std.HashMap UInt64 Nat := scope! "phCount" (
  keys.foldl bump {})

@[noinline] def lookupOne (m : @& Std.HashMap UInt64 Nat) (k : UInt64) : Nat := scope! "lookupOne" (m.getD k 0)

/-- `q` lookups of pseudo-random keys, about half of them present. -/
@[noinline] def phLookup (m : Std.HashMap UInt64 Nat) (q : Nat) : UInt64 := scope! "phLookup" (Id.run do
  let mut acc := 0
  let mut s : UInt64 := 7
  for _ in [0:q] do
    s := lcg s
    acc := acc + lookupOne m ((s >>> 21) % (2 * m.size.toUInt64 + 1))
  return acc.toUInt64)

/-! ### csv: split a CSV text, total it per key, write a report -/

/-- `n` lines `city<k>,<a>,<b>` over `k` cities. -/
def genCsv (n k : Nat) : String := Id.run do
  let mut out := ""
  let mut s : UInt64 := 4242
  for _ in [0:n] do
    s := lcg s
    out := out ++ "city" ++ toString ((s >>> 30) % k.toUInt64) ++ "," ++ toString ((s >>> 10) % 10000) ++
      "," ++ toString ((s >>> 45) % 100) ++ "\n"
  return out

structure Row where
  key : String
  a : Nat
  b : Nat
  deriving Inhabited

@[noinline] def parseRow (line : String) : Row := scope! "parseRow" (
  match line.splitOn "," with
  | [k, a, b] => { key := k, a := a.toNat!, b := b.toNat! }
  | _ => { key := "", a := 0, b := 0 })

@[noinline] def phSplit (text : String) (_ : Nat) : Array Row := scope! "phSplit" (
  ((text.splitOn "\n").filter (· ≠ "")).toArray.map parseRow)

@[noinline] def addRow (m : Std.HashMap String (Nat × Nat)) (r : Row) : Std.HashMap String (Nat × Nat) :=
  scope! "addRow" (let (a, b) := m.getD r.key (0, 0); m.insert r.key (a + r.a, b + r.b))

@[noinline] def phAggregate (rows : Array Row) (_ : Nat) : Std.HashMap String (Nat × Nat) :=
  scope! "phAggregate" (rows.foldl addRow {})

@[noinline] def fmtLine (out : String) (k : String) (v : Nat × Nat) : String := scope! "fmtLine" (
  out ++ k ++ ": total " ++ toString v.1 ++ ", mean " ++ toString (v.1 / max v.2 1) ++ "\n")

/-- The report, `reps` times over (one line per city, in key order). -/
@[noinline] def phFormat (m : Std.HashMap String (Nat × Nat)) (reps : Nat) : UInt64 := scope! "phFormat" (Id.run do
  let keys := (m.toArray.map (·.1)).qsort (· < ·)
  let mut acc := 0
  for _ in [0:reps] do
    let mut out := ""
    for k in keys do
      out := fmtLine out k (m.getD k (0, 0))
    acc := acc + out.length
  return acc.toUInt64)

end W

/-! ## driver -/

structure Phase where
  name : String
  wall : Nat
  cpu : Nat

/-- Times `f n`. `f` arrives as a closure, so the C compiler cannot inline the
phase into this function (see `K.repeatU`). -/
@[noinline] def timePhase (name : String) (f : Nat → UInt64) (n : Nat) : IO (Phase × UInt64) := do
  let t0 ← IO.monoNanosNow
  let r ← span! name (IO.lazyPure fun _ => f n)
  let t1 ← IO.monoNanosNow
  return ({ name, wall := t1 - t0, cpu := t1 - t0 }, r)

/-- Times `f n` for a phase whose result the next phase uses. -/
@[noinline] def timeStage {α : Type} (name : String) (f : Nat → α) (n : Nat) : IO (Phase × α) := do
  let t0 ← IO.monoNanosNow
  let r ← span! name (IO.lazyPure fun _ => f n)
  let t1 ← IO.monoNanosNow
  return ({ name, wall := t1 - t0, cpu := t1 - t0 }, r)

/-- A phase of a real program. With `only := some p`, only phase `p` is
timed: the phases before it run untimed (their results are its input), and
`done` tells the caller to stop after it. -/
def stage {α : Type} (only : Option String) (timed : IO.Ref (List (Phase × UInt64)))
    (name : String) (f : Nat → α) (n : Nat) : IO α := do
  if only.isNone || only == some name then
    let (p, r) ← timeStage name f n
    timed.modify (· ++ [(p, 0)])
    return r
  else
    return f n

def timeTasks (name : String) (act : IO (UInt64 × Nat)) : IO (Phase × UInt64) := do
  let t0 ← IO.monoNanosNow
  let (r, cpu) ← span! name act
  let t1 ← IO.monoNanosNow
  return ({ name, wall := t1 - t0, cpu }, r)

def jsonObj (kvs : List (String × Nat)) : String :=
  "{" ++ ", ".intercalate (kvs.map fun (k, v) => s!"\"{k}\":{v}") ++ "}"

def emit (workload : String) (scale : Nat) (phases : List (Phase × UInt64))
    (calls : List (String × Nat)) (allocs : List (String × Nat) := []) (copies : List (String × Nat) := []) :
    IO Unit := do
  let sum := phases.foldl (fun a (_, r) => a + r) 0
  let ps := phases.map fun (p, _) => s!"\{\"name\":\"{p.name}\",\"wall_ns\":{p.wall},\"cpu_ns\":{p.cpu}}"
  IO.println s!"BENCH_JSON \{\"workload\":\"{workload}\",\"scale\":{scale},\"phases\":[{", ".intercalate ps}],\"calls\":{jsonObj calls},\"allocs\":{jsonObj allocs},\"copies\":{jsonObj copies},\"checksum\":{sum}}"

/-- Distinct values of `(s >>> 30) % k` over `genCsv`'s sequence. -/
def csvKeys (n k : Nat) : Nat := Id.run do
  let mut seen := Array.replicate k false
  let mut s : UInt64 := 4242
  for _ in [0:n] do
    s := W.lcg s
    seen := seen.set! ((s >>> 30) % k.toUInt64).toNat true
  return seen.foldl (fun a b => if b then a + 1 else a) 0

/-- The real programs; `only`: time one phase alone (see `W.genProgram`). -/
def runReal (w : String) (scale : Nat) (sc : Nat → Nat) (only : Option String) : IO UInt32 := do
  let timed ← IO.mkRef ([] : List (Phase × UInt64))
  let st {α : Type} := @stage α only timed
  let finish (calls : List (String × Nat)) (copies : List (String × Nat) := []) : IO UInt32 := do
    emit w scale (← timed.get) calls (copies := copies)
    return 0
  let past (p : String) : Bool := only == some p  -- stop after the phase timed alone
  match w with
  | "interp" =>
    let n := sc 20000
    let rounds := 20
    let (src, c) := W.genProgram n
    let toks ← st "phLex" (W.phLex src) 0
    if past "phLex" then return ← finish []
    let prog ← st "phParse" (W.phParse toks) 0
    if past "phParse" then return ← finish []
    let r ← st "phEval" (W.phEval prog) rounds
    if r == 42 then IO.println ""  -- keep the result
    finish [("phLex", 1), ("phParse", 1), ("phEval", 1), ("lexToken", c.tokens + 1),
      ("parseExpr", n + c.groups), ("parseAtom", c.atoms + c.groups), ("evalExpr", (c.atoms + c.bins) * rounds)]
  | "sortmap" =>
    let n := sc 100000
    let reps := 2
    let q := 4 * n
    let keys := W.genKeys n (n / 2)
    let r ← st "phSort" (W.phSort keys) reps
    if past "phSort" then return ← finish []
    let m ← st "phCount" (W.phCount keys) 0
    if past "phCount" then return ← finish []
    let r2 ← st "phLookup" (W.phLookup m) q
    if r + r2 == 42 then IO.println ""
    finish [("phSort", 1), ("phCount", 1), ("phLookup", 1), ("heapSort", reps), ("bump", n), ("lookupOne", q)]
      (copies := [("siftDown", reps)])  -- the first swap of each sort
  | _ =>  -- csv
    let n := sc 100000
    let k := 2000
    let reps := 40
    let text := W.genCsv n k
    let rows ← st "phSplit" (W.phSplit text) 0
    if past "phSplit" then return ← finish []
    let m ← st "phAggregate" (W.phAggregate rows) 0
    if past "phAggregate" then return ← finish []
    let r ← st "phFormat" (W.phFormat m) reps
    if r == 42 then IO.println ""
    let keys := csvKeys n k
    finish [("phSplit", 1), ("phAggregate", 1), ("phFormat", 1), ("parseRow", n), ("addRow", n),
      ("fmtLine", keys * reps)]

def runWorkload (w : String) (scale : Nat) (only : Option String := none) : IO UInt32 := do
  -- `* 0` of a clock read: the compiler cannot treat the sizes as constants
  let z := (← IO.monoMsNow) * 0
  let sc (n : Nat) : Nat := n * scale / 100 + z
  if w == "interp" || w == "sortmap" || w == "csv" then return ← runReal w scale sc only
  match w with
  | "tiny" =>
    let n := sc 10000000
    let a ← timePhase "phTinyA" W.phTinyA n
    let b ← timePhase "phTinyB" W.phTinyB (2 * n)
    emit w scale [a, b] [("phTinyA", 1), ("phTinyB", 1), ("tinyA", n), ("tinyB", 2 * n)]
  | "rec" =>
    let total := sc 2000000 / 10000 * 10000
    let fn := 32 + z
    let a ← timePhase "phDeep100" W.phDeep100 total
    let b ← timePhase "phDeep1k" W.phDeep1k total
    let c ← timePhase "phDeep10k" W.phDeep10k total
    let d ← timePhase "phFib" W.phFib fn
    emit w scale [a, b, c, d] [("phDeep100", 1), ("phDeep1k", 1), ("phDeep10k", 1), ("phFib", 1),
      ("deepRec", 3 * total + total / 100 + total / 1000 + total / 10000), ("fib", W.fibCalls fn)]
  | "mix" =>
    let m := sc 80000
    let a ← timePhase "phHot" W.phHot m
    let b ← timePhase "phWarm" W.phWarm m
    let c ← timePhase "phCool" W.phCool m
    let d ← timePhase "phCold" W.phCold m
    emit w scale [a, b, c, d] [("phHot", 1), ("phWarm", 1), ("phCool", 1), ("phCold", 1),
      ("hot", m), ("warm", m), ("cool", m), ("cold", m)]
  | "alloc" =>
    let reps := sc 300
    let n := 10000
    let treps := sc 200
    let d := 13
    let a ← timePhase "phAllocList" (W.phAllocList reps) n
    let b ← timePhase "phAllocTree" (W.phAllocTree treps) d
    emit w scale [a, b] [("phAllocList", 1), ("phAllocTree", 1), ("allocList", reps), ("allocTree", treps)]
      (allocs := [("allocList", (List.range reps).foldl (fun a r => a + 2 * (n + r % 2)) 0),
        ("allocTree", (2 ^ d - 1) * treps)])
  | "copy" =>
    let reps := sc 40
    let n := 2000
    let a ← timePhase "phCopyShared" (W.phCopyShared reps) n
    let b ← timePhase "phPushExclusive" (W.phPushExclusive (reps * 100)) n
    -- n or n+1 pushes, alternating: (n-1) or n copies
    let copies := (List.range reps).foldl (fun a r => a + (n + r % 2 - 1)) 0
    emit w scale [a, b] [("phCopyShared", 1), ("phPushExclusive", 1), ("buildShared", reps),
      ("buildExclusive", reps * 100)] (copies := [("buildShared", copies)])
  | "tasks" =>
    let n := sc 8000000 / 8 * 8
    let a ← timeTasks "phTasks2" (W.runTasks "taskWork2" 2 n W.taskWork2)
    let b ← timeTasks "phTasks4" (W.runTasks "taskWork4" 4 n W.taskWork4)
    let c ← timeTasks "phTasks8" (W.runTasks "taskWork8" 8 n W.taskWork8)
    emit w scale [a, b, c] [("taskWork2", 2), ("taskWork4", 4), ("taskWork8", 8), ("taskStep", 3 * n)]
  | _ =>
    IO.eprintln s!"unknown workload {w}: tiny, rec, mix, alloc, copy, tasks, interp, sortmap, csv"
    return 2
  return 0

def main (args : List String) : IO UInt32 := do
  let w := args.headD "tiny"
  let scale := (args[1]? >>= String.toNat?).getD 100
  LeanProfiler.profileFromEnvironment "wl" (runWorkload w scale args[2]?)
