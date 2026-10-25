# Compile time: leanprof elab and lean-source-profiler, head to head

[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)
(LSP below; CLI 0.3.0, the latest release) is the other profiler of Lean
compile time. Both ran on the same files, on the same machine (Apple M5
Max, 18 cores), with Lean 4.35.0: Batteries `v4.35.0`'s four heaviest
proof files ([case study](batteries.md)) and leanprof's
`Examples/ElabHeavy.lean`, then all of Batteries. This is the second round:
the first found three gaps in leanprof (exact term and tactic ranges, a
near-free compact mode, a richer viewer); `elab` now elaborates with its own
in-process driver and has `--compact`, and the numbers below are from
re-running everything after that.

```
lean-profile profile FILE --mode compact|detailed --output OUT        # LSP
leanprof elab [--compact | --heartbeats | --counts] FILE               # leanprof
```

## Summary

| | lean-source-profiler | leanprof elab |
|---|---|---|
| how | its own Lean driver, wrapping the elaborators | its own Lean driver (`leanprof-elab-driver`), wrapping the elaborators, with `trace.profiler` and a few trace classes; `lean --json` when the project is on another Lean |
| setup | Node 20 and npm; compiles a driver per toolchain (8 s, once) | the leanprof command (or a Lake dependency), which builds its driver with it; one toolchain per build |
| granularity | every term and tactic, exact source range | every term and tactic over the threshold, exact source range; declarations; tactics by line for the editor |
| internal operations | `--mode detailed` | by default; not with `--compact` |
| definitions behind the work | "unfold evidence": the duration of each operation that names a constant, not a cost | the cost of the work each unfold, instance, `whnf` and simp lemma caused, per definition, with its `file:line`, call sites; exact counts with `--counts` |
| repeated work, across files | no | yes |
| whole project | sequential | parallel (`--jobs`) |
| exact, comparable numbers | no | `--heartbeats`; `compare`, `report-md`, the GitHub Action |
| viewing | VS Code overlay, browser explorer (folders, files, declarations, source lines), published profiles of all of Mathlib | text, JSON, `#leanprof` hints and hovers in the editor (ranges in the hover), `leanprof html` (a project view from project to term and tactic, with repeated work, definitions behind the work and a base to compare at each level), published profiles of Batteries and Mathlib's 40 slowest modules |

## Overhead

Wall time, seconds, median of three rounds (each round runs every command
once, so that the machine's load falls on all of them alike). Plain:
`lake env lean FILE`; leanprof: the whole command, `lake env`, the driver
check and locating definitions included; LSP: the whole command. The
machine was shared with other jobs during these runs (load average 20 to
30 on 18 cores): plain `lean` itself varied by up to 50% between rounds,
so differences under about 15% are noise. `ElabHeavy.lean`, which takes
half a second, is the fastest of three rounds.

| file | plain | leanprof | `--compact` | `--heartbeats` | `--counts` | `--no-driver` (before) | LSP compact | LSP detailed |
|---|---|---|---|---|---|---|---|---|
| `BinaryHeap/WF.lean` | 1.71 | 2.32 | 1.79 | 2.13 | 3.78 | 2.18 | 1.91 | 3.51 |
| `List/Lemmas.lean` | 1.51 | 2.40 | 1.74 | 2.89 | 5.99 | 2.67 | 1.84 | 4.39 |
| `String/Lemmas.lean` | 1.91 | 4.29 | 1.93 | 5.11 | 5.99 | 7.83 | 2.43 | 8.09 |
| `RBTree/WF.lean` | 1.20 | 2.43 | 1.58 | 2.58 | 3.62 | 2.55 | 1.26 | 3.27 |
| `ElabHeavy.lean` | 0.57 | 0.75 | 0.58 | 0.70 | 0.75 | 0.67 | 0.60 | 0.68 |

CPU time (user and system, all threads, median of the same runs), which
the load disturbs less:

| file | plain | leanprof | `--compact` | `--no-driver` | LSP compact | LSP detailed |
|---|---|---|---|---|---|---|
| `BinaryHeap/WF.lean` | 3.63 | 4.96 | 3.77 (+4%) | 5.05 | 3.86 (+6%) | 5.55 |
| `List/Lemmas.lean` | 7.02 | 9.37 | 7.46 (+6%) | 10.17 | 7.74 (+10%) | 10.94 |
| `String/Lemmas.lean` | 4.37 | 7.76 | 4.81 (+10%) | 11.00 | 4.80 (+10%) | 10.16 |
| `RBTree/WF.lean` | 3.64 | 6.35 | 4.36 (+20%) | 6.38 | 3.73 (+2%) | 6.30 |

**Compact profiles.** `--compact` (commands, terms and tactics, nothing
inside them) costs 1 to 32% more wall time than plain `lean` on these files
and 4 to 20% more CPU, against 5 to 27% and 2 to 10% for LSP's compact
mode: the two are about as cheap. LSP's is lighter on `RBTree/WF.lean`,
whose many small `match` terms each pay for a wrapper (leanprof keeps
`trace.profiler` on outside the wrapped elaborators, for the kernel,
compiler and linter times of each declaration).

**Full profiles.** With the driver, a full profile (every internal
operation over 1 ms, the definitions behind the work, terms and tactics by
range) costs 1.4 to 2.2 times plain `lean`, and 1.3 to 1.9 times less than
LSP's detailed mode. It costs about the same as the `lean --json` profile
`elab` made before, and 1.8 times faster on `String/Lemmas.lean`: Lean
prints the whole trace of each command as text, with every term in full,
while the driver formats only the descriptions the report reads, with
pretty-printing bounded. `--counts` stays the expensive option (Lean's
`diagnostics`).

On the whole of Batteries, LSP (one file at a time) and leanprof (9 at a
time), one run each, on the same loaded machine (`elab` with `--no-build`,
the package already built):

| run | files | wall |
|---|---|---|
| `lake build` from clean (first round, unloaded) | 195 modules | 13.3 s |
| leanprof `elab --project` | 195 (the built library modules), all through the driver | 16.8 s |
| leanprof `elab --project --compact` | 195 | 15.0 s |
| leanprof `elab --project --heartbeats` | 195 | 19.7 s |
| leanprof `elab --project --no-driver` (`lean --json`, as before) | 195 | 21.3 s |
| LSP `profile --project . --mode compact` | 263 of 271 (every `.lean` file, tests and scripts included; 8 failed) | 102.9 s |
| LSP `profile --project . --mode detailed` | 263 of 271 | 152.3 s |

LSP takes in files that are not part of the library (tests, scripts), so
the file counts differ; per file, leanprof's parallel run is about 4.5
times faster than LSP's compact mode and 6.7 times faster than its
detailed one, and `--compact` 5 times faster than LSP's compact mode. The
whole-project report lists 10,594 term and tactic ranges.

## Totals

Both report the sum of their recorded commands; Lean elaborates proofs on
several threads, so both sums exceed wall time, and they agree:

| file | leanprof | LSP detailed | `lean` wall |
|---|---|---|---|
| `BinaryHeap/WF.lean` | 3.6 s | 3.1 s | 1.5 s |
| `List/Lemmas.lean` | 16.4 s | 16.1 s | 1.5 s |
| `String/Lemmas.lean` | 4.0 s | 5.5 s | 1.2 s |
| `RBTree/WF.lean` | 4.5 s | 4.0 s | 1.0 s |

Neither is wrong; neither is the file's wall time, which leanprof reports
separately (`wall_ns` per file in `elab.json`, the `lean` process including
imports). Comparing the two found a bug in leanprof: a command Lean expands
into another (`theorem Foo.bar` into `namespace Foo theorem bar end`) is
traced twice, and leanprof counted both. It now counts the outer one only
for what it adds.

## What each finds

**The costliest declarations agree.** The four costliest lines are the
same, in the same order, in both tools on all four Batteries files
(`WF.lean:245`, `List/Lemmas.lean:1115` then `964` to `967`,
`String/Lemmas.lean:351`, `518`, `465`, `RBTree/WF.lean:537`, `365`, `398`,
`355`).

**Inside a proof**, both now time every term and tactic with its exact
range, wrapping Lean's elaborators the same way. On `RBTree/WF.lean` both
point at `fun_cases balLeft l v r <;> fun_cases balRight r' v l' <;> grind
[...]` (lines 293:3 to 294:71, 370 ms, of which `grind` 239 ms over 16
goals) and at the `match` on lines 214 to 218 (290 ms); on
`List/Lemmas.lean` at the `grind` calls on lines 964 to 967. Differences
that remain: leanprof records a term or tactic only above the threshold
(1 ms by default, `--threshold 0` for all), where LSP records all of them;
leanprof counts a range once however it nests (a macro's expansion, a
tactic sequence of one tactic) and says how many times it ran (`16×`),
where LSP keeps each elaboration as its own event and unions their
intervals.

**The definitions behind the work.** LSP lists, for each operation, the
constants it references or that were unfolded during it, and sums
durations per constant. Those sums are not costs: on `List/Lemmas.lean`
`outParam` gets 12.6 s and `Int.instLEInt` 11.5 s, in a file Lean
elaborates in 1.5 s, because every operation that mentions a constant
counts in full. leanprof charges each unfold the comparison it led to
(once per nest of the same constant), each instance its attempt, each
`whnf` its reduction and each simp lemma its unification, so costs are
bounded by the work done, and adds them up per definition across all
files, with the number of declarations that reached it. On Batteries that
is what surfaced `Std.Iterator.IsPlausibleStep`: 24,369 unfolds from 69
declarations, 2.3 s, mostly in `RBTree` proofs that never mention
iterators. LSP's view of `RBTree/WF.lean` does list `Std.Iterator.IsPlausibleStep`
(419 ms of operations naming it, among 48 such constants), but per file and with sums
that overlap without bound.

**Exact counts and regressions.** `--counts` adds Lean's own
`diagnostics` counters (unfolds by the elaborator and by the kernel,
instances used, simp lemmas used and tried: `eq_self` failed 3,648 of
4,766 times across Batteries). `--heartbeats` gives numbers that repeat to
within 2 in a million across runs, for `leanprof compare` and pull-request
comments. LSP has neither.

## Gaps closed while writing this

- Exact source ranges for every term and tactic (`costliest tactics` and
  `costliest terms`, `ranges` in `elab.json`, the editor's hover, a tab in
  `leanprof html`), from an in-process driver (`leanprof-elab-driver`)
  that wraps the elaborators. Before, tactic steps were placed on lines by
  their text, and before that leanprof only had declarations.
- `--compact`, a profile of commands, terms and tactics only, about as
  cheap as LSP's compact mode.
- Full profiles up to 1.8 times faster: the driver formats only what the
  report reads.
- Modules are elaborated with Lake's setup file, as LSP and `lake build`
  do: the package's `leanOptions` and the real module name (private names
  then match the environment).
- Nested commands counted once (above).
- `diagnostics` made opt-in (`--counts`): it doubled elaboration time on
  some files and changes what is measured.

## Gaps left, plainly

- **One Lean per build** (fixed since). The driver can only load `.olean`
  files of the Lean it was built with; for a project on another toolchain,
  `elab` fell back to `lean --json` (tactics by line, by their text; no
  terms). As LSP does, `elab` now compiles a driver for the project's
  toolchain the first time it needs one (seconds) and keeps it
  ([compile time](../guide/compile-time.md), "Another Lean").
- **Terms and tactics under the threshold** are not recorded on their own
  (their time is in the range around them); LSP records every one.
  `--threshold 0` records them all, at a cost on large files.
- **Elaborators defined in the profiled file** itself are not wrapped
  (both tools): their work is timed in the range around them.
- **Heartbeats with the driver** include the wrappers' own allocations
  (0.3% on `ElabHeavy.lean`), so a report made with the driver and one made
  with `lean` do not compare exactly; a declaration within 0.3% of
  `maxHeartbeats` could fail under the driver only.
- **Files outside the built library.** `--project` profiles the modules
  `lake build` built (the default targets); tests and scripts that are not
  built are not included unless named on the command line, where LSP takes
  every `.lean` file under the directory.
- **Viewers and datasets.** LSP has a VS Code overlay, a browser explorer
  with timelines, and profiles of all of Mathlib (8,556 files) published.
  leanprof shows ranges in Lean's own language server (`#leanprof` hovers)
  and in a static HTML page with a project view (project, folder, module,
  declaration, term or tactic, each compared with a base when given one);
  its [published profiles](../profiles/README.md) cover all of Batteries and
  only Mathlib's 40 slowest modules, and it has no timeline view.
