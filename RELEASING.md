# Releasing

A release is a version tag. Pushing it runs
[`.github/workflows/release.yml`](.github/workflows/release.yml), which
builds the `leanprof` command on macOS arm64 and Linux x86-64, checks the
packaged command by profiling `copybug` with it, and creates a GitHub
release with both archives, `SHA256SUMS`, and the version's section of
[CHANGELOG.md](CHANGELOG.md) as notes. Reservoir picks up version tags
(`v` followed by a digit) on its own.

1. Make sure CI passes on `main`.
2. Set the version in `lakefile.lean` (`version := v!"0.2.0"`).
3. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [0.2.0] - YYYY-MM-DD`
   and start a new, empty `## [Unreleased]` above it.
4. Commit both, then tag and push:

   ```
   git commit -am "Release 0.2.0"
   git tag -a v0.2.0 -m "leanprof 0.2.0"
   git push origin main v0.2.0
   ```

5. Watch the workflow (`gh run watch`) and check the release page.

Users of the GitHub Action can then pin it: `uses: unbalancedparentheses/leanprof@v0.2.0`.

If the workflow fails, fix it on `main`, delete the tag
(`git push origin :refs/tags/v0.2.0 && git tag -d v0.2.0`) and the release
if one was created (`gh release delete v0.2.0`), and tag again.

## Archives

`leanprof-vX.Y.Z-macos-arm64.tar.gz` and `leanprof-vX.Y.Z-linux-x86_64.tar.gz`
(built on Ubuntu 22.04, so glibc 2.35 or newer) contain:

```
leanprof-vX.Y.Z-PLATFORM/
  bin/leanprof              launcher: put this directory on PATH or symlink it
  .lake/build/bin/leanprof  the command itself
  c/leanprof.c              runtime, compiled for each project's Lean version
  scripts/leanprof-cc       compiler wrapper used by `leanprof run`
```

The command finds `c/` and `scripts/` relative to its real location, so
keep the directory together. It still needs Lean (through elan) and a C
compiler to profile a project, as when built from source.
