#!/usr/bin/env python3
"""bench/README.md and bench/RESULTS.md (the accuracy table); README "Sampling",
"Overhead against LeanProfiler" (about 6-7 ns per scope on the Mac) and
"Time of tiny functions in the exact modes".

Runs bench/run.py (7 runs of six workloads with known ground truth, every
configuration interleaved; about 5 minutes on an M5 Max), its reports
written outside the tree, then:

  exact   every leanprof mode's call and copy counts equal the program's own,
          on every workload (run.py --check);
  timing  each headline cell (error in share of time, percentage points, for
          profile!, run --auto, sample, samply, LeanProfiler) within
          max(2 x published, published + 1 pp) of bench/results.json, the
          published run (Apple M5 Max, shared, load 2-4, leanprof 4bdc762);
          the cost per scope on `tiny` (profile!) within 4-17 ns (published
          6.3 ns); run.py's own band for reported totals (0.75-1.35).

samply must be installed for the sample and samply columns (they are
reported as skipped otherwise, and those checks fail).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import ROOT, WORK, Claim, build_leanprof, read_json, sh, timing  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--reps", type=int, default=7)
a = ap.parse_args()

c = Claim("bench-suite", "Apple M5 Max, shared, load 2-4 (bench/RESULTS.md, bench/results.json)",
          f"python3 bench/run.py --reps {a.reps} --check")
build_leanprof()
os.makedirs(WORK, exist_ok=True)
md, js = os.path.join(WORK, "bench-RESULTS.md"), os.path.join(WORK, "bench-results.json")
with timing():
    p = sh([sys.executable, os.path.join(ROOT, "bench", "run.py"), "--reps", str(a.reps), "--noisy",
        "--check", "--md", md, "--json", js], check=False)
if not os.path.exists(js):
    print(p.stdout[-3000:], file=sys.stderr)
    sys.exit(2)
fails = [ln.split("CHECK FAILED: ", 1)[1] for ln in p.stdout.splitlines() if "CHECK FAILED: " in ln]
exact_fails = [f for f in fails if "reported total" not in f]
c.exact("call and copy counts exact in every leanprof mode and workload (run.py --check)", exact_fails, [])
c.exact("reported totals within run.py's band 0.75-1.35 where scopes do real work",
        [f for f in fails if "reported total" in f], [])
got, pub = read_json(js), read_json(os.path.join(ROOT, "bench", "results.json"))
c.note("skipped configurations", got.get("skipped", {}))
for cfg in ("profile", "auto", "sample", "samply", "leanprofiler"):
    for w in ("tiny", "rec", "mix", "alloc", "copy", "tasks"):
        want = pub["results"][w]["configs"][cfg]["share_mae_pp"]
        have = got["results"].get(w, {}).get("configs", {}).get(cfg, {}).get("share_mae_pp")
        c.within(f"share error, {cfg}, {w} (timing)", have, 0.0, max(2 * want, want + 1.0), round(want, 1), " pp")
ns = got["results"]["tiny"]["configs"]["profile"].get("ns_per_scope")
c.within("cost per scope, tiny, profile! (timing)", ns, 4.0, 17.0,
         round(pub["results"]["tiny"]["configs"]["profile"]["ns_per_scope"], 1), " ns")
c.finish()
