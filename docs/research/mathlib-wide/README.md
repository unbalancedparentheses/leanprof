# All of Mathlib, first look (2026-10-28)

`leanprof elab --project --no-build --heartbeats` over every Mathlib module
(Mathlib commit and toolchain in [mathlib-commit.txt](mathlib-commit.txt)),
run on fede-256gb (Ryzen 9 9950X3D, shared with other work; heartbeats do not
depend on load) with leanprof `d8b6426` (branch `mathlib-all`). The full
report (`mathlib.json`, 1.09 GB) stays on that machine; these files are
summaries extracted from it with small scripts, not yet reviewed or
published as a profile.

- [summary.txt](summary.txt): 8,643 modules (2 with errors), 261.6 billion
  heartbeats, 533,460 declarations and commands with a cost, 9.1 hours of
  per-module wall time added up.
- [top3.txt](top3.txt): the share of each kind of work. Instance synthesis
  22.8%, `isDefEq` 20.4%, tactic and term steps 17.0%, linters 11.4%,
  application elaboration 4.6%, the kernel 4.2%, the compiler 2.0%.
- [top.txt](top.txt): the definitions unfolded most across Mathlib
  (`DFunLike.coe`: 979,111 unfolds at 51,881 sites, 6.42 G heartbeats;
  `Membership.mem`, `Ring.toSemiring`, `CommSemiring.toSemiring`, ...) and
  the operations repeated most (`cat_disch`, category theory's discharger:
  8,524 runs in 863 files, 4.99 G heartbeats; the same `isDefEq` and
  instance problems solved again and again across thousands of files).

Caveats: heartbeats are counted with Lean's profiler on, which adds some
work of its own; costs attributed to unfolds and repeated operations
overlap, so they are where to look, not savings; the largest "repeated"
entry ("failed to pretty print term", 5.58 G heartbeats) groups unrelated
steps whose description could not be printed and is an artifact. The
combining step took 3.3 hours single-threaded and needs fixing before this
is run routinely.
