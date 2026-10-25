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
the project's own `lean.h`, so the project needs no dependency. On Linux the
wrapper hands the compile and the link to Lean's own `leanc` (its bundled
clang, sysroot and linker), so the profiled program is built like the one
Lake builds: built by the system's clang and linker instead, the copy
benchmark ran 18% faster without any probes, and that difference showed up
in the report as if leanprof had subtracted too much. (A probe still moves
code: Lean's precompiled runtime lands at other addresses, and on a Ryzen
7950X3D the alignment of its copy and free loops alone changes that
benchmark by up to 18%. No build setting removes that.)

## The clock

Each scope reads the clock twice. On Apple Silicon leanprof reads the
counter `CNTVCT_EL0` directly (not `mach_absolute_time`, which waits for
every earlier instruction). On Linux it reads the TSC on x86-64 and
`CNTVCT_EL0` on arm64, but only when the kernel keeps time with the same
counter (clocksource `tsc` or `arch_sys_counter`: the kernel checks that
the TSC is invariant and in step across cores) and, on x86-64, the CPU
reports an invariant TSC. The TSC's rate is measured against
`CLOCK_MONOTONIC`: over 50 µs at startup for intervals and thresholds, and
over at least 5 ms from startup for every reported time. Otherwise, or with
`LEANPROF_CLOCK=monotonic`, it calls `clock_gettime(CLOCK_MONOTONIC)`, about
18 ns a read through the vDSO on a 7950X3D against 4.5 ns for `RDTSC`.
None of these reads wait for earlier instructions; both ends of a scope
read the same way, and calibration measures the probes with the same
reads.

## Dependencies are rebuilt, then put back

Lake does not notice a new `LEAN_CC`, so `run`, `stat`, `measure` and `top`
move the compiled objects (`*.c.o*` with Lake's trace files) of the root
package and of every dependency in `lake-manifest.json` (git packages under
`.lake/packages`, path packages where they are) to
`<package>/.lake/leanprof/normal-objects/`. Lake then recompiles every
package's C through the wrapper, so copies inside a dependency are seen
with no setup. Afterwards the instrumented objects are deleted and the
normal ones moved back, with the normal executable, so the next `lake build`
recompiles nothing. A run that was interrupted (or used `--keep`) is undone
at the start of the next one. `--no-deps` sets aside only the root
package's objects: faster when the dependencies are large, but copies inside
them are not counted (unless they were never built, in which case Lake
builds them through the wrapper and leanprof leaves them so).

## Self-check: is copy detection working?

A Lean release can move a copy out of reach of the `-D` flags: Lean 4.36
made `lean_string_push` a `static inline` function in `lean.h` whose slow
path calls `lean_string_push_cold`, and String copies went silently
uncounted until the wrapper also renamed `lean_string_push_cold`. So every
profiled run checks itself. [`c/selfcheck.c`](../../c/selfcheck.c) is
compiled with the copy flags exactly as the program's C is (`leanc` with
`LEAN_CC` set to the wrapper for `leanprof run`, `copyFlags` in projects that
depend on leanprof), and calls `lean_array_push`, `lean_array_set`,
`lean_string_push`, `lean_string_append`, `lean_byte_array_push` and (4.35
and later) `lean_byte_array_set` the way generated code does. At exit, the
runtime runs each once on a shared one-element value: each must reach a shim
as one copy. While it runs, the thread's copies go to separate counters, so
the check adds no rows and changes no counts. It costs six copies of
one-element values and a few allocations, about 20 µs once, after the wall
time is taken.

If a copy is not seen, the report ends with, and the JSON's `self_check`
object carries, a warning such as

```
leanprof: warning: copies of String may be undercounted with Lean 4.36.0: a known copy through String.push (lean_string_push_cold) was not counted (...)
```

`stat` and `measure` print it too, and `leanprof doctor` builds and runs the
same check (`copy detection works with Lean 4.35.0 (Array.push, ...)`). The
check covers `lean.h` and the wrapper's flags for the installed Lean; it
does not cover a Lean version whose compiler emits calls to different
runtime functions, which the test suite and the Lean version matrix in CI
catch instead.

## Lean's own libraries (`--core`)

Lean's precompiled libraries (`libInit.a`, `libStd.a`, `libLean.a`, ...)
call the same runtime functions directly, and the `-D` flags never reach
them. `leanprof run --core` makes copies of these archives with
`llvm-objcopy --redefine-sym lean_array_push=leanprof_array_push` (and so on
for every redirected function, read from the wrapper's `-D` list), caches
them in `.lake/leanprof/core/<toolchain>-<hash>/`, and passes that directory
to the wrapper as `LEANPROF_CORE_LIB`. The wrapper puts it first among the
link's `-L` directories, so leanc's `-lInit -lStd -lLean` find the copies.
This is the static-archive version of GNU ld's `--wrap`.

`--redefine-sym` renames a symbol in every object of the archive, whether
it is referenced or defined there. That is safe here because none of the
rewritten archives defines a redirected function (checked with `nm` on
4.34.1 and 4.35.0: all are defined in `libleanrt.a`, which is never
rewritten). leanprof's own runtime object is not rewritten either, so a
shim's call to `lean_array_push` still links to the real function. Had a
rewritten archive defined one, the link would fail with a duplicate
`leanprof_*` symbol rather than miscall. CI checks that the copies have no
reference left to the old names and define no `leanprof_*` symbol.

## Scopes

Each thread keeps its own tables (no locks on the hot path), a stack of open
scopes, and log-scale histograms. leanprof measures what one enter/exit pair
costs (after a warm-up, fastest of many batches, the first time something is
profiled and again at exit) and subtracts it from every enclosing scope.
Automatic mode uses clang's `-finstrument-functions-after-inlining` hooks.

## Names and positions

Function names come from the binary's symbols (`-rdynamic`), demangled with
the inverse of Lean's name mangling (a port of `Name.demangle`) and printed
like `Name.toString` (`Foo.«weird name»`), which is also how `.ilean` files
key declarations. The project's package names (lakefile and `.lake/packages`)
are used to split `lp_<package>_` prefixes, longest first: the split is
ambiguous when a package name has escapes (`lean-compiler-backend` is
`lean_x2dcompiler_x2dbackend`). Compiler-generated parts (`_lam_0`,
`_closed_3`, `_redArg`, `_boxed`, macro scopes `_@.M._hyg.4`, the C
compiler's `.cold.1`) are dropped, so they count as their declaration;
other components starting with `_` are user names and kept.
Specializations (`Std.Legacy.Range.forIn'.loop._at_.foo.spec_0`) are
reported under the function that caused them, as
`foo (in Std.Legacy.Range.forIn'.loop)`; a specialization made inside
another one (`g._at_.(h._at_.foo.spec_1).spec_2`) is reported under the user
code at the end of the chain, `foo (in g)`. The compiler reuses a
specialization for every caller with the same arguments, so `foo (in g)` can
also run for other callers (`leanprof sample` shows the main one). Positions
come from the `.ilean` files Lake writes, restricted to modules that are
linked into the program; a module's source is looked up in its package and
one directory down, for libraries and executables with a `srcDir`
(`scripts/Bench.lean`).

### Checking the demangler against Lean's

`demangle-check` compares leanprof's demangler with Lean's own
(`Lean.Name.Demangle.demangleSymbol` in `Lean/Compiler/NameDemangling.lean`)
on every `l_`/`lp_` symbol of a binary:

```
lake build demangle-check
cd PROJECT && /path/to/leanprof/.lake/build/bin/demangle-check [--show N] BINARY...
```

Run it from the binary's project directory: both demanglers then know the
project's packages (Lean's takes the shortest valid split otherwise, which
is wrong for package names with escapes). Lean prints compiler details that
leanprof leaves out on purpose, so its output is mapped first:

| Lean prints | leanprof prints |
|---|---|
| `f [boxed]`, `f [arity↓, λ]`, `f [private]` | `f` |
| `f (pkg)` | `f` |
| `f [flags] spec at g[flags]` (more ` spec at` for nested ones) | `g (in f)`, the first caller |
| `f._lam_0.g`, `f._closed_3.value` (compiler parts inside the name) | `f` |
| `f .cold.1` (also `.isra.0`, `.llvm.N`) | `f` |
| `f` for `f._@.M._hyg.2._at_.g.spec_4` (all from `_@` on dropped) | `g (in f)` (only the macro scope dropped) |
| `_regBuiltin._private.M.0.f` (`_private` inside a name) | `_regBuiltin.f` |

Compiler parts are components starting with `_lam`, `_elam`, `_closed`,
`_boxed`, `_redArg`, `_impl`, `_jp`, `_override`, `_spec`, `_unsafe_rec`,
`_regBuiltin`, `_auto`, `_private` or `_@`. Any other difference is reported
as a mismatch and the command exits 1. CI runs it on leanprof's binaries, on
[`Tests/OddNames`](../../Tests/OddNames) (a package named `odd-names_v2` with
declarations such as `«weird name»`, `«1st»`, `ℕsum`, `x₁`, `«emoji🎉»`,
`Odd._under`, `«a.b»`, private and hygienic names and specializations) and
on [leanprover-community/repl](https://github.com/leanprover-community/repl)
(about 400,000 symbols, most of them Lean's own compiler), and then profiles
both with `run`, `sample` and `elab` from outside, checking that reported
names are demangled and resolve to positions (`scripts/check-report.py`).

## Sampling and compile time

`sample` runs samply and reads its profile and symbol files, so it needs no
probes. On Linux samply unwinds a copy of the top 64 KiB of the stack
(perf's limit), so samples deep in recursion lose their outer frames.
A stack is whole when its outermost frame is one that is never anything
but outermost on that thread (`_start`, the thread's start routine); a cut
one is completed with the outer frames of the thread's last whole stack,
from the outermost call of the cut stack's outermost function. Frame
pointers would not help: the limit is on the bytes copied, not on how
they are unwound, and Lean's bundled clang already keeps frame pointers. `elab` runs `lean` with `trace.profiler` and parses the trace trees
from its JSON messages.

## Limits

- **Copies and allocations inside Lean's precompiled standard library are not
  seen** by default, unless the code was specialized into your module.
  `leanprof run --core` sees them by linking against copies of the
  libraries whose references to the runtime are renamed to the shims (see
  below). Calls that the runtime makes to itself inside `libleanrt.a` stay
  invisible, for example the allocations of `String` and `Nat` primitives
  implemented in C++: renaming a symbol in the archive that defines it would
  rename the definition too. Seeing those needs a hook in Lean's runtime,
  such as an event callback or calls through exported function pointers.
- **No live memory per object.** Memory over time is mimalloc's committed
  memory and the process's resident memory, read about every millisecond
  at scope exits ([memory](memory.md)); frees are seen where compiled code
  drops a last reference (`--frees`), and the objects a cascade frees are
  counted by walking it first, not observed.
- **Positions are per declaration** for copies and functions, because Lean's
  C output carries no line information.
- **The compiler may move pure work**: closed terms run at startup, and pure
  work in `do` blocks can run before the action (use `IO.lazyPure`).
- **Apple Silicon's counter** runs at 1 GHz on an M5 but ticks every 41.7 ns
  on earlier chips, where percentiles of very short scopes are coarse.
- Tested with Lean 4.34.1 and 4.35.0 on macOS arm64 and Linux x86-64, and
  daily with the newest Lean release candidate and nightly; not on Windows
  ([supported platforms](getting-started.md#supported-platforms)).
