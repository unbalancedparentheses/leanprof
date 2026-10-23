# leanprof

> In Lean, `arr.push x` is fast only when nothing else refers to `arr`; if
> something does, Lean silently copies the whole array first. One stray
> reference turns a linear loop quadratic, and nothing in your code, your
> types, or a normal profiler tells you. **leanprof is the only tool that shows
> you those copies: the line, how many, how many bytes, how much time, and why
> the value was shared, with the fix.**

A profiler for Lean 4: where a compiled program spends its time, what it
allocates, which values it copies and why, and what each declaration costs to
compile. It works on any Lake project without changing it, and shows results
next to the code in your editor.

```
$ leanprof run myapp

     calls      total       self  %wall       mean        p50        p99  scope  (where)
         1     2.4 ms     2.4 ms  13.3%     2.4 ms     2.3 ms     2.3 ms  buildWithHistory  (Examples/CopyBug.lean:17)
     10945   54.9 µs   54.9 µs   0.3%      60 ns      42 ns     750 ns  fib  (Examples/CopyBug.lean:15)

copies of non-exclusive values (each one copied the whole value)
  copies       bytes       time  %scope  kind        why            in scope           function  (where)
    2001    15.3 MiB     2.3 ms   98.0%  Array       shared         buildWithHistory   buildWithHistory (in Std.Legacy.Range.forIn'.loop)  (Examples/CopyBug.lean:17)
```

Lean updates an `Array` or `String` in place only when nothing else refers to
it; otherwise every update copies the whole value. Here a loop kept one extra
reference, so each `push` copied: 98% of the function's time, in a loop that
looks linear. No other profiler shows this, and leanprof also says why, from
the compiler's own output:

```
$ leanprof explain

buildWithHistory (in Std.Legacy.Range.forIn'.loop)  Examples/CopyBug.lean:17
  Array copies: 1999 shared, 2 of a constant; 15.3 MiB, 3.13 ms copying
  why: `acc` is stored in `history` at line 21 (`history := history.push acc`) and is updated
       afterwards at line 22 (`acc := acc.push i`): both refer to the same Array, so the Array.push
       copies it.
  fix: Store the value after its last update, store something smaller (an index, a summary), or,
       when every intermediate version is needed, keep them in a persistent structure (`List`,
       `Lean.PersistentArray`) instead of copying the whole value at each step.
```

## What it finds

| | command |
|---|---|
| CPU time per Lean declaration, with no probes; flame graph with Lean names | `leanprof sample myapp` |
| Exact time and calls per function or `profile!` scope, own overhead subtracted | `leanprof run [--auto] myapp` |
| Copies of shared arrays and strings, with file:line and the reason | `leanprof run myapp` |
| Why each copy happened (where the second reference comes from) and how to fix it | `leanprof explain [--why myapp]` |
| Allocations per function; failed in-place reuse; closure calls | `leanprof run --allocs --counters myapp` |
| Tasks: run time, queue wait, blocking waits; Perfetto timeline | `leanprof run --trace out.json myapp` |
| Peak memory per scope, freeing pauses; one-screen summary | `leanprof stat myapp` |
| A running program, live; the last seconds of a slow request as a timeline | `leanprof top myapp`, `leanprof dump PID` |
| Profiling tools for AI agents (MCP) | `leanprof mcp` |
| Compile cost per line and operation kind, repeated work, exact heartbeats | `leanprof elab --heartbeats Foo.lean` |
| Regressions in CI, exactly for copies, calls and heartbeats; PR comments | `leanprof compare`, [GitHub Action](docs/guide/ci-and-regressions.md#github-action) |
| Keep or discard a change, for automated optimization loops | `leanprof measure`, `leanprof judge` |
| All of the above next to the code | `#leanprof` |
| All of the above in one shareable page | `leanprof html` |

`leanprof html` turns the reports into one page you can open offline or
share: a flame graph, sortable tables, source lines with the findings, and a
base-versus-new comparison.

![leanprof html: sampled flame graph of the example, with compile-time tiles](docs/images/html-report.png)

In the editor, `#leanprof` shows the last reports as inlay hints:

```
def buildWithHistory (n : Nat) ... := profile! "buildWithHistory" Id.run do   ⏱ 2.7 ms · 13.7% · 1×   ⚠ 1999 copies · 15.3 MiB · 2.7 ms   ⚙ 13.0 ms to compile
```

## Quickstart

```
git clone https://github.com/unbalancedparentheses/leanprof
sh leanprof/scripts/install.sh       # puts `leanprof` on your PATH
cd your-lean-project
leanprof doctor                      # checks Lean, clang, samply
leanprof sample myapp -- args        # where the time goes
leanprof stat myapp -- args          # one screen: time, memory, allocations, copies, frees
leanprof run myapp -- args           # exact counts, copies, tasks
```

Your project needs no changes: leanprof compiles its runtime for your Lean
version (4.34 and later) and puts your normal build back afterwards. To mark
code with `profile!`, assert in tests that code does not copy or allocate,
or use `#leanprof`, add the dependency:

```lean
require leanprof from git "https://github.com/unbalancedparentheses/leanprof" @ "main"
```

The [getting started guide](docs/guide/getting-started.md) walks through it.

## On real code

Profiled from outside, without changing the projects:

- **[lean-compiler-backend](docs/case-studies/lean-compiler-backend.md)**, a
  QBE-compatible compiler written in Lean: its tokenizer made a third of the
  11.9 million allocations needed to compile zlib, seven per input byte. The
  fix, now on its `main`, cut the whole run's allocations by 28% with
  byte-identical output; while it was written, leanprof caught a 6.8 GiB copy
  the first attempt had introduced. `leanprof explain` traced 121,054 copies
  in `CFG.build` to arrays pushed while still held by an outer array, and
  printed the fix.
- **[doc-gen4](docs/case-studies/doc-gen4.md)**: one SQL query that grows with
  the square of a module's declarations takes two thirds of the HTML pass;
  12.7% of the time is threads waiting on SQLite's memory mutex.
- **[verso](docs/case-studies/verso.md)**: about 23% of rendering is
  pretty-printing JSON only to compare index entries; a three-line function
  costs 125M heartbeats to compile.
- **[lean-regex](docs/case-studies/lean-regex.md)**: 15 allocations per input
  character in the ε-closure, and 13.7M closure calls through a function that
  is not specialized.
- **[concrete](docs/case-studies/concrete.md)**: linear list searches are a
  quarter of the self time; one `mutual` block is 69% of a file's compile
  cost.
- **[Batteries](docs/case-studies/batteries.md)** at compile time:
  termination and bounds proofs are about a quarter of all elaboration, and an
  iterator definition is unfolded 24,369 times from ordinary RBTree proofs.
- **[LeanProfiler](bench/README.md)**: why its cost per span grows with the
  number of events (its event array is copied on every span).

## How it compares

| | leanprof | [LeanProfiler](https://github.com/lean-dojo/LeanProfiler) | [lean-source-profiler](https://github.com/Vilin97/lean-source-profiler) | samply / perf |
|---|---|---|---|---|
| Run time | exact and sampled | manual spans | – | sampled |
| Overhead while recording | 11 ns per `IO` scope, 21 ns per pure one, 15 ns per call with `--auto`; constant, subtracted | 4.6 µs to 88 µs per span, growing with events | – | very low |
| Works without changing the project | ✅ | – | ✅ | ✅ |
| Lean names and file:line | ✅ | your span names | ✅ (compile time) | mangled C names |
| Copies, allocations, failed reuse, closures | ✅ | – | – | – |
| Why a copy happened, with a fix | ✅ from the compiler's IR, confirmed at run time | – | – | – |
| Peak memory per scope, freeing pauses | ✅ | – | – | – |
| Tasks | ✅ queue wait, blocking waits | parent links | – | threads |
| Compile time | per file, declaration and tactic line; the definitions unfolded behind it; repeated work; whole projects | – | exact term ranges, Mathlib-scale data ([comparison](docs/case-studies/compile-time-vs-lean-source-profiler.md)) | – |
| Exact regression checks, PR comments | ✅ | thresholded time | – | – |
| Live view, flight recorder | ✅ `top`, `dump` | – | – | – |
| In the editor | run time, copies, compile time | – | compile time | – |

### Accuracy

Measured against workloads with known answers ([results](bench/RESULTS.md)):
call and copy counts are exact in every mode. For time, `leanprof sample` is
as accurate as samply (within 0.1–1.7 percentage points of each function's
true share) and adds Lean names, file:line and the runtime breakdown. The
exact modes (`profile!`, `--auto`) report times that match the
uninstrumented program when each scope does real work (0.98–1.06× on the
allocation, copy and mixed workloads), but over-report functions that run
for only a few nanoseconds (up to 4× for `fib`-sized calls): use them for
counts, copies and causes, and `sample` for the time of tiny functions.

## Documentation

- [Getting started](docs/guide/getting-started.md)
- [Run time](docs/guide/run-time.md): sampling, every function, `profile!`, tasks, timeline
- [Copies and allocations](docs/guide/copies-and-allocations.md), reuse and closures
- [Memory, frees and `leanprof stat`](docs/guide/memory.md)
- [Compile time](docs/guide/compile-time.md)
- [In the editor](docs/guide/editor.md) and [HTML report](docs/guide/html-report.md)
- [CI, regressions and autoresearch](docs/guide/ci-and-regressions.md)
- [Live view, flight recorder and MCP server](docs/guide/live.md)
- [Lean API](docs/guide/lean-api.md) and [reference](docs/guide/reference.md) (commands, environment, JSON)
- [How it works, and limits](docs/guide/how-it-works.md)
- [Roadmap](ROADMAP.md), [changelog](CHANGELOG.md), [ideas from other ecosystems](docs/research/other-ecosystems.md)

Status: early. Tested with Lean 4.34.1 and 4.35.0 on macOS arm64 and Linux
x86-64.

## Development

```
lake test                                   # tests
lake build copybug && .lake/build/bin/copybug
```

The runtime is [`c/leanprof.c`](c/leanprof.c); the Lean library is
[`Leanprof/`](Leanprof); the command line is
[`LeanprofCli.lean`](LeanprofCli.lean). MIT license.
