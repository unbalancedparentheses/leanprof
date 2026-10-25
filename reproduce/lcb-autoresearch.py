#!/usr/bin/env python3
"""docs/case-studies/autoresearch-lean-compiler-backend.md and
research/lcb/results/README.md; README "Reviewed result, still awaiting
independent replication".

Pinned: unbalancedparentheses/lean-compiler-backend at 854fcc2 (baseline),
f9ed557 (the 12 kept optimization commits) and ac8324e (the reviewed
candidate, now on its main); Lean 4.34.1 through elan (the published timing
used the project's pinned Nix environment, also Lean 4.34.1); the 17 zlib
units archived at 854fcc2.

Exact: the experiment's totals, measured on f9ed557 (not ac8324e, as the
case study says): allocations 7,719,273 -> 6,460,575, copies of shared
values 86,449 -> 38,911; and the 540 output/diagnostic comparisons of
854fcc2 against ac8324e (17 units x 5 targets x 4 option sets, plus 10
malformed inputs that both must reject) must all pass.

Timing: research/lcb/compare.py, 3 warm-up pairs and 30 alternating pairs of
the plain binaries. Published (Apple M5 Max, shared, load 6): 810.85 ->
630.76 ms, 22.21% less median wall time (paired median 25.74%). Accepted:
a reduction of 11% to 44% (half to twice); machines differ, and on a loaded
machine the spread is large. --no-timing skips it, --runs changes the count.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lcb  # noqa: E402
from lib import ROOT, WORK, Claim, build_leanprof, read_json, sh, timing  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--no-timing", action="store_true")
ap.add_argument("--runs", type=int, default=30)
a = ap.parse_args()

c = Claim("lcb-autoresearch", "Apple M5 Max, shared (load 25-40 for the counts, 6 for the timing)",
          "leanprof run --allocs / measure on 854fcc2, f9ed557; research/lcb/compare.py 854fcc2 vs ac8324e")
build_leanprof()
inp = lcb.inputs()
base = lcb.counts(lcb.checkout("854fcc2"), inp, "854fcc2")
head = lcb.counts(lcb.checkout("f9ed557"), inp, "f9ed557")
c.exact("854fcc2: allocations", base["allocs"], 7719273)
c.exact("f9ed557: allocations", head["allocs"], 6460575)
c.exact("f9ed557:   MiB allocated", round(head["alloc_mib"], 1), 167.7)
c.exact("854fcc2: copies of shared values", base["copies_total"], 86449)
c.exact("f9ed557: copies of shared values", head["copies_total"], 38911)
c.exact("f9ed557: output byte-identical with leanprof", head["same_output"], True)

cand = lcb.checkout("ac8324e")
bins = {"base": lcb.build(lcb.checkout("854fcc2")), "candidate": lcb.build(cand)}
out = os.path.join(WORK, "lcb-qualification")
cmd = [sys.executable, os.path.join(ROOT, "research", "lcb", "compare.py"), "--base", bins["base"],
       "--candidate", bins["candidate"], "--inputs", inp, "--out", out, "--runs", str(a.runs)]
if a.no_timing:
    cmd.append("--identity-only")
with timing():  # the identity checks too, when timing: they are short
    p = sh(cmd, check=False)
if not os.path.exists(os.path.join(out, "results.json")):
    print(p.stdout[-3000:], file=sys.stderr)
    sys.exit(2)
r = read_json(os.path.join(out, "results.json"))
ident = r.get("identity", [])
c.exact("output/diagnostic comparisons, 854fcc2 vs ac8324e", len(ident), 540)
c.exact("  all identical, malformed inputs rejected by both", r.get("passed"), True)
if not a.no_timing:
    m = r["median_seconds"]
    c.note("median wall time, 854fcc2 (ms)", round(1000 * m["base"], 2), 810.85)
    c.note("median wall time, ac8324e (ms)", round(1000 * m["candidate"], 2), 630.76)
    c.within(f"reduction in the two medians, {a.runs} runs each (timing)", 100 * (1 - m["candidate"] / m["base"]),
             11.0, 44.0, 22.21, "%")
    c.note("median of the paired reductions", round(r["paired_median_reduction_percent"], 2), 25.74)
    c.note("paired bootstrap 95% interval", [round(x, 2) for x in r["paired_bootstrap_95_percent_interval"]],
           "22.72-26.98")
    c.note("1-minute load at the start and end of the timing",
           [round((r.get(k) or [0])[0], 1) for k in ("load_start", "benchmark_load_end")], "6.23, 6.01")
c.finish()
