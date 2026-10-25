# Changelog

All notable changes to leanprof. Versions follow [semantic
versioning](https://semver.org); a release is a `vX.Y.Z` tag (see
[RELEASING.md](RELEASING.md)).

## [Unreleased]

### Compile time: a project view and published profiles

- `leanprof html` on a compile-time report opens on a project view: project,
  folder, module, declaration, term or tactic, each with its cost split into
  elaboration, kernel, compiler and linters, the repeated work and the
  definitions behind the work done there, terms and tactics nested by the
  range that contains them, and the source. Given a base report, every level
  shows the base, the change and what regressed (modules by name,
  declarations by name, terms and tactics by text). The place is in the
  address, so links and the back button work. `--ranges N` and `--keep N`
  bound the page for large projects; the page says what it left out.
- `elab.json`: each module lists its 10 costliest repeated operations (with
  what they cost there and in all files) and the definitions behind its
  work (`files[].repeated`, `files[].unfolded`); `repeated[].files` counts
  the modules an operation was done in.
- Published profiles in `docs/profiles` (on the website too): all of
  Batteries `v4.35.0` (1,424 M heartbeats, 195 modules, 15 s) and
  Mathlib `v4.35.0`'s 40 slowest modules by Radar's instructions (16.1 G
  heartbeats, 8.5 minutes 4 at a time, at most 2.9 GB per process), each a
  page and its report, with the commands, versions and machine
  (`scripts/publish-profile.py`).
- CI drives the project view in jsdom (`scripts/check-html-view.js`): every
  level renders, without script errors, and compares with a base.

### Known issues from dogfooding lean-compiler-backend and concrete

- `measure --core` (and MCP `measure` with `core`): copies and allocations
  inside Lean's precompiled libraries count too, as with `run --core`. A
  real lean-compiler-backend speedup (`emitData`) was entirely in such code,
  invisible to `judge`'s allocation rule. Summaries record `core`, and
  `judge` discards a comparison of a `--core` summary with a plain one.
- Live snapshots mark copies of empty or tiny values (`tiny`, the report's
  rule against the time so far), and `top` and MCP `live` summarize them in
  one line as `run` and MCP `hot` do (`SSA.fresh`'s 17,775 9-byte copies
  were second in `top`). `LEANPROF_ALL_COPIES=1` lists them.
  `top --attach` on a program that had already exited now shows its last
  snapshot (it printed nothing).
- The last report is well-defined: `.lake/leanprof/report.json` is what
  `run`, `stat`, `sample` and `measure` leave, also when `--json FILE` saves
  a copy elsewhere (`run --json F` did not update it, so `explain` read an
  older report). `run` and `stat` remove it (and FILE) before they start,
  so a failed build or a killed program leaves no older report passing for
  this one (the MCP `run` tool summarized a stale one after a failed build).
  `run` and `stat` take `--out FILE` as another spelling of `--json FILE`,
  and `sample` takes `--json FILE` (a copy of its report; `--out` is still
  samply's profile).
- `stat` launches the freshly linked binary once without running it
  (`LEANPROF_LAUNCH_ONLY=1`: leanprof's runtime exits as it loads) before
  the measured run, and prints that first launch's time on its own line.
  On macOS a new binary's first launch is slow (1.1 s for `copybug`, 24 ms
  after; 2.3 s for concrete), and "including process start" counted it
  without saying so. That time also no longer includes `lake env`.
- The MCP `explain` tool gives `leanprof explain`'s diagnosis of each copy
  (cause from the IR, fix in the program's names, lines, confidence) instead
  of a generic list of usual causes, which it keeps only for live snapshots
  (no symbols). It refuses sampled reports as the command does; on one it
  had listed scopes "in 0 calls".
- `explain`, for a copied field of a kept structure, cites only structure
  updates (`{ s with … }`) next to the update, not every line with the word
  `with` (`match … with`, comments, docstrings), and no comment text: on
  concrete's `elabModule` it listed 38 lines and quoted a comment as the
  source; it now cites none and says no source line matched (the copy is
  `sp ++ "_"` at `Elab.lean:3356`, which text matching cannot single out
  among the declaration's many `++ "_"`). Comments are stripped before any
  source matching, and quoted lines leave out trailing comments.
- `elab` through `lean --json` (a project on another Lean, or
  `--no-driver`) prints trace descriptions on one line (`pp.oneline`). On
  concrete's `Check.lean` (Lean 4.34.1) `elab --heartbeats` took 61 s and
  10.2 GB against 5.4 s and 0.78 GB for plain `lean`: `Elab.step` prints a
  term's whole syntax at every nesting level, one message was 1.74 GB, and
  `lean` alone needed 28.6 s and 10.3 GB to print it. Now 16.9 s and
  1.36 GB, heartbeats per declaration within 0.03%. Steps whose description
  was cut (`term do [...]`) are not counted as repeated work, a cut command
  is named from the source, and tactics are no longer placed on comment
  lines (`simp` was placed on a comment saying "simply"). The driver (the
  project on leanprof's Lean) was not affected: 25.2 s and 1.26 GB on the
  same file.
- An interrupted `leanprof run` (also `stat`, `measure`) no longer leaves
  instrumented objects that a plain `lake build` keeps (every later binary
  carried the runtime and printed a report, leanprof itself included when
  profiled from its own repository). SIGINT, SIGTERM and SIGHUP are caught
  while a program or build runs (`c/cli.c`): TERM and HUP are passed on,
  the normal build is put back, and leanprof exits with 128 + the signal.
  Against SIGKILL, Lake's records of the instrumented objects are deleted
  once built (0.04 s on concrete), so the next plain `lake build`
  recompiles them normally (14.2 s for concrete's 114 objects, only after
  a kill). `leanprof doctor` puts a stashed normal build back.
  `scripts/interrupt-check.py` (CI) checks every signal.
- `bench/run.py`'s lean-compiler-backend step failed ("input contains no
  functions or data"): current checkouts keep zlib's inputs compressed in
  `docs/benchmarks/arm-scaled-load/private/zlib/ir`, not in `zlib/`, so lcb
  ran with none. The inputs are extracted from there (or taken from `zlib/`
  in older checkouts), the command must succeed once before it is timed,
  and `--lcb pinned` clones lean-compiler-backend at `d828ff3`
  (checked: plain 0.216 s, `run` 1.13×, `--auto` 1.59×, `--allocs` 1.22×,
  2 runs, shared Mac).

### Smaller fixes and maintenance

- `leanprof doctor`'s copy-detection self-check could not run on Linux
  ("fatal error: 'stdio.h'"): its probe was compiled with Lean's own `leanc`,
  whose sysroot has no libc headers. The probe declares `puts` instead.
- `leanprof help` ran `measure-pair` into its description; the command
  column is wider.
- `scripts/leanprof-tiny.awk` (which functions `--auto` leaves untimed)
  treats any function with a `while`, `for` or `do` loop as not tiny. Lean's
  C loops with `goto`, so no real function changed (57 untimed in
  leanprof's own IR before and after), but the rule no longer relies on it.
- The Linux benchmark results behind the README's Linux numbers are in the
  repository (`bench/linux/before` and `after`, a dedicated Ryzen 9
  7950X3D); the README had linked the Mac's results for them.
- README: the compile-time comparison was against lean-source-profiler's
  latest release (0.3.0), whose default is the compact mode it measured;
  per file, full profiles cost 1.3–1.9 times less than its detailed mode and
  compact ones about the same, and the Batteries gap (17 s against 103–152
  s) is mostly parallel elaboration.
- The VS Code extension's build tooling pins `@azure/msal-node` 7.1.1 (an
  advisory on the 6.x that `vsce` pulled in; not part of the `.vsix`).
- The Lean versions workflow retries a toolchain download that timed out.

### Tiny functions

- `run --auto` leaves functions too small to time untimed: straight-line
  code (no loop or join point) that calls only O(1) `lean.h` operations and
  other such functions of its file, and frees nothing but boxed scalars
  (`scripts/leanprof-tiny.awk`, run by the compiler wrapper on the C Lean
  emits). Their probes cost several times their work, in their own time and
  in every function's around them. The report lists them ("too small to
  time left untimed"; `untimed` in the JSON); their time is in their
  callers'. `--time-tiny` times and counts them as before. Mac, `tiny`
  workload: 9.5–10.2 → 0.6–1.2 points off, 7.8–8.2× → 0.98× slower.
- Light scopes: a scope near the probe cost (the `*` rows) that is not
  recursive is, after its first 1,024 calls, timed on about one call in 64
  at random and only counted on the others; its times are the timed calls'
  scaled up, its counts stay exact, and the cheaper untimed pair (4.6 ns
  against 6.6 ns on the M5 Max) is subtracted from its callers.
  `LEANPROF_TIME_ALL=1` times every call. `tiny` under `profile!` 7.7–7.9× →
  6.2× slower, `tasks` 2.8× → 2.4×; share errors unchanged within the noise.
  `timedCalls` says how many calls of a label were timed; percentiles are
  over the timed calls.
- Scope frames are one cache line (64 bytes, from 104): 10,000 levels of
  recursion with three functions each under `--auto` kept 3 MiB of frames.

### Mac accuracy: the runtime is compiled without the machine outliner

- On macOS, times of small scopes were over-reported since enter and exit
  were inlined into every probe (`a009129`): `run --auto` on the `alloc`
  workload was 22 pp off in share of time (`phAllocTree` at 2.4× its time),
  `profile!` on `rec` 7–9 pp (`fib` at 4.2–4.7×). Apple clang outlines
  repeated instruction sequences on arm64 even at -O2, so the program's
  probes became chains of calls to shared outlined pieces (25 in
  `__cyg_profile_func_exit`) that calibration's own copies did not make: a
  real probe cost ~5 ns more than calibrated, and the report kept it. The
  runtime is now built with `-mno-outline` on macOS (by the lakefile, and by
  `leanprof run` for projects that do not depend on leanprof). On the M5
  Max, two alternated suite runs each: `alloc` under `--auto` 22.0–22.1 →
  3.2–3.3 pp, `rec` under `profile!` 7.0–8.6 → 2.3–2.5 pp and under
  `--auto` 5.1–5.2 → 1.7 pp, `tiny` under `--auto` 9.9–11.2 → 4.2–5.3 pp;
  probes are cheaper too (9.3 → 6.3 ns a scope on `tiny`, `rec` under
  `--auto` 4.0–4.2× → 3.2–3.3×). `tasks`' share error rose (`profile!`
  0.4–0.9 → 1.8–2.6 pp) as its times moved from a uniform 1.6× to 1.03–1.27×.
  The tests and the smoke check fail if the runtime contains outlined code.
  Linux builds do not get the flag and are unchanged (not re-measured).

### Time per verdict, measured

- `measure --scope NAME` times one `profile!` scope (its total in each run's
  report) instead of the whole process; the summary records `scope`, and
  `judge` discards a comparison of summaries that timed different things.
- `measure-pair` measured against LeanBench and `measure` on the LeanBench
  case study's workload (`bench/leanbench/run.py pair`, shared Mac, load
  2–18, under the shared benchmark lock): 0 false time verdicts in 20
  unchanged sessions, a 2.4% slowdown caught 4/5 (5/5 in an earlier run
  without the lock), 4.8% and 10.4% 5/5; 7.1 s per verdict at 20 pairs,
  2.9 s at 6, against LeanBench's 0.74 s. `measure` + `judge` took 5.0 s and
  the next plain build 0.18 s (the 10 s rebuild is gone), but gave 7 false
  time verdicts in 20 on the same machine.

### Reproducing the published numbers

- `scripts/reproduce.sh CLAIM` re-runs each measured claim of the README
  from a clean clone (pinned commits, tags and toolchains), prints measured
  against published values and fails on any exact difference or a timing
  outside its stated range: the README example, Tests/Smoke, lean-regex,
  LeanProfiler, LeanBench, Batteries and lean-source-profiler,
  lean-compiler-backend's fixes and autoresearch, the benchmark suite
  ([docs/reproduce.md](docs/reproduce.md)). CI runs the cheap exact ones.

### Dogfooding on lean-compiler-backend and concrete

- `elab`: "definitions behind the work" placed a definition at any
  declaration in the profiled files with the same last name component when
  the project's Lean differs from leanprof's (its modules cannot be loaded,
  so positions come from the source): `Optimize.Algebra.operation` was shown
  at a `private def operation` in `SSA.lean`, `Id.run` at a test's `def run`.
  Declarations in the source are now qualified with the namespace in effect
  on their line, and a name never matches by its last component alone.
- `sample`: hot code outside the project (`List.reverseAux`, `hash_str`,
  `free`, `lean_dec_ref_cold`) is listed with the project's functions it ran
  under (the nearest project frame of each sample, up to three with at least
  5%). On lean-compiler-backend, `List.reverseAux` at 3.9% of CPU was 98%
  under `Assembly.emitData`, a `lines := lines ++ [line]` loop; fixing it made
  compiling crc32 14.6% faster.
- `judge --allow-overloaded PAIR.json` (and `allow_overloaded` for the MCP
  `judge` tool): judges a paired session's time although the load average
  exceeded the CPU count, and says so in the verdict. On the shared Mac the
  load stayed at 18–20 on 18 CPUs, so no paired session could ever be
  judged on time (one gave −5.2%, interval [−7.7%, −2.1%], "not judged").
- `sample --out FILE` in a project where leanprof had not run before ended
  with "no such file or directory (file: .lake/leanprof/report.json)" after
  printing the report (concrete, with `--out` in a scratch
  directory): the directory is now created.
- MCP `hot copies` (and the copies in `run`'s summary) listed copies of
  empty or tiny values first, which `leanprof run` summarizes in one line:
  on lean-compiler-backend, 17,775 9-byte copies in `SSA.fresh`
  (`prefix ++ toString n`) came second, above the copies worth looking at.
  They are now left out and counted in one line.
- `report-md`: each details section read "allocations: 3 changed
  (regression: the total grew)" even when the total fell and the table said
  pass. It now says whether anything regressed, then what a regression is.
- `explain` after `sample`: `sample` writes `.lake/leanprof/report.json` (for
  `#leanprof`) without copy counts, and `explain` then said "the report has no
  copies of shared values". It now says the report is a sampled one and to
  run `leanprof run` or pass `--report`.

### Fresh installs, more platforms

- Release archives for macOS x86-64 and Linux arm64, next to macOS arm64 and
  Linux x86-64; the install script picks them.
- `fresh-install.yml`: on every change and weekly, the packaged command is
  installed with the install script (source build hidden) and run on
  import-graph and lean4-cli at pinned tags, projects with nothing tailored
  to leanprof.

### Programs that load Lean modules at run time

- `run`, `stat`, `sample`, `measure` and `measure-pair` start the program
  with the environment `lake exe` gives it (`LEAN_PATH`, `LEAN_SYSROOT`,
  library paths, from `lake env`). Programs that import modules at run time
  (`importModules`, `supportInterpreter`: import-graph, doc-gen4, linters)
  failed with "unknown module prefix" under leanprof. Found by profiling
  import-graph, a project leanprof had never been run on.

### Security review

- [Review](docs/reviews/security-review.md) of the MCP server, the GitHub
  Action and the install script.
- MCP: `measure_pair` runs only binaries in a `.lake/build/bin/` directory,
  in Lake projects; files the server writes or deletes must be inside the
  project; `live` and `dump` (and `leanprof dump`, `top --pid`) accept only a
  single process id; an option is not taken as the executable; `live` waits
  at most 60 s. `scripts/mcp-check.py` checks each refusal.
- Action: line breaks in names can no longer end the inline code in the
  comment; the verdict step gets its values as environment variables; the
  guide recommends `persist-credentials: false`, minimal permissions and a
  pinned tag.
- Install: the launcher quotes the path it runs; the checksum lookup is an
  exact name match; the download directory is removed on failure.

### Interleaved timing and paired verdicts

- `measure-pair` runs two prebuilt binaries in alternating AB/BA order, with
  separate working directories, warmups, binary fingerprints, output checks
  and machine-load recording. It adds no probes and performs no rebuilds.
- `judge PAIR.json` uses a distribution-free 95% interval for the median paired
  percentage change. Output/diagnostic mismatches, missing output files and
  failed runs prevent KEEP; overload disables the timing verdict.
- Pure tests cover drift, confidence endpoints and failure cases; a CLI test
  verifies process ordering, arguments, working directories and stale output.
- The MCP server has a `measure_pair` tool, and its `judge` tool takes a
  paired session (`pair`) and `min_change`.
- Refresh the competitive priorities and qualify historical compile-time
  comparisons against lean-source-profiler's newer native compact capture.

### Compiler qualification and release preparation

- Reproducible clean-build compiler comparison, 540 output/diagnostic checks,
  full per-stage logs, and plain-binary timing evidence in `research/lcb/`.
  The reviewed compiler optimizations are merged, with a corrected validation
  fast path and 22% less median wall time on the measured workload.
- Contribution and supported-toolchain guidance, security reporting guidance,
  issue/PR templates, and a roadmap reconciled with implemented features.
- Extend the existing TSan allocator-reuse suppression to Lean's inlined fresh
  object header initialization; profiler task functions remain unsuppressed.

### `leanprof explain` prints the fix

- Recognises the causes of copies found in real projects from the compiler's
  IR and prints the fix as Lean code with the program's own names:
  an element of an outer array updated while the array holds it
  (`xs.set! i (xs[i]!.push v)` → `xs.modify i (·.push v)`); a value read
  from a hash map and inserted back (`m.getD k d` / `m[k]!` / `m[k]?` →
  `m.alter`, `m.modify`, or erasing the key first); a value stored in another
  array and then updated (when it only grows, store its length); a value in
  a global `IO.Ref` or `Std.Mutex`, which Lean never updates in place
  (a local buffer published once); a `for x in xs` loop that updates `xs`
  (loop over indices). Other causes keep the general advice.
- Each recognised cause has an example in `Examples/ExplainPatterns.lean`
  (`lake exe explainpatterns`), and `Tests/ExplainFixes.lean` checks that
  `explain` diagnoses it, that the printed code is the fixed version line
  for line, and that the fixed version makes no copies.
- `leanprof explain --json`: ranked findings with cause, location, why, fix,
  fix code, copies and estimated cost, for agents. `explain.json` entries
  carry the same fields; `#leanprof` hovers show the fix code.

### Added

- Self-check on every profiled run: a known copy of each kind
  (`Array.push`, `Array.set!`, `String.push`, `String.append`,
  `ByteArray.push`, `ByteArray.set!`) goes through `c/selfcheck.c`, compiled
  with the copy flags like the program, and must reach a shim. If one does
  not, the report, the JSON (`self_check`), `stat`, `measure` and `doctor`
  warn that copies of that kind may be undercounted with this Lean version
  (as String copies were with Lean 4.36 before the `lean_string_push_cold`
  shim). Its copies are counted apart (no rows); it costs about 20 µs at
  exit.
- `run`, `stat`, `measure` and `top` take `--no-deps`: only the root
  package is rebuilt with probes.
- `scripts/smoke.py` also profiles `Tests/Smoke`, a project that does not
  depend on leanprof, from a copy outside the repository with the command as
  packaged for a release; `--add` adds new facts to the baseline.
- `leanprof sample` takes a path to any program (`leanprof sample
  ~/.elan/toolchains/…/bin/lean -- FILE`). It names Lean code in Lean's
  shared libraries (`libleanshared`, `libInit_shared`, `libLake_shared`),
  and gives positions of Lean's own declarations in the toolchain's sources
  (from its `.ilean` files). `run` passes the toolchain
  (`LEANPROF_CORE_DIR`), so copies and allocations inside Lean's libraries
  (`--core`) get positions too.
- `leanprof doctor` checks for the objcopy that `run --core` needs.
  `run --core` also finds rustup's llvm-objcopy (`rust-objcopy`).
- `leanprof explain` recognizes arrays pushed inside an `IO.Ref` that
  threads share (each push copies the whole array) and says how to fix it.
- [Lake, the language server and `lean`](docs/case-studies/lake-and-server.md)
  case study, and seven candidate patches for Lean with measurements in
  [docs/upstream/lean4](docs/upstream/lean4/README.md) (not sent upstream).
- `measure` records the 1-minute load average and the CPU count, and the
  mean and standard deviation of the run times; `judge` does not judge time
  when either summary was measured on an overloaded machine (load above the
  CPU count), and prints the time change in percent.
- `judge --min-change PCT` (default 1): non-overlapping runs count as faster
  or slower only when the median also moved by PCT percent. On a quiet,
  pinned machine, unchanged code had been judged faster in 2 of 20 pairs;
  with the floor, 0 of 20, and a 2% slowdown is still caught 5 of 5
  ([LeanBench case study](docs/case-studies/leanbench.md)).
- `bench/leanbench/`: leanprof against LeanBench on noise, seeded copies,
  allocations, 2–30% slowdowns and a speedup, with the scripts and raw
  results.
- A `sanitizers` job: tests, examples, the server with live snapshots and
  the flight recorder, `run --allocs --counters --frees`, `explain --why`
  and the stress test, built with ASan and UBSan and with TSan on Linux
  (`LEANPROF_SANITIZE` with `scripts/leanprof-cc`), and plain on Linux and
  macOS.
- `Examples/Stress.lean` and `scripts/stress.sh`: many threads and tasks,
  deep recursion, millions of scopes and copies, snapshots every 10 ms and
  flight dumps under load, with exact counts.
- **`leanprof elab` times every term and tactic by its exact source range**
  (`file:line:col-line:col`). When the project's Lean is the one leanprof
  was built with, files are elaborated by `leanprof-elab-driver`, Lean's
  frontend run in-process (the module's setup file and `LEAN_PATH`, as
  Lake does) with every term and tactic elaborator and every macro
  wrapped to record the syntax it elaborates. The report lists the
  costliest tactics and terms by range, `elab.json` has them (`ranges`;
  `tactics` gain `range`), `#leanprof` lists them in the hover of their
  line, and `leanprof html` in a "Source ranges" tab. Tactics are no
  longer found by their text. With another Lean (or `--no-driver`) `elab`
  runs `lean --json` as before and says why. The driver also formats only
  the descriptions the report reads, so a full profile costs less than
  with `lean --json`.
- `leanprof elab --compact`: only commands, terms and tactics are timed,
  not the operations inside them, within a few percent of plain `lean`
  (needs the driver).
- **Allocations judged exactly.** `measure` counts allocations by default
  (`--no-allocs` turns it off; about 6 ns per allocation, 10% on
  lean-compiler-backend) and records them per site and per run; `judge`
  says DISCARD when they go up (any increase; for counts that vary between
  runs, only beyond their range) and counts a cut of at least 1% and 100
  as an improvement. `compare` reports more allocations in total as a
  regression when both reports counted them. The first `CFG.build` fix in
  lean-compiler-backend cut copies but added 59,514 allocations; `judge`
  kept it before and discards it now (a test checks that case).
- **Each finding states its share of the run.** Copy rows show `%run` and
  are sorted by time; allocation rows show an estimated time (count times
  the calibrated cost of a small allocation and its free, a lower bound)
  and `%run`, sorted by it; `explain`, `stat`, the HTML report, the editor
  hints and the MCP tools show and rank by the same shares. A run without
  `--allocs` says how to count allocations. JSON: `run_ns`,
  `resolution_ns`, `alloc_ns`; `pct_run` on copies and allocations,
  `est_ns` on allocations.
- **Copies of empty or tiny values** (at most 16 bytes per copy, under 1%
  of the run), such as the first push into an empty array slot, are
  grouped into one row; `run --all-copies` (`LEANPROF_ALL_COPIES=1`) lists
  them. The JSON keeps every row, with `"tiny": true`; `explain` and the
  editor skip them.
- **Times too small to measure are never shown as 0**: `< probe` (a
  scope's time after subtracting the probes' cost) and `< 1 ns` / `< 42 ns`
  (a copy, wait or task shorter than a clock tick) in the terminal, and
  `too_small` (the fields concerned) on JSON rows, read as `< probe cost` /
  `< 1 clock tick` by the HTML report, `#leanprof`, `compare` and the MCP
  tools. `compare` shows times in adaptive units instead of `0.00 ms`.

- Rows whose time is near the probes' own cost are marked: `*` after the
  total in the terminal report, `near_probe_cost` (and `probes_ns`) in the
  JSON, in the HTML report and in `#leanprof` hovers ("near the probe cost:
  use `leanprof sample` for this function's time"). The threshold (probes
  at least 0.3 of the time left) is calibrated on `bench/`: see
  bench/RESULTS.md, "Per component".

### Changed

- **The clock on Linux** is the CPU's counter where the kernel keeps time
  with it: the TSC on x86-64 (clocksource `tsc` and the CPU's invariant-TSC
  bit; its rate measured against `CLOCK_MONOTONIC`), `CNTVCT_EL0` on arm64
  (clocksource `arch_sys_counter`). `clock_gettime` through the vDSO cost
  18 ns a read on a Ryzen 7950X3D, two reads per scope.
  `LEANPROF_CLOCK=monotonic` keeps `clock_gettime`.
- **A scope costs less to enter and exit**: the enter and exit code is
  inlined into its callers (no shared function pushing and popping half a
  dozen registers), the scope lookup, the memory-sample check and the
  thread lookup have their common case inline and the rest out of line,
  and allocation counts are kept only once an allocation went through the
  `--allocs` shims (per-thread totals, read at each frame's start and end).
  On a Ryzen 7950X3D (fixed clock, boost off) the `tiny` benchmark went
  from 51 to 23 ns per scope and from 38× to 17.7× slower; on an M5 Max
  calibration measures 7 ns per direct pair instead of 13.
- **`leanprof sample` completes stacks samply cut short on Linux.** perf
  copies at most 64 KiB of a thread's stack per sample, so a sample deep
  in recursion lost its outer frames (10,000 calls deep, the phase that
  started the recursion was missing from 90% of samples). A cut stack now
  takes its outer frames from the thread's last whole stack, from the
  outermost call of the cut stack's outermost function: on the `rec`
  benchmark the share error went from 14.2 to 1.2 percentage points
  (samply itself: 14.8).
- **`scripts/leanprof-cc` builds with Lean's own `leanc` on Linux** (its
  bundled clang, sysroot and linker), so `run` and `--auto` build the
  program the way Lake does. Built by the system's clang and linker, the
  copy benchmark ran 18% faster with no probes at all, and leanprof's
  report then looked like it had subtracted too much (`run --auto` at 0.86
  of the plain time, now 1.05). Sanitizer builds and macOS still use the
  system's clang; `LEANPROF_REAL_CC` overrides.
- `bench/run.py` has a `phases` configuration: leanprof scopes exactly
  where LeanProfiler's spans are (phases and tasks), shown in the headline
  next to LeanProfiler, so the two are compared like with like.
- Profiling no longer deletes the compiled objects of the project and its
  dependencies: they are set aside (`.lake/leanprof/normal-objects`) while
  every package is rebuilt with probes, path dependencies included, and put
  back afterwards, so the next `lake build` recompiles nothing. Copies
  inside dependencies need no manual rebuild.
- An executable that had no normal build is removed after profiling instead
  of being left instrumented.

- **`profile!` on a pure term no longer builds a closure.** It compiles to
  `Leanprof.enterPure` before the term and `Leanprof.exitPure` after it,
  with a variant per scalar type, so nothing is allocated or boxed inside
  the scope (a `UInt64` result was boxed through the closure; that, not the
  probes, was most of what stayed in the times of tiny functions).
  `Leanprof.scope` (the closure) is still there for direct use.
- **The clock on Apple Silicon** is the counter itself (`CNTVCT_EL0`)
  instead of `mach_absolute_time`, which reads a self-synchronizing copy
  that waits for every earlier instruction: in real code that wait was
  most of a probe's cost (`mach_absolute_time` was 40% of an `--auto` run
  of lean-compiler-backend in samply). On an M5 the counter also runs at
  1 GHz, so scopes are timed to the nanosecond instead of in 41.7 ns ticks.
  `-DLEANPROF_SYNC_CLOCK` restores the old clock.
- **Symbols are looked up in a sorted table** of the executable's symbols,
  read once, instead of with `dladdr`, which scans every symbol on each
  call (0.3 ms in an executable with Lean's 450,000 symbols). `--auto`
  called it for every function it saw, inside the scope that called it, and
  the report for every row: on lean-compiler-backend that was 0.2 s of
  time inside the program's own scopes and 0.6 s of report.
- `--frees`: a run of frees from one call site in one scope skips the site
  table, and the "frees seen" flag is no longer written on every free (a
  cache line all threads wrote to).
- The fields of a scope that every enter and exit touches share two cache
  lines.

### Fixed

- `explain` no longer gives the multi-threaded explanation for a copy site
  where only a few copies were multi-threaded (Lake: 12 of 7,420).
- With `LEANPROF_PROJECT` set (`--cwd`), absolute source directories were
  joined onto the project path.
- `leanprof elab --project`, locating definitions in modules that cannot be
  imported together, kept every module's environment loaded: 16.8 GB on
  leanprof's own package once a module imports all of Lean. Each is now
  freed after use (3.2 GB).
- `probe_ns` and the "without the probes" wall time counted 1,024 times
  the probes' cost (descendants are counted in 1/1024 of a pair), so `%wall`
  was taken against a wall time that was far too small: `copybug` showed
  `buildWithHistory` at 100.0% and the column summed to more than 100%. CI
  now checks that scopes that do not overlap add up to at most the wall
  time without the probes.
- A recursive scope's self time could exceed its total (`fib` in copybug:
  self 38.0 µs, total 32.2 µs). Both subtract the same probes, counted two
  ways (self: each call's inner part plus its children's outside parts;
  total: one inner part plus every descendant's whole pair), but the inner
  part came from the calibration at exit and the rest from the weights
  fixed at the first one, rounded separately. All three now come from the
  same weights, with inner + outside = pair exactly, and CI checks that
  `fib`'s self equals its total.
- The test "scope total is reported" failed on busy CI runners: `fib`'s
  calls take about what their probes cost, so what is left after
  subtracting them can be 0. It now checks that the total is never
  negative; a scope with real work checks that its time is inside it.
- `bench/Main.lean` (the comparison with LeanProfiler) calibrates before
  its timed loops: the one-time calibration (about 10 ms) was counted as
  the cost of the first 1,000 actions (10 µs each).

Found hardening the runtime (sanitizers, a review by Codex, a stress test;
see [the review](docs/reviews/runtime-review.md)):

- Data races ThreadSanitizer found between the program's threads and the
  live snapshot thread: thread registration, new scope and copy records
  published with plain stores, counters, open frames and the calibration
  results. Records are now published with release stores and counters
  written with relaxed atomic stores (the same instructions), and one
  calibration runs at a time.
- A task's scope got its spawning scope's kind, and its begin event its
  kind, after both were visible to the live and flight readers; the
  flight recorder copied and compacted events with plain `memcpy` under its
  sequence count. Both are now race-free, and dumps no longer drop the
  newest event of a thread to work around the first.
- Threads that exit (one per dedicated task) kept their tables for good,
  and their flight buffer (8 MiB each): memory grew with every such task.
  An exited thread's records are now reused by the next new thread (83 to
  27 records, 1.0 to 0.47 GB in the stress test).
- Under `--auto`, each copy and allocation looked down the whole scope
  stack for the innermost `profile!` label: quadratic in deep recursion
  (80,000 levels that allocate took 4.5 s, now 6 ms). The label is kept in
  each frame.
- Histogram buckets were 32-bit: a hot scope fills one in about a minute,
  and its percentiles then read 0. They are 64-bit.
- Memory was sampled every millisecond for as long as the program ran (24
  bytes each, up to 400 MB); after the first minute samples are spread over
  the run so far (about 13 MB in a day).
- A huge `LEANPROF_TRACE_MAX` wrapped the flight buffer's size and wrote
  past it; it is capped at 2^28 events.
- A query (`totalNs`, `overheadNs`) inside an open scope charged that
  scope with the calibration it ran.
- Error paths: the report returned with its lock held when out of memory;
  a live snapshot without memory for its rows replaced the last good one
  with broken JSON; the report, timeline, `explain` data and flight marker
  ignored write errors; if the live thread could not start, the flight
  recorder stayed on with nothing to dump it.
- SIGUSR1 requests could be lost between the background thread's test and
  clear, and one arriving just before exit was dropped.
- The counters' table had no fill limit (a full table scanned every slot
  per call), and a thread still running at exit could make the counter
  report write past its array.
- The project's package names were read on the live thread while a
  program thread could read them too; they are read at startup.

Found on Mathlib ([case study](docs/case-studies/mathlib.md)):

- `elab` ran modules without their setup when Lake had not written one,
  which is every module fetched with `lake exe cache get`: Lean ran without
  the package's `leanOptions` (Mathlib's `maxSynthPendingDepth 3`, its
  linters), and 8 of Mathlib's 20 slowest files failed with errors. It now
  asks `lake setup-file` for the setup (saved under `.lake/leanprof/setup`).
- A command wrapped in `variable … in` or `set_option … in` was counted
  twice: Lean traces the inner command at its own position and then the
  wrapper, which includes it, over a range that contains it. Only commands
  at the same position were matched; now any command whose source range
  contains earlier ones counts only what it adds. On the 20 files, 23% of
  all heartbeats were counted twice (11.85 G reported, 9.15 G real), and a
  declaration under three `set_option … in` four times.
- A file with errors was elaborated a second time without its setup, even
  when the error was in a proof, which for a large file (Mathlib's
  `Modules/Sheaf.lean` runs for minutes when profiled) doubles its time.
  Now only for errors in the header, where a stale setup shows.
- "files had errors" now prints each file's first error with its line (and
  `first_error` in `elab.json`), and says when the error is a heartbeat
  limit, which profiling can reach where the build does not.
- Lines were named after the wrong command when several share one
  (`variable (x) in` puts its inner `section` and `variable` where the
  declaration starts) or when a declaration's doc comment was longer than
  the text kept: the declaration became `section` or nameless, so `compare`
  matched it by line. Commands that declare nothing (`variable … in`,
  `attribute …`) are now matched by `compare` by their text and order in the
  file instead of their line, so edits that move lines no longer show them
  as gone and new.
- `compare` printed heartbeats of new and removed scopes as milliseconds,
  listed thousands of scopes in no order, and showed `calls 0 -> 0` for
  compile-time reports. It now lists the largest changes first, uses the
  report's unit, and ends compile-time comparisons with the total.

## [0.1.0] - 2026-10-23

The first release: a profiler for Lean 4 programs and their compile times,
for Lean 4.34 and later on macOS arm64 and Linux x86-64.

### Install

- One command: `curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh`
  installs the prebuilt command for macOS arm64 or Linux x86-64 from the
  latest release (checked against `SHA256SUMS`), or builds from source when
  there is none for the platform. `--release VERSION`, `--source`, `--bin
  DIR`; from a clone it builds the clone.
- Release archives of the command for both platforms, and the VS Code
  extension as a `.vsix`, attached to each version tag.
- `leanprof doctor` checks Lean, the C compiler, samply and the project;
  `leanprof help [COMMAND]`.
- Reservoir metadata in the lakefile (description, keywords, homepage,
  license); use as a library with
  `require leanprof from git "https://github.com/unbalancedparentheses/leanprof" @ "v0.1.0"`.

### Any Lake project, unchanged

- `leanprof run`, `sample`, `stat`, `top`, `elab` and `measure` work on any
  Lake project with no dependency on leanprof: its runtime is compiled for
  the project's own Lean version and linked in, instrumented objects are
  removed afterwards, and the normal executable is restored.
- `--cwd DIR` for programs that read the current directory; positions still
  come from the project.
- Names are demangled like Lean's own demangler (checked against it by
  `demangle-check` on hundreds of thousands of symbols: escapes, private and
  hygienic names, nested specializations, package names), and given
  `File.lean:line` from `.ilean` files, including modules in a `srcDir`.

### Run time

- `leanprof sample`: CPU time per Lean declaration with file:line, through
  samply and with no probes; specializations reported under the declaration
  that caused them (and their real caller when the compiler reuses one); a
  breakdown of the Lean runtime's own time (copying, freeing, allocation,
  thread-local lookups, Lean's C++ code); a profile with Lean names for
  Firefox Profiler.
- `leanprof run`: exact time and calls per `profile!` scope, total and self,
  mean, p50/p99. leanprof measures its own cost per scope and per path
  (about 11 ns per `IO` scope, 21 ns per pure one) and subtracts it.
- `--auto`: every function timed with no annotations (about 15 ns per call),
  a declaration's compiled parts (`_redArg`, `_boxed`, lambdas) counted as
  one; exact counts in deep recursion.
- `profile! "label"` on pure terms and monadic actions; report on stderr at
  exit, JSON with `LEANPROF_JSON`. With `module` and
  `public import Leanprof`, programs do not link Lean's front end.
- Tasks: `Task.spawn`, `IO.asTask`, `Task.map/bind`, `IO.mapTask/bindTask`
  linked to the spawning scope with run time and queue wait; `IO.wait` and
  `Task.get` timed per call site.
- Timelines for Perfetto (`--trace FILE`, `LEANPROF_TRACE`), with copies as
  markers.

### Copies, allocations, memory

- Copies of non-exclusive `Array`, `ByteArray`, `FloatArray` and `String`
  values: per function and scope, with bytes, time, share of the scope,
  file:line and why (`shared`, `multi-threaded`, `persistent`).
- `leanprof explain`: why each copy happened (where the second reference
  comes from, from the compiler's IR) and how to fix it; `--why` confirms it
  at run time from the reference increments.
- `--allocs`: allocations per scope and call site; `--counters`: failed
  constructor reuse and closure applications per function; `--frees`:
  freeing pauses per call site.
- Peak memory per scope and memory over time; `leanprof stat`, a one-screen
  summary (time, memory, allocations, copies, frees, tasks, top scopes).
- `--core`: copies, tasks and allocations inside Lean's own libraries, by
  linking against copies rewritten with llvm-objcopy (cached).
- `scripts/leanprof-cc`, a `LEAN_CC` wrapper that adds the probes to every
  package, dependencies included.

### Compile time

- `leanprof elab FILE...`: compile cost per line and declaration from
  Lean's full `trace.profiler` trees, by kind of operation (elaboration,
  kernel, compiler, linters), repeated work, and tactic lines.
- The definitions behind the work, each with its own file:line: what
  `isDefEq` and `whnf` unfolded, instances tried, simp lemmas used.
- `--heartbeats` for exact counts that repeat across runs; `--counts` for
  Lean's exact unfold counts; `--project` (or `--module-glob`) for every
  module of a package, in parallel.
- Lean's messages are decoded a line at a time as they arrive (57 MB of
  memory for a 2.4 GB trace); files Lean fails on are reported.

### Live

- `leanprof top`: a running program, refreshed like top: hottest scopes,
  copy and allocation sites, tasks and waits, with rates per second, memory,
  CPU and what each thread is inside. `--attach FILE` and `--pid PID` for
  programs started with `LEANPROF_LIVE`.
- Flight recorder: the last seconds as a Perfetto trace when a scope is
  slower than `LEANPROF_SLOW_MS`, or on demand with `leanprof dump PID`.
- `leanprof mcp`: an MCP server with profiling tools for AI agents.

### Reports, CI and regressions

- `leanprof html`: one self-contained page (no network) with a flame graph,
  sortable tables, source lines with the findings, and a base-versus-new
  comparison.
- `leanprof compare`: exit 1 on regressions; copies, calls and compile
  heartbeats exact, time thresholded; per declaration and per module.
- GitHub Action (`action.yml`): profiles a pull request's base and head,
  and posts one comment with the changes in copies, allocations, calls,
  compile heartbeats and time, pass/fail per exact metric; `leanprof
  report-md` makes the comment locally.
- `leanprof measure` and `judge`: repeated runs into one summary and a
  KEEP/DISCARD verdict, for autoresearch loops (`research/`).
- Lean API for tests: `Leanprof.expectNoCopies`, `expectAllocsAtMost`,
  `expectNoReuseFailures`, `expectClosureApplicationsAtMost`, and
  `copies`, `calls`, `totalNs`, `overheadNs`, `depth`, `whereIs`.

### Editors

- `#leanprof`: the last reports as inlay hints next to the code (run time,
  sampled time, copies, compile cost, tactic steps), with details on hover
  and in the infoview.
- VS Code extension (`editors/vscode`, `.vsix` on the release): **Run…**,
  **Sample…**, **Compile cost of this file**, **Open report** (the HTML
  report in a tab) and **Live view** (`leanprof top` in a panel), all
  through the command; `leanprof.path` setting.

### Lean versions

- Lean 4.34 and later. CI runs the test suite and `run`, `sample` and
  `elab` on a project with Lean 4.34.1 and 4.35.0, and daily with the
  newest release candidate and the latest nightly.
- Copies of `String` values on Lean 4.36, where `String.push` is inline
  and copies in `lean_string_push_cold`.

### Accuracy and real projects

- A benchmark and accuracy suite (`bench/`) against workloads with known
  answers, samply and LeanProfiler: call and copy counts exact in every
  mode, sampled time within 0.1 to 1.7 points of the true share.
- Case studies, each with the fixes leanprof needed to handle the project:
  [lean-compiler-backend](docs/case-studies/lean-compiler-backend.md),
  [doc-gen4](docs/case-studies/doc-gen4.md),
  [verso](docs/case-studies/verso.md),
  [lean-regex](docs/case-studies/lean-regex.md),
  [concrete](docs/case-studies/concrete.md) and
  [Batteries](docs/case-studies/batteries.md) at compile time; CI profiles
  leanprover-community/repl and lean-regex from outside.

### Documentation

- The guide in [docs/guide](docs/guide/getting-started.md): getting
  started, run time, copies and allocations, memory, compile time, editor,
  VS Code, HTML report, CI and regressions, live view, Lean API, reference,
  how it works and its limits.
