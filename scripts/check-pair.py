#!/usr/bin/env python3
"""Exercise real paired-process ordering, cwd, arguments, outputs and verdicts.

Timing verdicts use synthetic durations after collection: host scheduling must
not decide whether this integration test passes.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

cli = Path(sys.argv[1] if len(sys.argv) > 1 else '.lake/build/bin/leanprof').resolve()
with tempfile.TemporaryDirectory(prefix='leanprof-pair-') as temporary:
    root = Path(temporary)
    binary = root / 'program with spaces'
    binary.write_text(f'#!{sys.executable}\n' + '''
import json, os, pathlib, sys
config = json.loads(pathlib.Path('config.json').read_text())
assert sys.argv[2:] == ['literal ; $() argument'], sys.argv
with open(sys.argv[1], 'a') as stream:
    stream.write(config['side'] + '\\n')
if config.get('bench_ns') and 'LEANPROF_BENCH_OUT' in os.environ:
    with open(os.environ['LEANPROF_BENCH_OUT'], 'a') as bench:
        # a region that runs twice is summed; other names are ignored
        ns = config['bench_ns']
        bench.write(f"work\\t{ns // 2}\\nwork\\t{ns - ns // 2}\\nother\\t5\\n")
if config.get('write_output'):
    pathlib.Path('output.txt').write_text(config.get('output', 'same file'))
print(config.get('stdout', 'same stdout'))
print(config.get('stderr', 'same stderr'), file=sys.stderr)
raise SystemExit(config.get('exit_code', 0))
''')
    binary.chmod(0o755)
    dirs = {side: root / side for side in ['base', 'candidate']}
    for side, directory in dirs.items():
        directory.mkdir()
        (directory / 'config.json').write_text(json.dumps({'side': side}))
    result = root / 'pair.json'
    order = root / 'order.txt'

    def invoke(args, expected=0):
        proc = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True)
        assert proc.returncode == expected, (args, proc.returncode, proc.stdout, proc.stderr)
        return proc

    def measure(*extra, warmup=0):
        invoke(['measure-pair', '--base', binary, '--candidate', binary,
                '--base-cwd', dirs['base'], '--candidate-cwd', dirs['candidate'],
                '--runs', '6', '--warmup', str(warmup), '--out', result, *extra,
                '--', order, 'literal ; $() argument'])
        return json.loads(result.read_text())

    data = measure(warmup=1)
    expected = ['base', 'candidate']
    for pair in range(6):
        expected += ['base', 'candidate'] if pair % 2 == 0 else ['candidate', 'base']
    assert order.read_text().splitlines() == expected
    assert len(data['samples']) == 12
    assert [r['side'] for r in data['samples']] == expected[2:]
    assert all(r['time_ns'] > 0 for r in data['samples'])

    # Give overlapping ranges a consistent 10% paired improvement.
    data['machine']['overloaded'] = False
    for row in data['samples']:
        row['time_ns'] = (100 + 10 * row['pair']) * (100 if row['side'] == 'base' else 90)
    result.write_text(json.dumps(data))
    assert invoke(['judge', result]).stdout.startswith('KEEP\n')
    assert invoke(['judge', '--min-change', '15', result], 1).stdout.startswith('DISCARD\n')
    invoke(['judge', '--min-change', 'not-a-number', result], 2)

    # Check stale output deletion and per-side working directories.
    for side, directory in dirs.items():
        (directory / 'output.txt').write_text('stale output')
    data = measure('--check-output', 'output.txt')
    assert all(not r['output_present'] for r in data['samples'])
    invoke(['judge', result], 1)
    for side, directory in dirs.items():
        (directory / 'config.json').write_text(json.dumps({'side': side, 'write_output': True}))
    data = measure('--check-output', 'output.txt')
    assert all(r['output_present'] for r in data['samples'])
    assert len({r['output_hash'] for r in data['samples']}) == 1

    (dirs['candidate'] / 'config.json').write_text(json.dumps({'side': 'candidate', 'exit_code': 7}))
    measure()
    assert 'exit code 7' in invoke(['judge', result], 1).stdout
    invoke(['measure-pair', '--base', binary, '--candidate', binary,
            '--base-cwd', dirs['base'], '--candidate-cwd', dirs['candidate'],
            '--runs', '6', '--warmup', '1', '--out', result,
            '--', order, 'literal ; $() argument'], 2)
    # --scope: the region's reported time, summed per run; sequential: a
    # constant +10% stops at the first look that can decide (8 pairs of at most 30)
    for side, ns in [('base', 1_000_000), ('candidate', 1_100_000)]:
        (dirs[side] / 'config.json').write_text(json.dumps({'side': side, 'bench_ns': ns}))
    scoped = ['measure-pair', '--base', binary, '--candidate', binary,
              '--base-cwd', dirs['base'], '--candidate-cwd', dirs['candidate'], '--warmup', '0', '--out', result]
    tail = ['--', order, 'literal ; $() argument']
    proc = invoke(scoped + ['--scope', 'work'] + tail)
    data = json.loads(result.read_text())
    assert data['version'] == 2 and data['runs'] == 8 and data['scope'] == 'work', data['runs']
    assert data['design']['max_runs'] == 30
    assert {r['time_ns'] for r in data['samples']} == {1_000_000, 1_100_000}
    assert all(r['process_ns'] > 0 for r in data['samples'])
    assert 'scope work' in proc.stdout and 'stopped at 8 of at most 30' in proc.stdout, proc.stdout
    assert invoke(['judge', '--allow-overloaded', result], 1).stdout.startswith('DISCARD\n  - paired time of scope work: median change 10.00%')
    # --fixed: no early stop
    invoke(scoped + ['--scope', 'work', '--fixed', '--runs', '10'] + tail)
    data = json.loads(result.read_text())
    assert data['runs'] == 10
    # a sequential session that does not end at one of its looks is refused
    data['design'] = {**data['design'], 'first_look': 7, 'max_runs': 30}
    result.write_text(json.dumps(data))
    assert 'looks' in invoke(['judge', result], 2).stderr
    # a scope the program does not report is an error, not a time of zero
    proc = invoke(scoped + ['--scope', 'missing'] + tail, 2)
    assert 'did not report scope missing' in proc.stderr, proc.stderr
    invoke(['measure-pair', '--base', binary, '--candidate', binary, '--runs', '5'], 2)
    invoke(['measure-pair', '--base', binary, '--candidate', binary, '--min-change', 'x'], 2)
    invoke(['measure-pair', '--base', binary, '--candidate', binary, '--warmup', 'bad'], 2)
    invoke(['measure-pair', '--base', binary], 2)
print('paired CLI: order, warmups, paths, literal arguments, output checks, --scope, sequential stop and verdicts passed')
