# What leanprof needs to be the best choice

Reviewed 2026-10-24. The target is the shortest reliable path from a slow Lean
program to a correct, measured improvement. Feature counts alone do not establish
that. This is an engineering priority list, not a claim of overall superiority.

## Current position

| Job | Alternative's strength | leanprof's position and gap |
|---|---|---|
| Lightweight benchmark verdicts | [LeanBench](https://github.com/alok/LeanBench) has named benchmarks, saved baselines and comparison output. | Exact Lean runtime metrics add diagnostic value. The recorded instrumented workflow costs more; `measure-pair` now supplies ordinary-binary interleaving, but named/per-scope benchmarks and a new cost comparison remain. |
| Application tracing | [LeanProfiler](https://github.com/lean-dojo/LeanProfiler) provides explicit structured spans, nested/cross-thread traces and strict summaries. | Automatic discovery and copy explanations reduce setup. Tiny-function timing and total attribution still need improvement; manual spans can be more accurate. |
| CPU sampling | [samply](https://github.com/mstange/samply) uses the Firefox Profiler UI and supports multiple platforms. | leanprof builds on samply, adding Lean names and attribution. It should improve Lean diagnosis rather than claim a new sampling engine. |
| Compile-time diagnosis | [lean-source-profiler](https://github.com/Vilin97/lean-source-profiler) now defaults to a cached native compact capture, with detailed capture optional, source overlays, a repository viewer and published large-project datasets. | leanprof has compile/runtime integration and demonstrated fixes. Our earlier timing comparison does not establish a lead against this newer capture path; rerun it at pinned current revisions. |
| Continuous performance history | [Radar](https://github.com/leanprover/radar) coordinates dedicated runners, stores commit metrics, provides a web UI and supports PR benchmark requests. | leanprof is primarily a local diagnostic tool. Export compatible measurements and support that workflow; do not treat a local comparison command as equivalent infrastructure. |

The [recorded benchmark results](../../bench/RESULTS.md) and
[compiler qualification](../../research/lcb/results/README.md) show useful
advantages and real limitations. They are measured on particular versions,
machines and workloads. No fresh, comprehensive ranking of all current tools
has been completed.

## Priorities and acceptance evidence

1. **Trustworthy decisions.** Interleaved ordinary-binary measurements, output
   checks and paired confidence intervals are implemented. Next validate their
   detection power and false-positive rate on unchanged programs and seeded
   1%, 2% and 5% changes, across quiet and loaded hosts. Publish run counts,
   intervals, inconclusive outcomes and cost; do not repeatedly sample until a
   desired verdict appears. Compare alternatives at matched decision thresholds.
2. **Trustworthy counting.** Detect unsupported or bypassed copy paths at runtime,
   distinguish instrumented-code totals from core-library coverage, and test known
   answers across the supported Lean matrix. Never present missing instrumentation
   as zero allocations or copies. This remains a release-hardening priority.
3. **Lower measurement cost.** Retain ordinary builds, add per-scope/named benchmark
   support, and avoid process startup hiding small changes. Measure complete
   time-to-verdict, including preparation and any required subsequent rebuild.
4. **Accurate attribution.** Fix Linux unwinding/frame-pointer gaps and quantify
   probe bias for tiny functions and concurrent workloads. Report low-confidence
   timing honestly. Compare manual spans and sampling with equal boundaries and
   collection settings; do not optimize one headline workload alone.
5. **A better first investigation.** A fresh user should get useful ranked findings
   from an unfamiliar runtime program or library, follow the source location,
   understand the proposed fix and verify it. Test installation, error recovery
   and source navigation with users outside this project. Refresh compile-time
   comparisons against native compact capture before claiming leadership there.
6. **Independent evidence.** Obtain reproduction of the compiler result and
   accepted fixes in additional projects. Preserve input/option coverage and
   correctness review. Fewer allocations, lower measured time and faster real
   executions are separate results and must be reported separately.

The immediate sequence is paired verdict validation, copy-count coverage checks,
then current-version compile-time and user-workflow comparisons. Broader platform
support and new interfaces should not displace these correctness and evidence
gaps. Progress should be judged by correct diagnoses and verified improvements,
with published costs and failure cases.
