# Compile time

```
leanprof elab [--heartbeats] [--compact] [--top N] [--out FILE] FILE.lean...
leanprof elab --project [--module-glob GLOB] [--jobs N] [--heartbeats] [--compact]
              [--term-threshold N] [--dataset DIR | --no-dataset] [--chrome-trace FILE]
```

elaborates the files with Lean's `trace.profiler` (each module with Lake's
setup file for it, so options, plugins and the shared libraries of
precompiled modules load as in the build; if Lean fails on a file, leanprof
says so and shows the error), reads the full trace trees (every `isDefEq`,
`whnf`, instance search, tactic step, kernel check and compiler pass, with
its own and total cost, and every term and tactic with its exact source
range) and reports:

- **where compile time went**: self cost by kind of operation;
- **the slowest files** (with `--project` or several files);
- **the costliest declarations**, each with its most expensive nested
  operations and the definitions behind them;
- **the costliest tactics and terms**, each by its exact source range
  (`file:line:col-line:col`);
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

## Terms and tactics, by exact source range

`trace.profiler` attaches each command's trace to the command; the
operations inside it keep no position. So `elab` does not run `lean` but
`leanprof-elab-driver`, Lean's own frontend run in-process, built with the
project's Lean (below): it loads the module as `lake` and `lean` would (its setup
file: options, imports, plugins, shared libraries; `LEAN_PATH`;
asynchronous elaboration; the kernel), with the same trace options, and
wraps, in that process only, every term and tactic elaborator and every
macro. Every elaboration is recorded against the exact range of the syntax
it elaborates, however short (`--term-threshold N`: only those over N ms, or
N heartbeats), which the report lists:

```
$ leanprof elab Batteries/Recycling/RBTree/WF.lean
  costliest tactics, by exact source range (line:column, inclusive: a tactic contains those under it)
  369.72 ms           Batteries/Recycling/RBTree/WF.lean:293:3-294:71  focus  fun_cases balLeft l v r <;> fun_cases balRight r' v l' <;> grind [reve
  290.07 ms           Batteries/Recycling/RBTree/WF.lean:214:3-218:66  cdot  · next H1 H2 => match hl with | .balanced hl => exact ⟨_, .black hl hr
  238.60 ms    16×    Batteries/Recycling/RBTree/WF.lean:294:5-294:71  grind  grind [reverse, reverse_reverse, reverse_balance2, reverse_setRed]
  146.88 ms           Batteries/Recycling/RBTree/WF.lean:244:3-263:37  induction  induction h with | nil => exact .balanced (.red .nil .nil) | @red a n

  costliest terms, by exact source range (line:column, inclusive: a term contains those under it)
  286.25 ms           Batteries/Recycling/RBTree/WF.lean:214:19-218:43  match  match hl with | .balanced hl => exact ⟨_, .black hl hr⟩ | .redred _ (c
  91.56 ms            Batteries/Recycling/RBTree/WF.lean:326:21-332:95  match  match hl with | .redred .. => nomatch H _ _ _ rfl | .balanced hl => ma
```

Columns count from 1, as editors do. Each range is inclusive (a `·` block
contains the tactics under it, a term the terms inside it), counted once
however its elaboration nests (a macro's expansion is timed at the macro's
range: `<;>` shows as the `focus` it expands to), and `16×` means it was
elaborated 16 times (`<;>` ran `grind` on 16 goals). Tactic sequences are
left out: they are their tactics. A term elaborated twice (postponed, then
resumed) counts both.

`elab.json` has every range (`ranges`: `range` `file:line:col-line:col`,
`pos` the line it starts on, `kind` term or tactic, `syntax` its syntax
kind, `text` its source, `amount`, `count`), `tactics` keeps the costliest
tactic per line with its `range`, and `#leanprof` and `leanprof html` show
them (below).

The wrappers' own cost is a few percent of elaboration (0.3% in heartbeats
on `Examples/ElabHeavy.lean`). The driver also formats only the
descriptions the report reads, with `pp` limits (a description is cut to
200 characters anyway), where `lean --json` prints every trace in full
while elaborating: a full profile costs less than before (below).

**Any Lean.** The driver can only load `.olean` files written by the Lean
it was built with. The one built with leanprof serves projects on
leanprof's Lean; for any other, `elab` builds the driver with the project's
own Lean the first time (its source is compiled into the command: `lean -c`,
then `leanc` linked against that Lean's shared library, as
lean-source-profiler does; a few seconds) and keeps it in
`~/.cache/leanprof/driver/COMMIT/` (`LEANPROF_CACHE` or `XDG_CACHE_HOME` to
move it):

```
$ leanprof elab Main.lean        # a project on Lean 4.34.1, leanprof built with 4.35.0
leanprof: building leanprof-elab-driver for the project's Lean (5045d0056413), once; kept in ~/.cache/leanprof/driver/5045d0056413...
```

Tested with Lean 4.34.1, 4.35.0, 4.36.0-rc1 and the nightly, on Linux and
macOS (CI builds leanprof with 4.35.0 and profiles a project on each). The
definitions behind the work are looked up by that driver as well (`--locate`):
leanprof's own Lean cannot read another Lean's `.olean` files.

When the driver cannot be built (a future Lean whose internals changed), or
cannot load a file's imports, `elab` says why and runs the project's `lean
--json` instead: tactics are then placed on lines by finding their text in
the source (a tactic Lean prints differently from how it is written is left
on its declaration's line), terms are not timed and there is no timeline.
`--no-driver` does that on purpose; `LEANPROF_ELAB_DRIVER=PATH` names a
driver to use as it is.

## Compact profiles

```
leanprof elab --compact FILE.lean...
leanprof elab --compact --project
```

times commands, terms and tactics (and the kernel, compiler and linters
under each command) and nothing inside them: `trace.profiler` is off inside
every wrapped elaborator, so the `isDefEq`, `whnf` and instance searches
that make a full profile expensive are not recorded. The report has
declarations, their elaboration, kernel, compiler and linter time, and the
term and tactic ranges; it has no repeated work and no definitions behind
the work. It costs close to plain `lean` (see the
[comparison](../case-studies/compile-time-vs-lean-source-profiler.md)), so
it is the one to leave on, or to run on a large project first. It needs the
driver (with another Lean, `elab` makes a full profile and says so).

## Timelines and datasets

Every profile made with the driver (in time, not heartbeats) records when
each command, term, tactic and operation ran and on which thread. `elab`
writes them, with every term and tactic by range, to a dataset next to the
report (`.lake/leanprof/elab/`: `index.json`, the report, and
`modules/MODULE.json`; `--dataset DIR`, `--no-dataset`), in documented,
versioned formats ([datasets](elab-dataset.md)). `leanprof html` draws them
in its Timeline tab, `--chrome-trace FILE` writes them for
[Perfetto](https://ui.perfetto.dev), and `scripts/elab-dataset.sh PROJECT OUT`
profiles a whole project into a dataset with its provenance.

## Whole projects

`--project` builds the package (`lake build`; imports are read from the
built `.olean` files), then elaborates every module of the root package
that has a source file, several at a time (`--jobs N`, default half the
cores; each `lean` uses several threads of its own), and writes one report.
Each module is elaborated as Lake does, with its setup file (module name,
the package's `leanOptions`): the one Lake wrote when it built the module,
or, for modules fetched from a cache that were never compiled locally
(Mathlib after `lake exe cache get`), the one `lake setup-file` prints.
`--module-glob 'Foo.Data.*'`
(comma-separated, `*` and `?`) profiles only the matching modules.
Batteries' 195 modules take 17 s on 18 cores (15 s with `--compact`),
against 13 s for a clean `lake build` ([case study](../case-studies/batteries.md)).

Lean processes running side by side slow each other down: on Batteries the
times add up to 118 s with 9 at a time and 77 s one at a time. Heartbeats
do not change; for times you will compare, use `--heartbeats`, or
`--jobs 1`.

`leanprof compare` and `report-md` work on project reports: declarations
match by file and name, modules by name (`module Foo.Bar`), and commands
that declare nothing (`variable (x) in`, `attribute [simp] …`) by file,
text and which of the commands with that text they are (`variable (W') #3`).
`compare` lists the largest changes first and ends with the total.

## Threshold

Terms and tactics are all recorded (`--term-threshold N` to record only those
over N ms): on Batteries' heaviest files that costs 0 to 3% more than
recording those over 1 ms. Other operations cheaper than 1 ms (10,000
heartbeats with `--heartbeats`) are not recorded on their own: their cost stays in the operation around them,
so totals hold, but they do not show up in repeated work or the tactic
lines, and the definitions behind them are counted at no cost. `--threshold
0` records everything, which is what you want for one small file; on large
files it makes Lean 50 to 100 times slower, nearly all of it printing the
trace (Batteries' `String/Lemmas.lean` through `lean --json`: 1.2 s plain,
3.7 s at the default, 111 s at 0).

At the default, `elab` takes 1.4 to 2.2 times as long as plain `lean` on
Batteries' heaviest files, and `--compact` 1.01 to 1.3 times (4 to 20% more
CPU time). Through `lean --json` (another Lean, or `--no-driver`) a full
profile is up to 1.8 times slower than through the driver
(`String/Lemmas.lean`, whose traces print large terms: Lean prints every
trace in full). The numbers are in the
[comparison](../case-studies/compile-time-vs-lean-source-profiler.md).

## Totals

A file's total is the sum of its commands' traced time. Lean elaborates
proofs in parallel, so this is more than the file's wall time (Batteries'
`List/Lemmas.lean`: 16.4 s of elaboration in a 1.5 s run), and per
declaration it is the time that declaration took, whichever thread ran it.
A command Lean expands into another (`theorem Foo.bar` into `namespace Foo
theorem bar end`, `variable (x) in theorem t …` into `section variable (x)
theorem t … end`, `set_option o v in …`) is traced twice, the outer
including the inner; `elab` counts it once, the inner command on its own
line and the outer one with what it adds.

`trace.profiler` itself costs time, mostly after elaboration, when Lean
prints the traced operations: usually 1.3 to 3 times plain `lean`, but
Mathlib's `AlgebraicGeometry/Modules/Sheaf.lean` takes 24 s plain and about
10 minutes profiled, 94% of it pretty-printing the large terms in its
traces. It also costs heartbeats, so a declaration close to `maxHeartbeats`
can fail only when profiled (that file's `pseudofunctor` does); `elab`
prints each file's first error and says when it is a heartbeat limit.

Each file's `wall_ns` in `elab.json` is the wall time of its driver (or
`lean`) process, imports included.

## Heartbeats: exact compile cost

With `--heartbeats` the numbers are Lean heartbeats (a count of allocations
during elaboration) instead of time, shown in kHB: 1 kHB is the unit of
`maxHeartbeats`, whose default limit is 200,000 per declaration. They do not depend on the machine or
its load, so they can be compared without noise, and in parallel. They are
nearly the same on every run: on all of Batteries two runs differ by 2 in
a million (no declaration by more than 290 heartbeats); Lean itself varies
that much between runs, even single-threaded. Editing one declaration moves
its neighbours by a few heartbeats, so `leanprof compare` counts an increase
above 1% and 1,000 heartbeats as a regression. Declarations are matched by
name, so edits that move lines still compare. The driver's wrappers allocate
too (0.3% more heartbeats on `Examples/ElabHeavy.lean` than through `lean`),
so compare reports made the same way (`exact_ranges` in `elab.json` says
which).

## In the editor

The report goes to `.lake/leanprof/elab.json`; `#leanprof` shows it as
`⚙ 17.3 kHB to compile` hints at the end of each line, and hovering lists the
line's costliest operations, the definitions behind them and the terms and
tactics that start on it, by range:

```
by exact source range (line:column, inclusive):
  29:3-29:32  148.3 kHB  tactic focus: refine ⟨?_, ?_, ?_⟩ <;> omega
  29:27-29:32  141.7 kHB (3×)  tactic omega: omega
  29:3-29:22  5.1 kHB  tactic refine: refine ⟨?_, ?_, ?_⟩
```

A line inside a proof with no declaration on it gets a `⚙` hint of its own.
`leanprof html` shows the same in its source view and lists every range in
a "Source ranges" tab. See [editor](editor.md).

## Compared with lean-source-profiler

[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)
records every term and tactic with its exact source range through its own
Lean driver (the approach `elab`'s driver takes too), has a VS Code overlay
and a browser explorer, and publishes profiles of all of Mathlib. [A head-to-head comparison on the same
files](../case-studies/compile-time-vs-lean-source-profiler.md) shows what
each finds, how accurate the totals are and what each costs to run.
