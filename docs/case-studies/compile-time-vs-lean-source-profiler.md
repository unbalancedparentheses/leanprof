# Compile time: leanprof elab and lean-source-profiler, head to head

[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)
(LSP below; CLI 0.3.0, the latest release) is the other profiler of Lean
compile time. Both ran on the same files, on the same machine (Apple M5
Max, 18 cores), with Lean 4.35.0: Batteries `v4.35.0`'s four heaviest
proof files ([case study](batteries.md)) and leanprof's
`Examples/ElabHeavy.lean`, then all of Batteries.

```
lean-profile profile FILE --mode compact|detailed --output OUT   # LSP
leanprof elab [--heartbeats | --counts] FILE                      # leanprof
```

## Summary

| | lean-source-profiler | leanprof elab |
|---|---|---|
| how | its own Lean driver, wrapping the elaborators | `lean --json` with `trace.profiler` and a few trace classes |
| setup | Node 20 and npm; compiles a driver per toolchain (8 s, once) | the leanprof command (or a Lake dependency) |
| granularity | every term and tactic, exact source range | declaration, and tactic steps by line |
| internal operations | `--mode detailed` | always |
| definitions behind the work | "unfold evidence": the duration of each operation that names a constant, not a cost | the cost of the work each unfold, instance, `whnf` and simp lemma caused, per definition, with its `file:line`, call sites; exact counts with `--counts` |
| repeated work, across files | no | yes |
| whole project | sequential | parallel (`--jobs`) |
| exact, comparable numbers | no | `--heartbeats`; `compare`, `report-md`, the GitHub Action |
| viewing | VS Code overlay, browser explorer, published Mathlib profiles | text, JSON, `#leanprof` hints and hovers in the editor |

## Overhead

Wall time, seconds (plain: median of three `lake env lean FILE`; leanprof:
the whole command, `lake env` and locating definitions included; LSP: the
whole command):

| file | plain | leanprof | `--heartbeats` | `--counts` | LSP compact | LSP detailed |
|---|---|---|---|---|---|---|
| `BinaryHeap/WF.lean` | 1.53 | 2.0 | 2.1 | 2.7 | 1.63 | 2.84 |
| `List/Lemmas.lean` | 1.49 | 2.2 to 2.6 | 2.6 | 5.1 | 2.10 | 4.72 |
| `String/Lemmas.lean` | 1.19 | 3.6 to 3.8 | 4.7 | 4.3 | 1.38 | 5.38 |
| `RBTree/WF.lean` | 0.97 | 2.0 | 2.5 | 3.6 | 1.08 | 2.94 |
| `ElabHeavy.lean` | 0.49 | 0.62 | 0.66 | 0.63 | 0.60 | 0.62 |

leanprof is faster than LSP's detailed mode, the one that sees internal
operations, by 1.4 to 2 times on the Batteries files (they tie on `ElabHeavy.lean`).
LSP's compact mode, which records source timings only, is the lightest:
within 6 to 41% of plain Lean. leanprof has no equivalent: its numbers come
from `trace.profiler`, and Lean prints the trace of each command as JSON
while it elaborates the next (on `String/Lemmas.lean`, whose traces print
large terms, that triples the time). LSP's driver keeps the trace in memory
and formats it afterwards; its "Lean processing" time is within 30% of plain
Lean even in detailed mode.

On the whole of Batteries, LSP (one file at a time) and leanprof (9 at a
time):

| run | files | wall |
|---|---|---|
| `lake build` from clean | 195 modules | 13.3 s |
| leanprof `elab --project` | 195 (the built library modules) | 17.0 s |
| leanprof `elab --project --heartbeats` | 195 | 16.7 s |
| LSP `profile --project . --mode compact` | 263 of 271 (every `.lean` file, tests and scripts included; 8 failed) | 88.5 s |
| LSP `profile --project . --mode detailed` | 263 of 271 | 129.5 s |

LSP takes in files that are not part of the library (tests, scripts), so
the file counts differ; per file, leanprof's parallel run is still about
4 times faster than LSP's compact mode and 6 times faster than its
detailed one.

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

**Inside a proof**, LSP times every term and tactic with its exact range.
leanprof finds each tactic step's text in the source and reports the
costliest tactic lines: on `RBTree/WF.lean` both point at lines 290 to 294
(`suffices` / `fun_cases` / `grind`), on `List/Lemmas.lean` at the `grind`
calls on lines 964 to 967. leanprof does not time terms (`have` bodies,
`by` blocks inside terms) separately from their tactic, nor columns.

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

- Tactic steps by line (`costliest tactic steps`, hints in the editor):
  leanprof only had declarations.
- Modules are elaborated with Lake's setup file, as LSP and `lake build`
  do: the package's `leanOptions` and the real module name (private names
  then match the environment).
- Nested commands counted once (above).
- `diagnostics` made opt-in (`--counts`): it doubled elaboration time on
  some files and changes what is measured.

## Gaps left, plainly

- **Exact ranges for every term and tactic.** `trace.profiler` drops the
  positions of nested operations; getting them needs a driver that wraps
  the elaborators, as LSP has. leanprof's tactic lines are found by text
  and can miss a tactic Lean prints differently from its source.
- **Overhead of a source-only profile.** LSP's compact mode is close to
  free; leanprof's lightest run still has `trace.profiler` printing
  through `--json`.
- **Files outside the built library.** `--project` profiles the modules
  `lake build` built (the default targets); tests and scripts that are not
  built are not included unless named on the command line, where LSP takes
  every `.lean` file under the directory.
- **Viewers and datasets.** LSP has a VS Code overlay, a browser explorer
  and profiles of all of Mathlib published. leanprof shows hints and hovers
  through Lean's own language server (`#leanprof`), text and JSON.
