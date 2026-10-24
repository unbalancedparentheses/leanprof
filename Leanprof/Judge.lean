import Lean.Data.Json

/-!
# `leanprof judge`: KEEP or DISCARD a change

The verdict of an autoresearch loop, from two `leanprof measure` summaries
(before and after a change). Pure, so the tests can check the rules on
summaries written by hand.

DISCARD when any of these hold:

* the command, the exit code or the output hash changed, or the output was
  not the same on every run;
* copies of shared or multi-threaded values went up (exact counts);
* allocations went up (exact counts; when they differ between runs, only
  when every new run allocated more than every base run);
* compile heartbeats of the measured files went up by more than 1% and 1,000;
* every new run was slower than every base run, by at least `minChange`
  percent of the median.

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

/-- What `judge` reads back from a `measure` summary. -/
structure Summary where
  command : Json := Json.null
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
    command := field "command", exitCode := toNat (num j "exit_code")
    outputSource := str out "source", outputHash := str out "hash"
    outputStable := (out.getObjValAs? Bool "stable").toOption.getD true
    median := num time "median", min := num time "min", max := num time "max"
    copies := toNat (num j "copies_total")
    sites := toNatMap (keyedMap (field "copies") "copies")
    calls := toNatMap (keyedMap (field "calls") "calls")
    allocs, allocSites := toNatMap (keyedMap (field "allocs") "allocs")
    heartbeats := if field "heartbeats" == Json.null then none else some (keyedMap (field "heartbeats") "heartbeats")
    overloaded := ((field "machine").getObjValAs? Bool "overloaded").toOption.getD false
    loadAvg := ((field "machine").getObjValAs? Float "load_avg_1m").toOption }

/-- The verdict and its reasons. -/
structure Verdict where
  keep : Bool
  /-- reasons to DISCARD -/
  worse : Array String
  /-- reasons to KEEP -/
  better : Array String
  /-- what changed without deciding anything -/
  notes : Array String

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
def judge (b n : Summary) (minChange : Float := 1) : Verdict := Id.run do
  let mut worse : Array String := #[]
  let mut better : Array String := #[]
  let mut notes : Array String := #[]
  if b.command != n.command then
    worse := worse.push s!"different commands measured: {b.command.compress} vs {n.command.compress}"
  if b.exitCode != n.exitCode then
    worse := worse.push s!"exit code changed: {b.exitCode} -> {n.exitCode}"
  if b.outputSource != n.outputSource || b.outputHash != n.outputHash then
    worse := worse.push s!"output changed ({n.outputSource}): {b.outputHash} -> {n.outputHash}"
  if !b.outputStable || !n.outputStable then
    worse := worse.push "output differs between runs, so changes to it cannot be detected (measure with --check-output)"
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
  if b.overloaded || n.overloaded then
    -- on a machine running more jobs than CPUs, load drifts between the two
    -- summaries and whole runs shift together; non-overlap proves nothing
    let la (x : Summary) := match x.loadAvg with | some l => fmt2 l | none => "?"
    notes := notes.push s!"{t} (not judged: machine overloaded while measuring, load average {la b} and {la n})"
  else if n.max < b.min && -pct >= minChange then better := better.push s!"{t} (every new run faster than every base run)"
  else if n.min > b.max && pct >= minChange then worse := worse.push s!"{t} (every new run slower than every base run)"
  else if n.max < b.min || n.min > b.max then
    notes := notes.push s!"{t} (runs do not overlap, but the change is below --min-change {fmt2 minChange}%)"
  else notes := notes.push s!"{t} (within noise: base {fmtMs b.min}..{fmtMs b.max}, new {fmtMs n.min}..{fmtMs n.max})"
  return { keep := worse.isEmpty && !better.isEmpty, worse, better, notes }

/-- Distribution-free 95% interval for the population median of paired percent
changes. Endpoints are order statistics: choose the largest k for which
40 * sum(j=0..k, choose(n,j)) <= 2^n. Each excluded tail has probability
at most 0.025 under independent pairs. No normality or symmetry is assumed.
With fewer than six pairs there is no finite interval at this confidence. -/
def pairedInterval (changes : Array Float) : Option (Float × Float × Float) := Id.run do
  let n := changes.size
  if n < 6 || n > 1000 then return none
  let sorted := changes.qsort (· < ·)
  let mut choose := 1
  let mut tail := 0
  let mut endpoint : Option Nat := none
  for k in [:n / 2] do
    tail := tail + choose
    if 40 * tail ≤ 2 ^ n then endpoint := some k
    choose := choose * (n - k) / (k + 1)
  let some k := endpoint | return none
  let med := if n % 2 == 1 then sorted[n / 2]! else
    (sorted[n / 2 - 1]! + sorted[n / 2]!) / 2
  return some (med, sorted[k]!, sorted[n - k - 1]!)

/-- Judge one plain-binary interleaved session. Validate its ordering and every
sample's output/exit status before using paired times. Separate sessions cannot
accidentally be presented as pairs of compatible standalone summaries. -/
def judgePaired (j : Json) (minChange : Float := 1) : Except String Verdict := do
  unless str j "leanprof" == "measure-pair" do throw "not a `leanprof measure-pair` result"
  unless (j.getObjValAs? Nat "version").toOption == some 1 do throw "unsupported paired result version"
  let samples ← j.getObjValAs? (Array Json) "samples"
  let runs ← j.getObjValAs? Nat "runs"
  unless runs ≥ 6 && runs ≤ 1000 && samples.size == 2 * runs do
    throw "paired result needs 6..1000 complete pairs"
  let machine ← j.getObjVal? "machine"
  let overloaded ← machine.getObjValAs? Bool "overloaded"
  let mut worse : Array String := #[]
  let mut better : Array String := #[]
  let mut notes : Array String := #["plain binaries: copies, allocations and compile heartbeats were not measured"]
  let mut changes : Array Float := #[]
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
      if code != 0 then worse := worse.push s!"pair {i}, {side}: exit code {code}"
      unless ← row.getObjValAs? Bool "output_present" do
        worse := worse.push s!"pair {i}, {side}: checked output file missing"
      let stdout ← row.getObjValAs? String "stdout_hash"
      let stderr ← row.getObjValAs? String "stderr_hash"
      let output ← row.getObjValAs? String "output_hash"
      unless !stdout.isEmpty && !stderr.isEmpty && !output.isEmpty do throw "missing paired output hash"
      let signature := (stdout, stderr, output)
      if let some original := expected then
        if signature != original then worse := worse.push s!"pair {i}, {side}: output or diagnostics changed"
      else expected := some signature
    let (base, candidate) := if i % 2 == 0 then (times[0]!, times[1]!) else (times[1]!, times[0]!)
    changes := changes.push ((candidate.toFloat / base.toFloat - 1) * 100)
  let some (med, lo, hi) := pairedInterval changes | throw "not enough pairs for a 95% median interval"
  let description := s!"paired time: median change {fmt2 med}%, 95% median interval [{fmt2 lo}%, {fmt2 hi}%] ({runs} pairs)"
  if overloaded then notes := notes.push (description ++ " (not judged: machine overloaded)")
  else if hi < -minChange then better := better.push description
  else if lo > minChange then worse := worse.push description
  else notes := notes.push (description ++ s!" (inconclusive at --min-change {fmt2 minChange}%)")
  return { keep := worse.isEmpty && !better.isEmpty, worse, better, notes }

/-- The verdict as `judge` prints it. -/
def Verdict.render (v : Verdict) : String := Id.run do
  let mut out := if v.keep then "KEEP\n" else "DISCARD\n"
  for r in v.worse do out := out ++ s!"  - {r}\n"
  for r in v.better do out := out ++ s!"  + {r}\n"
  if v.worse.isEmpty && v.better.isEmpty then out := out ++ "  - no measurable improvement\n"
  for r in v.notes do out := out ++ s!"    {r}\n"
  return out

end Leanprof.Judge
