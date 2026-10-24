# Qualifying the compiler autoresearch result

These scripts reproduce the plain-build timing and correctness comparison in
the [case study](../../docs/case-studies/autoresearch-lean-compiler-backend.md).
They use Python's standard library and invoke the binaries directly.
The [reviewed results and raw evidence](results/README.md) are saved alongside them.

The baseline is `854fcc2` in `unbalancedparentheses/lean-compiler-backend`.
The original optimization head is `f9ed557`. The reviewed candidate is
`ac8324e`, which retains the optimization series and restores validation on
memory promotion's already-SSA path. Build both sides from clean checkouts:

```sh
git clone https://github.com/unbalancedparentheses/lean-compiler-backend.git lcb
git -C lcb worktree add --detach ../lcb-base 854fcc2
git -C lcb worktree add --detach ../lcb-candidate ac8324e
(cd lcb-base && nix develop --command lake build lcb lcb-tests)
(cd lcb-candidate && nix develop --command lake build lcb lcb-tests)
```

The exact 17 input files already live, compressed, in the baseline repository.
They were verified byte-for-byte against the original experiment inputs. Extract
them without needing to regenerate C frontend output:

```sh
mkdir -p zlib-inputs
python3 - <<'PY'
from pathlib import Path
import gzip
source = Path('lcb-base/docs/benchmarks/arm-scaled-load/private/zlib/ir')
for path in source.glob('*.ssa.gz'):
    (Path('zlib-inputs') / path.stem).write_bytes(gzip.decompress(path.read_bytes()))
PY
```

Set `LEANPROF_RESEARCH` to the absolute path of this directory. Once other builds
and tests have finished, run:

```sh
python3 "$LEANPROF_RESEARCH/compare.py" \
  --base lcb-base/.lake/build/bin/lcb \
  --candidate lcb-candidate/.lake/build/bin/lcb \
  --inputs zlib-inputs --out qualification
```

The default is three warmups and 30 measured runs per binary, with AB/BA order
alternating each pair. The report includes raw wall times, load averages,
platform, CPU count, binary hashes, compiler build identities, and input hashes.
It gives a paired median reduction and a seeded bootstrap interval over pairs.
That interval describes variability in this session, not independent replication.

After timing, it compares assembly, stdout, stderr and exit status for all 17
inputs × five targets × four option sets (340 cases), then ten malformed inputs
under the same settings (200 cases), requiring both sides to reject them.
Use `--identity-only` or `--benchmark-only` to separate these phases. Inputs are
passed through stdin so checkout paths cannot change diagnostics.

Run the complete compiler checks separately on each checkout:

```sh
(cd lcb-base && nix develop --command python3 "$LEANPROF_RESEARCH/check_steps.py" \
  --repo . --out ../qualification-base-checks)
(cd lcb-candidate && nix develop --command python3 "$LEANPROF_RESEARCH/check_steps.py" \
  --repo . --out ../qualification-candidate-checks)
```

`check_steps.py` retains the strict build-identity, unit-test, CLI and proof-audit
prelude. It then runs every remaining command from `scripts/check.sh` separately
and saves its exit status and log, continuing after failures. A nonzero exit
means at least one stage failed; inspect both sides, not just the total. It
passes `--require-native` to the commands that accept it. On this study's macOS
host, cross-target script success may mean a documented platform skip; consult
the logs and Linux CI before claiming cross-platform execution.

The check runner depends on the layout of `scripts/check.sh` at these commits.
It is deliberately a case-study reproduction tool rather than a general shell
parser or a new `leanprof judge` implementation.
