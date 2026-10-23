#!/usr/bin/env python3
"""Overhead of leanprof's live channel and flight recorder.

    python3 bench/live-overhead.py [BASE_OVERHEAD_EXE]

Runs Examples/Overhead (10 million `profile!` scopes) with the live channel
off, with LEANPROF_LIVE, and with the flight recorder, and reports the cost
per scope of each, best of 7 runs. With BASE_OVERHEAD_EXE (the same example
built from a commit before the live channel existed) it also compares the
off case against it. Then it measures the background thread's CPU per
snapshot on Examples/Server (a mostly idle program), from the process's
CPU time with and without LEANPROF_LIVE_MS=10.
"""
import os
import re
import resource
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, ".lake", "build", "bin")
tmp = tempfile.mkdtemp()


def per_scope(exe, env, runs=7):
    best = None
    for _ in range(runs):
        out = subprocess.run([exe, "10000000"], env=dict(os.environ, LEANPROF_QUIET="1", **env),
                             capture_output=True, text=True, check=True).stdout
        plain = float(re.search(r"plain loop\s+([\d.]+) ms", out).group(1))
        prof = float(re.search(r"profiled loop\s+([\d.]+) ms", out).group(1))
        ns = (prof - plain) * 1e6 / 1e7
        best = ns if best is None else min(best, ns)
    return best


def cpu_of(cmd, env):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    subprocess.run(cmd, env=dict(os.environ, LEANPROF_QUIET="1", **env), stdout=subprocess.DEVNULL, check=True)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)


overhead = os.path.join(BIN, "overhead")
rows = [("off", {}),
        ("LEANPROF_LIVE (250 ms)", {"LEANPROF_LIVE": os.path.join(tmp, "live.json")}),
        ("LEANPROF_LIVE_MS=10", {"LEANPROF_LIVE": os.path.join(tmp, "live.json"), "LEANPROF_LIVE_MS": "10"}),
        ("LEANPROF_FLIGHT", {"LEANPROF_FLIGHT": tmp})]
print("cost per profile! scope, best of 7 runs of 10M scopes")
if len(sys.argv) > 1:
    print(f"  {'before the live channel (off)':34} {per_scope(sys.argv[1], {}):6.1f} ns")
for name, env in rows:
    print(f"  {name:34} {per_scope(overhead, env):6.1f} ns")

server = [os.path.join(BIN, "server"), "100", "0"]  # 100 requests of ~10 ms, mostly sleeping
base = min(cpu_of(server, {}) for _ in range(3))
live = min(cpu_of(server, {"LEANPROF_LIVE": os.path.join(tmp, "s.json"), "LEANPROF_LIVE_MS": "10"}) for _ in range(3))
snaps = 100 * 0.0105 / 0.010  # about one snapshot per 10 ms over the ~1.05 s run
print(f"background thread: {(live - base) * 1e3:.1f} ms CPU for ~{snaps:.0f} snapshots "
      f"= {(live - base) * 1e6 / snaps:.0f} µs per snapshot (Examples/Server, 4 scope rows)")
