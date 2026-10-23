# Case study: lean-compiler-backend

[lean-compiler-backend](https://github.com/unbalancedparentheses/lean-compiler-backend)
(`lcb`) is a QBE-compatible compiler backend written in Lean 4.34.1: 356
modules, no dependency on leanprof. All runs below used leanprof's CLI from
another checkout (`/path/to/leanprof/.lake/build/bin/leanprof …`) on a copy
of the project at commit `a25c541`, on an Apple M5 Max. The workload is
`lcb --target aarch64-macos --optimize --allocate` on zlib's `deflate`,
`inflate`, `trees` and `crc32` compiled to QBE IL (562 KB of input, 0.51 s).

## Where run time goes (`leanprof sample`)

No rebuild, no source changes; samply underneath.

| inclusive CPU | |
|---|---|
| 50% | `Optimize.module` (`Optimize.lean:85`): memory promotion 16%, common-subexpression elimination 15% |
| 26% | `validateFunction` (`Validate.lean:126`), much of it `String.decEq` and hash-map lookups |
| 22% | AArch64 emission (`AArch64.lean:1093`) |
| 17% | `loadModule` (parsing) |

Runtime self time: freeing objects 9%, allocation 7%, `Lean.mkAtom` plus
string hashing about 7% (string interning in the hot path), copies of
non-exclusive values 0.7%.

## Copies (`leanprof run`)

`run` compiled leanprof's runtime for Lean 4.34.1 and linked it in; the
compiled assembly was byte-for-byte identical to the normal build's.

| copies | bytes | time | function | where |
|---|---|---|---|---|
| 121,054 | 822 KiB | 1.5 ms | `CFG.build` (array, in a `for` loop) | `CFG.lean:13` |
| 46,633 | 764 KiB | 0.5 ms | `Optimize.function` | `Optimize.lean:67` |
| 17,775 | 156 KiB | 0.3 ms | `SSA.fresh` (string) | `SSA.lean:44` |
| 7,903 | 988 KiB | 0.2 ms | `CFG.build` (hash map buckets) | `CFG.lean:13` |

Together about 3 ms of a 575 ms run: real non-linear updates, worth fixing
for hygiene (`CFG.build` copies an array on almost every iteration), but not
the bottleneck.

## Allocations (`leanprof run --allocs`)

11,946,202 allocations, 266.6 MiB, to compile 562 KB of input (output again
identical to the normal build):

| allocations | bytes | share | function | where |
|---|---|---|---|---|
| 4,066,775 | 88.8 MiB | 33.3% | `Parser.tokenize` | `Parser.lean:20` |
| 415,067 | 22.3 MiB | 8.4% | `validateFunction` (range loop) | `Validate.lean:126` |
| 910,550 | 16.2 MiB | 6.1% | `Parser.peek` | `Parser.lean:79` |
| 992,116 | 15.1 MiB | 5.7% | hash-map lookups (`Std.DHashMap` `get?`) | |
| 615,346 | 11.7 MiB | 4.4% | `Statement.definition` | `IR.lean:228` |
| 560,981 | 11.2 MiB | 4.2% | `Optimize.Cleanup.copies` | `Optimize/Cleanup.lean:51` |

The tokenizer makes about 7 allocations per input byte and is a third of all
allocation; `Parser.peek`, which should not need to allocate, allocates
910,550 times. Both are cheap to fix and would also cut the time spent
freeing objects (9% of CPU in the sampled profile).

### The fix

The loop state was the cause: `tokenize` was a `for c in source` loop with
seven `let mut` variables, which compiled to a `WellFounded.opaqueFix₃` loop
allocating seven constructor cells per input byte. The tokenizer now scans
bytes with its state in arguments, reads them in place with `getUTF8Byte` and
extracts each token once
([commit 4864dd2](https://github.com/unbalancedparentheses/lean-compiler-backend/commit/4864dd2), on `main`):

| | before | after |
|---|---|---|
| tokenizer allocations | 4,066,775 (88.8 MiB) | 692,597 (37.3 MiB) |
| whole run | 11,946,202 (266.6 MiB) | 8,572,024 (215.1 MiB), −28% |
| output | | byte-identical on all 160 input/target/option combinations |

The first version of the fix was 30 times slower. `leanprof run` showed why
in one run: `tokenize.go` copied the token array 91,020 times (6.84 GiB) on
`crc32` alone, because a `let flush := … tokens.push …` written above the
branches was evaluated while `tokens` was still used by other branches. Moving
the push into the branches that use it removed every copy. The project's CI
(three runners, proofs and native checks) passed before the merge.

### Two more fixes: `CFG.build` and `Parser.peek`

Same workload, measured with leanprof built for Lean 4.35 against the
project's Lean 4.34.1, after the tokenizer fix:

- **`CFG.build`**: `explain` named `successors.set! i (successors[i]!.push
  target)` (and the same for `predecessors`): the push updates an element the
  outer array still holds. `Array.modify` takes it out first. The first
  version of this fix updated both arrays in one loop and `run --allocs`
  showed it added 59,514 allocations: the pair carrying the two arrays through
  the loop was no longer reused. Filling predecessors in a second pass over
  the deduplicated successors (same order) removed them
  ([commit 8a0d286](https://github.com/unbalancedparentheses/lean-compiler-backend/commit/8a0d286)).
- **`Parser.peek`** returned `Option String` through `StateT` over `Except`,
  three allocations per call (the `Option`, the result pair, `Except.ok`).
  It is now `@[inline]`, and the 47 comparisons with a literal token use
  `peekIs`/`peekStartsWith`, which never build the `Option`
  ([commit a623acc](https://github.com/unbalancedparentheses/lean-compiler-backend/commit/a623acc)).

| | before | after |
|---|---|---|
| `CFG.build` array copies | 121,054 (822 KiB, 35,093 of filled arrays) | 43,899 (360 KiB), each the first push into an empty slot |
| `Parser.peek` allocations | 910,550 (16.2 MiB) | none |
| whole run | 8,572,024 allocations (215.1 MiB) | 7,719,273 (200.1 MiB), −10% |
| wall time (30 runs × 3, median) | 338–347 ms | 328–346 ms: within noise on a loaded machine |
| output | | byte-identical on all 160 input/target/option combinations |

Both are on the `perf-cfg-peek` branch and go to `main` once the project's CI passes.

## Compile time (`leanprof elab --heartbeats`)

Six large or proof-heavy files: 296M heartbeats in total (2 min 38 s).

- Kind of work: code generation 41%, kernel 22%, elaboration steps 8%,
  `isDefEq` 8%, instance search 3%.
- **`emitFunctionUsingBank` (`AArch64.lean:857`) alone costs 73.6M
  heartbeats, 25% of these files**: 26M to elaborate its large `do` block and
  47M in the code generator. Splitting it into smaller functions is the
  largest compile-time win available.
- **Eleven `cases w <;> decide +kernel` proofs** in
  `Verified/PhiExamples.lean` cost 51.9M heartbeats (17.5%); each evaluates a
  whole machine run.
- **Repeated work**: the coercions `LineBuffer → List String` and back are
  searched 132 times each (7.6M heartbeats), and `HAppend String String
  String` 1,772 times. A direct coercion instance (or explicit conversions)
  would remove most of the first.

Because these numbers are heartbeats, they are the same on every run, so a
`leanprof compare` of `elab.json` before and after a change shows its exact
effect.
