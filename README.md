# leanprof

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
looks linear. No other profiler shows this.

## What it finds

| | command |
|---|---|
| CPU time per Lean declaration, with no probes; flame graph with Lean names | `leanprof sample myapp` |
| Exact time and calls per function or `profile!` scope, own overhead subtracted | `leanprof run [--auto] myapp` |
| Copies of shared arrays and strings, with file:line and the reason | `leanprof run myapp` |
| Allocations per function; failed in-place reuse; closure calls | `leanprof run --allocs --counters myapp` |
| Tasks: run time, queue wait, blocking waits; Perfetto timeline | `leanprof run --trace out.json myapp` |
| Compile cost per line and operation kind, repeated work, exact heartbeats | `leanprof elab --heartbeats Foo.lean` |
| Regressions in CI, exactly for copies, calls and heartbeats; PR comments | `leanprof compare`, [GitHub Action](docs/guide/ci-and-regressions.md#github-action) |
| Keep or discard a change, for automated optimization loops | `leanprof measure`, `leanprof judge` |
| All of the above next to the code | `#leanprof` |

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

- **[lean-compiler-backend](docs/case-studies/lean-compiler-backend.md)**, a
  QBE-compatible compiler written in Lean. Its tokenizer made a third of the
  11.9 million allocations needed to compile zlib, seven per input byte. The
  fix cut the whole run's allocations by 28% with byte-identical output. While
  writing that fix, leanprof caught a 6.8 GiB copy the first attempt had
  introduced. Other findings: one function was a quarter of its compile cost,
  and 76% of closure calls went through one non-specialized helper.
- **[LeanProfiler](bench/README.md)**: leanprof found why its cost per span
  grows with the number of events (its event array is copied on every span).

## How it compares

| | leanprof | [LeanProfiler](https://github.com/lean-dojo/LeanProfiler) | [lean-source-profiler](https://github.com/Vilin97/lean-source-profiler) | samply / perf |
|---|---|---|---|---|
| Run time | exact and sampled | manual spans | – | sampled |
| Overhead while recording | ~11 ns per scope, constant, subtracted | 4.6 µs to 88 µs per span, growing | – | very low |
| Works without changing the project | ✅ | – | ✅ | ✅ |
| Lean names and file:line | ✅ | your span names | ✅ (compile time) | mangled C names |
| Copies, allocations, failed reuse, closures | ✅ | – | – | – |
| Tasks | ✅ queue wait, blocking waits | parent links | – | threads |
| Compile time | per line and operation, repeated work | – | deeper (unfolded definitions, all of Mathlib) | – |
| Exact regression checks, PR comments | ✅ | thresholded time | – | – |
| In the editor | run time, copies, compile time | – | compile time | – |

Overhead from [`bench/`](bench/README.md) on an Apple M5 Max.

## Documentation

- [Getting started](docs/guide/getting-started.md)
- [Run time](docs/guide/run-time.md): sampling, every function, `profile!`, tasks, timeline
- [Copies and allocations](docs/guide/copies-and-allocations.md), reuse and closures
- [Compile time](docs/guide/compile-time.md)
- [In the editor](docs/guide/editor.md)
- [CI, regressions and autoresearch](docs/guide/ci-and-regressions.md)
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
