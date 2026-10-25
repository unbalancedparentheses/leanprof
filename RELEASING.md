# Releasing

A release is a version tag. Pushing it runs
[`.github/workflows/release.yml`](.github/workflows/release.yml), which
builds the `leanprof` command on macOS arm64 and x86-64 and Linux x86-64 and
arm64, installs each
archive with [`scripts/install.sh`](scripts/install.sh) and profiles a
project outside this repository with it (`run`, `--allocs --counters
--frees`, `explain --why`, `elab`, and `sample` on macOS), packages the VS
Code extension, and creates a GitHub release with both archives, the
`.vsix`, `SHA256SUMS`, and the version's section of
[CHANGELOG.md](CHANGELOG.md) as notes. Reservoir picks up version tags
(`v` followed by a digit) on its own.

## Dry run

The same workflow runs without publishing anything on every push that
changes what a release is made of (the workflow, the install, packaging and
smoke-test scripts, the extension, `lakefile.lean`, `CHANGELOG.md`), and by
hand from the Actions tab (**Release > Run workflow**, optionally with a
version). It builds, installs, tests and packages exactly as for a tag,
checks that `CHANGELOG.md` has a section for the version, and keeps the
would-be release (archives, `.vsix`, `SHA256SUMS`, notes) as an artifact,
with the notes in the run's summary. Look at a green dry run of the commit
you are about to tag.

## Steps

1. Make sure CI, the Lean version matrix and a release dry run pass on
   `main`.
2. Set the version in `lakefile.lean` (`version := v!"0.2.0"`) and in
   `editors/vscode/package.json` (`"version": "0.2.0"`); the workflow
   refuses a tag that disagrees with either.
3. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [0.2.0] - YYYY-MM-DD`
   and start a new, empty `## [Unreleased]` above it.
4. Commit, then tag and push:

   ```
   git commit -am "Release 0.2.0"
   git tag -a v0.2.0 -m "leanprof 0.2.0"
   git push origin main v0.2.0
   ```

5. Watch the workflow (`gh run watch`) and check the release page. Then
   check the one-command install on a clean machine or account:

   ```
   curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh
   leanprof help
   ```

Users of the GitHub Action can then pin it: `uses: unbalancedparentheses/leanprof@v0.2.0`.

If the workflow fails, fix it on `main`, delete the tag
(`git push origin :refs/tags/v0.2.0 && git tag -d v0.2.0`) and the release
if one was created (`gh release delete v0.2.0`), and tag again.

## Assets

`leanprof-vX.Y.Z-macos-arm64.tar.gz` and `leanprof-vX.Y.Z-linux-x86_64.tar.gz`
(built on Ubuntu 22.04, so glibc 2.35 or newer), made by
[`scripts/package-release.sh`](scripts/package-release.sh), contain:

```
leanprof-vX.Y.Z-PLATFORM/
  bin/leanprof              launcher: put this directory on PATH or symlink it
  .lake/build/bin/leanprof  the command itself
  c/                        runtime source (leanprof.c, *.inc.c, headers),
                            compiled for each project's Lean version
  scripts/leanprof-cc       compiler wrapper used by `leanprof run`
```

The command finds `c/` and `scripts/` relative to its real location, so
keep the directory together. It still needs Lean (through elan) and a C
compiler to profile a project, as when built from source. The install
script unpacks it to `~/.local/share/leanprof/releases/` and puts a
`leanprof` launcher in `~/.local/bin`.

`leanprof-X.Y.Z.vsix` is the VS Code extension
([docs/guide/vscode.md](docs/guide/vscode.md)); it is not published to the
Marketplace. `SHA256SUMS` covers all three.

## Reservoir

[Reservoir](https://reservoir.lean-lang.org) indexes public, non-fork
GitHub repositories with a root `lake-manifest.json`, a license GitHub
recognizes as OSI-approved, and at least two stars. It reads the package's
`description`, `keywords`, `homepage`, `license` (an SPDX identifier),
`licenseFiles` and `readmeFile` from `lakefile.lean`, and treats tags that
start with `v` and a digit as versions.
