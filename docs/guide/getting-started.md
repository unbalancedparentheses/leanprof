# Getting started

leanprof works in two ways, and you can use both:

- **From the command line, on any Lake project**, with no changes to the
  project: `leanprof run`, `leanprof sample` and `leanprof elab` build and
  profile it from outside.
- **As a library**, to mark the code you care about with `profile!`, check
  copies and allocations in tests, and see results in the editor.

## Install the command

You need Lean (through [elan](https://github.com/leanprover/elan)) and, for
sampling, [samply](https://github.com/mstange/samply)
(`brew install samply` or `cargo install samply`).

```
git clone https://github.com/unbalancedparentheses/leanprof
sh leanprof/scripts/install.sh          # puts `leanprof` in ~/.local/bin
```

Run `leanprof doctor` inside a project to check that everything it needs is
there.

## First profile of an existing project

From the project's directory (`myapp` is one of its `lean_exe` targets):

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
scope                         calls      total       self  %wall       mean        p50        p99  where
buildWithHistory                  1     2.5 ms     2.5 ms  16.8%     2.5 ms     2.5 ms     2.5 ms  Examples/CopyBug.lean:17

copies of non-exclusive values (each one copied the whole value)
function                                 kind           copies       bytes       time  %scope  why             in scope             where (declaration)
buildWithHistory (in Std.Legacy.Range.forIn'.loop) Array            2001    15.3 MiB     2.5 ms   98.5%  shared+persistent buildWithHistory     Examples/CopyBug.lean:17
```

- **total** includes everything called inside; **self** excludes what was
  timed by nested scopes. leanprof's own cost (about 15 ns per scope) has
  already been subtracted.
- **copies**: Lean updates an `Array`, `ByteArray` or `String` in place only
  when nothing else refers to it. Otherwise it copies the whole value first.
  The `why` column says whether another reference was alive (`shared`), the
  value had been shared with another thread (`multi-threaded`), or it was a
  compile-time constant (`persistent`, harmless and hidden by default).
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
editor.

Next: [run time](run-time.md), [copies and allocations](copies-and-allocations.md),
[compile time](compile-time.md), [editor](editor.md),
[CI and regressions](ci-and-regressions.md).
