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
```

## What it does

1. **Profile.** With `--exe EXE`, it runs `leanprof run EXE -- ARGS`.
   Without it, it reads the last report (`.lake/leanprof/report.json`, or
   `--report FILE`).
2. **Choose a finding.** It reads the findings as `explain --json` ranks
   them (time spent copying, costliest first). It lists each one with
   either the edit it would make or the reason it has none. Then it picks
   the first finding that has an edit, or finding N with `--finding N`.
3. **Check the original.** It builds EXE and runs the tests, which are
   `--test CMD` (run with `sh -c`) or `lake test` when the project has a
   test driver. It records the output (stdout, or the file given with
   `--check-output FILE`) and runs `leanprof measure` (5 runs, `--runs N`).
   If the original fails to build or its tests fail, `fix` stops: nothing
   could be checked.
4. **Try each alternative on a new branch**
   (`leanprof-fix/<function>-<cause>`, or `--branch NAME`). Each step
   below must pass before the next one runs:
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
5. **KEEP**: the edit is committed on the branch, with the evidence in the
   message. **DISCARD**: the next alternative is tried. When none is left,
   the branch is deleted and every reason is printed.

Either way, your checkout ends where it started: the same branch, the same
files. A working tree with uncommitted changes to tracked files is refused
before anything runs (untracked files are allowed). The output of every step
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
| `nested-array-element` | `xs := xs.set! i (xs[i]!.push v)` | `xs := xs.modify i (·.push v)`. When one site has several such lines, they are tried together first, then one at a time |
| `map-value-reinserted` (`getD`) | `let a := m.getD k d` … `m := m.insert k (a.push v)` | `m := m.alter k fun a? => some ((a?.getD d).push v)`, with the read line removed (only when `a` is not used anywhere else); or `m := (m.erase k).insert k (a.push v)` |
| `map-value-reinserted` (`get!`) | `let a := m[k]!` … `m := m.insert k { a with … }` | `m := m.modify k fun a => { a with … }`; or erase before inserting |
| `map-value-reinserted` (`get?`, `match`) | `\| some a => m := m.insert k (a.push v)` | `\| some a => m := (m.erase k).insert k (a.push v)` |
| `loop-over-updated-array` | `for x in xs do` | `for i in [0:xs.size] do` followed by `let x := xs[i]!` |

The loop rewrite changes what the body reads: `xs[i]!` is the current
array, not the one the loop started with. The two give the same values only
when the body changes elements it has already visited, or appends. The
output comparison is what catches the other case.

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
line, and a loop that binds a membership proof (`for h : x in xs`).

Copy sites that copied only empty or tiny values are left out, as in
`explain`. `fix` prints how many it left out, and `--all` includes them.

## Example: KEEP and DISCARD (`Tests/Fix`)

`scripts/fix-check.sh`, run in CI, copies `Tests/Fix` into a fresh git
repository. It is a small project with no dependency on leanprof. The script
runs `fix` four ways: on a tree with uncommitted changes (refused), with
`--dry-run`, on `buckets` and on `smooth`. The numbers below are from one
run on an Apple M5 Max (`--runs 3 --pairs 10`).

`buckets` pushes onto `bs[i]!` while `bs` still holds it, so every push
copies:

```
leanprof fix: alternative 1 (Array.modify) on branch leanprof-fix/buckets-nested-array-element
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

KEEP: committed 99be65f on branch leanprof-fix/buckets-nested-array-element; your checkout is back on main, unchanged.
```

The remaining copy is in `main`, a single `Array.map`.

`smooth` loops over the array it updates. The loop rewrite builds, and the
tests pass, because they check only sizes. The output changes, though: the
body writes the element the next pass reads.

```
  tests pass (`lake test`)
  DISCARD: the output changed (stdout), line 1: `smooth sum 2098950, first 1999, last 1999` became
    `smooth sum 197901666, first 99950, last 99949`

DISCARD: no alternative was kept, branch leanprof-fix/smooth-loop-over-updated-array deleted; your checkout is back on main, unchanged.
```

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
