# Live view, flight recorder and MCP server

`leanprof run` writes its report when the program exits, so a long-running
server never produces one. Three tools look at a program while it runs:

| | how | gives |
|---|---|---|
| Live view | `leanprof top EXE`, or `LEANPROF_LIVE=1` and `leanprof top --pid PID` | hottest scopes, copy sites, allocation sites, tasks, waits, memory and CPU, with rates per second, refreshed like `top` |
| Flight recorder | `LEANPROF_FLIGHT=DIR`, `LEANPROF_SLOW_MS=MS`, `leanprof dump PID` | a Perfetto trace of the last seconds, written on demand or when a scope is slow |
| MCP server | `leanprof mcp` | profiling tools for AI agents: run, sample, stat, elab, explain, compare, judge, experiments, live, dump |

## `leanprof top`

```
leanprof top [--interval MS] [--rows N] [--frames N] [--plain] [--flight DIR] [--slow-ms MS]
             [--auto | --auto-all] [--allocs] [--counters] [--frees] [--core] EXE [-- ARGS...]
leanprof top [OPTIONS] --attach FILE | --pid PID
```

`leanprof top EXE` builds `EXE` with probes, as `run` does, starts it, and
redraws once a second (`--interval`):

```
leanprof top  server  pid 80119  up 2.69 s  threads 2
cpu 0.01 cores   memory 11.3 MiB resident (+0 B/s), 5.9 MiB committed, peak 11.4 MiB

scopes (p50/p99 of the last 1-2 s, max and total of the whole run)
   calls/s   time/s   self/s       p50       p99       max        calls      total  scope  (where)
        45    99.6%    54.3%   12.3 ms  316.8 ms  317.6 ms          120     2.68 s  handle  (Examples/Server.lean:26)
       1.5    45.2%    45.2%  294.9 ms  294.9 ms  305.0 ms            4     1.22 s  slowPath  (Examples/Server.lean:31)
        45     0.1%     0.1%   30.7 µs   32.0 µs   47.9 µs          120     3.7 ms  parse  (Examples/Server.lean:19)

copies of shared values
  copies/s     bytes/s   time/s       copies       bytes  kind        in scope           function  (where)
        44    20.7 KiB     0.0%          119    55.8 KiB  Array       handle             handle  (Examples/Server.lean:26)

tasks
   tasks/s    run/s        tasks        run  wait mean  spawned by
        45     0.0%          120   966.0 µs     9.0 µs  handle
```

- Rates (`calls/s`, `copies/s`, `bytes/s`, ...) are since the previous
  frame. `time/s` and `self/s` are time per second of wall time as a share of
  one core, so a scope busy on four threads shows 400%. A scope's time is
  counted when a call ends: a 300 ms call that ends in a 250 ms frame adds
  more than 100%.
- `p50` and `p99` are of the calls that ended in the last one to two seconds
  (`LEANPROF_LIVE_WINDOW_MS`, default 1000), so a slowdown shows at once
  instead of being averaged into the whole run; `max` and `total` are for the
  whole run.
- `now` lists the scopes each busy thread is inside, outermost first, with
  how long each has been open: what a stuck program is doing.
- Rows are ordered by what grew since the last frame, then by the total.
  Sections share the terminal's height; `--rows N` fixes the rows per section.
- The program's output goes to `.lake/leanprof/top.log`. When it exits, the
  final frame stays on screen with the last lines of the log; the full report
  is in `.lake/leanprof/report.json`, as after `run`.
- Plain ANSI escapes (home, clear to end of line), no curses. Without a
  terminal, or with `--plain`, frames are printed one after another;
  `--frames N` stops after N frames (with `EXE`, it then waits for the
  program and prints the final one).

### Attaching to a running program

Any program that links leanprof's runtime (built with `leanprof run --keep`,
the `copyFlags` of the lakefile, or `LEAN_CC=scripts/leanprof-cc`) publishes
snapshots when started with `LEANPROF_LIVE`:

```
LEANPROF_LIVE=1 ./myserver &           # $TMPDIR/leanprof-<pid>.live.json
leanprof top --pid $!

LEANPROF_LIVE=/var/tmp/srv.json ./myserver &
leanprof top --attach /var/tmp/srv.json
```

Any number of viewers can attach and detach; the program never waits for
them. `top` stops when the program exits (its final snapshot is marked
`exited`) or is gone.

### How the live channel works

When `LEANPROF_LIVE` is set, a background thread (started before `main`,
signals blocked) rewrites the snapshot every `LEANPROF_LIVE_MS` ms (default
250). It writes `FILE.tmp` and renames it over `FILE`, so readers always see
a whole snapshot.

A file and not a socket or a port: `rename` is atomic on Linux and macOS
alike, the program never blocks on a slow or absent reader, any number of
readers (`top`, the MCP server, `cat`, `jq`, a script) can come and go,
nothing listens on the network, and nothing is left listening when the
program is killed.

The program's threads are never stopped or locked. Each thread keeps its own
tables, as for the exit report; the background thread reads them racily but
safely:

- table slots only go from empty to a record, and records are never freed;
- a record is read only once its slot was already seen at the previous
  snapshot, so its initialization is long visible (at exit every record is
  read, as the report does);
- counters are read with relaxed atomic loads: a snapshot may be a few
  events behind, never torn;
- scope stacks are shown only through records that passed the same check.

The snapshot has the same names and file:line as the report: `scopes`
(`calls`, `total_ns`, `self_ns`, `max_ns`, `p50_ns`, `p99_ns`, `recent`
percentiles, `allocs`, `alloc_bytes`), `copies`, `allocations`, `tasks`,
`waits`, `stacks`, `memory`, `cpu`, `flight`, and `pid`, `seq`, `ts_ns`,
`exited` (see the [reference](reference.md#live-snapshot)). Each section has
at most `LEANPROF_LIVE_ROWS` rows (default 100), the busiest since the last
snapshot first.

## Flight recorder

```
LEANPROF_FLIGHT=traces ./myserver &              # dumps on demand, into traces/
leanprof dump $!                                 # or kill -USR1 <pid>
LEANPROF_SLOW_MS=500 ./myserver                  # also dump when a scope takes 500 ms or more
```

With the flight recorder on, every thread records its timeline (scope begins
and ends, task runs, copies) into a fixed buffer of `LEANPROF_TRACE_MAX`
events (default 262,144, 8 MiB). When it fills, the older half is dropped,
keeping the begins of scopes that are still open, so the timeline stays
balanced and memory stays bounded; each event is moved once on average.

A dump writes the last `LEANPROF_FLIGHT_SECS` seconds (default 10, or as
many as the buffers still hold) of every thread to
`DIR/leanprof-<pid>-<n>.trace.json`, in the Chrome trace format of
`--trace`: open it in [ui.perfetto.dev](https://ui.perfetto.dev). It has the
memory counter track (sampled every 50 ms) and a marker naming what
triggered it. Scopes open when the window starts begin at their real start;
scopes still open at the dump end at the dump.

Triggers:

- `SIGUSR1`, or `leanprof dump PID`, which signals the program and prints the
  trace's path when it is written. `$TMPDIR/leanprof-<pid>.flight` names the
  directory and counts the dumps; `dump` refuses a process without it, since
  `SIGUSR1` would kill a program that does not handle it.
- `LEANPROF_SLOW_MS=MS`: a scope that took MS ms or more. The program's
  thread only notes it; the background thread writes the dump (the slow
  request's own thread pays nothing more). The scopes around a slow scope end
  later and are also slow, so a slow scope that contains the last one
  reported does not trigger again. `LEANPROF_SLOW_SCOPE=name` only watches
  scopes with that name, and `LEANPROF_SLOW_MAX` (default 10) bounds the
  number of slow dumps.

Dumps are written by the background thread: each thread's buffer is copied
under a sequence count that is odd while the thread compacts it, and events
are published with release stores, so a dump never reads a half-written
event. `LEANPROF_FLIGHT=1` dumps into the current directory, and
`LEANPROF_SLOW_MS` alone turns the recorder on with that directory.

With `LEANPROF_TRACE` as well, the exit trace holds what the ring still has.

## MCP server

`leanprof mcp` speaks the [Model Context Protocol](https://modelcontextprotocol.io)
on stdio (newline-delimited JSON-RPC 2.0): `initialize`, `ping`,
`tools/list`, `tools/call`. Register it with a client, from the project
directory:

```
claude mcp add leanprof -- leanprof mcp
```

or in a client's configuration: `{"mcpServers": {"leanprof": {"command":
"leanprof", "args": ["mcp"]}}}`. Tools that build or run take an optional
`cwd` (the project directory).

| tool | does |
|---|---|
| `doctor` | discovery, before anything else: the Lean version and whether it is supported, the project's executables, libraries and test driver, which modes work here and why not, samply and perf, each setup failure with its error code and fix (`leanprof doctor --json`; a few seconds, nothing of the project is built) |
| `run` | build with probes (`auto`, `allocs`, `counters`, `frees`, `core`), run, summarize the report |
| `sample` | samply: CPU per Lean declaration with file:line |
| `stat` | one-screen summary: time, CPU, peak memory, allocations, copies, frees, tasks |
| `elab` | compile cost per line and declaration, or exact heartbeats |
| `measure` | repeated runs into one summary, for `judge` |
| `measure_pair` | two prebuilt binaries run in alternating AB/BA order (no builds, no probes) into one paired session, for `judge` |
| `report` | summary of a saved report or live snapshot |
| `hot` | hottest scopes, copies, allocations, tasks or waits, with file:line |
| `explain` | why each costly copy happens and its fix, from the compiler's IR as `leanprof explain` gives them (in a live snapshot, which has no symbols, the usual causes); where each scope's time goes, task groups, failed reuse and closure calls. Refuses sampled reports (no copies or calls counted) |
| `compare` | regressions between two reports (exact for copies and calls) |
| `judge` | KEEP or DISCARD from two `measure` summaries (`base`, `new`) or one paired session (`pair`); `min_change` in percent |
| `experiment_start`, `experiment_try`, `experiment_finish`, `experiment_status` | [`leanprof experiment`](experiment.md): record a baseline, try a commit or the working tree (verdict and evidence JSON), run the held-out inputs; tests are the project's Lake test driver (no shell command), paths must be inside the project |
| `live` | a running program's current state, with rates over `seconds` (it must run with `LEANPROF_LIVE`) |
| `dump` | a running program's flight recorder as a Perfetto trace |

### Structured results

Every tool result has the text above for people and `structuredContent`
for agents, which follows the `outputSchema` each tool declares in
`tools/list`. It always has `ok` and `tool`; the rest is the tool's own:
`run` the report's path, exit code, wall time and copies; `measure` the
summary's path and its time, copy and allocation totals; `compare` the
whole of `compare --json`; `judge` and `measure_pair` the verdict of
`judge --json`, with its `outcome`, `measurement_valid` and `retryable`
([verdict outcomes](reference.md#verdict-outcomes)); `experiment_try` the
evidence; `hot` the section's rows as the report has them, with `total`
and `truncated`. Agents do not need to parse the text.

A call that fails has `isError: true`, `ok: false` and an `error`:

```json
{"ok": false, "tool": "run",
 "error": {"code": "build_failed", "retryable": false,
           "message": "`lake build nosuchexe` with leanprof's probes failed (exit code 1)",
           "hint": "the project does not build: fix the error in the message (`lake build EXE` shows it), then call again"}}
```

| `code` | when | retryable |
|---|---|---|
| `not_lake_project` | `cwd` (or a working directory) has no `lakefile.lean` or `lakefile.toml` | no |
| `build_failed` | the project, or the instrumented build, does not build | no |
| `lean_not_found` | `lake` or `lean` is not on the server's `PATH` | no |
| `samply_missing` | `sample` without samply | no |
| `overloaded` | the machine ran more jobs than CPUs while measuring: time not judged (a warning in `warnings`, with the verdict's outcome `insufficient_evidence`) | yes |
| `bad_argument` | an argument is missing, malformed, outside the project, or an option where a file belongs | no |
| `not_found` | a report, summary or snapshot that does not exist | no |
| `failed` | anything else; the message has the command's last output | no |

The commands report these too: with `LEANPROF_ERROR_JSON=FILE`, a command
that fails writes its error to FILE (`schemas/error.schema.json`).

CI runs a scripted session against it ([`scripts/mcp-check.py`](../../scripts/mcp-check.py)):
two `run`s of `copybug`, `report`, `hot`, `explain`, `compare` both ways,
`measure` and `judge`, `measure_pair` and a paired `judge`, `live` and `dump` on a running `server`, an
experiment on a copy of `Tests/Experiment` (start, a KEEP, status, finish), and the error cases. Every
result is validated against its tool's `outputSchema`, and each error kind above except `failed` is
produced and checked.

## Overhead

[`bench/live-overhead.py`](../../bench/live-overhead.py) on an Apple M5 Max,
`Examples/Overhead` (10 million `profile!` scopes, best of 7 runs):

| | cost per scope |
|---|---|
| before the live channel existed | 17.4 ns |
| off (`LEANPROF_LIVE` unset) | 18.1 ns |
| `LEANPROF_LIVE` (every 250 ms) | 17.3 ns |
| `LEANPROF_LIVE_MS=10` | 17.2 ns |
| `LEANPROF_FLIGHT` (timeline recorded, ring) | 23.4 ns |

Run-to-run noise is about ±1 ns.

- **Off costs nothing.** Without `LEANPROF_LIVE`, `LEANPROF_FLIGHT` and
  `LEANPROF_SLOW_MS` (three `getenv` calls at startup), no thread starts and no signal handler is installed;
  the only new instruction is a flag test inside the timeline's append, which
  runs only while a timeline is recorded. The scope path is the same code.
- **The live channel costs the program's threads nothing per scope**: they do
  not know it is there. The background thread spends about 0.3 ms of CPU per
  snapshot on a small program (most of it reading two 32,768-slot tables per
  thread), so 0.1% of a core at the default 250 ms.
- **The flight recorder costs about 6 ns per scope**: two timeline events
  into the ring, including the compactions.

## Compared with hotpath

[hotpath](https://github.com/pawurb/hotpath-rs) is a Rust profiler with a
live TUI (`hotpath console`, reading an HTTP metrics server in the program)
and an MCP server inside the program (HTTP, port 6771). leanprof's live tools
against it:

| | hotpath | leanprof |
|---|---|---|
| Live per-function calls and time | ✅ calls, avg, p95, total, % | ✅ calls/s, time/s, self/s, p50/p99 of the last 1-2 s, max, total |
| Rates per second | throughput for channels, I/O | every row: calls, copies, bytes, allocations, tasks, waits |
| Copies of shared values (Lean's hidden quadratic) | – (no such thing in Rust) | ✅ per site, with file:line and why |
| Allocations per site | ✅ per function (`hotpath-alloc`) | ✅ per call site and scope (`--allocs`) |
| Tasks, queue wait, blocking waits | futures, channels, Tokio runtime | ✅ per spawning scope, wait to start, blocking waits per site |
| Memory | per-thread alloc/dealloc, RSS | RSS and committed heap with rate, peak; peak per scope in the report |
| What each thread is inside now | – | ✅ scope stacks with time open |
| Attach to a running program | ✅ (metrics server on by default) | ✅ `LEANPROF_LIVE=1`, `top --pid`; file, no port |
| Recent per-call events | `function_timing_logs` over MCP | flight recorder: last N seconds as a Perfetto timeline, on demand or on slow scopes |
| MCP transport | HTTP inside the program (live data only) | stdio, separate process: builds, runs, samples and compares, and reads live data and dumps |
| MCP tools | per-resource summaries and logs | run, sample, stat, elab, measure, report, hot, explain, compare, judge, live, dump |
| Compile time | – | ✅ `elab` (per line, heartbeats) |
| Regression verdicts | hotpath Cloud | ✅ `compare`, `judge` (exact for copies and calls) |
| Cost per measured scope | about 40 ns (M2 Pro, its docs) | about 17 ns (M5 Max), +0 live, +6 ns flight |
| Off | feature-gated, zero | zero: no thread, no handler, same scope path |

hotpath covers things leanprof does not: SQL, HTTP and I/O wrappers, mutex
contention, CPU sampling per thread inside the TUI, Prometheus export, and
sampling a fraction of calls to cut its cost.
