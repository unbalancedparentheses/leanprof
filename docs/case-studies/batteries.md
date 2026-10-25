# Case study: compile time of Batteries

[Batteries](https://github.com/leanprover-community/batteries), the
community's extended standard library, at tag `v4.35.0` (Lean 4.35.0): 195
modules with source files. All runs used leanprof's CLI from another
checkout, in a clean clone, on an Apple M5 Max (18 cores):

```
git clone --depth 1 --branch v4.35.0 https://github.com/leanprover-community/batteries
cd batteries && lake build
leanprof elab --project                 # times
leanprof elab --project --heartbeats    # exact, twice
leanprof elab --project --counts        # with Lean's diagnostics counters
```

## Timings

| run | wall |
|---|---|
| `lake build` from clean | 13.3 s |
| `elab --project` (9 files at a time) | 17.0 s |
| `elab --project --heartbeats` | 16.7 s, 17.0 s |
| `elab --project --counts` | 20.0 s |
| `elab --project --jobs 1` | 77.5 s |
| report (locating 688 constants, writing a 3.2 MB `elab.json`) | 0.6 s |

Profiling the whole library costs about as much as building it. Running 9
files at a time inflates each file's times (118 s of compile time in total,
against 77 s one at a time), so compare times from runs with the same
`--jobs`, or heartbeats, which do not depend on it.

The two heartbeat runs differ by 3,394 heartbeats in 1,504 million (2 in a
million); no declaration differs by more than 290, and `leanprof compare`
on the two reports finds no regressions among 3,415 declarations and 195
modules.

The figures below were measured with leanprof `a69f32a`; the heartbeats
reproduce exactly with it (`scripts/reproduce.sh batteries`, see
[reproduce.md](../reproduce.md)). Later versions elaborate through their
own driver and report fewer heartbeats (1,424 million in all). Re-running,
pairs of `--heartbeats` runs differed by 0.4 to 5 in a million, not always
within 2. Unfold and instance counts come from the timed profile, which
keeps only operations over its 1 ms threshold, so they vary with timing:
`Std.Iterator.IsPlausibleStep` came out at 24,368 unfolds from 68
declarations in every re-run, the instance below at 32 to 66 tries.

## Where compile time goes

Heartbeats, by kind of operation (self): tactic steps 55%, the compiler
15%, the kernel 3.5%.

Slowest files (heartbeats; times with 9 at a time):

| heartbeats | time | file |
|---|---|---|
| 98.3 M | 17.6 s | `Data/List/Lemmas.lean` |
| 94.6 M | 4.7 s | `Data/BinaryHeap/WF.lean` |
| 83.2 M | 8.0 s | `Recycling/RBTree/Lemmas.lean` |
| 83.0 M | 10.3 s | `Recycling/RBTree/WF.lean` |
| 79.6 M | 7.2 s | `Data/String/Lemmas.lean` |

## Findings

**Termination and bounds proofs are a quarter of the library's
elaboration.** The repeated-work table, across all files:

| heartbeats | share | times | operation |
|---|---|---|---|
| 216.5 M | 14.4% | 193 | `decreasing_tactic` |
| 145.2 M | 9.7% | 187 | `get_elem_tactic` |
| 26.4 M | 1.8% | 99 | `grind` |

`decreasing_tactic` (termination of well-founded definitions) and
`get_elem_tactic` (array bounds) are what Lean runs when a definition does
not say `decreasing_by` or the index proof is not given. In time, 14.2 s and
5.0 s of the 118 s. The largest single ones are in `RBTree/WF.lean`
(`append`, line 365: three `decreasing_tactic` runs of 261 to 416 ms) and
`BinomialHeap/Basic.lean` (`merge'`, line 374: 157 to 187 ms each). Explicit `termination_by`
and `decreasing_by` proofs, or index proofs passed directly, are where the
compile time is.

**`Std.Iterator.IsPlausibleStep` is unfolded 24,369 times from 69
declarations**, 2.3 s of `isDefEq` work (the comparisons after the
unfolds), with `Std.IterM.IsPlausibleStep` (24,371, 2.0 s) and
`Std.Iter.IsPlausibleStep` (12,180, 1.3 s) behind it. They come from
`Init/Data/Iterators/Basic.lean` (lines 375, 416, 482), not from Batteries,
and most of the cost is in proofs that never mention iterators: the
`RBTree` `append` theorems (`WF.lean:365`, 380 ms and 1,944 unfolds;
`:398`, 356 ms; `:355`, 344 ms), `zoom_del` and `zoom_ins`
(`Lemmas.lean:724`, `:693`) and `String/Lemmas.lean`'s `splitAux_of_valid`.
These are the same declarations whose cost is mostly `decreasing_tactic`
runs, so the likely path is the termination proofs unifying through the
iterator library's step relation; the report shows which definitions and
declarations, not which tactic inside them (a `--threshold 0` run of one
of these files would). Either way it is a candidate for a lemma or an
irreducibility attribute upstream, found only because the cost is
attributed to the definition, with its location, across the project.

**One instance is tried 66 times for 633 ms**:
`String.Slice.RevPosIterator.instIteratorSubtypePosNeEndPosOfPure`
(`Init/Data/String/Iterate.lean:139`), from 21 declarations, again mostly
in `RBTree` (`WF.lean:398`: 154 ms, `Lemmas.lean:724`: 104 ms).

**The costliest tactic lines** are `grind` calls in `List/Lemmas.lean`
(lines 941 to 967, 270 to 600 ms each) and a `suffices`/`fun_cases` block in
`RBTree/WF.lean:290` (656 ms).

**With `--counts`**, the most unfolded declarations: `outParam` (76,990
times by the elaborator, from 1,834 declarations), and, by the kernel,
`Int.rec` (65,797), `Bool.rec` (64,911) and `List.rec` (52,734): kernel
reduction in `decide` and `omega` proofs. The simp lemma tried most without
success is `eq_self` (3,648 failures in 4,766 tries).

## Notes

- `Batteries/Data/MLList/Basic.lean` fails to elaborate with `diagnostics`
  on (Lean 4.35: "Unknown constant `_nested.Thunk_1.rec`"); `--counts`
  profiles it again without it.
- Lean cannot print some commands of the tactic files (`failed to pretty
  print term`); `elab` names them after their source line instead.
- Lean's `trace.profiler` traces a command it expands (`theorem
  ParentGeChildren.swap_parent` into `namespace ParentGeChildren theorem
  swap_parent end`) twice; earlier versions of `elab` counted such
  declarations twice. They are now counted once.
