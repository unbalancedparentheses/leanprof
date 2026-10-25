# Linux results: AMD Ryzen 9 7950X3D

`python3 bench/run.py`, 7 runs each, on a dedicated, idle machine (Arch
Linux, kernel 7.2, `performance` governor, boost off, the suite pinned to
cores 0–7), run with `servers/leanprof-bench-run.sh` from the maintainer's
dotfiles. `machine.txt` in each folder records the host, commit, settings
and load.

- [before/](before/RESULTS.md): leanprof `8d9f807`, the runtime before the
  Linux fixes (`clock_gettime`, no stack completion in `sample`).
- [after/](after/RESULTS.md): leanprof `4b6d6a7`, with the TSC clock, the
  inlined scope entry and exit, `sample`'s stack completion and `leanc` in
  the compiler wrapper. The branch's last commit (`80c7ad7`) only moved a
  flag into a struct's padding and changed docs; it was not re-measured.

[../README.md](../README.md#linux-amd-ryzen-9-7950x3d-2026-10-23) has the
before/after table and what changed.
