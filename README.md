# leanprof

[Website and documentation](https://unbalancedparentheses.github.io/leanprof)

> **Find out why your Lean 4 code is slow, and how to fix it.**
>
> leanprof profiles Lean programs and proofs without changing your project. It
> counts what makes Lean slow that no other profiler sees (copies of shared
> arrays and strings, allocations, failed reuse, the unfolds and instance
> searches behind compile time), names the line and the cause, and prints the
> fix. In CI it fails a pull request on "+1 copy" and says what made it slower.

- A compiler written in Lean: **22% faster**, from changes leanprof's loop
  found and kept ([merged](docs/case-studies/autoresearch-lean-compiler-backend.md)).
- Three of Mathlib's slowest files: **46–69% fewer heartbeats**, same terms
  ([case study](docs/case-studies/mathlib.md)).
- A **2.4% slowdown caught 4 times in 5** where LeanBench caught none
  ([comparison](docs/case-studies/leanbench.md)).

Why copies: `arr.push x` is fast only when nothing else refers to `arr`; if
something does, Lean silently copies the whole array first. One stray
reference turns a linear loop quadratic, and nothing in your code, your
types, or a normal profiler tells you. leanprof shows each one: the line, how
many, how many bytes, how much time, why the value was shared, and the fix.

## Why leanprof, and not the alternatives

samply, perf, [LeanProfiler](https://github.com/lean-dojo/LeanProfiler),
[LeanBench](https://github.com/alok/LeanBench) and
[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)
report time. leanprof also reports what makes Lean code slow, and carries a
finding through to a checked change.

**The costs specific to Lean, which no other profiler sees**

- **Copies of shared values.** `Array`, `ByteArray`, `FloatArray` and
  `String` updates that copy because something else still refers to the
  value: counted per function, with the line, bytes, time and why the value
  was shared (`shared`, `multi-threaded`, `persistent`).
- **Why, and the fix.** `explain` reads the compiler's IR to name where the
  second reference comes from ("`acc` is stored in `history` at line 20"),
  `--why` confirms it at run time, and the fix is written as code with your
  own names (`Array.modify`, swapping an element out, `alter` on a map).
- **Copies without running anything.** `explain --static` flags likely copies
  across a whole package, libraries included: all 16 copying examples and
  none of 18 alternatives; on lean-compiler-backend, 97% of the copies were
  in flagged functions. A run report then marks which flags it confirmed.
- **Allocations, failed in-place reuse, closure calls, freeing pauses, peak
  memory** per function and call site; `--core` counts them inside Lean's
  own libraries too.

**Time, measured cheaply**

- **Probes cost nanoseconds, not microseconds:** about 5–8 ns per scope on
  the Mac and 23 ns on Linux, measured at startup and subtracted;
  LeanProfiler's span costs 4.6 µs at first and 88.5 µs once its events
  accumulate. With scopes placed where LeanProfiler's spans are, leanprof is
  within 0.5 points of it or better on every benchmark workload
  ([results](bench/RESULTS.md)).
- **Sampling that knows Lean:** samply underneath, plus Lean names,
  file:line, specializations under the declaration that caused them, and the
  runtime's share (allocation, freeing, copying). On Linux it rebuilds the
  stacks perf cuts short: deep recursion 1.2 points off its true share,
  against samply's 14.8.
- **Nothing to change in your project:** any Lake project, from outside,
  every function with `--auto`, dependencies included, and your normal
  build put back afterwards. LeanProfiler and LeanBench need code in your
  project.

**Compile time, with causes**

- Cost per declaration, term and tactic by exact source range on every
  supported Lean, in heartbeats (nearly the same on every run, so a
  regression on a shared machine is real), with the definitions unfolded,
  instances tried and `simp` lemmas used behind it, each with file:line.
- Whole projects in parallel (all of Batteries in 17 s, against 103–152 s
  for lean-source-profiler one file at a time) and a
  [viewer](docs/profiles/README.md) from project to tactic; full profiles
  cost 1.3–1.9 times less per file than lean-source-profiler's detailed
  mode.

**From a finding to a checked change, which no other tool does**

- **`leanprof fix`** applies a mechanical fix only where the code shows it
  computes the same values, in an isolated worktree: build, tests, output
  compared, both versions measured, and a commit with the evidence only on
  KEEP. Your checkout is never touched.
- **`leanprof experiment`** judges any candidate change against a baseline:
  it must build, pass the proof-preservation audit (a `sorry`, a new axiom,
  a removed theorem or a changed test is refused), pass the tests, and
  behave identically on every input you give; then exact counts first,
  heartbeats for proof-only changes, paired timing last. In Lean the
  cheapest fake speedup is deleting a proof obligation; this refuses it.
- **Paired time verdicts:** `measure-pair` interleaves the two versions and
  stops as soon as the verdict is settled (each claim wrong at most 2.5% of
  the time if the pairs are independent).

**CI that says why**

- Copies, allocations and calls are exact counts, so CI can fail on "+1
  copy" without noise. The pull request comment names the declaration that
  got more expensive and the unfold, instance search, `simp` lemma or
  `grind` theorem behind it, and explain's cause for each copy site that
  copies more. Against LeanBench it caught a 2.4% slowdown 4 times in 5
  (LeanBench at its 5% threshold: 0 in 5), with no false verdict in 20
  unchanged runs ([case study](docs/case-studies/leanbench.md)).

**Built for agents**

- An MCP server with run, sample, explain, static copies, elab, measure,
  paired timing, judge, fix and the experiment tools, restricted to Lake
  projects ([security review](docs/reviews/security-review.md)); structured
  results and typed errors, versioned JSON with schemas, ranked findings
  with stable ids, and provenance on every report; and an
  [autoresearch loop](docs/case-studies/autoresearch-lean-compiler-backend.md)
  that made a compiler written in Lean 22% faster, merged after review.

**Where it is behind:** lean-source-profiler publishes compile-time
profiles of all of Mathlib (8,556 files) and has timelines; leanprof
publishes Batteries and Mathlib's 40 slowest modules. Tiny `profile!`
scopes (a few nanoseconds of work) are marked in the report, but their
time is less precise than a sample's: 6.1 points off in share on the
`tiny` benchmark, against 0.6 for `leanprof sample`. At high load
LeanBench reaches a time verdict faster (1.06 s against 1.9–2.3 s). A
scope costs about 23 ns on Linux, against 5–8 ns on the Mac. Details and
every number in
[where leanprof wins, and where it does not](#where-leanprof-wins-and-where-it-does-not).

## What it found in real code

All profiled from outside, without changing the projects:

- **[Mathlib](docs/case-studies/mathlib.md)**: among its 20 slowest files,
  two small kinds of change cut compile heartbeats by 55%, 69% and 46% in
  three of them (`Formula.lean` 8.2 s → 2.6 s, `FourierTransform.lean`
  about 10 s → 3.5 s, `LpSpace.lean` 3.6 s → 2.1 s), producing the same
  terms. The patches are [ready](docs/upstream/mathlib/), not sent.
- **[Lake and the language server](docs/case-studies/lake-and-server.md)**:
  seven candidate Lean patches; four of them make a no-op `lake build` of a
  Mathlib project 19% faster (1.58 s → 1.29 s), another cuts the server's
  CPU by 13%. Not sent, and not yet run through Lean's own test suite.
- **[lean-compiler-backend](docs/case-studies/lean-compiler-backend.md)**, a
  compiler written in Lean: three fixes found with leanprof, now on its
  `main`, cut the allocations needed to compile zlib from 11.95M to 7.72M
  (−35%) with byte-identical output on 160 input and option combinations.
  `explain` printed the `CFG.build` fix (121,054 copies). Wall time did not
  measurably change: fewer allocations is not always a faster program.
  Then the [autoresearch loop](docs/case-studies/autoresearch-lean-compiler-backend.md)
  found that each function was validated about ten times on its way through
  the compiler, each time rebuilding its CFG. Its 12 kept changes initially
  cut measured wall time by 24% and allocations by another 16%. After
  review and a validation correction, the series is merged:
  [fresh ordinary builds](research/lcb/results/README.md) confirm **22% less
  median wall time**, with 540 matching output/diagnostic cases.
- **[doc-gen4](docs/case-studies/doc-gen4.md)**: one SQL query that grows
  with the square of a module's declarations takes two thirds of the HTML
  pass.
- **[verso](docs/case-studies/verso.md)**: about 23% of rendering is
  pretty-printing JSON only to compare index entries.
- **[lean-regex](docs/case-studies/lean-regex.md)**: 15 allocations per
  input character in the ε-closure; 13.7M closure calls through an
  unspecialized function.
- **[concrete](docs/case-studies/concrete.md)** and
  **[Batteries](docs/case-studies/batteries.md)**: linear list searches are
  a quarter of concrete's self time; an iterator definition is unfolded
  24,369 times from ordinary RBTree proofs.
- **[Dogfooding on both compilers](docs/case-studies/dogfood-lcb-concrete.md)**:
  every command run again on lean-compiler-backend and concrete found two
  more fixes in each (paired timing: −8.2% and −19.1% on their workloads,
  same output on 540 and 6,817 cases) and seven leanprof bugs, now fixed.
- **[LeanProfiler](bench/README.md)**: why its cost per span grows with the
  number of events (its event array is copied on every span).

## Quickstart

```
curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh
cd your-lean-project
leanprof                             # finds what to profile, samples it, top findings and next steps
leanprof myapp -- args               # the same for one of several executables, with its arguments
leanprof run myapp -- args           # exact counts: copies, allocations, calls, tasks
leanprof explain                     # why each copy happened, and the fix
leanprof fix --exe myapp -- args     # apply it in a git worktree, test, measure, commit a KEEP on a branch
leanprof elab --heartbeats Foo.lean  # what each line costs to compile
```

Your project needs no changes: leanprof compiles its runtime for your Lean
version and puts your normal build back afterwards. The installer fetches
[samply](https://github.com/mstange/samply) 0.13.1 (pinned,
checksum-verified) for sampling when there is none on your `PATH`: it asks
on a terminal, `--samply` fetches it without asking. `leanprof doctor` says
what is missing and how to install it. See [install](#install) for
platforms and Lean versions.

To mark code with `profile!`, assert in tests that code does not copy or
allocate, or use `#leanprof` in the editor, add the dependency:

```lean
require leanprof from git "https://github.com/unbalancedparentheses/leanprof" @ "main"
```

The [getting started guide](docs/guide/getting-started.md) walks through it.

## What it does

### The first run: `leanprof`

`leanprof` with no arguments reads the lakefile and picks the workload: the
one `lean_exe`, else the test driver, else compile time of the libraries.
With several executables it lists them with the command for each and
chooses none. It samples with samply when it can (no rebuild), else runs
`leanprof stat`, then prints the top three findings with file:line and the
exact `run`, `explain` and `fix` commands that go deeper. On a Mac, a new
`lake new` project got its first report in 8.6 s, after a 4.8 s install
with samply ([getting started](docs/guide/getting-started.md)).

### Compile time: `elab`, `--why` and `fix --elab`

Most Lean code is proofs, and what its authors wait on is elaboration.
`leanprof elab` gives the compile cost of each declaration, term and tactic
by exact source range, split into elaboration, kernel, compiler and
linters, in time or (`--heartbeats`) in heartbeats, which do not depend on
the machine. It names the definitions unfolded, instances tried and simp
lemmas behind the work, finds repeated work, and runs whole projects in
parallel (`--project`). On a project whose Lean is not leanprof's, the first
run builds leanprof's elaboration driver for that Lean (2 to 7 s on an M5
Max) and caches it, so ranges are exact on every supported Lean.

`elab --why` says why the costliest declarations are slow, keeping what the
profile shows apart from what to try: a costly `simp` with Lean's own
`simp only [...]` list for it, a termination measure Lean searched for with
the one it found, definitions unfolded, instance searches that fail,
`decide` and the kernel, repeated work. `leanprof fix --elab` applies the
edits Lean computed and keeps them only if an experiment says KEEP: the
proofs still check, the proof-preservation guard passes and the heartbeats
went down. On Batteries, stating Lean's inferred `termination_by` cut two
lemmas from 17.4 and 16.2 M heartbeats to 6.2 and 5.9 M
([case study](docs/case-studies/compile-time-fixes.md)).
`elab --max-heartbeats N` fails CI on any declaration above a budget.

`leanprof html` turns a report into one self-contained page that drills
from project to folder, module, declaration and tactic, each compared with
a base report when given one; the published
[Batteries and Mathlib profiles](docs/profiles/README.md) are such pages
([compile time](docs/guide/compile-time.md)).

### Copies, allocations and counters: `run` and `explain`

```
$ leanprof run copybug

     calls      total       self  %wall       mean        p50        p99  scope  (where)
         1     3.1 ms     3.1 ms  12.7%     3.1 ms     3.0 ms     3.0 ms  buildWithHistory  (Examples/CopyBug.lean:17)
     10945  36.9 µs*   36.9 µs   0.1%      41 ns    < probe     352 ns  fib  (Examples/CopyBug.lean:15)
* near the probe cost: use `leanprof sample` for this function's time

copies of non-exclusive values (each one copied the whole value; costliest first)
  copies       bytes       time   %run  %scope  kind        why            in scope           function  (where)
    2001    15.3 MiB     3.1 ms  12.5%   99.1%  Array       shared         buildWithHistory   buildWithHistory (in Std.Legacy.Range.forIn'.loop)  (Examples/CopyBug.lean:17)
```

A loop kept one extra reference to an array, so each `push` copied it: 99%
of the function's time, in a loop that looks linear. `explain` says why,
from the compiler's own output, and prints the fix with your names:

```
$ leanprof explain

buildWithHistory (in Std.Legacy.Range.forIn'.loop)  Examples/CopyBug.lean:17
  why: `acc` is stored in `history` at line 21 (`history := history.push acc`) and is updated
       afterwards at line 22 (`acc := acc.push i`): both refer to the same Array, so the Array.push
       copies it.
  fix: `acc` only grows (by `push`), so each version stored in `history` is a prefix of the final
       `acc`: store its length and rebuild version k as `acc.extract 0 history[k]!` when it is
       needed.
         history := history.push acc.size
```

It recognises five causes (an array inside an array, a map value updated
and reinserted, a value stored and then updated, a global shared by
threads, a loop over the array it updates), and each printed fix is tested
to remove the copies. `explain --json` gives the same findings, ranked by
their share of the run, to agents. When the second reference is taken in
another function, `explain --why EXE` records it at run time: it wraps
reference-count increments and reports where each copied value got its
second reference (about 7% more wall time on lean-compiler-backend).

`run --allocs` counts allocations per function and call site;
`run --counters` counts failed in-place reuse and closure calls; both are
exact for compiled code outside Lean's precompiled libraries (`--core`
reaches into those). Tests can assert them with `expectNoCopies` and
`expectAllocsAtMost` ([copies and allocations](docs/guide/copies-and-allocations.md)).

### Copies without running: `explain --static`

`leanprof explain --static` reads the C the compiler emitted for every
function of the package, libraries included, and flags each update likely
to copy, with file:line, the value, why another reference is alive there
(in the function, in a caller, or in a global) and `explain`'s fix. Nothing
runs. Given a run report it marks which flags the run confirmed and which
flagged functions never ran. On the repository's examples it flags all 16
functions that copy and none of the 18 that do not; on lean-compiler-backend
compiling zlib, 97% of the copies are in flagged functions
([guide](docs/guide/static-copies.md)).

### Applying the fix: `leanprof fix`

`leanprof fix --exe myapp -- args` takes the costliest finding whose cause
has a mechanical edit (`Array.modify` for an array inside an array, `alter`
or erase-then-insert for a map value, an index loop for a loop over the
array it updates) and checks it in a git worktree of `HEAD`: build, tests,
output byte for byte, exact counts with `measure`, paired timing with
`measure-pair`, and `judge`. A KEEP is committed with the evidence in the
message and your repository gets a new branch; your checkout is never
touched, also when `fix` is interrupted. Each rewrite is applied only where
the code shows it computes the same values; the checks run one workload, so
they are evidence, not proof ([guide](docs/guide/fix.md)).

### Experiments: `leanprof experiment`

```
leanprof experiment start --exe myapp --inputs inputs/ --heldout heldout/ -- ARGS
leanprof experiment try --working-tree     # or: leanprof experiment try REV
leanprof experiment finish                 # held-out inputs on the final base
leanprof experiment status
```

One experiment records a baseline in a git worktree, then judges each
candidate in order: build; the proof-preservation guard; tests; identical
stdout, stderr, exit code and output files on every input and case; exact
counts (worse counts are a DISCARD before anything is timed); paired timing
of the plain binaries. The guard refuses a candidate that changes a test or
an expected output, adds `sorry`, an axiom, `@[implemented_by]`, `@[extern]`,
`unsafe` or `partial`, or removes a theorem, and returns INCONCLUSIVE when a
theorem's statement changed: in Lean the cheapest "speedup" deletes a proof
obligation. Without `--exe` the measure is compile heartbeats of the
changed modules and their dependents. Each try returns KEEP, DISCARD, ERROR
or INCONCLUSIVE with an evidence file; a KEEP becomes the base. On
lean-regex, candidate builds took 1–2 s because the base's build is kept
([guide](docs/guide/experiment.md)).

### Time verdicts: `measure`, `measure-pair`, `judge`

`measure` runs a program several times with probes and records copies,
allocations, calls, heartbeats, output hash and time; `judge` says KEEP or
DISCARD from two summaries, exact counts first. `measure-pair` interleaves
two plain binaries in AB/BA order and stops once the verdict is settled (a
group-sequential sign test: each claim wrong at most 2.5% of the time);
`judge PAIR.json` gives the paired 95% interval of the median change.
`--scope NAME` times one `Leanprof.bench` region instead of the whole
process, and `--base-rev REV --exe NAME` builds the base at a revision once
and keeps it, so a loop of verdicts pays only the candidate's incremental
build. `judge` refuses time measured with the load above the CPU count
unless told otherwise ([CI and regressions](docs/guide/ci-and-regressions.md#measure-and-judge)).

### CI: the GitHub Action

The [Action](docs/guide/ci-and-regressions.md#github-action) profiles a pull
request's base and head on the same runner and comments the difference:
copies, allocations, calls and heartbeats, failing on the ones you choose.
For each declaration that got more expensive it says what changed inside it
(definitions unfolded, instances, simp lemmas, `grind` theorems, repeated
work, each with file:line), and for each copy site that copies more, the
cause `explain` gives. What the reports do not record is said to be not
attributed, never estimated
([worked example on Batteries](docs/guide/ci-and-regressions.md#worked-example-batteries)).

### Agents: the MCP server

`leanprof mcp` serves the profiler over the Model Context Protocol on stdio:
`doctor` (what the project has and which modes work), `run`, `sample`,
`stat`, `elab`, `measure`, `measure_pair`, `judge`, `compare`, `explain`,
`static_copies`,
`findings` and `finding` (a ranked page of findings with stable ids, then
one in full with its source, cause and before/after), `hot`, `report`, the
four `experiment_*` operations, and `live` and `dump` for a running
program. Every result has `structuredContent` matching the tool's
`outputSchema`; failures carry an error code, whether a retry may help,
and a hint. Paths it writes must be inside the project, and the binaries
it runs must be Lake-built ([MCP server](docs/guide/live.md#mcp-server)).
Every JSON file the commands write names its schema in
[`schemas/`](schemas/) and records its provenance
([machine-readable output](docs/guide/reference.md#machine-readable-output)).

### Tiny functions

A function of a nanosecond or two costs several times its work in probes.
`run --auto` leaves straight-line functions of a few constant-time
operations untimed (listed in the report; `--time-tiny` times and counts
them), so the functions around them are timed without their probes: on the
Mac's `tiny` benchmark 0.7 points off in share and 0.99× the plain time
([results](bench/RESULTS.md)). A `profile!` scope near the probe cost is
timed on a sample of its calls (counts stay exact), its row is marked `*`,
and a caller whose time is distorted by such scopes' probes is marked too
(`holds_tiny`, `†` in the results), with the advice to remove those
`profile!` and use `leanprof sample` for its time
([run time](docs/guide/run-time.md)).

### All commands

| | command |
|---|---|
| Pick the workload (the executable, the tests, or compile time), profile it, top three findings and the commands that go deeper | `leanprof` |
| CPU time per Lean declaration, no probes; flame graph with Lean names | `leanprof sample myapp` |
| Time per function or `profile!` scope, own cost subtracted (calibrated estimates), and exact call counts (`--auto` leaves functions too small to time untimed; `--time-tiny` counts them) | `leanprof run [--auto] myapp` |
| Copies of shared arrays and strings, with file:line, the reason and the fix; where the second reference was taken | `leanprof run`, `leanprof explain [--why]` |
| Apply that fix in a worktree, test it, compare output, measure and judge it; commit only a KEEP, with the evidence | [`leanprof fix`](docs/guide/fix.md) |
| Judge candidates with the proof-preservation guard, many inputs and held-out inputs | [`leanprof experiment`](docs/guide/experiment.md) |
| Allocations per function; failed in-place reuse; closure calls | `leanprof run --allocs --counters myapp` |
| Tasks: run time, queue wait, blocking waits; Perfetto timeline | `leanprof run --trace out.json myapp` |
| Peak memory per scope, freeing pauses; one-screen summary | `leanprof stat myapp` |
| A running program, live; the last seconds as a timeline | `leanprof top myapp`, `leanprof dump PID` |
| Compile cost per line, term and tactic (exact source ranges), repeated work, the definitions behind it, whole projects | `leanprof elab [--project] [--heartbeats] [--counts]` |
| Why the costliest declarations are slow, observed and suggested apart; a heartbeat budget for CI | `leanprof elab --why`, `leanprof explain --elab`, `leanprof elab --max-heartbeats N` |
| Apply Lean's own compile-time edits (`simp only` lists, inferred `termination_by`), keep them only on an experiment's KEEP | [`leanprof fix --elab`](docs/guide/fix.md#compile-time-fix---elab) |
| Regressions in CI, exact for copies, allocations, calls and heartbeats, with the cause of each | `leanprof compare`, `leanprof report-md`, [GitHub Action](docs/guide/ci-and-regressions.md#github-action) |
| Keep or discard a change, with exact metrics or interleaved plain-binary timing | `leanprof measure`, `leanprof measure-pair`, `leanprof judge` |
| Profiling tools for AI agents | `leanprof mcp` |
| Everything next to the code, or in one shareable page | `#leanprof`, [VS Code](docs/guide/vscode.md), `leanprof html` |

![leanprof html: sampled flame graph of the example, with compile-time tiles](docs/images/html-report.png)

## Where leanprof wins, and where it does not

Measured, with the method and raw numbers linked; `scripts/reproduce.sh` re-runs each claim and checks it ([how](docs/reproduce.md)). "Mac" is an Apple M5 Max shared with other work ([results](bench/RESULTS.md)); "Linux" is a dedicated, idle AMD Ryzen 9 7950X3D with the CPU frequency fixed ([results](bench/linux/after/RESULTS.md), [before the Linux fixes](bench/linux/before/RESULTS.md)). Counts (copies, allocations, calls, heartbeats) are exact; times from probes are calibrated estimates with the probes' cost subtracted.

**Ahead, clearly:**

- **Copies and their causes.** No other Lean tool reports them. leanprof
  counts them exactly, names the line and the reason, and prints a fix that
  is tested to remove them.
- **Exact regression checks.** Copies, allocations and calls are exact
  counts: the same on every run of a program whose threads do not race
  (when threads or tasks change what runs, `measure` says the counts varied
  and `judge` compares their ranges). Compile heartbeats are nearly the
  same on every run (a whole project elaborated in parallel varied by up to
  5 per million of its total between runs). So CI can fail on "+1 copy".
  Against [LeanBench](docs/case-studies/leanbench.md), only leanprof saw a
  hidden copy per iteration or 2,000 extra allocations (each under 1% of
  time).
- **Small slowdowns.** On the quiet Linux machine leanprof caught a 2%
  slowdown 5 times in 5 with no false alarm in 20 unchanged runs; LeanBench
  at a 5% threshold caught none of the 2% and 2 of 5 at 4.8%.
- **Full compile-time profiles.** Per file, a full profile (internal
  operations, the definitions behind the work, terms and tactics by range)
  costs 1.3 to 1.9 times less than lean-source-profiler's detailed mode
  ([comparison](docs/case-studies/compile-time-vs-lean-source-profiler.md),
  its latest release 0.3.0, on the shared Mac). Compact profiles cost about
  the same in both. All of Batteries took 17 s against 103–152 s, mostly
  because leanprof elaborates files in parallel and lean-source-profiler one
  at a time.
- **Overhead against LeanProfiler.** A profiled scope costs about 5–8 ns on
  the Mac (4.7 ns on `tiny`, 7.6 ns on `rec`; 23 ns on Linux, see below) and
  stays constant however long the program runs; LeanProfiler's span grows
  from 4.6 µs to 88.5 µs as events accumulate (25 ns with recording off).
- **Breadth.** Run time, memory, tasks, compile time, CI, experiments,
  editor, HTML, live view and MCP in one tool that needs no change to the
  project.
- **Sampling deep recursion on Linux.** perf copies at most 64 KiB of a
  thread's stack per sample, so samply loses the outer frames of deep
  recursion (14.8 points off on the `rec` benchmark). `leanprof sample`
  completes those stacks from the thread's last whole one: 1.2 points.
- **Like-for-like with LeanProfiler.** With leanprof's scopes exactly where
  LeanProfiler's spans are, leanprof is within 0.5 points of LeanProfiler
  or better on every workload, on the Mac and on Linux (Linux worst: 0.6
  points against 0.7).

**Even, or behind:**

- **Probe cost on Linux: about 23 ns per scope** (51 ns before it read the
  CPU's counter instead of `clock_gettime`), against 5–8 ns on the Mac.
  Tiny functions still run about 18× slower under `profile!` there.
- **Time of tiny scopes.** When a call costs about as much as its probes,
  its time can be off by half either way; such rows are marked `*`.
  `run --auto` leaves straight-line functions of a few operations untimed,
  so on the Mac's `tiny` workload it is 0.7 points off and 0.99× the plain
  time. Under `profile!` tiny scopes are timed on a sample of their calls
  and their callers are marked (`holds_tiny`): the counts stay exact, but
  the `tiny` workload is still 6.1 points off in share in the published run
  (7.6–9.0 in three interleaved pairs, [bench/README.md](bench/README.md))
  and runs 4.3× slower. `leanprof sample` is the tool for those functions
  (0.6 points).
- **Sampling** is as accurate as samply (it runs samply underneath; on the
  Mac within 0.1–1.9 points of each function's true share across the six
  workloads, samply 0.1–2.0) and adds Lean names, file:line and the runtime
  breakdown (on Linux, see deep recursion above).
- **`--auto` on Linux** is 2.6–3.2 points off on allocation- and copy-heavy
  workloads (6.5–8.2 before the Linux fixes; samply 0.5) and 10.4 points
  off on deep recursion (7.1 before: the shallow phases are now slightly
  over-subtracted while the deepest is still over-reported, see
  [bench/README.md](bench/README.md)): use `sample` or `profile!` there. On
  the Mac, `--auto` on the allocation workload is 4.7 points off (samply
  0.1).
- **Cost per verdict.** On the LeanBench case study's trials (shared Mac,
  load 4–13), sequential `measure-pair --scope` took 0.89 s per verdict end
  to end (candidate build included) against LeanBench's 1.09 s, with 0
  false verdicts in 20 and the 2.4% slowdown caught 4 of 5 (LeanBench at
  5%: 0 of 5); at load up to 15 it took 1.9–2.3 s against LeanBench's
  1.06 s. Timing whole 20-action processes takes 5.5 s
  ([case study](docs/case-studies/leanbench.md#paired-timing-measure-pair-and-measure---scope)).
  On a machine this loaded, time verdicts are less reliable than on a quiet
  one; exact counts are not affected.
- **[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler)**
  publishes profiles of all of Mathlib (8,556 files); leanprof's
  [published profiles](docs/profiles/README.md) cover all of Batteries and
  only Mathlib's 40 slowest modules (16.1 G heartbeats, 8.5 minutes 4 at a
  time on the shared Mac). Both have a drill-down viewer; only
  lean-source-profiler's has timelines. The comparison above is against its
  latest release (0.3.0), whose default is the compact mode measured there;
  its main branch has since changed its dataset tooling and explorer, not
  re-tested here. On another Lean than its own, leanprof builds its driver
  for that Lean once (seconds), as lean-source-profiler compiles its driver
  per toolchain.

**Reviewed result, still awaiting independent replication:** the
autoresearch loop found 12 compiler optimizations in about three hours.
Review caught a missing validation check and restored it before merging.
Fresh ordinary builds then took
[22% less median wall time](research/lcb/results/README.md) (811 → 631 ms,
30 runs each, alternating order), with 540 output/diagnostic comparisons
passing and green compiler CI on three platforms. The machine was shared;
this remains one workload measured by this project, not an outside
reproduction.

## How it compares

| | leanprof | [LeanProfiler](https://github.com/lean-dojo/LeanProfiler) | [lean-source-profiler](https://github.com/Vilin97/lean-source-profiler) | samply / perf | [LeanBench](https://github.com/alok/LeanBench) |
|---|---|---|---|---|---|
| Run time | sampled, or probes with their cost subtracted (calibrated estimates) | manual spans | – | sampled | wall time per named benchmark: mean, stddev, percentiles |
| Overhead while recording | about 5–8 ns per scope on the Mac, 23 ns on Linux; constant, subtracted | 4.6 µs to 88.5 µs per span, growing with events | – | very low | none (times the plain build, two clock reads per sample) |
| Works without changing the project | ✅ | – | ✅ | ✅ | – (a dependency and a bench module) |
| First report | `leanprof` alone picks the workload and samples it: 8.6 s on a new `lake new` project, after a 4.8 s install with samply (Mac) | not measured | not measured | not measured | after adding the dependency and writing a bench module |
| Lean names and file:line | ✅ | your span names | ✅ (compile time) | mangled C names | your benchmark names |
| Copies, allocations, failed reuse, closures | ✅ exact counts | – | – | – | – |
| Why a copy happened, with a fix | ✅ from the compiler's IR, confirmed at run time; `leanprof fix` applies three kinds | – | – | – | – |
| Peak memory per scope, freeing pauses | ✅ | – | – | – | – |
| Tasks | ✅ queue wait, blocking waits | parent links | – | threads | – |
| Compile time | per file, declaration, term and tactic (exact ranges on every supported Lean: on another Lean than leanprof's, a driver is built for it once, in seconds); the definitions unfolded behind it; repeated work; whole projects; a project-to-tactic HTML view compared with a base; published Batteries and Mathlib (40 modules) profiles | – | exact term ranges, all of Mathlib published, timelines ([comparison](docs/case-studies/compile-time-vs-lean-source-profiler.md)) | – | LeanObserve (not evaluated) |
| Exact regression checks, PR comments | ✅, with the cause of each ([example](docs/guide/ci-and-regressions.md#worked-example-batteries)) | thresholded time | – | – | mean against a saved baseline, fixed threshold |
| Checked experiments (proofs preserved, outputs identical, held-out inputs) | ✅ `leanprof experiment` | – | – | – | – |
| Live view, flight recorder | ✅ `top`, `dump` | – | – | – | – |
| In the editor | run time, copies, compile time | – | compile time | – | a visualizer extension (not evaluated) |
| Seeded slowdowns caught, quiet machine ([case study](docs/case-studies/leanbench.md)) | 2%: 5/5, 5% and up: 5/5; never a false alarm in 20 | – | – | – | at a 5% threshold: 2%: 0/5, 4.8%: 2/5, 10% and up: 5/5; 0 false alarms in 20 |
| Wall time per verdict | sequential `measure-pair --scope` 0.89 s end to end at load 4–13 (1.9–2.3 s at load up to 15); 5.5 s timing whole 20-action processes; Mac, shared | – | – | – | 1.09 s in the same run (1.06 s with a rebuild at load up to 15; 0.74 s earlier, 0.6 s on Linux) |

## Reproducing the numbers

`scripts/reproduce.sh` re-runs the measured claims of this README from a
clean clone: each claim pins the commits and toolchains it measures, prints
every measured value next to the published one, and ends with PASS or
FAIL. Exact rows (copies, allocations, calls, heartbeats, output hashes)
must match; timing rows have a stated range.

```
scripts/reproduce.sh list          # the claims
scripts/reproduce.sh copybug       # one claim
scripts/reproduce.sh exact         # every cheap exact claim (what CI runs)
```

[docs/reproduce.md](docs/reproduce.md) lists every claim, where each number
came from, and what did not reproduce. The Linux-only timings need the
dedicated host and are not re-run by the scripts.

## Known issues

- **Lean's precompiled libraries.** Copies and allocations inside Lean's
  core libraries are not seen unless specialized into your code;
  `run --core` relinks against renamed copies of them, but calls the
  runtime makes to itself inside `libleanrt.a` (allocations of `String`
  and `Nat` primitives written in C++) stay invisible.
- **Positions are per declaration** for copies and functions: Lean's C
  output carries no line information, so `explain` matches the source by
  text, and cannot single out one of several identical expressions in a
  declaration (it then says that no line matched).
- **Times are estimates.** Probe times are calibrated and subtracted, which
  is accurate for scopes that do real work and not for scopes of a few
  nanoseconds (marked `*` and `holds_tiny`); `--auto` is less accurate on
  Linux than on the Mac for allocation-heavy code and deep recursion. Use
  `leanprof sample` for those.
- **Time verdicts need a quiet machine.** On the shared Mac, the LeanBench
  trials' time verdicts were wrong 6 times in 20 on unchanged code
  ([docs/reproduce.md](docs/reproduce.md)); `judge` refuses timing taken
  with the load above the CPU count. Exact counts do not depend on load.
- **`fix` and `experiment` check the inputs you give.** Identical output on
  them is evidence, not proof. `fix` edits three causes of copies; the
  others get advice, not code. The experiment guard is conservative: a
  candidate that changes a theorem's statement, or optimizes a function its
  theorems mention, is INCONCLUSIVE and needs a human review.
- **Interrupted runs.** INT, TERM and HUP put the normal build back.
  After `kill -9`, Lake's records of the instrumented objects are already
  gone, so the next `lake build` recompiles them normally; with `--no-deps`,
  a dependency compiled for the first time during the run stays
  instrumented until rebuilt.
- **`elab` without the driver** (`--no-driver`, or when the driver fails to
  build) prints trace descriptions on one line, so steps cut to
  `term do [...]` are not counted as repeated work, and term ranges are
  approximate.
- **Platforms.** macOS x86-64 and Linux arm64 are smoke-tested on each
  release but not in the per-commit matrix. Windows is not supported (WSL 2
  works).

## Install

```
curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh
```

The installer puts `leanprof` in `~/.local/bin`: the prebuilt command of the
latest [release](https://github.com/unbalancedparentheses/leanprof/releases)
for macOS arm64, macOS x86-64, Linux x86-64 or Linux arm64, checked against
the release's `SHA256SUMS`, or, when there is no release for the platform,
the command built from source. Options: `--release vX.Y.Z`, `--source`,
`--bin DIR`, `--samply`, `--no-samply`, `--samply-only`. You need Lean
(through elan) and a C compiler for the commands that rebuild with probes.

Lean 4.27 through 4.35 are supported:

| Lean | CI |
|---|---|
| 4.27.0, 4.31.0, 4.34.1, 4.35.0 | required to pass, Linux and macOS |
| 4.28.1, 4.29.1, 4.30.0, 4.32.2, 4.33.1 | advisory, Linux |
| newest release candidate, nightly | advisory, daily, Linux and macOS |
| 4.26 and earlier | not supported |

See [supported platforms](docs/guide/getting-started.md#supported-platforms)
and [CONTRIBUTING.md](CONTRIBUTING.md) for the policy.

## Documentation

- [Getting started](docs/guide/getting-started.md)
- [Run time](docs/guide/run-time.md): sampling, every function, `profile!`, tasks, timeline
- [Copies and allocations](docs/guide/copies-and-allocations.md), reuse and closures
- [Applying a fix with `leanprof fix`](docs/guide/fix.md)
- [Experiments with `leanprof experiment`](docs/guide/experiment.md) and the [proof-preservation audit](docs/guide/proof-audit.md)
- [Memory, frees and `leanprof stat`](docs/guide/memory.md)
- [Compile time](docs/guide/compile-time.md)
- [In the editor](docs/guide/editor.md), [VS Code](docs/guide/vscode.md) and [HTML report](docs/guide/html-report.md)
- [CI, regressions and autoresearch](docs/guide/ci-and-regressions.md)
- [Live view, flight recorder and MCP server](docs/guide/live.md)
- [Lean API](docs/guide/lean-api.md) and [reference](docs/guide/reference.md) (commands, environment, JSON)
- [How it works, and limits](docs/guide/how-it-works.md)
- Case studies: [Mathlib](docs/case-studies/mathlib.md), [Lake and the server](docs/case-studies/lake-and-server.md), [lean-compiler-backend](docs/case-studies/lean-compiler-backend.md), [doc-gen4](docs/case-studies/doc-gen4.md), [verso](docs/case-studies/verso.md), [lean-regex](docs/case-studies/lean-regex.md), [concrete](docs/case-studies/concrete.md), [Batteries](docs/case-studies/batteries.md), [vs lean-source-profiler](docs/case-studies/compile-time-vs-lean-source-profiler.md), [vs LeanBench](docs/case-studies/leanbench.md); [benchmarks](bench/README.md)
- [Reproducing the published numbers](docs/reproduce.md)
- [Roadmap](ROADMAP.md), [changelog](CHANGELOG.md), [ideas from other ecosystems](docs/research/other-ecosystems.md)

Status: early.

## Development

```
lake test                                   # tests
lake build copybug && .lake/build/bin/copybug
```

The runtime is [`c/leanprof.c`](c/leanprof.c); the Lean library is
[`Leanprof/`](Leanprof); the command line is
[`LeanprofCli.lean`](LeanprofCli.lean). MIT license.
