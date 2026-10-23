# Why your Lean loop is secretly quadratic

*Draft only. Not published.*

Lean values are immutable, yet `arr.push x` in a loop runs in amortized
constant time, just as it would in Rust or C. The trick is reference
counting. When it works, you never notice it. When it fails, a loop that
looks linear becomes quadratic, and nothing in the source shows it. This
post covers how that happens, how to see it, how to find the cause, and how
to keep it from coming back.

## In-place updates and the hidden copy

Every Lean object carries a reference count. When the runtime is asked to
`push` onto an array, it first checks whether the array is *exclusive*:
its reference count is one, so nothing else refers to it (and it has not
been shared with other threads, more on that below). If it is, the push writes into the
existing buffer, growing it when it is full. If it isn't, the runtime copies the whole array and pushes
onto the copy, because someone else may still read the old version.

This loop keeps every intermediate version of an array
(`Examples/CopyBug.lean` in the leanprof repository):

```lean
def buildWithHistory (n : Nat) : Array Nat × Array (Array Nat) := profile! "buildWithHistory" Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut history : Array (Array Nat) := #[]
  for i in [0:n] do
    history := history.push acc
    acc := acc.push i
  return (acc, history)
```

After `history := history.push acc`, both `history` and `acc` refer to the
same array, so `acc.push i` finds it shared and copies it. The copy at
iteration `i` costs `i` elements, so the loop makes about `n²/2` element
copies in total.

You can see this in the C that Lean generates, which Lake keeps in
`.lake/build/ir/`. Here is the loop body, from the current build:

```c
lean_inc(v_fst_30_);
v___x_35_ = lean_array_push(v_snd_31_, v_fst_30_);
lean_inc(v_i_26_);
v___x_36_ = lean_array_push(v_fst_30_, v_i_26_);
```

`v_fst_30_` is `acc`. The `lean_inc` gives it a second owner before it is
pushed into `history` (`v_snd_31_`), so the second `lean_array_push` gets a
shared array. `lean_array_push` is a function in Lean's runtime, and when
its argument isn't exclusive it copies the array before pushing.

## Seeing it: `leanprof run`

[leanprof](https://github.com/unbalancedparentheses/leanprof) builds a Lake
executable with the runtime's copy paths redirected to its own shims
(`-Dlean_array_push=leanprof_array_push` and similar). The project doesn't
change, and the normal build is put back afterwards. It then runs the
program and reports the copies of non-exclusive values made by the code
it compiled. Sites that only copied compile-time constants (the first push
onto a literal `#[]` copies it once) are hidden by default:

```
$ leanprof run copybug -- 2000

     calls      total       self  %wall       mean        p50        p99  scope  (where)
         1     2.6 ms     2.6 ms 100.0%     2.6 ms     2.6 ms     2.6 ms  buildWithHistory  (Examples/CopyBug.lean:17)
         1   84.2 µs   36.3 µs   3.2%   84.2 µs   82.7 µs   82.7 µs  report  (Examples/CopyBug.lean:35)
     10945   48.0 µs   47.7 µs   1.8%      51 ns      42 ns     500 ns  fib  (Examples/CopyBug.lean:15)
         1    6.5 µs    6.5 µs   0.3%    6.5 µs    6.3 µs    6.3 µs  build  (Examples/CopyBug.lean:25)

copies of non-exclusive values (each one copied the whole value)
  copies       bytes       time  %scope  kind        why            in scope           function  (where)
    2001    15.3 MiB     2.6 ms   98.5%  Array       shared         buildWithHistory   buildWithHistory (in Std.Legacy.Range.forIn'.loop)  (Examples/CopyBug.lean:17)
```

98.5% of `buildWithHistory`'s reported time is spent inside the pushes
that copied. `build`, in the same
file, is the same loop without `history`. It does 2,000 pushes in 6.5 µs.
The `(in Std.Legacy.Range.forIn'.loop)` means the copy happened in the
`for` loop's code, specialized into `buildWithHistory`, so it is reported
under that function.

The growth is easy to see by doubling `n`. Copies and bytes are exact. The
times come from one run each on a machine running other jobs:

| n | copies | bytes copied | `buildWithHistory` | `build` |
|---|---|---|---|---|
| 1,000 | 1,001 | 3.8 MiB | 1.7 ms | 9.3 µs |
| 2,000 | 2,001 | 15.3 MiB | 2.9 ms | 9.6 µs |
| 4,000 | 4,001 | 61.0 MiB | 6.9 ms | 12.1 µs |
| 8,000 | 8,001 | 244.1 MiB | 24.1 ms | 16.9 µs |

Twice the input means four times the bytes copied.

## Finding the cause: `leanprof explain`

Knowing *that* a value was shared is half the answer. `leanprof explain`
reads the same generated C, finds the update that copied, traces where the
updated value came from, and finds the `lean_inc` that gave it a second
owner:

```
$ leanprof explain
leanprof explain: why 1 of 1 copy sites copied (from .lake/leanprof/report.json)

buildWithHistory (in Std.Legacy.Range.forIn'.loop)  Examples/CopyBug.lean:17
  Array copies: 1999 shared, 2 of a constant; 15.3 MiB, 2.57 ms copying
  why: `acc` is stored in `history` at line 21 (`history := history.push acc`) and is updated
       afterwards at line 22 (`acc := acc.push i`): both refer to the same Array, so the Array.push
       copies it.
  fix: Store the value after its last update, store something smaller (an index, a summary), or,
       when every intermediate version is needed, keep them in a persistent structure (`List`,
       `Lean.PersistentArray`) instead of copying the whole value at each step.
  where: Examples/CopyBug.lean lines 21, 22
  evidence: .lake/build/ir/Examples/CopyBug.c:186 `v___x_36_ = lean_array_push(v_fst_30_, v_i_26_);`, second reference at .lake/build/ir/Examples/CopyBug.c:183
  confidence: high: the IR takes a second reference on every path to the update; source lines matched by text, not positions
  (1 other update(s) in this function with weaker evidence not shown)
  note: 2 copies were of a constant (a literal such as `#[]` or `""`, a closed term, or the shared
        elements of `Array.replicate n #[]`): the first update of each copies it once, which is
        expected.
```

Two details are worth noticing. The `evidence` line names the exact C line,
so you can check the claim yourself. And `confidence` says how the source
line was found: Lean's IR has no source positions, so `explain` matches the
declaration's text against what the IR shows, and it says so.

In this example the copies are not a mistake in the runtime. The program
asked to keep 2,000 versions of the array, and copying is how it gets them.
The fix is a different data structure: store what you actually need (a
size, an index), or keep versions in something built for sharing, such as a
`List` or `Lean.PersistentArray`.

Other shapes produce the same problem. These are the ones `explain`
recognizes:

| shape | example | usual fix |
|---|---|---|
| stored elsewhere, then updated | `history := history.push acc; acc := acc.push i` | update before storing, or store less |
| element read out of an array that still holds it | `xs := xs.set! i (xs[i]!.push v)` | `xs := xs.modify i (·.push v)` |
| still used after the update | `let b := a.push x; f a b` | do the later read first |
| read from an `IO.Ref` that still holds it | `let a ← r.get; r.set (a.push x)` | `r.modify (·.push x)` |
| `multi-threaded` | reachable from a `Task`, a global `IO.Ref` or `Mutex` | build it in the thread that updates it |

The last row deserves a word. Lean marks values reachable from more than
one thread as multi-threaded and never updates them in place, even when
only one reference exists. An array kept in a global `Std.Mutex` therefore
copies on every push, however careful the code is. leanprof's benchmark
found this in [LeanProfiler](https://github.com/lean-dojo/LeanProfiler),
whose recorded events live in such a mutex: at 4,000 spans, its
`completeSpan` makes 8,002 array copies (61.1 MiB), most of the bytes from
copying the event array on every span. A
reference-counting bug isn't always a bad `let`.

When the second reference is taken in another function, the static reading
can only say "from the caller". `leanprof explain --why EXE` then rebuilds
with `lean_inc` wrapped, and records at run time where copied values got
their second reference. That costs about 7% more wall time on
lean-compiler-backend. It sees only increments in the code it compiled, not
those in Lean's precompiled libraries or in `lean.h`'s inline
functions.

## On real code: a 6.8 GiB copy in a fix

[lean-compiler-backend](https://github.com/unbalancedparentheses/lean-compiler-backend)
is a QBE-compatible compiler written in Lean. Profiling it compiling zlib
with `leanprof run --allocs` showed its tokenizer making 4,066,775 of the
run's 11,946,202 allocations, about seven per input byte. The cause was the
loop state: a `for c in source` loop with seven `let mut` variables compiled
to a `WellFounded.opaqueFix₃` loop that allocated seven constructor cells
per byte.

The rewrite scans bytes with its state in function arguments, reads them in
place with `getUTF8Byte`, and extracts each token once. Its first version
was 30 times slower than the code it replaced. One `leanprof run` showed
why: `tokenize.go` copied the token array 91,020 times, 6.84 GiB, on
`crc32` alone. A `let flush := … tokens.push …` had been written above the
branches. It was evaluated while `tokens` was still used by the other
branches, so the push always found the array shared. Moving the push into
the branches that use it removed every copy.

The version that was merged
([commit 4864dd2](https://github.com/unbalancedparentheses/lean-compiler-backend/commit/4864dd2))
cut the tokenizer from 4,066,775 allocations (88.8 MiB) to 692,597
(37.3 MiB), and the whole run from 11,946,202 to 8,572,024 (−28%). Output
was byte-identical on all 160 input/target/option combinations.

The same project had smaller cases too. `CFG.build` made 121,054 array
copies (822 KiB) because it pushed onto arrays that were still held by an
outer array. Together, all its copies cost about 3 ms of a 575 ms run, so
they were worth fixing for hygiene but weren't the bottleneck. Copy counts
tell you where non-linear updates are. Copy time tells you whether they
matter.

## Keeping it fixed: tests and CI

For a deterministic program, a copy is a deterministic event: the same
input makes the same copies. That makes it a property you can test, unlike
time. Programs whose threads race can vary.

In a test executable built with leanprof's `copyFlags` (copy them from its
lakefile into `moreLeancArgs`, with `-rdynamic` in `moreLinkArgs`), the
assertions throw when violated. From leanprof's own tests:

```lean
let r ← (expectNoCopies (pure (linear n100)) |>.toBaseIO)
check "expectNoCopies passes linear code" (r matches .ok _)
let r ← (expectNoCopies (IO.lazyPure fun _ => (withHistory n50).1.size) |>.toBaseIO)
check "expectNoCopies rejects shared code" (r matches .error _)
```

Note the `IO.lazyPure`. Lean's compiler can evaluate pure work before the
action that is meant to measure it, and `lazyPure` keeps the work inside.
`Leanprof.expectAllocsAtMost n x` does the same for allocations (with
`allocFlags`).

In CI, compare a report against a baseline:

```
leanprof run --json new.json myapp -- bench-input
leanprof compare baseline.json new.json
```

`compare` exits 1 on any increase in copies of shared or multi-threaded
values, a changed call count for a scope present in both reports, or
compile heartbeats up by more than 1% and 1,000. Time fails only past a
threshold, 10% and 1 ms by default. The GitHub Action in the repository
does this per pull request with no baseline to keep. It profiles the base
and head commits on the same runner and comments the difference:

```yaml
- uses: unbalancedparentheses/leanprof@main
  with:
    executable: myapp
    args: bench-input --size 1000
    allocs: true
    elab-files: MyApp/Basic.lean MyApp/Proofs.lean
    fail-on: copies,heartbeats
```

Copies, allocations, calls and heartbeats are counted exactly, so a change
in them is a real change in what the program did, not noise. Whether it
matters is still your call. Wall time appears in the comment, but it never
fails the job.

## What it doesn't see

- Copies inside Lean's precompiled libraries (`Init`, `Std`, `Lean`) are
  invisible unless the code was specialized into your module, which loops
  over ranges and arrays usually are. `leanprof run --core` links against
  copies of those libraries with the runtime calls renamed. It needs
  `llvm-objcopy` (or GNU `objcopy` on Linux), and it shows more noise from
  Lean's own startup.
- Positions are per declaration for copies and functions, because Lean's C
  output carries no line information. `explain` recovers lines by matching
  text.
- `explain` reads the C that Lake keeps. Copies made in precompiled library
  code have no C to read. `--why`'s run-time table is lossy, so each line
  is "the last recorded increment".
- The per-thread tables are bounded. With `--allocs`, a large program can
  have more allocation sites than they hold (8,192), and the report then
  says how many events were dropped.

leanprof works on Lean 4.34 and later, and is tested on 4.34.1 and 4.35.0 on
macOS arm64 and Linux x86-64. It's early. To try it on your own project:

```
git clone https://github.com/unbalancedparentheses/leanprof
sh leanprof/scripts/install.sh
cd your-project && leanprof run yourapp -- args && leanprof explain
```

---

*Outputs were regenerated on 2026-10-23 with leanprof at `2021ecd` (Lean
4.35.0, Apple M5 Max). The lean-compiler-backend numbers come from
`docs/case-studies/lean-compiler-backend.md` (Lean 4.34.1). The LeanProfiler
numbers were re-measured against its current `main` (`35e1899`).*

## Accuracy review

Reviewed by Codex (`codex exec --sandbox read-only`, codex-cli 0.162.1) on 2026-10-23, in two passes, against README.md, the guides, the case studies, bench/RESULTS.md and the code, and against the measurements re-run for these drafts.

Fixed after the review:
- An exclusive array is now defined by its reference count and thread sharing, and an in-place push may still grow the buffer.
- "`n²/2` work" is now "about `n²/2` element copies".
- `leanprof run` reports copies made by the code it compiled. Sites that only copied constants are hidden by default.
- The 98.5% is now described as reported scope time spent inside the pushes that copied (the shim times the whole push), not "copying".
- `--why` records where copied values got their second reference, but not increments in precompiled libraries or `lean.h`'s inline functions.
- Determinism is now limited to deterministic programs. "Any regression is real" is now "a real change in what the program did".
- `compare` counts copies of shared or multi-threaded values only, and call-count changes only for scopes present in both reports.
- `--core` also works with GNU `objcopy` on Linux. Bounded tables (8,192 allocation sites) were added to the limits.

Not changed: the `%wall` column in the quoted `leanprof run` output shows `buildWithHistory` at 100.0%, and the column sums to more than 100%. That is what current main prints (see the commit message). It should be fixed in leanprof, or the column cropped, before publishing.

