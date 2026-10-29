# Compile time

```
leanprof elab [--heartbeats] [--compact] [--top N] [--out FILE] FILE.lean...
leanprof elab --project [--module-glob GLOB] [--jobs N] [--heartbeats] [--compact]
leanprof elab --heartbeats --why FILE.lean...       # why the costliest declarations are slow
leanprof elab --max-heartbeats N FILE.lean...       # every declaration above a budget (for CI)
leanprof fix --elab FILE.lean...                    # apply Lean's own fixes, checked
leanprof fix --elab --project                       # project-wide changes, each checked
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

## Why a declaration is slow: `--why`

```
leanprof elab --heartbeats --why FILE.lean...
leanprof explain --elab               # the same from the last report (--report FILE for another)
leanprof explain --elab --json        # for agents; also the MCP `elab` (why: true) and `explain` tools
```

For the costliest declarations (`--top`, at most 10), `--why` names the
causes the profile shows and a change to try for each. It keeps two things
apart: **observed** is measured in this profile (a cost, a count, a share
of the declaration); **suggested** is what to try. A suggestion marked
`[mechanical]` is an edit Lean computed itself, which
[`leanprof fix --elab`](fix.md#compile-time-fix---elab) applies and checks;
the others are hypotheses that nothing has checked.

| cause | observed | suggested |
|---|---|---|
| `simp-set` | a `simp`, `simp_all`, `simpa` or `dsimp` call costing 2% or more of its declaration, and the lemmas it used | `simp only [...]` with Lean's own list for that call (`[mechanical]`). Not offered for a call already restricted with `only`, one run on several goals with different lemma lists (`<;>`), one that spans lines with a tactic block inside, or a `simp` a macro runs |
| `termination` | `decreasing_tactic` run once per measure Lean tried (no `termination_by`), and the measure it found | that measure as a `termination_by` clause after the proof (`[mechanical]`). Not offered for `mutual` or `where` declarations, nor when a clause is there already |
| `unfold`, `whnf` | `isDefEq` or `whnf` unfolding a definition, how often, and the work that followed | for a definition of this project: `@[irreducible]` with a lemma that unfolds it, or a `@[simp]` lemma about it; otherwise `attribute [local irreducible] f in`, or rewriting with its equations first |
| `instance-failed` | an instance search that failed, how often and at what cost (searches with a metavariable, still being elaborated, are left out) | declare the instance (or `haveI` in the proof), or give explicitly the term that asks for it |
| `instance` | an instance tried at a high cost | a priority for the instance that should apply, or a local instance |
| `decide` | a `decide` call, the `whnf` work under it and the kernel's check | `decide +kernel` (the kernel evaluates, once); `rfl` for closed equations. `native_decide` is not a fix: it trusts the compiler (the axiom `Lean.ofReduceBool`), and the experiment guard rejects it |
| `kernel` | the kernel's share, and with `--counts` what it unfolded | a lemma stating the computed value, used by `rw` or `simp only` |
| `repeated` | the same operation (or term, or tactic) done 3 or more times | depends on the operation: `decreasing_by` with a direct proof for `decreasing_tactic`, a `have` or one call for all goals for a term or tactic |
| `grind` | a `grind` call costing 20% or more | `grind?`, which prints `grind only [...]` |

On Batteries `v4.35.0`, 3 of the 10 costliest declarations spend 78 to 90%
of their heartbeats in `decreasing_tactic`, run once for each termination
measure Lean tries:

```
$ leanprof explain --elab --top 3
  2. 17489.50 kHB  Batteries/Data/String/Lemmas.lean:351  theorem firstDiffPos_loop_eq ...
     termination
       observed   `decreasing_tactic` ran 6× for 13728.69 kHB (78%): with no `termination_by`, Lean
                  tries measures until one works, proving the recursive calls for each
       observed   the measure Lean found (`showInferredTerminationBy`): `termination_by r₁`
       suggested  state it after the proof: `termination_by r₁`; Lean then proves the calls for that
                  measure only (`leanprof fix --elab` adds it and checks the proof and the
                  heartbeats) [mechanical]
```

Stating it takes the declaration from 17,424 to 6,155 kHB
([case study](../case-studies/compile-time-fixes.md)).

`--why` turns on two Lean options while elaborating: `showInferredTerminationBy`
for the file, and `tactic.simp.trace` (each `simp` reports its `simp only`
list, as `simp?` does) for each `simp` call separately, by the driver. Set
for a whole file, `tactic.simp.trace` stops Lean 4.35 at a `simpa` whose
term has an antiquotation (Mathlib's `simpa using congr($h + 1)`: "Unknown
constant `term.pseudo.antiquot`"), and everything after it went uncounted;
the driver leaves the option off for such calls. Without the driver
(`--no-driver`, or no driver for that Lean) there are no `simp only`
lists. The options cost a little, so compare heartbeats from runs made the
same way. The driver also records each `simp` call's whole source range
(Lean's message covers only its first word) and where each command ends.

A profile that stops at an error in some file is incomplete: what comes
after the error is not counted. `elab.json` says so (`"complete": false`,
and each file's `errors` and `first_error`), `--why` says so, and nothing
judges such a profile as an improvement: `experiment` (and so `fix --elab`)
returns INCONCLUSIVE, and `judge` does not compare the heartbeats of a
`measure --heartbeats-files` summary made from one. `elab.json` has them as
`simp_suggestions` and `termination_suggestions`, and failed instance
searches per declaration as `instances_failed`.

## A heartbeat budget: `--max-heartbeats`

```
leanprof elab --max-heartbeats 20000 FILE.lean...     # implies --heartbeats
leanprof elab --project --compact --max-heartbeats 20000
```

lists every declaration that costs more than N thousand heartbeats (the
unit of `maxHeartbeats`, whose default limit is 200,000) and exits 1 if
there is one, so slow lemmas do not accumulate unnoticed. The total
includes kernel, compiler and linter work, each shown. Profiling costs
heartbeats too, so a full profile counts more than the build does;
`--compact` comes closest to it. The list is also in `elab.json`
(`budget`). In CI, `report-md --max-heartbeats N` and the Action's
`max-heartbeats` input fail the job on any declaration of the head above
the budget, marking those that were not above it on the base
([CI](ci-and-regressions.md#a-heartbeat-budget)).

## Project-wide changes: `fix --elab --project`

```
leanprof fix --elab --project --dry-run          # the hypotheses, their evidence and the edits
leanprof fix --elab --project                    # check the first 5 mechanical ones
leanprof fix --elab --project --only 2,15 --report elab.json --build-runs 3
```

`--why` explains one declaration at a time. Some changes act on many: a
definition unfolded in every file that uses it, an instance tried by every
search for its class, a simp lemma every `simp` tries. `fix --elab
--project` reads a project report (`elab --project --heartbeats --counts
--why`, made first unless `--report` names one) and lists such candidates
with their evidence:

| candidate | evidence (from `--counts`, exact) | the change |
|---|---|---|
| `irreducible` | a definition of the package the elaborator and the kernel unfolded at least 10 times, in at least 2 files | `attribute [irreducible] f` at the end of its file: the modules importing it stop unfolding it (its own file is unchanged) |
| `reducible` | the same, and failed instance searches in at least 2 files name it (instance search unfolds reducible definitions only) | `attribute [reducible] f` at the end of its file |
| `instance-priority` | an instance of the package tried at least 10 times in at least 2 files and used in fewer than half of the tries | `instance (priority := low)` |
| `simp-attr` | a simp lemma of the package tried at least 10 times in at least 2 files and used at most once in 10 tries | `simp` removed from its `@[...]` |
| `termination` | the declarations whose termination measure Lean searched for (`--why`'s inferred measures), all at once | each measure stated after its declaration |
| `shortcut-instance` | the same instance problem solved at least 10 times in at least 2 files | not tried: where to declare it is a choice for a person, and a new instance can change the terms statements elaborate to |

Each candidate lists the declarations and files where the work was seen.
`diagnostics` prints a name relative to the namespaces open where it was
used (`Affine` for `WeierstrassCurve.Affine`); such a name is matched to
the one declaration of the profiled files whose name ends so, the evidence
says so, and the edit uses the full name. An `abbrev` is not made
irreducible (Lean refuses), and a name that matches only a `protected`
declaration is left out (Lean prints those with their namespace).

**The evidence is not a saving.** What the report charges to a constant is
inclusive (unfolding `f` can unfold `g`, and both are charged), different
candidates count the same work, and with parallel elaboration the summed
costs exceed the build's wall time. So candidates are ranked by the number
of files the work was seen in, then by their exact count, never by summed
heartbeats, each says which other candidate shares most of its files, and
nothing is projected: each one is measured.

**Checking a candidate.** Each of the first `--top` mechanical candidates
(default 5), or those `--only` names, becomes one commit on top of HEAD
(the checkout is not touched), judged by
[`experiment try --keep-base`](experiment.md) against the same base, so
the candidates are alternatives, not a sequence:

1. the package builds, so every proof still checks, and the modules that
   import the changed one build too;
2. the proof-preservation guard passes on the changed module and every
   module that imports it;
3. the tests pass (`--test CMD`, the Lake test driver, or `--no-test`);
4. compile heartbeats of those modules, per declaration and per module: the
   total must go down by more than 1% and 1,000; the declarations and
   modules that got dearer are listed with the ones that got cheaper;
5. the plain `lake build` of those modules (their build outputs removed
   first) is timed in both worktrees, base and candidate alternating, 3
   times each (`--build-runs N`; `--lock FILE` takes an `flock` on FILE for
   each build and times it once the lock is held, so other timing jobs on
   the machine wait). With fewer than 3 builds a side the times are
   reported, not judged.

The verdict is the experiment's. A KEEP becomes INCONCLUSIVE when every
timed build of the candidate was slower than every build of the base and
its median by more than 2%. A KEEP is committed with the evidence on a new
local branch (`leanprof-fix/project-KIND-NAME`); nothing is pushed. When a
candidate does not build, Lean's first errors are in its reasons.
Everything goes to `.lake/leanprof/fix/project-fixes.json`
([`schemas/fix-project.schema.json`](../../schemas/fix-project.schema.json);
`--json` prints it), and the MCP tool `project_fixes` does the same.

On Batteries `v4.35.0` (6 candidates checked, [case
study](../case-studies/project-compile-fixes.md)), stating the 27 inferred
termination measures was kept: the 61 modules affected went from 751,103 to
655,223 kHB, 24 declarations cheaper and none dearer, and their plain
build took 8.01 to 8.34 s against 8.35 to 9.59 s (3 builds each, machine
load 13 to 23). The four `irreducible` candidates were discarded: two broke
proofs in other modules, one changed nothing measurable, and one was an
`abbrev`, which Lean refused (leanprof now leaves those out). Removing
`@[simp]` from `SatisfiesM_Except_eq` (tried 19 times, never used) changed
the heartbeats by 0.1%: discarded. On Mathlib's elliptic curve modules (from
the Mathlib cache), the heaviest hypotheses are `abbrev`s, and the five
candidates checked (four `irreducible`, one `@[simp]` removal) all built and
moved the heartbeats of the modules affected by at most 0.09%: discarded.

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
project's Lean (on another Lean than leanprof's, once: see below): it
loads the module as `lake` and `lean` would (its setup file: options,
imports, plugins, shared libraries; `LEAN_PATH`;
asynchronous elaboration; the kernel), with the same trace options, and
wraps, in that process only, every term and tactic elaborator and every
macro. Each elaboration that takes longer than the threshold is recorded
against the exact range of the syntax it elaborates, which the report
lists:

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

**Another Lean.** A driver can only load `.olean` files written by the
Lean it was built with. The one built with leanprof serves projects on
leanprof's Lean. When the project's `lean --githash` differs, the first
`elab` builds a driver for that Lean, with that Lean, from the driver's
source (compiled into the command, so a release has it): `lean -c` and
`leanc`, linked against that Lean's shared libraries as `lean` itself is.
It says so and keeps the driver for the next runs:

```
leanprof: building leanprof-elab-driver for the project's Lean 4.34.0 (once; kept in ~/.cache/leanprof/drivers/293d5d0c0c3f-51ee28445160132a)
leanprof: built in 3197 ms
```

The cache is `LEANPROF_CACHE`, else `$XDG_CACHE_HOME/leanprof`, else
`~/.cache/leanprof`; a driver is kept by the Lean's commit, the driver's
source (a new leanprof builds a new one) and the Lean's directory (it links
against the libraries there). A build is done in a directory of its own and
moved into place only once the driver runs and reports that commit, so a
failed or concurrent build leaves nothing broken behind. On that Lean the
driver also looks up the definitions behind the work (leanprof cannot
read that Lean's `.olean` files itself), so the report has what it has on
leanprof's own Lean. The driver source builds on every supported Lean
(4.27 and later, the newest release candidate and the nightly: the Lean
versions workflow checks `"exact_ranges":true` on each, daily); the parts of
Lean's API that changed in between are written once per version range
(`#lean_since`).

Building takes 2.1 to 6.9 s once per Lean (lean4-cli at `v4.34.0`, 5
builds, Apple M5 Max at load 5 to 15; 26 s once with the machine at load
57); after that, finding the driver is one file check. On lean4-cli's
`Cli/Basic.lean` with Lean 4.34.0 (10 runs each), a profile through the
cached driver takes 1.79 s (1.89 s with the definitions located), against
1.76 s through `lean --json` and 1.64 s for plain `lean`. A driver built
this way elaborates as fast as the one built with leanprof: with Lean
4.35.0, 1.776 and 1.779 s against 1.778 and 1.744 s, with the same 373
ranges.

Only when that build fails (no `leanc` in the toolchain, an unwritable
cache, a Lean the source does not build on), or the driver cannot load a
file's imports, does `elab` say why and run that project's `lean --json`:
tactics are then placed on lines by finding their text in the source (a
tactic Lean prints differently from how it is written is left on its
declaration's line) and terms are not timed. `--no-driver` does that on
purpose; `LEANPROF_ELAB_DRIVER=PATH` names a driver to use as it is.

Through `lean --json`, descriptions are printed on one line
(`pp.oneline`): `Elab.step` describes a term with its whole syntax, so
nested terms print their source again at every level, and on concrete's
`Check.lean` (a 1,000-line `mutual` block, Lean 4.34.1) one message was
1.74 GB: `elab --heartbeats` took 61 s and 10.2 GB, against 5.4 s and
0.78 GB for plain `lean`. With one-line descriptions it takes 16.9 s and
1.36 GB (Apple M5 Max, load 2–5), with the same heartbeats per
declaration to within 0.03% (Lean's own count changes with the printing).
A description cut short (`term do [...]`) names many different terms, so
such steps are not listed as repeated work; a command cut short is named
from the source.

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
driver (without one, `elab` makes a full profile and says so).

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

Operations cheaper than 1 ms (10,000 heartbeats with `--heartbeats`) are
not recorded on their own: their cost stays in the operation around them,
so totals hold, but they do not show up in repeated work or the tactic
lines, and the definitions behind them are counted at no cost. `--threshold
0` records everything, which is what you want for one small file; on large
files it makes Lean 50 to 100 times slower, nearly all of it printing the
trace (Batteries' `String/Lemmas.lean` through `lean --json`: 1.2 s plain,
3.7 s at the default, 111 s at 0).

At the default, `elab` takes 1.4 to 2.2 times as long as plain `lean` on
Batteries' heaviest files, and `--compact` 1.01 to 1.3 times (4 to 20% more
CPU time). Through `lean --json` (`--no-driver`, or no driver) a full
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

## A whole project in the browser

```
leanprof elab --project --heartbeats
leanprof html                          # .lake/leanprof/report.html
leanprof html base.json elab.json      # compared with a base, at every level
```

The page opens on a project view that goes down from the project to a
folder, a module, a declaration and a term or tactic: at each level the
cost split into elaboration, kernel, compiler and linters, what is under it
(folders and modules, declarations, terms and tactics nested by
containment), the repeated work and the definitions behind the work done
there, and the source. Given a base report, every level shows the base, the
change and what regressed. It is one file with no network access
([HTML report](html-report.md#what-the-page-shows)).

For this, `elab.json` lists per module (`files[].repeated`,
`files[].unfolded`) its 10 costliest repeated operations, with what they
cost there and in all files, and the 10 definitions behind the most work in
it; `repeated[].files` says in how many modules an operation was done.

Published profiles made this way, with their reports: [all of Batteries
`v4.35.0` and Mathlib `v4.35.0`'s 40 slowest modules](../profiles/README.md)
(16.1 G heartbeats; 8.5 minutes on the Mac, 4 at a time, at most 2.9 GB per
process).

## Compared with lean-source-profiler

[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)
records every term and tactic with its exact source range through its own
Lean driver (the approach `elab`'s driver takes too), has a VS Code overlay
and a browser explorer, and publishes profiles of all of Mathlib (leanprof
publishes Batteries and 40 Mathlib modules). [A head-to-head comparison on the same
files](../case-studies/compile-time-vs-lean-source-profiler.md) shows what
each finds, how accurate the totals are and what each costs to run.
