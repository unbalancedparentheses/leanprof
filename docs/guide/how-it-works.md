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
`foo (in Std.Legacy.Range.forIn'.loop)`. Positions come from the `.ilean`
files Lake writes, restricted to modules that are linked into the program.

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
probes. `elab` runs `lean` with `trace.profiler` and parses the trace trees
from its JSON messages.

## Limits

- **Copies and allocations inside Lean's precompiled standard library are not
  seen**, unless the code was specialized into your module.
- **Frees are not seen** (they happen inside the runtime), so there is no
  live or peak memory yet.
- **`Task.map`/`bind` and `IO.mapTask`/`bindTask`** are not linked to their
  spawning scope.
- **Positions are per declaration** for copies and functions, because Lean's
  C output carries no line information.
- **The compiler may move pure work**: closed terms run at startup, and pure
  work in `do` blocks can run before the action (use `IO.lazyPure`).
- **Apple Silicon's clock ticks every 41.7 ns**, so percentiles of very short
  scopes are coarse.
- Tested with Lean 4.34.1 and 4.35.0 on macOS arm64 and Linux x86-64.
