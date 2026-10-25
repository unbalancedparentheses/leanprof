# Proof-preservation audit (standalone prototype)

An optimization that still compiles can weaken the theorem it was meant to
prove. This audit compares compiled declarations in baseline and candidate Git
checkouts and returns structured evidence before a caller considers a KEEP.
It is independent of `leanprof fix`; it is **not yet wired into that command**.

```sh
python3 /path/to/leanprof/scripts/proof-audit/audit.py \
  --base /path/to/baseline --candidate /path/to/candidate \
  --module MyProject.Proofs \
  --protect 'fixtures/expected/**' > /tmp/proof-audit.json
```

Repeat `--module` for each changed module. Both checkouts must have the same
module names, Lean version and Lean compiler Git hash. Each must be the root of
its Git repository/worktree, with source modules at `MyProject/Proofs.lean`.
Custom Lake `srcDir`, unusual quoted module names, source symlinks and Git
submodules are currently unsupported. Both working trees may be dirty: their
actual file contents, including nonignored untracked files, are fingerprinted.

The command runs `lake build MODULE...` in each checkout and then runs the
collector using that project's `lake env lean`. Build/module initializers run
as usual; this is a trusted-project tool, not a sandbox for hostile Lean code.
It does not switch branches, edit source, commit, judge performance or run the
project's tests. Each subprocess has a 300-second default timeout; use
`--timeout SECONDS` to change it. Timeout or interruption terminates its process
group, including compiler children, on the supported Unix platforms.

Build the checkouts once before auditing if Lake needs to generate a manifest.
A source/manifest change during collection causes an inconclusive result; retry
on stable checkouts. Save the JSON outside both audited checkouts.

## Result contract

| Status | Exit | Meaning |
|---|---:|---|
| `PASS` | 0 | The scoped checks below established preservation. |
| `FAIL` | 1 | A protected obligation or policy was violated. |
| `INCONCLUSIVE` | 2 | Evidence is incomplete, incompatible, stale, or insufficient to establish preservation. |

Every JSON result has `schema: 1`, `status`,
`scope: "selected-module-proof-preservation"`, and a `findings` array.
Each finding has a machine-readable `code`, `status`, `subject`, and explanatory
`detail`. A proven failure takes precedence over inconclusive findings; all
findings remain in the report. Collection failures, including missing tools,
build failures and timeouts, return `INCONCLUSIVE`, never `PASS`.

Successful collection also records selected modules, checked declaration and
statement-dependency counts, changed files, protected patterns and per-checkout
provenance: revision, per-file SHA-256, aggregate source fingerprint, collector
SHA-256, snapshot SHA-256, Lean version and compiler Git hash. Snapshots are
collected in memory, not accepted from arbitrary user-provided JSON. The hash
records which evidence was compared; it is not a signed attestation.

## What it checks

- Every baseline declaration in the selected modules remains present, including
  private/generated declarations. Changing its declaration kind fails.
- Structural signatures are preserved. The collector uses kernel expressions,
  not pretty-printed types or source text. It erases binder spelling and source
  metadata, retaining universe parameters, binder kinds and expression structure.
- A theorem's statement dependencies retain their interpretation. The audit
  follows referenced definitions, inductives, constructors and recursor rules.
  For example, changing `def obligation n := n + 0 = n` to `True` cannot pass
  merely because the theorem's type still says `obligation n`.
- Existing declarations acquire no new transitive axiom dependencies. Axiom
  types and the definitions they refer to are also checked. New declarations
  cannot introduce axioms beyond the selected baseline's existing axiom set.
- Candidate declarations in selected modules must not depend on `sorryAx`.
  Adding an axiom in those modules fails even if it is unused.
- New or changed `implemented_by`, `extern`, unsafe and partial flags in the
  imported environment fail. Existing standard-library overrides are allowed.
  This includes attributes placed on imported declarations, even if no selected
  theorem references them. A new import can conservatively trigger this check.
- Protected files cannot be added, edited or removed. Defaults cover `Tests/`,
  `tests/`, `test/`, and `expected/` at the root, plus nested `Tests/`, `tests/`
  and `expected/` paths. `--protect` adds globs; it cannot disable the defaults.
- Every changed inventoried file must be a selected root-layout Lean module or
  a protected file. Other changes yield `INCONCLUSIVE`; this deliberately catches
  unselected modules, dependency manifests, build settings and native code.
- Source fingerprints and revisions are checked around collection and again
  after both snapshots. Empty evidence, missing dependency records, different
  toolchains and selected modules without any baseline theorem do not pass.

## Limits and integration

This first version recognizes structural equality after binder-name/metadata
erasure. It does **not** attempt general cross-environment definitional equality.
A different but equivalent statement, a renamed universe parameter, a changed
supporting definition, or the removal of a generated helper may therefore yield
`INCONCLUSIVE` or `FAIL`. Neither permits an automatic KEEP. A future equivalence
checker can discharge specific inconclusive cases against preserved dependencies.

`PASS` concerns theorem declarations and their assumptions in the selected
modules. It does not establish equivalence of executable definitions, preserve
runtime validation branches, audit every downstream module, or prove that tests
are adequate. Ignored files and installed toolchain/dependency artifacts are not
part of the Git source inventory; this is not a hermetic build or a defense
against tampered `.olean` files. The prototype is intended for small, controlled
module experiments before attempting whole-library coverage.

The intended integration is additive: the caller requires **both** audit `PASS`
and its normal correctness checks, then measures the candidate and judges the
result. Any audit `FAIL` or `INCONCLUSIVE` prevents KEEP. Preserve the JSON with
the experiment ID and recheck source fingerprints before committing. Do not use
this result to waive output comparisons, configured tests, downstream builds or
performance measurements.

## Development

```sh
lake env lean scripts/proof-audit/Snapshot.lean
python3 -B Tests/ProofAudit/check.py
```

The tests create temporary independent Git/Lake projects and compile actual
Lean examples: valid proof changes, binder renames, direct and indirect statement
weakening, new/unused axioms, `sorry`, `native_decide` trust increases, runtime
overrides, removed declarations, comments
and strings, protected-file additions/edits/deletions, missing evidence, uncovered
source edits, source changes during collection, process-group timeout cleanup,
and the CLI's three exit statuses.
