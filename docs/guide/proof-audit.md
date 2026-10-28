# Proof-preservation audit

An optimization that still compiles can weaken the theorem it was meant to
prove. This audit compares compiled declarations in baseline and candidate Git
checkouts and returns structured evidence before a caller considers a KEEP.
[`leanprof experiment try`](experiment.md) runs it as its guard, on the
changed modules and their dependents, with the source compiled into the
command; it is not wired into `leanprof fix`. It also runs on its own:

```sh
python3 /path/to/leanprof/scripts/proof-audit/audit.py \
  --base /path/to/baseline --candidate /path/to/candidate \
  --module MyProject.Proofs \
  --protect 'fixtures/expected/**' > /tmp/proof-audit.json
```

Repeat `--module` for each changed module; with none, only the file checks
below run (protected and uncovered files). Both checkouts must have the same
module names, Lean version and Lean compiler Git hash. Each must be the root of
its Git repository/worktree, with source modules at `MyProject/Proofs.lean`, or
at `SUBDIR/MyProject/Proofs.lean` with `--subdir SUBDIR` when the Lake package
is in a subdirectory (lean-regex's `regex/`). Custom Lake `srcDir`, unusual
quoted module names, Lean sources that are symbolic links and Git submodules
are currently unsupported; other symbolic links (Batteries' `docs/README.md`)
are recorded by their target, never followed. Both working trees may be dirty: their
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
  private ones. Changing its declaration kind fails. Declarations Lean
  generates for another one (a tactic's `_proof_1` lemma, `eq_1`, `eq_def`,
  `match_1`, `_unsafe_rec`, `_auxLemma`, …: `audit.generated`) are not
  obligations: a rewritten proof may remove them or change their statement,
  and `_unsafe_rec`, the compiled code of well-founded recursion, may be
  partial. Their axioms are still checked.
- Structural signatures are preserved. The collector uses kernel expressions,
  not pretty-printed types or source text. It erases binder spelling and source
  metadata, retaining universe parameters, binder kinds and expression structure.
- A theorem's statement dependencies retain their interpretation. The audit
  follows referenced definitions, inductives, constructors and recursor rules.
  For example, changing `def obligation n := n + 0 = n` to `True` cannot pass
  merely because the theorem's type still says `obligation n`.
- Existing declarations acquire no new transitive axiom dependencies. The
  types of the axioms they still use, and the definitions those refer to, are
  also checked (an axiom a proof no longer needs cannot weaken it). New declarations
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
supporting definition, or the removal of a declaration it does not recognise as
generated may therefore yield `INCONCLUSIVE` or `FAIL`. Neither permits an automatic KEEP. A future equivalence
checker can discharge specific inconclusive cases against preserved dependencies.

`PASS` concerns theorem declarations and their assumptions in the selected
modules. It does not establish equivalence of executable definitions, preserve
runtime validation branches, audit every downstream module, or prove that tests
are adequate. Ignored files and installed toolchain/dependency artifacts are not
part of the Git source inventory; this is not a hermetic build or a defense
against tampered `.olean` files. It is meant for module-sized experiments; `leanprof
experiment` passes it the changed modules and every module of the package that
imports them.

The integration is additive, as `leanprof experiment` does it: the caller
requires **both** audit `PASS` and its normal correctness checks, then measures
the candidate and judges the result. Any audit `FAIL` or `INCONCLUSIVE` prevents
KEEP (the experiment accepts one finding alone, `no_theorems`: no statement to
weaken, see [the guard](experiment.md#the-guard)). The experiment keeps the JSON
with its evidence (`tries/N/audit.json`). Do not use
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
