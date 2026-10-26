# Contributing

Use the Lean version pinned in `lean-toolchain`. Install that toolchain with
elan, then run:

```sh
lake build
lake test
git diff --check
```

Changes to the runtime, compiler wrapper, reports or regressions should include
a focused example that would fail before the change. Run the relevant commands
from `.github/workflows/ci.yml` locally; Linux sanitizers and the macOS/Linux
version matrix provide additional coverage in CI. Keep normal project builds
usable after profiling.

For performance claims, record the commit, toolchain, platform, workload, raw
runs and machine load. Alternate baseline and candidate runs, check outputs,
and measure plain binaries separately from instrumented ones. Distinguish
counts observed in instrumented code from allocations or copies inside
precompiled libraries. Do not infer a wall-time gain from fewer allocations.

Keep pull requests focused. Explain the triggering example, the resulting
behavior and the checks run, including failures or platform limitations.
For release packaging, follow [RELEASING.md](RELEASING.md).

## Lean and platform support

leanprof supports projects on Lean **4.27 and later** (`run`, `stat`,
`sample`, `measure`/`judge`, `explain`, `elab`, and the library with
`profile!` and `#leanprof`). The required CI matrix covers Lean **4.27.0,
4.31.0, 4.34.1 and 4.35.0**, on Linux x86-64 and macOS arm64; the other
supported minor versions (4.28.1, 4.29.1, 4.30.0, 4.32.2, 4.33.1) run on
Linux as advisory jobs, and so do the newest release candidate and the
nightly, daily. A green stable matrix does not imply support for every newer
Lean release. See [the version workflow](.github/workflows/lean-versions.yml)
for the exact matrix.

Where Lean changed, the code checks the version: `LEAN_VERSION_MAJOR`/`MINOR`
in `c/` (lean.h's copy functions: `lean_copy_expand_array` before 4.28,
`lean_copy_byte_array`/`lean_copy_float_array` before 4.35,
`lean_internal_get_rc` from 4.33, `lean_string_push_cold` from 4.36), and
`#lean_since N ... #lean_else ... #lean_end` in `LeanprofElabDriver.lean`,
which each project's Lean compiles (trace results from 4.29, the header's
syntax from 4.31). The self-check runs the same six copies on every version
and warns when a shim misses one; a new version check belongs with a
self-check operation that would catch its absence.

Exact compile-time source ranges require the Lean version the driver was built
with. Runtime instrumentation depends on Lean's C runtime and generated code;
changes to inlining can affect counting coverage. Lean 4.26 and earlier are
not supported: there the module system (`module`, which every library file
uses) is still experimental, and the `String` API leanprof and the driver are
written against (`trimAscii`, `dropEnd`, slices) does not exist yet, so
neither builds. (`leanprof run` from outside still counts copies on 4.26, but
without the driver it has no source positions.) Windows is unsupported; WSL uses the
Linux path.

Release archives target macOS arm64 and x86-64 and Linux x86-64 and arm64.
macOS x86-64 and Linux arm64 are smoke-tested when a release is built, not on
every commit. `.github/workflows/fresh-install.yml` installs the packaged
command with the install script and profiles projects outside this
repository on every change.
