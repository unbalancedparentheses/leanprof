#!/usr/bin/env python3
"""docs/case-studies/leanbench.md; README "Exact regression checks" and "Small slowdowns".

Pinned: LeanBench 250d2a8 (bench/leanbench/project/lakefile.toml), the
workload bench/leanbench/project, Lean 4.35.0.

Exact (any machine): a hidden copy of a 64-element array per round is 0 ->
1,980 copies per `work` run and judge DISCARDs it on copies; the `alloc`
variant is 46,214 -> 48,214 allocations (+2,000) and `report-md --fail-on
allocs` fails on it. Both change time by under 1%.

Timing (--timing; published on a dedicated, idle AMD Ryzen 9 7950X3D):
leanprof `judge` caught the 2.4% slowdown 5/5 (rerun with --min-change, the
default now) with 0 false verdicts in 20 unchanged pairs; LeanBench at a 5%
threshold caught 0/5 of the 2.4% and 2/5 of the 4.8% slowdowns. Takes about
15 minutes on a quiet machine; on a loaded one (load above the CPU count)
leanprof refuses to judge time, so detection fails by design.
"""
import argparse
import importlib.util
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import LP, ROOT, WORK, Claim, build_leanprof, read_json, sh, timing  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--timing", action="store_true", help="also the detection trials (~15 min, quiet machine)")
ap.add_argument("--noise-trials", type=int, default=20)
ap.add_argument("--trials", type=int, default=5)
a = ap.parse_args()

PROJ = os.path.join(ROOT, "bench", "leanbench", "project")
c = Claim("leanbench", "exact: any machine; timing: dedicated AMD Ryzen 9 7950X3D (case study)",
          "leanprof measure/judge, run --allocs, report-md on bench/leanbench/project")
build_leanprof()
sh(["lake", "build", "work", "bench"], cwd=PROJ)
work = os.path.join(WORK, "leanbench")
os.makedirs(work, exist_ok=True)


def measure(variant):
    out = os.path.join(work, f"measure-{variant}.json")
    sh([LP, "measure", "--runs", "1", "--warmup", "0", "--out", out, "work"], cwd=PROJ,
       env={"LB_VARIANT": variant, "LEANPROF_QUIET": "1"})
    return out


def allocs(variant):
    out = os.path.join(work, f"allocs-{variant}.json")
    sh([LP, "run", "--allocs", "--json", out, "work"], cwd=PROJ, env={"LB_VARIANT": variant, "LEANPROF_QUIET": "1"})
    return out


mb, mc = measure("base"), measure("copy")
c.exact("copies per `work` run, base", read_json(mb)["copies_total"], 0)
c.exact("copies per `work` run, copy variant", read_json(mc)["copies_total"], 1980)
j = sh([LP, "judge", mb, mc], cwd=PROJ, check=False)
# the verdict line (stderr is merged in: skip anything printed before it)
first = next((ln for ln in j.stdout.splitlines() if ln.startswith(("KEEP", "DISCARD"))), "")
c.exact("judge base -> copy: DISCARD, on copies",
        first.startswith("DISCARD") and "- copies: 0 -> 1,980" in j.stdout, True)
ab, aa = allocs("base"), allocs("alloc")
na = [sum(x["allocs"] for x in read_json(p)["allocations"]) for p in (ab, aa)]
c.exact("allocations per `work` run, base", na[0], 46214)
c.exact("allocations per `work` run, alloc variant", na[1], 48214)
rm = sh([LP, "report-md", "--fail-on", "allocs", ab, aa], cwd=PROJ, check=False)
c.exact("report-md --fail-on allocs fails on +2,000 allocations", rm.returncode != 0, True)
rm0 = sh([LP, "report-md", "--fail-on", "allocs", ab, ab], cwd=PROJ, check=False)
c.exact("  and passes on base against itself", rm0.returncode, 0)

if a.timing:
    # the case study's own trial code (bench/leanbench/run.py), results kept out of the tree
    spec = importlib.util.spec_from_file_location("lbrun", os.path.join(ROOT, "bench", "leanbench", "run.py"))
    run = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(run)
    run.RES = work

    class Args:
        samples, runs, tools, leanprof, allocs = 20, 5, "lb,lp", LP, False

    def trials(variant, n):
        import tempfile
        recs = []
        with tempfile.TemporaryDirectory() as tmp:
            for i in range(n):
                with timing():
                    r = run.trial(Args, variant, i, tmp)
                print(f"   {variant} #{i}: LeanBench {r['lb']['delta_pct']:+.1f}%, leanprof "
                      f"{r['lp']['delta_pct']:+.1f}% {r['lp']['judge']['verdict']}", flush=True)
                recs.append(r)
        return recs

    def lp_slower(r):
        return r["lp"]["judge"]["verdict"] == "DISCARD" and any("slower" in w for w in r["lp"]["judge"]["worse"])

    def lp_time_verdict(r):
        return r["lp"]["judge"]["verdict"] == "KEEP" or lp_slower(r)

    noise = trials("base", a.noise_trials)
    s2 = trials("slow2", a.trials)
    s5 = trials("slow5", a.trials)
    n = a.trials
    c.within(f"leanprof false time verdicts, unchanged code, of {a.noise_trials} (timing)",
             sum(map(lp_time_verdict, noise)), 0, 1, 0)
    c.within(f"LeanBench >=5% false regressions, unchanged code, of {a.noise_trials} (timing)",
             sum(r["lb"]["delta_pct"] >= 5 for r in noise), 0, 1, 0)
    c.within(f"leanprof catches the 2.4% slowdown, of {n} (timing)", sum(map(lp_slower, s2)), n - 1, n, n)
    c.within(f"LeanBench >=5% catches the 2.4% slowdown, of {n} (timing)",
             sum(r["lb"]["delta_pct"] >= 5 for r in s2), 0, 1, 0)
    c.within(f"leanprof catches the 4.8% slowdown, of {n} (timing)", sum(map(lp_slower, s5)), n - 1, n, n)
    c.within(f"LeanBench >=5% catches the 4.8% slowdown, of {n} (timing)",
             sum(r["lb"]["delta_pct"] >= 5 for r in s5), 0, n - 1, 2)
c.finish()
