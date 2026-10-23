# Draft: Zulip announcements

*Draft only. Not posted.*

---

## #lean4: "leanprof: a profiler for compiled Lean programs (copies, allocations, compile time)"

While rewriting the tokenizer of a Lean compiler backend
([lean-compiler-backend](https://github.com/unbalancedparentheses/lean-compiler-backend)),
the first version of the fix ran 30 times slower than the code it replaced.
One profiler run showed why: the inner loop copied the token array 91,020
times, 6.84 GiB in all, while compiling zlib's `crc32` alone. A
`let flush := … tokens.push …` written above the branches was evaluated
while `tokens` was still used by other branches, so every `push` found the
array shared. Moving the push into the branches that use it removed every
copy. The fix that was merged cuts the run's allocations by 28%
(11.9M to 8.6M) with byte-identical output.
([Case study](https://github.com/unbalancedparentheses/leanprof/blob/main/docs/case-studies/lean-compiler-backend.md).)

That run used leanprof, which I've been building to find this kind of
problem. It works on any Lake project without changes to the project:

```
leanprof sample myapp -- ARGS   # CPU time per Lean declaration with file:line (samply underneath)
leanprof run myapp -- ARGS      # exact: copies of shared Arrays/Strings, with file:line and why; tasks
leanprof explain                # where the second reference came from, read from the IR in .lake/build/ir
```

On the copy example in the repo, `explain` prints:

```
buildWithHistory (in Std.Legacy.Range.forIn'.loop)  Examples/CopyBug.lean:17
  Array copies: 1999 shared, 2 of a constant; 15.3 MiB, 2.57 ms copying
  why: `acc` is stored in `history` at line 21 (`history := history.push acc`) and is updated
       afterwards at line 22 (`acc := acc.push i`): both refer to the same Array, so the Array.push
       copies it.
```

It also does allocations, failed constructor reuse and closure calls
(`run --allocs --counters`), peak memory and freeing pauses (`stat`),
compile cost per declaration and tactic line (`elab`, `--heartbeats` for
exact counts), and `compare` plus a GitHub Action that fails a PR on more
copies (or, opted in, compile heartbeats), since those counts are exact.

Limits:

- Time from the instrumented modes (`profile!`, `run --auto`) is good when
  a scope does real work: workload totals (median of 7 runs) came out at 0.98–1.06× of the
  uninstrumented program on the benchmark's allocation, copy and mixed
  workloads. It over-reports functions that run for a few nanoseconds (a
  1 ns function 3–4×, `fib` about 5×). For those, use `sample`. Its mean error in
  each function's share was 0.1–1.7 percentage points per workload, about
  the same as samply. Call and copy counts were exact in every instrumented
  mode on every workload. Sampling has no counts.
  ([benchmark](https://github.com/unbalancedparentheses/leanprof/blob/main/bench/RESULTS.md))
- Copies and allocations inside the precompiled `Init`/`Std`/`Lean` are
  not seen unless the code was specialized into your module, or you use
  `run --core`, which links against rewritten copies of those libraries
  (needs `llvm-objcopy`). Allocations the runtime makes inside its own C/C++
  (`libleanrt`) stay invisible either way.
- Positions are per declaration, not per line: Lean's C output carries no
  line information. `explain` finds source lines by matching text and says
  so, with a confidence level and the C line it read.
- Early. Lean 4.34 and later; tested with 4.34.1 and 4.35.0 on macOS arm64
  and Linux x86-64.

For compile time specifically, there is also lean-source-profiler by
Vilin97, which records exact ranges for every term and tactic. I wrote
[a head-to-head comparison](https://github.com/unbalancedparentheses/leanprof/blob/main/docs/case-studies/compile-time-vs-lean-source-profiler.md)
covering what each finds and where it does better.

Repo: https://github.com/unbalancedparentheses/leanprof. Bug reports and
"it reported something wrong on my project" are very welcome.

---

## #mathlib4 (shorter, compile time): "Finding where compile time goes: definitions unfolded behind the work"

Profiling Batteries (`v4.35.0`, all 195 built modules) turned up
`Std.Iterator.IsPlausibleStep` (`Init/Data/Iterators/Basic.lean:375`),
unfolded 24,369 times from 69 declarations: 2.3 s of `isDefEq` work. Most
of it comes from `RBTree` proofs that never mention iterators (the `append`
theorems in `Recycling/RBTree/WF.lean`, `zoom_del`/`zoom_ins`). These are
the same declarations whose cost is mostly `decreasing_tactic`, so the
likely path is termination proofs unifying through the iterator library's
step relation. I haven't confirmed that inside the tactic.
`decreasing_tactic` and `get_elem_tactic` together are about a quarter of
the library's compile heartbeats (14.4% and 9.7%).
([Case study](https://github.com/unbalancedparentheses/leanprof/blob/main/docs/case-studies/batteries.md).)

This comes from `leanprof elab`, which reads `trace.profiler` plus a few
`Meta` traces through `lake lean` and charges each unfold, instance attempt,
`whnf` and simp rewrite the work it caused, per definition and across files.
Costs of different definitions overlap, and operations under 1 ms (10,000
heartbeats) are not recorded on their own by default.

```
leanprof elab --project                # the package's built modules in parallel: declarations, tactic lines, repeated work, definitions behind it
leanprof elab --heartbeats Foo.lean    # the same in heartbeats: two runs on all of Batteries differ by 2 in a million
leanprof compare base.json new.json    # exit 1 if a declaration costs >1% and >1,000 heartbeats more
```

On Batteries, `elab --project` takes 17 s on 18 cores, against 13 s for a
clean `lake build`. There is a GitHub Action that comments heartbeat changes
per declaration on PRs. It has a `setup` input for `lake exe cache get`.

Limits:

- The published case studies don't include Mathlib. They cover Batteries,
  Verso, lean-compiler-backend, doc-gen4, lean-regex and concrete.
  `--project` profiles the modules `lake build` builds, not tests or
  scripts.
- Tactic steps are placed on lines by finding their text in the source. There
  are no column ranges, and terms aren't timed separately from their tactic.
  lean-source-profiler does exact ranges and has published profiles of all
  of Mathlib
  ([comparison](https://github.com/unbalancedparentheses/leanprof/blob/main/docs/case-studies/compile-time-vs-lean-source-profiler.md)).
- Printing the trace costs. The whole command took 1.3–2.1× as long as plain
  `lean` on Batteries' heaviest files, and 3× on `String/Lemmas.lean`.
  `--counts` (Lean's `diagnostics`) can double elaboration time.
- Times are summed over Lean's parallel elaboration, so a file's total
  exceeds its wall time. Use `--heartbeats` for anything you compare.

Repo: https://github.com/unbalancedparentheses/leanprof

---

## Accuracy review

Reviewed by Codex (`codex exec --sandbox read-only`, codex-cli 0.162.1) on 2026-10-23, in two passes, against README.md, the guides, the case studies, bench/RESULTS.md and the code, and against the measurements re-run for these drafts.

Fixed after the review:
- "Counts are exact in every mode": now limited to the instrumented modes on the benchmark's workloads. Sampling has no counts.
- `sample`'s 0.1–1.7 pp is a mean error per workload, not a bound per function. It is now worded that way, with "median of 7 runs" for the workload totals.
- The "up to 4×" over-report for `fib`-sized calls came from README.md, but bench/RESULTS.md shows 5.48× for `fib` under `profile!`. It now reads "a 1 ns function 3–4×, `fib` about 5×". **README.md still says "up to 4×".**
- `elab`'s attribution now says that costs overlap and that operations under 1 ms / 10,000 heartbeats are not recorded on their own.
- "All of Batteries" is now "all 195 built modules". `--project` does not cover tests or scripts.
- Trace overhead is now 1.3–2.1× for the whole command, from the comparison table (RBTree/WF is 2.0 s against 0.97 s). The compile-time guide's "1.3 to 1.7 times" is narrower than its own case study.
- "A quarter of elaboration" is now "a quarter of compile heartbeats": the percentages are of all heartbeats.
- The GitHub Action fails on `copies` by default. Heartbeats are opt-in.
- "Not run on Mathlib" is now "the published case studies don't include Mathlib", which the repo can show.

