# How it works, and limits

## Probes without changing Lean

Compiled Lean code is C that calls the runtime through `lean.h`. Copies of
non-exclusive values, `Array.push`, task spawns, blocking waits and
allocations all reach out-of-line runtime functions from that C. Compiling it
with `-Dlean_array_push=leanprof_array_push` (and similar) sends those calls
to leanprof's shims in [`c/leanprof.c`](../../c/leanprof.c), which record what
happened and forward to the real function. The rest of the runtime is
untouched. The compiler wrapper `scripts/leanprof-cc` adds the flags to every
package when set as `LEAN_CC`, and `leanprof run` compiles the shims against
the project's own `lean.h`, so the project needs no dependency.

## Scopes

Each thread keeps its own tables (no locks on the hot path), a stack of open
scopes, and log-scale histograms. leanprof measures what one enter/exit pair
costs (after a warm-up, fastest of many batches, the first time something is
profiled and again at exit) and subtracts it from every enclosing scope.
Automatic mode uses clang's `-finstrument-functions-after-inlining` hooks.

## Names and positions

Function names come from the binary's symbols (`-rdynamic`), demangled with
the inverse of Lean's name mangling; the project's package names are used to
split `lp_<package>_` prefixes. Specializations
(`Std.Legacy.Range.forIn'.loop._at_.foo.spec_0`) are reported under the
function that caused them. Positions come from the `.ilean` files Lake
writes, restricted to modules that are linked into the program.

## Sampling and compile time

`sample` runs samply and reads its profile and symbol files, so it needs no
probes. `elab` runs `lean` with `trace.profiler` and parses the trace trees
from its JSON messages.

## Limits

- **Copies and allocations inside Lean's precompiled standard library are not
  seen**, unless the code was specialized into your module.
- **No live memory per object.** Memory over time is mimalloc's committed
  memory and the process's resident memory, read about every millisecond
  at scope exits ([memory](memory.md)); frees are seen where compiled code
  drops a last reference (`--frees`), and the objects a cascade frees are
  counted by walking it first, not observed.
- **`Task.map`/`bind` and `IO.mapTask`/`bindTask`** are not linked to their
  spawning scope.
- **Positions are per declaration** for copies and functions, because Lean's
  C output carries no line information.
- **The compiler may move pure work**: closed terms run at startup, and pure
  work in `do` blocks can run before the action (use `IO.lazyPure`).
- **Apple Silicon's clock ticks every 41.7 ns**, so percentiles of very short
  scopes are coarse.
- Tested with Lean 4.34.1 and 4.35.0 on macOS arm64 and Linux x86-64.
