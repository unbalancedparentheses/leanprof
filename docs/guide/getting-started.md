# Getting started

leanprof works in two ways, and you can use both:

- **From the command line, on any Lake project**, with no changes to the
  project: `leanprof` alone finds what to profile and profiles it;
  `leanprof run`, `leanprof sample` and `leanprof elab` go deeper.
- **As a library**, to mark the code you care about with `profile!`, check
  copies and allocations in tests, and see results in the editor.

## Install the command

You need Lean (through [elan](https://github.com/leanprover/elan)) and a C
compiler (for the exact commands, which rebuild with probes). Then one
command:

```
curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh
```

When [samply](https://github.com/mstange/samply), the sampler `leanprof
sample` runs, is not on your `PATH`, the installer asks whether to fetch
samply 0.13.1, the version leanprof is tested with, checked against its
SHA256, into `~/.local/share/leanprof/samply`; leanprof uses that one when
there is no samply on `PATH`. Without samply everything but `sample` works,
and `leanprof` with no arguments rebuilds with probes instead.

It puts `leanprof` in `~/.local/bin`: the prebuilt command of the latest
[release](https://github.com/unbalancedparentheses/leanprof/releases) for
macOS arm64 or Linux x86-64, checked against the release's `SHA256SUMS`, or,
when there is no release for your platform yet, the command built from
source (in `~/.local/share/leanprof/src`). Options go after `sh -s --`:

```
curl -sSfL .../install.sh | sh -s -- --release v0.1.0   # a given version
curl -sSfL .../install.sh | sh -s -- --source           # always build from source
curl -sSfL .../install.sh | sh -s -- --bin ~/bin        # somewhere else
curl -sSfL .../install.sh | sh -s -- --samply           # also samply, without asking
curl -sSfL .../install.sh | sh -s -- --samply-only      # only samply, later
```

From a clone, `sh scripts/install.sh` builds that clone instead. Run the
installer again to update.

Run `leanprof doctor` inside a project to check that everything it needs is
there; for each missing tool it prints the command that installs it on your
system (macOS: `xcode-select --install` for the C compiler, `brew install
llvm` for the llvm-objcopy of `--core`; Debian and Ubuntu: `sudo apt install
clang`, `sudo apt install llvm`; Arch: `sudo pacman -S clang`, `sudo pacman
-S llvm`). `run` and `stat` say the same when the compiler is what failed.
For the editor, see also the [VS Code extension](vscode.md).

### Supported platforms

| | |
|---|---|
| macOS arm64 | supported; prebuilt command |
| Linux x86-64 | supported; prebuilt command (glibc 2.35 or newer, e.g. Ubuntu 22.04; older systems build from source) |
| macOS x86-64, Linux arm64 | prebuilt command, smoke-tested on each release (run, allocations, `explain`, `elab`; `sample` on macOS) but not in the per-commit test matrix |
| Windows | not supported; WSL 2 with Linux is the way to use it |

Lean 4.34 and later. CI runs the test suite and `leanprof run`, `sample` and
`elab` on a project for Lean 4.34.1 and 4.35.0 (required to pass), and for
the newest release candidate and the latest nightly, daily, so a Lean
release that breaks leanprof shows up before it is out
([lean-versions.yml](../../.github/workflows/lean-versions.yml)).
`leanprof sample` is checked on macOS; on Linux, samply needs perf events
(`sudo sysctl kernel.perf_event_paranoid=1`).

Windows is unsupported because every part of leanprof that touches a program
assumes a POSIX system: `leanprof run` builds through a `sh` compiler
wrapper (`scripts/leanprof-cc`) that redirects Lean's runtime functions
with clang flags and links with `-rdynamic`; the runtime uses pthreads,
`dladdr` to name the code that copied, `getrusage` and `/proc` for
memory, and signals (`SIGUSR1` for `leanprof dump`); and sampling
relies on samply's macOS and Linux backends and on ELF or Mach-O symbol
names. A Windows port would need each of these replaced.

## First profile of an existing project

From the project's directory:

```
leanprof
```

leanprof reads the lakefile and picks what to profile: the project's one
`lean_exe`; else its test driver, when that is an executable; else, for a
library, its compile time (`leanprof elab --project --compact`). With
several executables it lists them and profiles none; name one, with its
arguments after `--`:

```
$ leanprof
leanprof: this project has 3 executables; pick the one to profile (with its arguments):
  leanprof graph -- ARGS
  leanprof unused_transitive_imports -- ARGS
  leanprof import-graph-workspace-summary -- ARGS
compile time of the libraries:
  leanprof elab --project --compact
$ leanprof graph -- --to ImportGraph out.dot
```

It runs the cheapest profile that says something: `leanprof sample` when
samply can sample (no rebuild with probes; on Linux perf events must be open
to users, `sudo sysctl kernel.perf_event_paranoid=1`), else `leanprof stat`.
After that profile's report come the top findings and the commands that go
deeper. On leanprof's small test project (`Tests/Smoke`):

```
leanprof: top findings
  1. 55.25% of CPU in buildWithHistory (in Std.Legacy.Range.forIn'.loop) (Main.lean:10): lean_copy_expand_array 45.76%, mi_page_free_list_extend 5.09%
  2. 50.31% of CPU allocates and frees objects: `leanprof run --allocs smoke -- 30000` counts allocations per function
  3. 45.78% of CPU copies arrays or strings that were still shared: `leanprof run smoke -- 30000` finds each copy site, `leanprof explain` says why and gives the fix

next steps
  leanprof run smoke -- 30000             exact: copies of shared values, tasks, waits (rebuilds with probes, puts your build back)
  leanprof explain                        after run: why each copy happened, and the fix in Lean
  leanprof fix --exe smoke -- 30000       apply that fix on a git branch, test, measure, commit it only if it helps
  leanprof run --auto smoke -- 30000      every function's exact time and call count
  samply load .lake/leanprof/smoke.json   flame graph with Lean names
```

On a Mac (M-series) with no samply and an empty leanprof home, installing
from a release archive, samply included, took 4.8 s (plus downloading the
77 MB archive), and `leanprof` in a new `lake new` project, building it
included, 8.6 s; on the project above, 5.4 s. While no release is
published, the installer builds leanprof from source, which took 58 s.

The commands it chooses between, by hand (`myapp` is one of the project's
`lean_exe` targets):

```
leanprof sample myapp -- ARGS      # where CPU time goes; no rebuild of your code with probes
leanprof run myapp -- ARGS         # exact: copies of shared values, tasks, blocking waits
leanprof run --allocs myapp        # also allocations per function
leanprof run --auto myapp          # also every function's time and call count
leanprof elab Main.lean Foo.lean   # compile time per declaration
```

The project does not need to depend on leanprof: `run` compiles leanprof's
runtime for the project's own Lean version (4.34 and later) and links it in,
and removes the instrumented objects afterwards so your normal builds stay
clean.

Each command prints its report and saves it under `.lake/leanprof/`.

## Reading the report

```
     calls      total       self  %wall       mean        p50        p99  scope  (where)
         1     4.3 ms     4.3 ms  13.8%     4.3 ms     4.2 ms     4.2 ms  buildWithHistory  (Examples/CopyBug.lean:17)
     10945  73.1 µs*   73.1 µs   0.2%      80 ns       7 ns     480 ns  fib  (Examples/CopyBug.lean:15)
* near the probe cost: use `leanprof sample` for this function's time

copies of non-exclusive values (each one copied the whole value; costliest first)
  copies       bytes       time   %run  %scope  kind        why            in scope           function  (where)
    2001    15.3 MiB     4.3 ms  13.7%   99.0%  Array       shared         buildWithHistory   buildWithHistory (in Std.Legacy.Range.forIn'.loop)  (Examples/CopyBug.lean:17)

allocations: not counted (`leanprof run --allocs` counts them, at a cost of about 6 ns per allocation that is not subtracted from the times)
```

- **total** includes everything called inside; **self** excludes what was
  timed by nested scopes. leanprof's own cost (about 8 ns per scope) has
  already been subtracted; a `*` after a total means the scope's time is
  near that cost (use `leanprof sample` for it).
- **copies**: Lean updates an `Array`, `ByteArray` or `String` in place only
  when nothing else refers to it. Otherwise it copies the whole value first.
  The `why` column says whether another reference was alive (`shared`), the
  value had been shared with another thread (`multi-threaded`), or it was a
  compile-time constant (`persistent`, harmless and hidden by default).
  `%run` is the copy time's share of the whole run, the first thing to look
  at: rows are sorted by it. Copies of empty or tiny values are grouped in
  one row (`--all-copies` lists them).
- A time too small to measure is never shown as 0: `< probe` means less
  than leanprof's own cost per scope, `< 1 ns` less than one clock tick.
- **`(in Std.Legacy.Range.forIn'.loop)`**: the copy happened in a library
  function specialized into `buildWithHistory`, so it is reported under your
  function.

## Using it as a library

Add the dependency:

```lean
require leanprof from git "https://github.com/unbalancedparentheses/leanprof" @ "main"
```

Mark code with `profile!` (in a file that is a `module`, so the program does
not link Lean's front end):

```lean
module

public import Leanprof

def solve (xs : Array Nat) : Nat := profile! "solve" (xs.foldl (· + ·) 0)

public def main : IO Unit := profile! "main" do
  IO.println (solve #[1, 2, 3])
```

Run the program as usual and the report appears on stderr when it exits. Add
`#leanprof` to a file to see the last report next to the code in your
editor. `leanprof html` puts the reports in one page you can open offline
and share ([HTML report](html-report.md)).

Next: [run time](run-time.md), [copies and allocations](copies-and-allocations.md),
[memory, frees and `leanprof stat`](memory.md),
[compile time](compile-time.md), [editor](editor.md), [VS Code](vscode.md),
[CI and regressions](ci-and-regressions.md).
