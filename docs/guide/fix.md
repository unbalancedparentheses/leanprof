# Applying a fix: `leanprof fix`

`leanprof explain` says why a value was copied and, for the causes it
recognises, prints the fix as Lean code with your program's names.
`leanprof fix` goes one step further. It applies that fix, checks it, and
commits it only if the checks pass. The checks are the ones you would run by
hand: the build, the tests, the program's output, exact copy and allocation
counts, and paired timing of the plain binaries. The commit message holds
the evidence, so a reviewer can see why the change is there.

```
leanprof fix --exe myapp -- ARGS          # profile, fix, check, commit (or not)
leanprof fix --dry-run --exe myapp -- ARGS  # print the findings and the diff only
leanprof fix --dry-run                    # the same from the last report
leanprof fix --elab FILE.lean...          # compile time: Lean's own edits, checked by an experiment
leanprof fix --elab --project             # compile time: project-wide changes, each checked
```

For compile time, see [below](#compile-time-fix---elab).

## What it does

1. **Profile.** With `--exe EXE`, it runs `leanprof run EXE -- ARGS`.
   Without it, it reads the last report (`.lake/leanprof/report.json`, or
   `--report FILE`).
2. **Choose a finding.** It reads the findings as `explain --json` ranks
   them (time spent copying, costliest first). It lists each one with
   either the edit it would make or the reason it has none. Then it picks
   the first finding that has an edit, or finding N with `--finding N`.
3. **Check the original, in a git worktree.** Everything from here runs in
   a git worktree of `HEAD` in `.lake/leanprof/fix/worktree`, never in your
   checkout. The worktree uses your project's `.lake/packages` (a symbolic
   link: no download, no rebuild of dependencies) and starts from a copy of
   its `.lake/build`. In it, `fix` builds EXE and runs the tests, which are
   `--test CMD` (run with `sh -c`) or `lake test` when the project has a
   test driver. It records the output (stdout, or the file given with
   `--check-output FILE`) and runs `leanprof measure` (5 runs, `--runs N`).
   If the original fails to build or its tests fail, `fix` stops: nothing
   could be checked.
4. **Try each alternative** in the worktree. Each step below must pass
   before the next one runs:
   - the program builds;
   - the tests pass;
   - the exit code and output are byte for byte the original's;
   - `leanprof judge` of the two `measure` summaries says KEEP. That means
     copies or allocations went down (exact counts), and nothing got worse:
     allocations, copies, compile heartbeats, and time when every run is
     slower;
   - `leanprof measure-pair` (at most 30 pairs of the plain binaries in AB/BA
     order, stopping once settled, `--pairs N`) finds them no slower and with the same output. A
     significant speedup is reported. One is not required, because removing
     small copies often saves less time than the noise.
5. **KEEP**: the edit is committed in the worktree, with the evidence in
   the message, and your repository gets a new branch pointing at that
   commit (`leanprof-fix/<function>-<cause>`, or `--branch NAME`). Git
   runs without hooks (`-c core.hooksPath=/dev/null`), so a `pre-commit`
   hook cannot run other code or change what is committed. Before the
   branch is created, `fix` checks that the file still holds the edit it
   measured (a test may have rewritten it) and that the commit changes
   that file only, with exactly that content.
   **DISCARD**: the next alternative is tried. When none is left, every
   reason is printed and no branch is created.

Either way the worktree is removed, and your checkout is never touched: the
same branch, the same files, also when `fix` is interrupted. INT, TERM and
HUP are passed on to the step that is running; `fix` then removes the
worktree and exits with 128 + the signal's number. Only a signal that
cannot be caught (`kill -9`) leaves the worktree behind, and the next `fix`
removes it. A working tree with uncommitted changes to tracked files is
refused before anything runs. Untracked files are allowed, but they are not
in the worktree, so the file to fix must be committed. A path dependency
given relative to the project that leads out of the git repository is
refused, since the worktree's copy of the path would not reach it. The output of every step
is saved in `.lake/leanprof/fix/log.txt`. Exit code: 0 for KEEP (or a dry
run that printed a fix), 1 for DISCARD or when no finding has an edit, and
2 for an error.

## The fixes it applies

These are the causes whose `fix_code` replaces source lines one for one.
`Tests/ExplainFixes.lean` checks each edit: applied to the copying
declaration in `Examples/ExplainPatterns.lean`, it must give the fixed
declaration line for line, and that version must make no copies.

| cause | before | after |
|---|---|---|
| `nested-array-element` | `xs := xs.set! i (xs[i]!.push v)` | `xs := xs.modify i (·.push v)`, only when the element read is at the same index, written the same way (`xs.set! i (xs[j]!.push v)` is refused). When one site has several such lines, they are tried together first, then one at a time |
| `map-value-reinserted` (`getD`) | `let a := m.getD k d` … `m := m.insert k (a.push v)` | `m := m.alter k fun a? => some ((a?.getD d).push v)`, with the read line removed (only when `a` is not used anywhere else); or `m := (m.erase k).insert k (a.push v)` |
| `map-value-reinserted` (`get!`) | `let a := m[k]!` … `m := m.insert k { a with … }` | `m := m.modify k fun a => { a with … }`; or erase before inserting |
| `map-value-reinserted` (`get?`, `match`) | `\| some a => m := m.insert k (a.push v)` | `\| some a => m := (m.erase k).insert k (a.push v)` |
| `loop-over-updated-array` | `let mut j := 0`, `for x in xs do`, a body that ends with `j := j + 1` | `for i in [0:xs.size] do` followed by `let x := xs[i]!` |

`fix` must not commit a change that alters what the program computes, and
the checks below run one workload: identical output on it is evidence, not
proof. So each rewrite is applied only when the code shows it computes the
same values on every input.

The loop rewrite changes what the body reads: `xs[i]!` is the current
array, not the one the loop started with. The two give the same values only
when the body changes no element it has not visited yet and never shrinks
`xs`. `fix` applies it only in the shape where that is visible in the text:
the line before the loop is `let mut j := 0`, the body is flat (no nested
blocks, no `continue`), ends with `j := j + 1` and assigns `j` nowhere else,
and the only assignments to `xs` are `xs := xs.set! j …`, `xs := xs.modify j …`
(the element just visited) and `xs := xs.push …`. Any other loop is refused
with the reason, even if its output would not change on your workload.

These causes are refused, with a reason:

- `stored-then-updated`: the fix stores lengths instead of whole versions,
  so the code that reads them must change too.
- `multi-threaded-global`: the fix adds code before and after a loop, and
  `explain` does not locate the loop.
- `field-of-kept-structure`, `map-over-shared-array`, `shared-on-entry`,
  `used-after-update` and the rest: `explain` gives advice for these, not
  code.

`fix` also refuses code in a dependency (`.lake/packages`), a source line
that no longer matches the report, an insert that continues onto the next
line, a loop that binds a membership proof (`for h : x in xs`), and the
loops and nested updates above whose rewrite it cannot show to be the same
computation.

Copy sites that copied only empty or tiny values are left out, as in
`explain`. `fix` prints how many it left out, and `--all` includes them.

## Example: KEEP and DISCARD (`Tests/Fix`)

`scripts/fix-check.sh`, run in CI, copies `Tests/Fix` into a fresh git
repository. It is a small project with no dependency on leanprof. The script
runs `fix` six ways: on a tree with uncommitted changes (refused), with
`--dry-run`, on `buckets` (KEEP), on `smooth` (refused) and on `buckets`
with a test the edit fails (DISCARD), and interrupted by TERM. The numbers below are from one
run on an Apple M5 Max (`--runs 3 --pairs 10`).

`buckets` pushes onto `bs[i]!` while `bs` still holds it, so every push
copies:

```
leanprof fix: alternative 1 (Array.modify)
  builds
  tests pass (`lake test`)
  output identical (stdout, 118 bytes)
  leanprof judge (measure, 3 runs each):
  KEEP
    + copies: 19,985 -> 1
    + time: median 24.36 ms -> 15.74 ms (-35.39%) (every new run faster than every base run)
      copies buckets (in Std.Legacy.Range.forIn'.loop) [Array] in -: 19,984 -> 0
  leanprof judge (measure-pair, 10 pairs of plain binaries):
  KEEP
    + paired time: median change -57.67%, 95% median interval [-59.09%, -56.14%] (10 pairs)

KEEP: committed 99be65f on branch leanprof-fix/buckets-nested-array-element; your checkout is unchanged (the checks ran in a git worktree).
```

The remaining copy is in `main`, a single `Array.map`.

`smooth` loops over the array it updates, and the body writes the element
the *next* pass reads (`xs.set! ((j + 1) % xs.size) …`). The loop rewrite
would build and pass the tests, which check only sizes, but compute other
values. `fix` refuses it from the code, before changing anything:

```
     not mechanical: reading `xs[i]!` instead of the elements the loop started with gives the same
       values only when the body changes no element it has not visited yet, which fix cannot show
       here (`xs := xs.set! ((j + 1) % xs.size) (x + j % 3)` uses `j` other than as the index of an
       update of `xs`): apply the fix by hand if it holds
```

With `--test 'grep -q "bs.set!" Fix.lean'`, a test the edit fails, `buckets`
shows a DISCARD: no branch is created and every reason is printed. The
script also sends TERM while the candidate is being checked: `fix` exits
with 143, the worktree is gone and the checkout is untouched.

## On real projects

**lean-compiler-backend**, at `a623acc`, the parent of the commit where its
`CFG.build` copies were fixed by hand (`8a0d286`, see the
[case study](../case-studies/lean-compiler-backend.md)). The workload was
zlib's `deflate`, `inflate`, `trees` and `crc32`, run with
`--target aarch64-macos --optimize --allocate`. The options were
`--check-output zlib.s` and
`--test 'lake build lcb-tests && .lake/build/bin/lcb-tests'`. The
`CFG.build` site averages 7 bytes per copy, so only `--all` considers it.
`fix` then wrote the `Array.modify` edit `explain` prints for both lines,
`successors.set! i (successors[i]!.push target)` and its `predecessors`
twin. All three alternatives (both lines, then each alone) built, passed the
tests and produced byte-identical assembly. All three were DISCARDed:

```
  DISCARD
    - allocations: 7,719,273 -> 7,778,787
    + copies: 119,516 -> 86,449
      copies LeanCompilerBackend.CFG.build (in List.forIn'.loop) [Array] in -: 35,093 -> 2,026
      allocations LeanCompilerBackend.CFG.build (in List.forIn'.loop) in -: 46,117 -> 105,631
```

The second alternative did not add allocations, but every one of its runs
was 6.6% slower than every base run with probes. This is the same finding
the hand-made fix ran into. Updating both arrays in one loop keeps them in a
state pair whose cell is no longer reused, which costs one allocation per
edge (59,514). The fix that was merged also fills `predecessors` in a second
pass. That is a change of structure, not a rewrite of lines, so it is left
to a person.

**lean-regex**, at `32af6f3` (the commit CI uses), on its `Bench` over 4.56
MB of Lean source. All four findings are `shared-on-entry`: the capture
buffers and the sparse set arrive shared from the caller. `explain` prints no
code for them, so `fix` reports that no finding has a mechanical fix and
exits 1 without creating a branch.

## Compile time: `fix --elab`

```
leanprof fix --elab FILE.lean...               # profile (elab --heartbeats --why), apply, check
leanprof fix --elab --report elab.json         # from an `elab --why` report (--project works too)
leanprof fix --elab --dry-run FILE.lean...     # the edits and the diff only
```

`elab --why` finds two edits that Lean computes itself:

- a `simp`, `simp_all`, `simpa` or `dsimp` call becomes Lean's own
  `simp only [...]` list for it (what `simp?` prints), laid out within 100
  columns;
- a recursive declaration with no `termination_by` gets the measure Lean's
  search found (`showInferredTerminationBy`), on a line of its own after
  it. Without it, Lean proves the recursive calls once for every measure it
  tries.

`fix --elab` takes the costliest of these (`--top N`, default 10; a call
inside a costlier call's range waits for a later run), writes them as one
commit on top of HEAD with a separate index (the checkout, its index and
its stash are not touched), and judges that commit with
[`leanprof experiment`](experiment.md) in library mode: the package builds
(every proof is checked again), the proof-preservation guard passes on the
changed modules and their dependents, the tests pass (`--test CMD`, the
Lake test driver, or `--no-test`), and the heartbeats of those modules went
down. If the build fails, the edits in the declarations it names are
dropped; if a declaration got dearer, its edits are dropped; the rest is
tried again, at most `--rounds` times (default 4). A KEEP becomes a commit
with the evidence in its message on a new local branch
(`leanprof-fix/elab-FILE`, or `--branch NAME`); nothing is pushed.

`simp only` is faster but less robust: a renamed or new simp lemma no
longer reaches the call. Many projects keep terminal `simp` calls
unrestricted on purpose; `fix --elab` measures the speed, the choice is
yours.

On Batteries `v4.35.0`, from a `--why` report of
`Batteries/Data/String/Lemmas.lean` and `Batteries/Data/BinomialHeap/Basic.lean`
(2 inferred measures and 8 `simp only` lists, all kept in one round):

```
round 1: 10 edit(s), candidate cfa8d3427f1b
  KEEP
  - compile heartbeats: 129827.02 kHB -> 108127.91 kHB

KEEP: committed 9b469d96d6a1 on branch leanprof-fix/elab-Lemmas (10 edit(s)); your checkout is unchanged.
```

The two measures did nearly all of it: `splitAux_of_valid` 16,274 → 5,960
kHB and `firstDiffPos_loop_eq` 17,424 → 6,158 kHB. The eight `simp only`
lists saved little: `HeapNode.realSize_toHeap` 382 → 345 kHB, `next` 1,487
→ 1,460 kHB, the others less than 1% of their declarations. The guard audited 9
modules (the changed ones and everything in the package that imports them,
test modules included) and `lake test` passed
([case study](../case-studies/compile-time-fixes.md)).

### Project-wide: `fix --elab --project`

`fix --elab --project` forms changes that act across files from a project
report with exact counts: a definition unfolded in many files made
irreducible (or reducible), an instance at a lower priority, a `@[simp]`
removed from a lemma tried often and rarely used, every inferred
termination measure stated. It checks each one against the same base, on
the changed module and every module importing it, and reports the
heartbeats per declaration and module (dearer ones included) and the plain
build time of those modules. See [compile time](compile-time.md#project-wide-changes-fix---elab---project).
