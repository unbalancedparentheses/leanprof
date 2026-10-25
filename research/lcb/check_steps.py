#!/usr/bin/env python3
"""Run every LCB check.sh stage, retaining logs and baseline-comparable failures.

Run inside `nix develop --command python3 ...` with --repo and --out.
The proof-audit prelude remains a single strict stage; subsequent test commands
run independently so a host-specific failure cannot hide later failures.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--repo', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = (repo / 'scripts/check.sh').read_text()
    prelude, rest = source.split('python3 scripts/test.py "$@"', 1)
    stages = [('identity, unit tests, CLI, inventory, proof audit', prelude)]
    stages += [(line, 'set -euo pipefail\n' + line + '\n')
               for line in ('python3 scripts/test.py "$@"' + rest).splitlines()
               if line.strip() and not line.startswith('#')]
    results = []
    for index, (name, script) in enumerate(stages):
        start = time.monotonic()
        log = out / f'{index:03d}.log'
        with log.open('w') as stream:
            result = subprocess.run(['bash', '-s', '--', '--require-native'],
                                    input=script, text=True, cwd=repo,
                                    stdout=stream, stderr=subprocess.STDOUT)
        row = dict(stage=name, exit_code=result.returncode,
                   seconds=time.monotonic() - start, log=log.name)
        results.append(row)
        (out / 'steps.json').write_text(json.dumps(results, indent=2) + '\n')
        print(f'{index + 1}/{len(stages)} exit={result.returncode} {name}', flush=True)
    raise SystemExit(bool(any(r['exit_code'] for r in results)))


if __name__ == '__main__':
    main()
