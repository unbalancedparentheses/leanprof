import Lean.Data.Json
import Leanprof.Contract

/-!
# `leanprof judge`: KEEP or DISCARD a change

The verdict of an autoresearch loop, from two `leanprof measure` summaries
(before and after a change). Pure, so the tests can check the rules on
summaries written by hand.

DISCARD when any of these hold:

* the command, the exit code or the output hash changed, or the output was
  not the same on every run, or the two summaries timed different things
  (the whole process, or different `measure --scope` scopes);
* copies of shared or multi-threaded values went up (exact counts);
* allocations went up (exact counts; when they differ between runs, only
  when every new run allocated more than every base run);
* compile heartbeats of the measured files went up by more than 1% and 1,000;
* every new run was slower than every base run, by at least `minChange`
  percent of the median (time is not judged when a `--scope` time was too
  small to measure in any run).

Otherwise KEEP when copies went down, allocations went down by at least 1%
and 100, heartbeats went down by more than 1% and 1,000, or every new run was
faster than every base run by at least `minChange` percent (default 1).
Independent runs would not overlap by chance 1 time in 252 with 5 runs each,
but base and new are measured one after the other and a quiet machine drifts
by about 1% between them: unchanged code gave 2 such verdicts in 20
(docs/case-studies/leanbench.md). Time is not judged at all when either
summary was measured on an overloaded machine (load above its CPU count).
-/

namespace Leanprof.Judge

open Lean

/-- `s` without its lines that contain any of `ignore` (`--ignore-lines`: a
benchmark's own timings, which differ on every run), before it is hashed. -/
def dropLines (ignore : Array String) (s : String) : String :=
  if ignore.isEmpty then s
  else "\n".intercalate ((s.splitOn "\n").filter fun l => !ignore.any fun t => (l.splitOn t).length > 1)

/-- What an output hash covers: `stdout`, or stdout without some lines. Both
summaries of a verdict must cover the same. -/
def stdoutSource (ignore : Array String) : String :=
  if ignore.isEmpty then "stdout"
  else s!"stdout without lines containing {", ".intercalate (ignore.toList.map fun t => s!"`{t}`")}"

/-- What `judge` reads back from a `measure` summary. -/
structure Summary where
  command : Json := Json.null
  /-- the `profile!` scope timed (`measure --scope`); empty: the whole process -/
  scope : String := ""
  exitCode : Nat := 0
  outputSource : String := ""
  outputHash : String := ""
  outputStable : Bool := true
  median : Float := 0
  min : Float := 0
  max : Float := 0
  copies : Nat := 0
  sites : Std.HashMap String Nat := {}
  calls : Std.HashMap String Nat := {}
  /-- allocations by compiled Lean code: the last run's total, and the
  smallest and largest total over the runs (`none`: not counted) -/
  allocs : Option (Nat × Nat × Nat) := none
  allocSites : Std.HashMap String Nat := {}
  heartbeats : Option (Std.HashMap String Float) := none
  /-- the machine ran more jobs than it has CPUs while measuring -/
  overloaded : Bool := false
  loadAvg : Option Float := none
  /-- measured with `--core`: copies and allocations inside Lean's libraries counted too -/
  core : Bool := false
  /-- runs whose `--scope` time was too small to measure (what was left after
  subtracting the probes' cost came out at or below 0) -/
  tooSmallRuns : Nat := 0
  /-- where the summary came from (`Contract.provenance`), null when not recorded -/
  provenance : Json := Json.null

def num (j : Json) (k : String) : Float :=
  match j.getObjVal? k with
  | .ok (.num n) => n.toFloat
  | _ => 0

def str (j : Json) (k : String) : String :=
  (j.getObjVal? k >>= Json.getStr?).toOption.getD ""

/-- `[{"key": k, field: v}, ...]` back into a map. -/
def keyedMap (j : Json) (field : String) : Std.HashMap String Float :=
  (j.getArr?.toOption.getD #[]).foldl (fun m e => m.insert (str e "key") (num e field)) {}

/-- A `measure` summary, or an error naming what it is instead. -/
def Summary.ofJson (j : Json) : Except String Summary := do
  unless str j "leanprof" == "measure" do throw "not a `leanprof measure` summary"
  let field (k : String) := (j.getObjVal? k).toOption.getD Json.null
  let out := field "output"
  let time := field "time_ns"
  let toNat (x : Float) := x.toUInt64.toNat
  let toNatMap (m : Std.HashMap String Float) := m.fold (fun acc k v => acc.insert k (toNat v)) {}
  let allocs :=
    if field "allocs_total" == Json.null then none
    else
      let runs := ((field "allocs_runs").getArr?.toOption.getD #[]).filterMap (·.getNat?.toOption)
      let last := toNat (num j "allocs_total")
      some (last, runs.foldl Nat.min last, runs.foldl Nat.max last)
  return {
    command := field "command", scope := str j "scope", exitCode := toNat (num j "exit_code")
    outputSource := str out "source", outputHash := str out "hash"
    outputStable := (out.getObjValAs? Bool "stable").toOption.getD true
    median := num time "median", min := num time "min", max := num time "max"
    copies := toNat (num j "copies_total")
    sites := toNatMap (keyedMap (field "copies") "copies")
    calls := toNatMap (keyedMap (field "calls") "calls")
    allocs, allocSites := toNatMap (keyedMap (field "allocs") "allocs")
    heartbeats := if field "heartbeats" == Json.null then none else some (keyedMap (field "heartbeats") "heartbeats")
    overloaded := ((field "machine").getObjValAs? Bool "overloaded").toOption.getD false
    loadAvg := ((field "machine").getObjValAs? Float "load_avg_1m").toOption
    core := (j.getObjValAs? Bool "core").toOption.getD false
    tooSmallRuns := toNat (num time "too_small_runs"), provenance := field "provenance" }

/-- The verdict and its reasons. -/
structure Verdict where
  keep : Bool
  /-- reasons to DISCARD -/
  worse : Array String
  /-- reasons to KEEP -/
  better : Array String
  /-- what changed without deciding anything -/
  notes : Array String
  /-- time could not be settled either way (a paired session stopped at its
  most pairs without a call, or not judged on an overloaded machine): an
  experiment says INCONCLUSIVE rather than DISCARD when nothing else improved -/
  unsettled : Bool := false
  /-- the reasons in `worse` that are changed behaviour (exit code, output) -/
  correctness : Array String := #[]
  /-- the reasons in `worse` that make the two sides incomparable (another
  command, scope or `--core`) -/
  incompatible : Array String := #[]
  /-- the reasons in `worse` that make the measurement unusable (an output
  that differs between runs of the same code) -/
  invalid : Array String := #[]
  /-- time was not judged because the machine was overloaded while measuring -/
  overloaded : Bool := false

/-- `x` with two decimals. -/
def fmt2 (x : Float) : String :=
  let v := (x.abs * 100).round.toUInt64.toNat
  let frac := v % 100
  s!"{if x < 0 && v > 0 then "-" else ""}{v / 100}.{if frac < 10 then "0" else ""}{frac}"

def fmtMs (ns : Float) : String := s!"{fmt2 (ns / 1e6)} ms"

/-- `n` with thousands separators. -/
def groupDigits (n : Nat) : String :=
  if _h : n < 1000 then toString n
  else
    let r := n % 1000
    groupDigits (n / 1000) ++ "," ++ (if r < 10 then "00" else if r < 100 then "0" else "") ++ toString r
termination_by n
decreasing_by omega

/-- Allocations count as an improvement when they go down by at least this
share of the base count and `allocMinDrop` allocations: each one costs a
few nanoseconds, so a smaller cut, while exact, saves less than time
measurements can see. -/
def allocMinShare : Float := 0.01
def allocMinDrop : Nat := 100

/-- How much allocations must drop, from a base count, to count as better. -/
def allocMargin (base : Nat) : Nat :=
  max allocMinDrop (base.toFloat * allocMinShare).ceil.toUInt64.toNat

/-- Changes of a per-site map, largest first, at most `top` of them. -/
def siteChanges (what : String) (b n : Std.HashMap String Nat) (top : Nat := 10) : Array String := Id.run do
  let ds := (b.toList.map (·.1) ++ n.toList.map (·.1)).eraseDups.filterMap fun k =>
    let (x, y) := (b.getD k 0, n.getD k 0)
    if x == y then none else some (k, x, y)
  let ds := ds.toArray.qsort fun (_, x1, y1) (_, x2, y2) =>
    (Int.ofNat y1 - x1).natAbs > (Int.ofNat y2 - x2).natAbs
  let mut out := #[]
  for (k, x, y) in ds.toList.take top do
    out := out.push s!"{what} {k}: {groupDigits x} -> {groupDigits y}"
  if ds.size > top then out := out.push s!"{what}: {ds.size - top} more sites changed"
  return out

/-- KEEP or DISCARD, from the summaries before (`b`) and after (`n`) a change
(the rules are in the module docstring). -/
def judge (b n : Summary) (minChange : Float := 1) (judgeTime : Bool := true) (allowIncompatible : Bool := false) :
    Verdict := Id.run do
  let mut worse : Array String := #[]
  let mut better : Array String := #[]
  let mut notes : Array String := #[]
  let mut correctness : Array String := #[]
  let mut incompatible : Array String := #[]
  let mut invalid : Array String := #[]
  let mut overloadedNotJudged := false
  if b.command != n.command then
    incompatible := incompatible.push s!"different commands measured: {b.command.compress} vs {n.command.compress}"
  -- another Lean or platform: the numbers are not of the same code
  let (_, refusals, provWarnings) := Contract.provenanceCheck (Json.mkObj [("provenance", b.provenance)])
    (Json.mkObj [("provenance", n.provenance)])
  if allowIncompatible then notes := notes ++ refusals.map (· ++ " (judged anyway: --allow-incompatible)")
  else incompatible := incompatible ++ refusals
  notes := notes ++ provWarnings
  if b.scope != n.scope then
    let what (s : String) := if s.isEmpty then "the whole process" else s!"scope {s}"
    incompatible := incompatible.push s!"different times measured: {what b.scope} vs {what n.scope}"
  if b.core != n.core then
    incompatible := incompatible.push ("copies and allocations counted differently: only one summary was measured with --core " ++
      "(Lean's libraries included); measure both the same way")
  if b.exitCode != n.exitCode then
    correctness := correctness.push s!"exit code changed: {b.exitCode} -> {n.exitCode}"
  if b.outputSource != n.outputSource then
    incompatible := incompatible.push s!"output changed ({n.outputSource}): {b.outputHash} -> {n.outputHash} (different outputs checked: {b.outputSource} vs {n.outputSource})"
  else if b.outputHash != n.outputHash then
    correctness := correctness.push s!"output changed ({n.outputSource}): {b.outputHash} -> {n.outputHash}"
  if !b.outputStable || !n.outputStable then
    invalid := invalid.push "output differs between runs, so changes to it cannot be detected (measure with --check-output)"
  worse := incompatible ++ correctness ++ invalid
  -- copies: exact
  if n.copies > b.copies then worse := worse.push s!"copies: {groupDigits b.copies} -> {groupDigits n.copies}"
  else if n.copies < b.copies then better := better.push s!"copies: {groupDigits b.copies} -> {groupDigits n.copies}"
  notes := notes ++ siteChanges "copies" b.sites n.sites
  -- allocations: exact; when a program's count varies between runs
  -- (threads), only a change beyond that spread counts
  match b.allocs, n.allocs with
  | some (bl, bmin, bmax), some (nl, nmin, nmax) =>
    let t := s!"allocations: {groupDigits bl} -> {groupDigits nl}"
    let spread := if bmin != bmax || nmin != nmax then
      s!" (runs vary: base {groupDigits bmin}..{groupDigits bmax}, new {groupDigits nmin}..{groupDigits nmax})" else ""
    if nmin > bmax then worse := worse.push (t ++ spread)
    else if nmax + allocMargin bl ≤ bmin then better := better.push (t ++ spread)
    else if nl != bl then
      notes := notes.push (t ++ spread ++
        (if nmax < bmin then s!" (fewer, but by less than 1% and {allocMinDrop}: not an improvement on its own)" else ""))
    notes := notes ++ siteChanges "allocations" b.allocSites n.allocSites
  | none, none => pure ()
  | _, _ => notes := notes.push "allocations counted in only one summary; not compared (measure counts them unless --no-allocs)"
  -- compile heartbeats: exact, but editing one declaration moves its
  -- neighbours by a few, so only changes above 1% and 1,000 count. Judged
  -- on the total, since experiments move code between declarations.
  if let (some bh, some nh) := (b.heartbeats, n.heartbeats) then
    let kHB (x : Float) := s!"{fmt2 (x / 1000)} kHB"
    let (x, y) := (bh.fold (fun a _ v => a + v) 0, nh.fold (fun a _ v => a + v) 0)
    let margin := max (x * 0.01) 1000
    if y - x > margin then worse := worse.push s!"compile heartbeats: {kHB x} -> {kHB y}"
    else if x - y > margin then better := better.push s!"compile heartbeats: {kHB x} -> {kHB y}"
    for k in (bh.toList.map (·.1) ++ nh.toList.map (·.1)).eraseDups do
      match bh.get? k, nh.get? k with
      | some x, some y =>
        if (y - x).abs > max (x * 0.01) 1000 then notes := notes.push s!"compile {k}: {kHB x} -> {kHB y}"
      | some x, none => notes := notes.push s!"compile {k}: gone (was {kHB x})"
      | none, some y => notes := notes.push s!"compile {k}: new, {kHB y}"
      | none, none => pure ()
  else if b.heartbeats.isSome != n.heartbeats.isSome then
    notes := notes.push "compile heartbeats measured in only one summary; not compared"
  -- calls: exact, but restructuring code changes them legitimately
  notes := notes ++ siteChanges "calls" b.calls n.calls
  -- time: only when the runs do not overlap and the median moved by at
  -- least minChange percent, and never on an overloaded machine
  let pct := if b.median > 0 then (n.median - b.median) / b.median * 100 else 0
  let t := s!"time: median {fmtMs b.median} -> {fmtMs n.median} ({if pct > 0 then "+" else ""}{fmt2 pct}%)"
  if !judgeTime then
    -- exact counts only (`leanprof experiment` times plain binaries in pairs instead)
    notes := notes.push s!"{t} (not judged: exact counts only)"
  else if b.tooSmallRuns > 0 || n.tooSmallRuns > 0 then
    -- the scope's time was what is left after subtracting leanprof's probes,
    -- 0 or less in some runs: no time to compare
    notes := notes.push s!"{t} (not judged: the scope's time was too small to measure in {b.tooSmallRuns} base and {n.tooSmallRuns} new runs)"
  else if b.overloaded || n.overloaded then
    -- on a machine running more jobs than CPUs, load drifts between the two
    -- summaries and whole runs shift together; non-overlap proves nothing
    let la (x : Summary) := match x.loadAvg with | some l => fmt2 l | none => "?"
    notes := notes.push s!"{t} (not judged: machine overloaded while measuring, load average {la b} and {la n})"
    overloadedNotJudged := true
  else if n.max < b.min && -pct >= minChange then better := better.push s!"{t} (every new run faster than every base run)"
  else if n.min > b.max && pct >= minChange then worse := worse.push s!"{t} (every new run slower than every base run)"
  else if n.max < b.min || n.min > b.max then
    notes := notes.push s!"{t} (runs do not overlap, but the change is below --min-change {fmt2 minChange}%)"
  else notes := notes.push s!"{t} (within noise: base {fmtMs b.min}..{fmtMs b.max}, new {fmtMs n.min}..{fmtMs n.max})"
  return { keep := worse.isEmpty && !better.isEmpty, worse, better, notes, correctness, incompatible, invalid,
           overloaded := overloadedNotJudged, unsettled := overloadedNotJudged }

/-! ## Paired sessions: a group-sequential sign test

`measure-pair` looks at the paired percent changes after `first`,
`first + step`, … pairs and at `max`, and stops at the first look where the
time verdict is settled. Looking again and again at a fixed-sample interval
would raise its error rate, so every look has its own order statistic, fixed
in advance, such that over all looks together each end of the interval
misses the true median with probability at most `alpha / 2`.

Why: let the changes be independent with median `μ` (continuous). Among the
first `n`, the count of changes `≤ μ` is a Binomial(n, ½) random walk. At a
look `n` with bound `kₙ`, the interval's lower end is the `(kₙ+1)`-th smallest
change, which lies above `μ` exactly when at most `kₙ` changes are `≤ μ`.
`seqBounds` computes the chance that the walk is at or below `kₙ` at some look
exactly (dynamic programming over the walk, a path counted at its first
crossing only) and takes each `kₙ` as large as the alpha-spending function
`alpha / 2 · n / max` allows (linear spending in the pairs measured, after Lan
and DeMets). The upper end is the same by symmetry. The interval reported is
the intersection of every look's interval so far, so, however the session
was stopped, it contains `μ` with probability at least `1 - alpha`, and with
`m` the minimum change (`--min-change`):

* "slower" (lower end above `m`) when `μ ≤ m`: at most `alpha / 2` (2.5%);
* "faster" (upper end below `-m`) when `μ ≥ -m`: at most 2.5%;
* "no change beyond ±m" (interval inside `[-m, m]`) when `|μ| > m`: at most 2.5%.

A single look (`SeqDesign.fixed`, `measure-pair --fixed` and version-1
sessions) is the classic distribution-free interval: the largest `k` with
`P(Binomial(n, ½) ≤ k) ≤ 0.025`. Tests/Main.lean checks the spent error
exactly and the error rates and power by simulation. -/

/-- When a paired session looks at its changes: after `first`, `first + step`,
… pairs and after `max`. -/
structure SeqDesign where
  max : Nat
  first : Nat := 6
  step : Nat := 2
  /-- two-sided: each end of the interval may miss the median with probability `alpha / 2` -/
  alpha : Float := 0.05
  deriving Repr, Inhabited

/-- One look after `n` pairs: the classic fixed-sample interval. -/
def SeqDesign.fixed (n : Nat) : SeqDesign := { max := n, first := n }

def SeqDesign.looks (d : SeqDesign) : Array Nat := Id.run do
  let mut out := #[]
  let step := Nat.max d.step 1
  for i in [:(d.max - d.first + step - 1) / step] do out := out.push (d.first + i * step)
  return out.push d.max

def SeqDesign.json (d : SeqDesign) : Json :=
  Json.mkObj [("rule", "group-sequential sign test, linear alpha spending"),
    ("max_runs", Lean.toJson d.max), ("first_look", Lean.toJson d.first), ("look_every", Lean.toJson d.step),
    ("alpha", Lean.toJson d.alpha)]

def SeqDesign.ofJson (j : Json) : Except String SeqDesign := do
  let max ← j.getObjValAs? Nat "max_runs"
  let first ← j.getObjValAs? Nat "first_look"
  let step ← j.getObjValAs? Nat "look_every"
  let alpha ← j.getObjValAs? Float "alpha"
  let d : SeqDesign := { max, first, step, alpha }
  unless 6 ≤ d.first && d.first ≤ d.max && d.max ≤ 1000 && d.step ≥ 1 && 0.001 ≤ d.alpha && d.alpha ≤ 0.2 do
    throw "invalid sequential design"
  return d

/-- Each look's bound `k` (`none`: no interval yet at that look) and the
probability spent on one side over all looks, which never exceeds `alpha / 2`. -/
def seqBounds (d : SeqDesign) : Array (Nat × Option Nat) × Float := Id.run do
  -- dist[s]: probability that s of the first n changes are ≤ μ and the walk
  -- has not crossed a bound yet
  let mut dist : Array Float := #[1]
  let mut n := 0
  let mut spent : Float := 0
  let mut out := #[]
  for look in d.looks do
    for _ in [n:look] do
      let prev := dist
      dist := (Array.range (prev.size + 1)).map fun s =>
        ((if s < prev.size then prev[s]! else 0) + (if s > 0 then prev[s - 1]! else 0)) / 2
    n := look
    let allow := d.alpha / 2 * look.toFloat / d.max.toFloat
    let mut k : Option Nat := none
    let mut cum : Float := 0
    for s in [:dist.size] do
      if spent + cum + dist[s]! ≤ allow * (1 + 1e-12) then
        cum := cum + dist[s]!
        k := some s
      else break
    spent := spent + cum
    if let some b := k then dist := dist.mapIdx fun i p => if i ≤ b then 0 else p
    out := out.push (look, k)
  return (out, spent)

/-- The interval for the median after the last look within `changes`: the
intersection of the intervals of every look so far (`none` before the first
look that bounds the median). -/
def seqInterval (bounds : Array (Nat × Option Nat)) (changes : Array Float) : Option (Float × Float) := Id.run do
  let mut acc : Option (Float × Float) := none
  for (n, k) in bounds do
    if n > changes.size then break
    let some k := k | continue
    let sorted := (changes.extract 0 n).qsort (· < ·)
    let (lo, hi) := (sorted[k]!, sorted[n - k - 1]!)
    acc := some <| match acc with
      | some (a, b) => (Max.max a lo, Min.min b hi)
      | none => (lo, hi)
  return acc

/-- What an interval says about time, with minimum change `m` percent. -/
inductive TimeCall | slower | faster | same | unsettled
  deriving BEq, Repr, Inhabited

def timeCall (lo hi m : Float) : TimeCall :=
  if lo > hi then .unsettled  -- the looks disagree (rare): no claim
  else if lo > m then .slower
  else if hi < -m then .faster
  else if -m ≤ lo && hi ≤ m then .same
  else .unsettled

/-- Whether a session with these changes stops now: at a look whose interval
settles the time verdict, or at the last look. -/
def seqStop (d : SeqDesign) (bounds : Array (Nat × Option Nat)) (changes : Array Float) (m : Float) : Bool :=
  changes.size ≥ d.max ||
    (bounds.any (·.1 == changes.size) &&
      match seqInterval bounds changes with
      | some (lo, hi) => timeCall lo hi m != .unsettled
      | none => false)

/-- Distribution-free 95% interval for the population median of paired percent
changes, from one look at all of them: `(median, lower, upper)`. With fewer
than six pairs there is no finite interval at this confidence. -/
def pairedInterval (changes : Array Float) : Option (Float × Float × Float) := do
  let n := changes.size
  if n < 6 || n > 1000 then none
  let (lo, hi) ← seqInterval (seqBounds (.fixed n)).1 changes
  let sorted := changes.qsort (· < ·)
  let med := if n % 2 == 1 then sorted[n / 2]! else (sorted[n / 2 - 1]! + sorted[n / 2]!) / 2
  return (med, lo, hi)

/-- Judge one plain-binary interleaved session. Validate its ordering and every
sample's output/exit status before using paired times. Separate sessions cannot
accidentally be presented as pairs of compatible standalone summaries.
Version 1: one look after all pairs; version 2: the sequential design it
records (`seqBounds`), stopped at one of its looks. -/
def judgePaired (j : Json) (minChange : Float := 1) (allowOverloaded : Bool := false) :
    Except String Verdict := do
  unless str j "leanprof" == "measure-pair" do throw "not a `leanprof measure-pair` result"
  let version := (j.getObjValAs? Nat "version").toOption
  unless version == some 1 || version == some 2 do throw "unsupported paired result version"
  let samples ← j.getObjValAs? (Array Json) "samples"
  let runs ← j.getObjValAs? Nat "runs"
  unless runs ≥ 6 && runs ≤ 1000 && samples.size == 2 * runs do
    throw "paired result needs 6..1000 complete pairs"
  let design ← if version == some 2 then SeqDesign.ofJson (← j.getObjVal? "design") else pure (.fixed runs)
  unless design.looks.contains runs do throw "a sequential session must stop at one of its looks"
  let machine ← j.getObjVal? "machine"
  let overloaded ← machine.getObjValAs? Bool "overloaded"
  let scope := str j "scope"
  let mut worse : Array String := #[]
  let mut better : Array String := #[]
  let mut notes : Array String := #["plain binaries: copies, allocations and compile heartbeats were not measured"]
  let mut changes : Array Float := #[]
  let mut correctness : Array String := #[]
  let mut expected : Option (String × String × String) := none
  for i in [:runs] do
    let mut times : Array Nat := #[]
    for offset in [:2] do
      let row := samples[2 * i + offset]!
      let side := if (i + offset) % 2 == 0 then "base" else "candidate"
      unless (← row.getObjValAs? Nat "pair") == i && str row "side" == side do
        throw "paired samples must follow alternating AB/BA order"
      let elapsed ← row.getObjValAs? Nat "time_ns"
      unless elapsed > 0 && elapsed ≤ 18446744073709551615 do throw "invalid paired duration"
      times := times.push elapsed
      let code ← row.getObjValAs? Nat "exit_code"
      if code != 0 then correctness := correctness.push s!"pair {i}, {side}: exit code {code}"
      unless ← row.getObjValAs? Bool "output_present" do
        correctness := correctness.push s!"pair {i}, {side}: checked output file missing"
      let stdout ← row.getObjValAs? String "stdout_hash"
      let stderr ← row.getObjValAs? String "stderr_hash"
      let output ← row.getObjValAs? String "output_hash"
      unless !stdout.isEmpty && !stderr.isEmpty && !output.isEmpty do throw "missing paired output hash"
      let signature := (stdout, stderr, output)
      if let some original := expected then
        if signature != original then correctness := correctness.push s!"pair {i}, {side}: output or diagnostics changed"
      else expected := some signature
    let (base, candidate) := if i % 2 == 0 then (times[0]!, times[1]!) else (times[1]!, times[0]!)
    changes := changes.push ((candidate.toFloat / base.toFloat - 1) * 100)
  worse := worse ++ correctness
  let some (lo, hi) := seqInterval (seqBounds design).1 changes
    | throw "not enough pairs for a 95% median interval"
  let sorted := changes.qsort (· < ·)
  let med := if runs % 2 == 1 then sorted[runs / 2]! else (sorted[runs / 2 - 1]! + sorted[runs / 2]!) / 2
  let what := if scope.isEmpty then "paired time" else s!"paired time of scope {scope}"
  let how := if design.first == design.max then s!"{runs} pairs"
    else s!"{runs} pairs, sequential: stopped at {runs} of at most {design.max}"
  let description := s!"{what}: median change {fmt2 med}%, 95% median interval [{fmt2 lo}%, {fmt2 hi}%] ({how})"
  -- Pairs cancel a drift common to both sides, but an overloaded machine adds
  -- noise and stalls of its own: judged only when asked (a machine always shared)
  let description := if overloaded && allowOverloaded then
    description ++ " (machine overloaded while measuring; judged with --allow-overloaded)" else description
  let mut unsettled := false
  if overloaded && !allowOverloaded then
    notes := notes.push (description ++ " (not judged: machine overloaded; --allow-overloaded judges it anyway)")
    unsettled := true
  else match timeCall lo hi minChange with
    | .faster => better := better.push description
    | .slower => worse := worse.push description
    | .same => notes := notes.push (description ++ s!" (no change beyond ±{fmt2 minChange}%, the --min-change)")
    | .unsettled =>
      notes := notes.push (description ++ s!" (inconclusive at --min-change {fmt2 minChange}%)")
      unsettled := true
  return { keep := worse.isEmpty && !better.isEmpty, worse, better, notes, unsettled, correctness,
           overloaded := overloaded && !allowOverloaded }

/-- What the verdict means (`Contract.Outcome`): the first that applies of
incompatible sides, an unusable measurement, changed behaviour, a cost that
got worse, an improvement, an unsettled time, and no improvement. -/
def Verdict.outcome (v : Verdict) : Contract.Outcome :=
  if !v.incompatible.isEmpty then .incompatible
  else if !v.invalid.isEmpty then .measurementFailed
  else if !v.correctness.isEmpty then .correctnessFailure
  else if !v.worse.isEmpty then .regression
  else if v.keep then .improved
  else if v.unsettled then .insufficientEvidence
  else .noImprovement

/-- The verdict as `judge --json` prints it (without the `schema` field). -/
def Verdict.json (v : Verdict) : List (String × Json) :=
  [("verdict", Json.str (if v.keep then "KEEP" else "DISCARD")), ("keep", Json.bool v.keep)] ++
  v.outcome.json ++
  [("worse", toJson v.worse), ("better", toJson v.better), ("notes", toJson v.notes),
   ("correctness", toJson v.correctness), ("incompatible", toJson v.incompatible), ("invalid", toJson v.invalid),
   ("unsettled", Json.bool v.unsettled), ("overloaded", Json.bool v.overloaded)]

/-- The verdict as `judge` prints it. -/
def Verdict.render (v : Verdict) : String := Id.run do
  let mut out := if v.keep then "KEEP\n" else "DISCARD\n"
  for r in v.worse do out := out ++ s!"  - {r}\n"
  for r in v.better do out := out ++ s!"  + {r}\n"
  if v.worse.isEmpty && v.better.isEmpty then out := out ++ "  - no measurable improvement\n"
  for r in v.notes do out := out ++ s!"    {r}\n"
  return out

end Leanprof.Judge
