# leanprof

An instrumentation profiler for compiled Lean 4 programs. It reports time per
scope and, unlike general-purpose profilers, the **hidden copies** that make
Lean code slow: every time an `Array`, `ByteArray` or `String` is updated while
another reference to it is alive, Lean copies the whole value.

```
leanprof: 4 scopes, wall 43.4 ms

scope                             calls      total       self  %wall       mean        p50        p99
buildWithHistory                      1     2.7 ms     2.7 ms   6.2%     2.7 ms     2.6 ms     2.6 ms
report                                1  244.0 µs   33.5 µs   0.6%  244.0 µs  234.7 µs  234.7 µs
fib                               10945  210.8 µs  210.8 µs   0.5%     235 ns      42 ns    2.7 µs
build                                 1    8.0 µs    8.0 µs   0.0%    8.0 µs    8.0 µs    8.0 µs

copies of non-exclusive values (each one copied the whole value)
function                                     kind             copies        bytes  why            in scope
buildWithHistory (in Std.Legacy.Range.forIn'.loop) Array              2001     15.3 MiB  shared+persistent buildWithHistory
```

That is [`Examples/CopyBug.lean`](Examples/CopyBug.lean): `buildWithHistory`
keeps each intermediate array alive, so every `push` copies (quadratic work in
a loop that looks linear). `build`, the same loop without the extra reference,
copies nothing.

Status: early. Tested with Lean 4.35.0 on macOS arm64; CI also runs Linux.
See [ROADMAP.md](ROADMAP.md).

## Use

Add the dependency to your `lakefile.lean`:

```lean
require leanprof from git "https://github.com/unbalancedparentheses/leanprof" @ "main"
```

Mark the code to time with `profile!`. It works on pure terms and on monadic
actions (any monad with `MonadFinally` and a `BaseIO` lift, such as `IO` or
`StateT σ IO`); a monadic scope also closes when the action throws.

```lean
import Leanprof

def solve (xs : Array Nat) : Nat := profile! "solve" (xs.foldl (· + ·) 0)

def main : IO Unit := profile! "main" do
  IO.println (solve #[1, 2, 3])
```

The report goes to stderr when the program exits.

| Variable | Effect |
|---|---|
| `LEANPROF_JSON=path` | also write the report as JSON |
| `LEANPROF_QUIET=1` | no table on stderr |
| `LEANPROF_ALL=1` | include copies of compile-time constants (hidden by default) |

To turn the annotations off without removing them, set
`leanprof.enabled` to `false` (for example in `leanOptions`): `profile!` then
elaborates to the bare term.

### Counting copies

Copy detection needs your executable's C code compiled with these flags, which
route the runtime's copy paths through leanprof:

```lean
lean_exe myapp where
  root := `Main
  moreLeancArgs := #[
    "-Dlean_copy_expand_array_nonlinear=leanprof_copy_expand_array_nonlinear",
    "-Dlean_copy_sarray_nonlinear=leanprof_copy_sarray_nonlinear",
    "-Dlean_copy_string_nonlinear=leanprof_copy_string_nonlinear",
    "-Dlean_array_push=leanprof_array_push",
    "-Dlean_byte_array_push=leanprof_byte_array_push",
    "-Dlean_float_array_push=leanprof_float_array_push",
    "-Dlean_string_push=leanprof_string_push",
    "-Dlean_string_append=leanprof_string_append",
    "-Dlean_string_utf8_set=leanprof_string_utf8_set"]
  moreLinkArgs := #["-rdynamic"]  -- so the report can name functions
```

Each copy is attributed to the compiled function that made it and to the
innermost `profile!` scope, with the reason the value was not exclusive:
`shared` (another reference is alive), `multi-threaded` (the value was shared
with another task, so Lean never mutates it in place) or `persistent` (a
compile-time constant).

### In tests

```lean
-- fails if `x` copies a shared or multi-threaded value
Leanprof.expectNoCopies x
```

`Leanprof.copies`, `Leanprof.calls "label"` and `Leanprof.depth` expose the
counters while the program runs.

## Caveats

- **Only your executable's code is observed.** Copies made inside the
  precompiled core library are not counted unless the code is specialized
  into your module, which loops over ranges and arrays usually are.
- **The compiler may move pure work.** Closed terms such as `fib 20` are
  computed once at startup, and in `do` blocks a pure `let` can run before the
  action. Profile the pure expression itself, or use `IO.lazyPure`.
- **Labels must be string literals.** The runtime keys its tables by the
  literal's address.
- **Timer resolution.** On Apple Silicon the clock ticks every 41.7 ns, so
  percentiles of very short scopes are coarse. Means and totals over many
  calls are fine.
- **Threads, not tasks.** Scopes are kept per OS thread. Work in a `Task` is
  timed on the thread that runs it, with no link to the scope that spawned it.

Overhead: about 15 ns per `profile!` scope on an Apple M-series machine,
including the closure it allocates (`lake build overhead &&
.lake/build/bin/overhead`).

## Development

```
lake test                         # in-process tests
lake build copybug && .lake/build/bin/copybug
```

The runtime is [`c/leanprof.c`](c/leanprof.c); the Lean side is
[`Leanprof/`](Leanprof).

## License

MIT
