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

The required CI matrix currently covers Lean **4.34.1 and 4.35.0**, on Linux
x86-64 and macOS arm64. Newest release-candidate and nightly toolchains are
tested daily as advisory jobs; a green stable matrix does not imply support
for every newer Lean release. See
[the version workflow](.github/workflows/lean-versions.yml) for the exact matrix.

Exact compile-time source ranges require the Lean version the driver was built
with. Runtime instrumentation depends on Lean's C runtime and generated code;
changes to inlining can affect counting coverage. Versions before 4.34 are not
currently supported. Windows is unsupported; WSL uses the Linux path.

Release archives target macOS arm64 and x86-64 and Linux x86-64 and arm64.
macOS x86-64 and Linux arm64 are smoke-tested when a release is built, not on
every commit. `.github/workflows/fresh-install.yml` installs the packaged
command with the install script and profiles projects outside this
repository on every change.
