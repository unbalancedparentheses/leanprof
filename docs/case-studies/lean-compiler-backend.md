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
