#!/usr/bin/env python3
"""Reproduce the plain-build zlib comparison and output/diagnostic identity checks.

Supply freshly built binaries and the original 17 zlib SSA inputs. No profiler
is invoked. Benchmark first on an otherwise idle machine, then check identity.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import time

TARGETS = ['aarch64-macos', 'aarch64-linux', 'x86_64-linux',
           'x86_64-macos', 'riscv64-linux']
FLAGS = [[], ['--optimize'], ['--allocate'], ['--optimize', '--allocate']]
MALFORMED = {
    'undefined': 'function l $f() { @s ret %missing }',
    'promotion_undefined': 'function l $f() { @s %p =l alloc8 8 storel 17,%p %r =l loadl %p ret %missing }',
    'duplicate_label': 'function l $f() { @s ret 1 @s ret 2 }',
    'unknown_target': 'function l $f() { @s jmp @missing }',
    'entry_target': 'function l $f() { @s jmp @s }',
    'wrong_return': 'function l $f(s %x) { @s ret %x }',
    'bad_phi': 'function l $f(w %c) { @s jnz %c,@a,@b @a jmp @end @b jmp @end @end %r =l phi @a 1 ret %r }',
    'bad_dominance': 'function l $f(w %c) { @s jnz %c,@a,@b @a %v =l copy 1 jmp @end @b jmp @end @end ret %v }',
    'duplicate_parameter': 'function l $f(l %x,l %x) { @s ret %x }',
    'syntax': 'not valid IL',
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--base', type=Path, required=True)
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--inputs', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--runs', type=int, default=30)
    ap.add_argument('--warmup', type=int, default=3)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--identity-only', action='store_true')
    mode.add_argument('--benchmark-only', action='store_true')
    args = ap.parse_args()
    if args.runs < 2 or args.warmup < 0:
        ap.error('need at least two measured runs and nonnegative warmup')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    inputs = args.inputs.resolve()
    expected_inputs = set(('adler32 compress crc32 deflate gzclose gzlib gzread '
                           'gzwrite infback inffast inflate inftrees test-example '
                           'test-minigzip trees uncompr zutil').split())
    if {p.stem for p in inputs.glob('*.ssa')} != expected_inputs:
        ap.error('--inputs must contain exactly the 17 original zlib SSA files')
    binaries = {'base': args.base.resolve(), 'candidate': args.candidate.resolve()}
    env = {k: v for k, v in os.environ.items() if not k.startswith('LEANPROF_')}
    report = dict(platform=platform.platform(), cpu_count=os.cpu_count(),
                  load_start=os.getloadavg(), runs=[], identity=[],
                  binaries={k: {'path': str(p), 'sha256': digest(p.read_bytes()),
                                'build_identity': subprocess.check_output(
                                    [str(p), '--build-identity'], text=True).strip()}
                            for k, p in binaries.items()},
                  inputs={p.name: digest(p.read_bytes()) for p in sorted(inputs.glob('*.ssa'))})

    def save():
        (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')

    def run(which, options, source=None):
        target = out / 'output.s'
        target.unlink(missing_ok=True)
        start = time.perf_counter()
        proc = subprocess.run([str(binaries[which]), *options, '-o', str(target)],
                              input=source, capture_output=True, env=env, timeout=120)
        elapsed = time.perf_counter() - start
        signature = dict(exit_code=proc.returncode, stdout=digest(proc.stdout),
                         stderr=digest(proc.stderr),
                         assembly=digest(target.read_bytes()) if target.exists() else None)
        return elapsed, signature

    if not args.identity_only:
        options = ['--target', TARGETS[0], '--optimize', '--allocate'] + [
            str(inputs / (name + '.ssa')) for name in ['deflate', 'inflate', 'trees', 'crc32']]
        report['benchmark_arguments'] = options
        expected = None
        for pair in range(-args.warmup, args.runs):
            for which in (['base', 'candidate'] if pair % 2 == 0 else ['candidate', 'base']):
                elapsed, signature = run(which, options)
                if signature['exit_code'] != 0:
                    raise RuntimeError(f'{which} benchmark failed: {signature}')
                expected = signature if expected is None else expected
                if signature != expected:
                    raise RuntimeError('benchmark output/diagnostics differ')
                if pair >= 0:
                    report['runs'].append(dict(pair=pair, variant=which,
                                              seconds=elapsed, load=os.getloadavg()))
        report['benchmark_signature'] = expected
        medians = {k: statistics.median(r['seconds'] for r in report['runs']
                                      if r['variant'] == k) for k in binaries}
        report['median_seconds'] = medians
        ratios = [next(r['seconds'] for r in report['runs'] if r['pair'] == i and r['variant'] == 'candidate') /
                  next(r['seconds'] for r in report['runs'] if r['pair'] == i and r['variant'] == 'base')
                  for i in range(args.runs)]
        rng = random.Random(0)
        bootstrap = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
        report['paired_median_reduction_percent'] = 100 * (1 - statistics.median(ratios))
        report['paired_bootstrap_95_percent_interval'] = [100 * (1-bootstrap[9750]), 100 * (1-bootstrap[250])]
        report['benchmark_load_end'] = os.getloadavg()
        save()
        print(json.dumps({k: report[k] for k in ['median_seconds', 'paired_median_reduction_percent',
                                               'paired_bootstrap_95_percent_interval']}), flush=True)

    if args.benchmark_only:
        return

    for name, source in [(p.name, p.read_bytes()) for p in sorted(inputs.glob('*.ssa'))] + [
            (name, source.encode()) for name, source in MALFORMED.items()]:
        for target in TARGETS:
            for flags in FLAGS:
                options = ['--target', target, *flags, '-']
                signatures = {k: run(k, options, source)[1] for k in binaries}
                same = signatures['base'] == signatures['candidate']
                refused = name not in MALFORMED or all(s['exit_code'] != 0 for s in signatures.values())
                report['identity'].append(dict(input=name, target=target, flags=flags,
                                               same=same, expected_rejection=refused, signatures=signatures))
        save()
        print(f'checked {name}', flush=True)
    report['load_end'] = os.getloadavg()
    report['passed'] = all(r['same'] and r['expected_rejection'] for r in report['identity'])
    save()
    print(f"{len(report['identity'])} comparisons; passed={report['passed']}", flush=True)
    raise SystemExit(not report['passed'])


if __name__ == '__main__':
    main()
