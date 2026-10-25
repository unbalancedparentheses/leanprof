# Reviewed compiler qualification, 2026-10-23

Baseline: `854fcc2`. Candidate: `ac8324e` (the original 12 optimization commits
through `f9ed557`, plus the memory-promotion validation correction).

## Plain-binary timing

Fresh builds in separate checkouts, using the compiler's pinned Nix environment
(Lean 4.34.1). The final candidate was built again from an empty build directory.
Neither benchmark binary contains leanprof symbols. All local build and test
jobs from this qualification finished before measurement.

| Statistic | Baseline | Reviewed candidate |
|---|---:|---:|
| Median wall time, 30 runs each | 810.85 ms | 630.76 ms |
| Minimum–maximum | 755.69–961.26 ms | 559.03–768.20 ms |
| Reduction in the two medians | | **22.21%** |
| Median of the 30 paired reductions | | **25.74%** |
| Paired bootstrap 95% interval | | **22.72–26.98%** |

The ratio of two medians and the median of paired ratios are different
statistics; both are reported rather than combining their numbers. Every pair
alternated AB/BA ordering, following three warmup pairs. Assembly, stdout and
stderr hashes and successful exit statuses matched throughout.

This was a shared Apple M5 Max host with 18 logical CPUs, not a dedicated idle
runner. One-minute load was 6.23 at the start and 6.01 at the end. The bootstrap
interval describes variability within this session, not platform or workload
generalization. The earlier saved-binary repeat (26.3% reduction) used different
build artifacts; the clean pinned builds above are the qualification result.

[benchmark.json](benchmark.json) contains every run, load measurement, binary
hash, input hash, build identity and command arguments. See [../README.md](../README.md)
for exact reproduction commands and the already-archived input files.

## Correctness and review

- **540 differential comparisons passed** using the freshly built candidate:
  17 zlib units × five targets × four option sets, plus ten malformed inputs
  under the same 20 target/option combinations. Assembly, diagnostics and exit
  status were compared; malformed inputs had to be rejected by both binaries.
  Raw signatures: [identity.json.gz](identity.json.gz).
- **99/99 local check stages passed on each side**, including build identity,
  unit tests, CLI protocol, proof-axiom audit, native tests, QBE comparisons,
  fuzzing and emission-only tests. Unlike the earlier experiment environment,
  no baseline failure needed an exception with this pinned Nix environment.
  Results: [base-checks.json](base-checks.json), [head-checks.json](head-checks.json).
- The corrected compiler passed [CI on macOS, Linux x86-64 and Linux arm64](https://github.com/unbalancedparentheses/lean-compiler-backend/actions/runs/40052249263).
  Local cross-target tests sometimes check emission only; their logs explicitly
  distinguish that from execution.

The source review covered the complete optimization series:

| Change | Review conclusion |
|---|---|
| Phi constant checks without a temporary array | Empty, singleton and differing-value behavior preserved; remaining values are checked from index 1. |
| Structural CSE keys | Retain result width, floating class, operation, operand order and comparison width; symbol operands remain excluded. |
| Indexed label validation | CFG construction retains duplicate-label, missing-target and entry-target checks in the original order. |
| Module, emitter and allocator validation reuse | Existing public entry points retain checks. New `Validated` helpers have explicit caller preconditions; CLI paths validate via SSA construction and optimization. |
| CFG reuse in liveness, home-flow and SSA | Callers reuse the same function's graph; memory promotion changes instructions and debug indices, preserving block order, labels and terminators. |
| Memory promotion's removed output validation | **Required a correction.** SSA construction's no-renaming path returns unchecked input. |

The correction adds an opt-in `validateUnchanged` check to `constructWithGraph`
and enables it for memory promotion. Renamed results were already validated;
they are not checked twice. The existing `SSA.construct` behavior is unchanged.
A regression fixture containing a promotable single-store object and an undefined
return value formerly returned the original function. The uncorrected branch
changed that invalid function; the corrected branch again keeps the original.
The test fails without the correction, while all 340 zlib CLI comparisons had
passed—an example of why the acceptance workload alone is insufficient.

This review and the tests are evidence, not a proof of equivalence for all inputs.
The original allocation and copy totals in the case study belong to `f9ed557`;
they were not remeasured for `ac8324e` and should not be presented as its counts.

## leanprof release checks

`lake test` passed. A local macOS arm64 release archive was packaged, checksum
verified and installed into a temporary prefix. Its external-project smoke test
passed on Lean 4.35.0, including `run`, allocation/reuse/free counters,
`explain --why`, `elab`, and `sample`. Sampling required execution outside the
computer sandbox; the initial sandboxed attempt could not access macOS profiling.

The prior CI failure was a TSan report at Lean's inlined fresh-object header
initialization, paired with a read of the previous object occupying that memory.
The existing uninstrumented-allocator reuse suppression was extended only to
`lean_set_st_header`, not to leanprof task functions. The TSan job passed on the
review branch. This does not provide race detection inside Lean's precompiled
runtime or constitute a full security audit.

[logs.tar.gz](logs.tar.gz) preserves all 198 stage logs, build logs, the fresh
candidate's unit-test log, leanprof tests, installer output and installed smoke
test output. No release version tag was created.
