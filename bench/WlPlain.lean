import BenchScope
import BenchKernels

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

partial def runWorkload (w : String) (scale : Nat) : IO UInt32 := do
  -- `* 0` of a clock read: the compiler cannot treat the sizes as constants
  let z := (← IO.monoMsNow) * 0
  let sc (n : Nat) : Nat := n * scale / 100 + z
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
  | "all" =>
    -- every workload in turn (bench/run.py builds `run --retime` from this run)
    for x in ["tiny", "rec", "mix", "alloc", "copy", "tasks"] do
      let rc ← runWorkload x scale
      if rc != 0 then return rc
  | _ =>
    IO.eprintln s!"unknown workload {w}: tiny, rec, mix, alloc, copy, tasks, all"
    return 2
  return 0

def main (args : List String) : IO UInt32 := do
  let w := args.headD "tiny"
  let scale := (args[1]? >>= String.toNat?).getD 100
  LeanProfiler.profileFromEnvironment "wl" (runWorkload w scale)
