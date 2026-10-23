# Compile time

```
leanprof elab [--heartbeats] [--top N] [--out FILE] FILE.lean...
leanprof elab --project [--module-glob GLOB] [--jobs N] [--heartbeats]
```

elaborates the files with Lean's `trace.profiler`, reads the full trace
trees (every `isDefEq`, `whnf`, instance search, tactic step, kernel check
and compiler pass, with its own and total cost) and reports:

- **where compile time went**: self cost by kind of operation;
- **the slowest files** (with `--project` or several files);
- **the costliest declarations**, each with its most expensive nested
  operations and the definitions behind them;
- **the costliest tactic steps**, by the line each is on;
- **repeated work**: the same operation done many times, across files;
- **the definitions behind the work**: which constants `isDefEq` and `whnf`
  unfolded, which instances were tried and which simp lemmas rewrote, what
  each cost, from how many places, each with its own `file:line`;
- **exact counts** (with `--counts`): how often each declaration was
  unfolded by the elaborator and by the kernel, and the simp lemmas tried
  most without success.

```
$ leanprof elab --project        # in a checkout of Batteries
  costliest declarations (elab / kernel / compiler / lint)
  1657.70 ms   1589.63 ms / 0.00 ms   / 0.00 ms   / 68.08 ms   Batteries/Recycling/RBTree/WF.lean:365  protected theorem append ...
      415.51 ms    [Elab.step] decreasing_tactic
      380.20 ms    isDefEq unfolds Std.Iterator.IsPlausibleStep  (Init/Data/Iterators/Basic.lean:375)

  costliest tactic steps, by the line each is on (inclusive: a step contains the steps under it)
  656.11 ms           Batteries/Recycling/RBTree/WF.lean:290   suffices ∀ r' l', r' = r.reverse → ...
  605.69 ms    2×     Batteries/Data/List/Lemmas.lean:967  grind

  repeated work (the same operation done more than once, across files)
  14247.65 ms  193×   [Elab.step] decreasing_tactic  (first at Batteries/Data/Array/Basic.lean:176)
  5013.78 ms   188×   [Elab.step] get_elem_tactic  (first at Batteries/CodeAction/Basic.lean:29)

  definitions behind the work (the isDefEq/whnf/instance/simp work each caused; overlapping)
  2258.68 ms   isDefEq unfolds  Std.Iterator.IsPlausibleStep  (Init/Data/Iterators/Basic.lean:375), reached from 69 sites, 24369×
  705.04 ms    isDefEq unfolds  LT.lt  (Init/Prelude.lean:1407), reached from 559 sites, 14619×
  633.40 ms    instance tried   String.Slice.RevPosIterator.instIteratorSubtypePosNeEndPosOfPure  (Init/Data/String/Iterate.lean:139), reached from 21 sites, 66×
  392.73 ms    whnf reduces     Decidable.decide  (Init/Prelude.lean:1158), reached from 89 sites, 377×

$ leanprof elab --project --counts
  most unfolded (exact counts from `diagnostics`: elaborator / kernel)
  76,990     / 5,574      outParam  (Init/Prelude.lean:733), 1834 sites
  1,746      / 64,911     Bool.rec  (Init/Prelude.lean:99), 564 sites
```

Repeated work usually means a missing instance, a coercion found the long
way every time, or a definition that should be reducible. A definition that
is unfolded thousands of times, or costs a lot from many sites, is a
candidate for `@[irreducible]`, a lemma that avoids unfolding it, or a
cheaper instance.

## The definitions behind the work

Besides `trace.profiler`, `elab` turns on, for the files it elaborates:

| what | Lean option | gives |
|---|---|---|
| `isDefEq` unfolds | `trace.Meta.isDefEq.delta.unfold{Left,Right,LeftRight}` | the constant unfolded; its cost is the comparison of the unfolded terms that follows |
| `whnf` reduces | (the `Meta.whnf` trace, printed with `pp.fullNames`) | the head constant of the term reduced, when it is a definition |
| instance tried | (the `Meta.synthInstance.apply` trace) | the instance and the cost of trying it |
| simp lemma | `trace.Meta.Tactic.simp.rewrite` | each lemma that rewrote, charged the unification just before it |
| exact counts (`--counts`) | `diagnostics` | per declaration: unfolds by the elaborator and the kernel, instances used, simp lemmas used and tried |

`--counts` is off by default because `diagnostics` slows elaboration down by
up to 2× (it also changes the heartbeat counts, so compare reports made with
the same options). If Lean fails on a file only with `diagnostics` on (Lean
4.35 does on some nested inductive types), `elab` profiles that file again
without it and says so.

Costs of different constants overlap (unfolding `f` can unfold `g`); a
constant unfolded again inside its own unfolding is counted but not charged
twice. The constants are then looked up in the environment of the profiled
modules (their `.olean` files) for the file and line they are declared on,
whether in the project, a dependency or Lean itself (`Init/Prelude.lean:1407`
is in the toolchain's sources). `--no-defs` turns all of this off.

The same appears in `elab.json` (`constants`, and `unfolded` per
declaration) and in the editor: hovering a declaration's `⚙` hint lists
"73 ms unfolding `Foo.bar` (Foo.lean:12), reached from 40 call sites".

## Tactic steps by line

A declaration's trace is attached to the line it starts on. To point inside
proofs, `elab` finds each tactic step's text in the source after the
declaration's start, in the order Lean ran them, and reports the costliest
lines (inclusive: a `·` block contains the steps under it). The editor shows
them as `⚙` hints too. A tactic Lean prints differently from how it is
written (rare: whitespace is ignored) is left on its declaration's line.

## Whole projects

`--project` builds the package (`lake build`; imports are read from the
built `.olean` files), then elaborates every module of the root package
that has a source file, several at a time (`--jobs N`, default half the
cores; each `lean` uses several threads of its own), and writes one report.
Each module is elaborated as Lake does, with its setup file (module name,
the package's `leanOptions`). `--module-glob 'Foo.Data.*'`
(comma-separated, `*` and `?`) profiles only the matching modules.
Batteries' 195 modules take 17 s on 18 cores, against 13 s for a clean
`lake build` ([case study](../case-studies/batteries.md)).

Lean processes running side by side slow each other down: on Batteries the
times add up to 118 s with 9 at a time and 77 s one at a time. Heartbeats
do not change; for times you will compare, use `--heartbeats`, or
`--jobs 1`.

`leanprof compare` and `report-md` work on project reports: declarations
match by file and name, modules by name (`module Foo.Bar`).

## Threshold

Operations cheaper than 1 ms (10,000 heartbeats with `--heartbeats`) are
not recorded on their own: their cost stays in the operation around them,
so totals hold, but they do not show up in repeated work or the tactic
lines, and the definitions behind them are counted at no cost. `--threshold
0` records everything, which is what you want for one small file; on large
files it makes Lean 50 to 100 times slower, nearly all of it printing the
trace (Batteries' `String/Lemmas.lean`: 1.2 s plain, 3.7 s at the default,
111 s at 0).

At the default, `elab` takes 1.3 to 1.7 times as long as plain `lean` on
Batteries' heaviest files (3 times on `String/Lemmas.lean`, whose traces
print large terms).

## Totals

A file's total is the sum of its commands' traced time. Lean elaborates
proofs in parallel, so this is more than the file's wall time (Batteries'
`List/Lemmas.lean`: 16.4 s of elaboration in a 1.5 s run), and per
declaration it is the time that declaration took, whichever thread ran it.
A command Lean expands into another (`theorem Foo.bar` into `namespace Foo
theorem bar end`) is traced twice, the outer including the inner; `elab`
counts it once. Each file's `wall_ns` in `elab.json` is the wall time of its
`lean` process, imports included.

## Heartbeats: exact compile cost

With `--heartbeats` the numbers are Lean heartbeats (a count of allocations
during elaboration) instead of time. They do not depend on the machine or
its load, so they can be compared without noise, and in parallel. They are
nearly the same on every run: on all of Batteries two runs differ by 2 in
a million (no declaration by more than 290 heartbeats); Lean itself varies
that much between runs, even single-threaded. Editing one declaration moves
its neighbours by a few heartbeats, so `leanprof compare` counts an increase
above 1% and 1,000 heartbeats as a regression. Declarations are matched by
name, so edits that move lines still compare.

## In the editor

The report goes to `.lake/leanprof/elab.json`; `#leanprof` shows it as
`⚙ 17.3 kHB to compile` hints at the end of each line, and hovering lists the
line's costliest operations and the definitions behind them. See
[editor](editor.md).

## Compared with lean-source-profiler

[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)
records every term and tactic with its exact source range through its own
Lean driver, has a VS Code overlay and a browser explorer, and publishes
profiles of all of Mathlib. [A head-to-head comparison on the same
files](../case-studies/compile-time-vs-lean-source-profiler.md) shows what
each finds, how accurate the totals are and what each costs to run.
