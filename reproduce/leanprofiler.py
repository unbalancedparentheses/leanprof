#!/usr/bin/env python3
"""bench/README.md, "Overhead benchmark against LeanProfiler" and "Why
LeanProfiler's cost grows"; README "Overhead against LeanProfiler".

Pinned: LeanProfiler 35e1899 (bench/lakefile.toml), Lean 4.35.0. Published
on an Apple M5 Max shared with other jobs (load average 25), three runs each:

  exact   `LEAN_PROFILE=1 leanprof run bench -- leanprofiler 1 4000`: 12,003
          copies in LeanProfiler.Internal.reserveSpan, 8,002 in completeSpan
  timing  leanprof 7.3-8.9 ns per scope (1 thread, n = 1M), 8.2-11.8 ns (4 threads);
          LeanProfiler recording off 24.7-26.8 ns (1 thread), 419-495 ns (4 threads);
          LeanProfiler recording on 4.6 / 20.1 / 88.5 us per span at 1,000 /
          4,000 / 16,000 events; leanprof over the same counts 8.9-17.8 ns.

Accepted ranges for timings are wide (machines differ): half to twice the
published value, and the shape of the claim checked on its own: LeanProfiler's
span cost at 16,000 events is at least 8 times its cost at 1,000 (it grows
with the events), leanprof's stays under 50 ns at every count (constant).
"""
import argparse
import os
import re
import shutil
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import LP, ROOT, WORK, Claim, build_leanprof, read_json, sh  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--exact-only", action="store_true", help="only the copy counts (CI)")
ap.add_argument("--runs", type=int, default=3)
a = ap.parse_args()

BENCH = os.path.join(ROOT, "bench")
c = Claim("leanprofiler", "Apple M5 Max, shared, load average 25 (bench/README.md)",
          "bench leanprof|leanprofiler THREADS N; leanprof run bench -- leanprofiler 1 4000")
build_leanprof()
sh(["lake", "build", "bench"], cwd=BENCH)
exe = os.path.join(BENCH, ".lake", "build", "bin", "bench")
work = os.path.join(WORK, "leanprofiler")
os.makedirs(work, exist_ok=True)

# exact: every span copies every event recorded so far
out = os.path.join(work, "copies.json")
had_build = os.path.exists(os.path.join(BENCH, "build"))
sh([LP, "run", "--json", out, "bench", "--", "leanprofiler", "1", "4000"], cwd=BENCH,
   env={"LEAN_PROFILE": "1", "LEANPROF_QUIET": "1"})
if not had_build:  # LeanProfiler writes its trace and summary to ./build
    shutil.rmtree(os.path.join(BENCH, "build"), ignore_errors=True)
# the two rows bench/README.md shows (by copy site; reserveSpan has a second
# site, its own Array.push, with 4,001 more, not in the published table)
cp = {(x["function"], x["where"].split("LeanProfiler/", 1)[-1]): x for x in read_json(out)["copies"]}
for fn, where, n in [("LeanProfiler.Internal.reserveSpan (in Std.DHashMap.Internal.Raw₀.insert)",
                      "LeanProfiler/Runtime/Capture.lean:65", 12003),
                     ("LeanProfiler.Internal.completeSpan", "LeanProfiler/Runtime/Capture.lean:94", 8002)]:
    x = cp.get((fn, where), {})
    c.exact(f"copies, {fn.replace('LeanProfiler.Internal.', '')} (4,000 spans)", x.get("copies"), n)
    c.exact("  all of multi-threaded or persistent values",
            x.get("multi_threaded", 0) + x.get("persistent", 0) == n and x.get("shared") == 0, True)

if not a.exact_only:
    def per_action(tool, threads, n, record=False):
        vals = []
        for _ in range(a.runs):
            env = {"LEAN_PROFILE": "1"} if record else {}
            p = sh([exe, tool, str(threads), str(n)], cwd=work, env=env)
            vals.append(float(re.search(r": (-?[0-9.e+]+) ns per action", p.stdout).group(1)))
        return vals

    def chk(what, vals, lo_pub, hi_pub, unit="ns", scale=1.0):
        m = statistics.median(vals) / scale
        pub = (lo_pub + hi_pub) / 2
        c.within(what + f" (timing; runs {', '.join(f'{v / scale:.1f}' for v in vals)})", m,
                 lo_pub / 2, hi_pub * 2, pub, " " + unit)
        return m

    chk("leanprof, 1 thread, n=1M", per_action("leanprof", 1, 1_000_000), 7.3, 8.9)
    chk("leanprof, 4 threads, n=1M", per_action("leanprof", 4, 1_000_000), 8.2, 11.8)
    chk("LeanProfiler recording off, 1 thread, n=1M", per_action("leanprofiler", 1, 1_000_000), 24.7, 26.8)
    chk("LeanProfiler recording off, 4 threads, n=1M", per_action("leanprofiler", 4, 1_000_000), 419, 495)
    on = {}
    for n, pub in ((1000, 4.6), (4000, 20.1), (16000, 88.5)):
        on[n] = chk(f"LeanProfiler recording on, {n:,} events, per span",
                    per_action("leanprofiler", 1, n, record=True), pub, pub, "us", 1000.0)
    c.within("LeanProfiler: span cost at 16,000 events / at 1,000 (grows)", on[16000] / on[1000],
             8.0, 1e9, 88.5 / 4.6, "x")
    lp_max = 0.0
    for n, lo, hi in ((1000, 15.9, 17.8), (4000, 8.9, 17.0), (16000, 10.0, 11.6)):
        lp_max = max(lp_max, chk(f"leanprof over {n:,} actions", per_action("leanprof", 1, n), lo, hi))
    c.within("leanprof: worst cost per scope at those counts (constant)", lp_max, 0.0, 50.0, 17.8, " ns")
c.finish()
