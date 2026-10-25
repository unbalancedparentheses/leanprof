#!/usr/bin/env python3
"""Interleaved A/B timing: ab.py N -- DIR_A CMD_A... -- DIR_B CMD_B...
Runs A and B alternately N times each (after one warm-up of each) and reports
wall time and the child's user+sys CPU (rusage) per run."""
import os, resource, statistics, subprocess, sys, time

n = int(sys.argv[1])
rest = sys.argv[2:]
assert rest[0] == "--"
i = rest.index("--", 1)
cmds = {"A": (rest[1], rest[2:i]), "B": (rest[i + 1], rest[i + 2:])}
env = dict(os.environ)
env["PATH"] = os.path.expanduser("~/.elan/bin") + ":" + env["PATH"]
failed = set()

def run(k):
    d, cmd = cmds[k]
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t = time.perf_counter()
    p = subprocess.run(cmd, cwd=d, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    w = time.perf_counter() - t
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    if p.returncode and k not in failed:
        failed.add(k)
        print("exit", p.returncode, k, cmd, p.stderr.decode()[-500:], file=sys.stderr)
    return w, (r1.ru_utime - r0.ru_utime), (r1.ru_stime - r0.ru_stime)

for k in "AB":
    run(k)
res = {"A": [], "B": []}
for _ in range(n):
    for k in "AB":
        res[k].append(run(k))
for k in "AB":
    w = [x[0] for x in res[k]]; u = [x[1] for x in res[k]]; s = [x[2] for x in res[k]]
    print(f"{k}: wall median {statistics.median(w):.3f}s min {min(w):.3f}s mean {statistics.mean(w):.3f}s"
          f" | user median {statistics.median(u):.3f}s | sys median {statistics.median(s):.3f}s  (n={n})")
mw = {k: statistics.median([x[0] for x in res[k]]) for k in "AB"}
mn = {k: min([x[0] for x in res[k]]) for k in "AB"}
ms = {k: statistics.median([x[1] + x[2] for x in res[k]]) for k in "AB"}
print(f"B/A wall median {mw['B'] / mw['A']:.3f}, wall min {mn['B'] / mn['A']:.3f}, CPU (user+sys) median {ms['B'] / ms['A']:.3f}")
