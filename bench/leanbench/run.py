#!/usr/bin/env python3
"""leanprof vs LeanBench on the job both claim: did a change make code slower
or faster? See docs/case-studies/leanbench.md.

Both tools measure the same action (project/Work.lean). A seeded change is
selected with LB_VARIANT at run time, so neither tool rebuilds between base
and new (a real change would rebuild both equally).

One trial of a variant V, per tool:
  LeanBench:  lake exe bench --samples S --format json --json-out base.json   (LB_VARIANT=base)
              lake exe bench --samples S --compare base.json
                  --fail-on-regressions --regress-pct 10 --format json (LB_VARIANT=V)
              exit 1 = regression at 10%; the JSON means give the verdict at
              other thresholds with LeanBench's own rule (new mean / base mean).
              When new is measured first (every other pair of trials) the
              verdict is that rule applied to the two JSON files.
  leanprof:   leanprof measure --runs R work                         (base, then V)
              leanprof judge base.json new.json   -> KEEP / DISCARD + reasons
              for `alloc` also: leanprof run --allocs --json (base, V) and
              leanprof report-md --fail-on allocs  (exit 1 = regression)

Trials alternate which tool goes first and whether base or new is measured
first. Every measurement records the 1-minute load average.

  python3 bench/leanbench/run.py noise  --trials 20
  python3 bench/leanbench/run.py detect --trials 5 [--variants slow5,copy]
  python3 bench/leanbench/run.py sweep  --trials 5     # samples/runs vs detection
  python3 bench/leanbench/run.py summary               # tables from results/*.jsonl
LB_WRAP="flock ~/bench.lock taskset -c 0-7" prefixes every measured command
(the load average is then read before the lock is taken).
Options: --samples S (LeanBench, default 20), --runs R (leanprof, default 5),
--leanprof PATH (default ../../.lake/build/bin/leanprof), --tools lb,lp.
"""
import argparse, json, os, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.join(HERE, "project")
RES = os.path.join(HERE, "results")
LP_DEFAULT = os.path.normpath(os.path.join(HERE, "..", "..", ".lake", "build", "bin", "leanprof"))
VARIANTS = ["copy", "alloc", "slow2", "slow5", "slow10", "slow30", "fast"]
EXPECTED = {"base": 0.0, "slow2": 2.4, "slow5": 4.8, "slow10": 10.4, "slow30": 30.4, "fast": -20.0,
            "copy": None, "alloc": None}


def load():
    return round(os.getloadavg()[0], 2)


# LB_WRAP: a prefix for every measured command, e.g. on a shared benchmark
# host "flock ~/bench.lock taskset -c 0-7" (one lock per measurement)
WRAP = [os.path.expanduser(w) for w in os.environ.get("LB_WRAP", "").split()]


def sh(cmd, env_extra, capture=True):
    env = dict(os.environ, **env_extra)
    cmd = WRAP + cmd
    t0 = time.monotonic()
    p = subprocess.run(cmd, cwd=PROJ, env=env, capture_output=capture, text=True)
    return p, time.monotonic() - t0


def lb_measure(variant, samples, tmp, baseline=None):
    out = os.path.join(tmp, f"lb-{variant}-{time.monotonic_ns()}.json")
    cmd = ["lake", "exe", "bench", "--match", "work", "--samples", str(samples), "--warmup", "2",
           "--format", "json", "--json-out", out]
    if baseline:
        cmd += ["--compare", baseline, "--fail-on-regressions", "--regress-pct", "10"]
    la = load()
    p, wall = sh(cmd, {"LB_VARIANT": variant})
    if p.returncode not in (0, 1):
        sys.exit(f"leanbench failed: {p.stderr[-2000:]}")
    r = json.load(open(out))["results"][0]
    return {"load": la, "wall_s": round(wall, 3), "mean_ns": r["mean_ns"], "stddev_ns": r["stddev_ns"],
            "median_ns": r.get("median_ns"), "min_ns": r["min_ns"], "max_ns": r["max_ns"],
            "exit": p.returncode, "path": out}


def lp_measure(lp, variant, runs, tmp):
    out = os.path.join(tmp, f"lp-{variant}-{time.monotonic_ns()}.json")
    la = load()
    p, wall = sh([lp, "measure", "--runs", str(runs), "--out", out, "work"], {"LB_VARIANT": variant})
    if p.returncode != 0:
        sys.exit(f"leanprof measure failed: {p.stderr[-2000:]}")
    j = json.load(open(out))
    t = j["time_ns"]
    return {"load": la, "wall_s": round(wall, 3), "median_ns": t["median"], "min_ns": t["min"],
            "max_ns": t["max"], "runs_ns": t["runs"], "copies": j["copies_total"], "path": out}


def lp_judge(lp, base, new):
    p, wall = sh([lp, "judge", base, new], {})
    lines = p.stdout.splitlines()
    worse = [l.strip()[2:] for l in lines if l.startswith("  - ") and "no measurable improvement" not in l]
    better = [l.strip()[2:] for l in lines if l.startswith("  + ")]
    return {"verdict": lines[0] if lines else "?", "worse": worse, "better": better, "judge_s": round(wall, 3)}


def lp_allocs(lp, variant, tmp):
    out = os.path.join(tmp, f"lpa-{variant}-{time.monotonic_ns()}.json")
    la = load()
    p, wall = sh([lp, "run", "--allocs", "--json", out, "work"], {"LB_VARIANT": variant, "LEANPROF_QUIET": "1"})
    if p.returncode != 0:
        sys.exit(f"leanprof run --allocs failed: {p.stderr[-2000:]}")
    return {"load": la, "wall_s": round(wall, 3), "path": out}


def lp_report_md(lp, base, new):
    p, _ = sh([lp, "report-md", "--fail-on", "allocs", base, new], {})
    row = next((l for l in p.stdout.splitlines() if l.startswith("| allocations")), "")
    return {"exit": p.returncode, "row": row}


def trial(args, variant, i, tmp):
    """One A/B trial of `variant` against base with each selected tool."""
    rec = {"variant": variant, "trial": i, "samples": args.samples, "runs": args.runs,
           "host": os.uname().nodename, "cpus": os.cpu_count(), "wrap": " ".join(WRAP),
           "time": time.strftime("%Y-%m-%dT%H:%M:%S")}
    tools = args.tools.split(",")
    if i % 2 == 1:
        tools = tools[::-1]
    base_first = (i // 2) % 2 == 0   # base/new order flips every two trials
    for tool in tools:
        if tool == "lb":
            # the saved-baseline workflow measures the baseline first and the
            # CLI's exit code is the verdict; in the other order the verdict
            # comes from the same rule applied to the two JSON means
            if base_first:
                b = lb_measure("base", args.samples, tmp)
                n = lb_measure(variant, args.samples, tmp, baseline=b["path"])
            else:
                n = lb_measure(variant, args.samples, tmp)
                b = lb_measure("base", args.samples, tmp)
            ratio = n["mean_ns"] / b["mean_ns"]
            rec["lb"] = {"base": b, "new": n, "delta_pct": round((ratio - 1) * 100, 3),
                         "fail_at_10pct": lb_verdict((ratio - 1) * 100, 10)}
            if base_first:
                rec["lb"]["cli_exit"] = n["exit"]
                if (n["exit"] == 1) != rec["lb"]["fail_at_10pct"]:
                    print("warning: LeanBench's exit code disagrees with its rule", file=sys.stderr)
        else:
            if base_first:
                b = lp_measure(args.leanprof, "base", args.runs, tmp)
                n = lp_measure(args.leanprof, variant, args.runs, tmp)
            else:
                n = lp_measure(args.leanprof, variant, args.runs, tmp)
                b = lp_measure(args.leanprof, "base", args.runs, tmp)
            j = lp_judge(args.leanprof, b["path"], n["path"])
            rec["lp"] = {"base": b, "new": n, "judge": j,
                         "delta_pct": round((n["median_ns"] / b["median_ns"] - 1) * 100, 3)}
            if variant in ("alloc", "base") and args.allocs:
                ab = lp_allocs(args.leanprof, "base", tmp)
                an = lp_allocs(args.leanprof, variant, tmp)
                rec["lp"]["allocs"] = {"base": ab, "new": an, "report_md": lp_report_md(args.leanprof, ab["path"], an["path"])}
    rec["base_first"] = base_first
    return rec


def lb_verdict(delta, thr):
    """LeanBench's rule: regression iff mean ratio - 1 >= thr% (thr None: any increase)."""
    return delta > 0 if thr is None else delta >= thr


def retro_time(lp, cpus, min_change=1.0):
    """The time part of `judge` as changed after this study, applied to the
    recorded runs: non-overlapping runs and a median change of at least
    `min_change`%, and nothing when the load average (recorded before each
    measurement) exceeded the machine's CPUs (18 on the Mac, 32 on Linux)."""
    faster = slower = none = 0
    for x in lp:
        b, n = x["base"], x["new"]
        pct = (n["median_ns"] / b["median_ns"] - 1) * 100
        if max(b["load"], n["load"]) > cpus:
            none += 1
        elif n["max_ns"] < b["min_ns"] and -pct >= min_change:
            faster += 1
        elif n["min_ns"] > b["max_ns"] and pct >= min_change:
            slower += 1
        else:
            none += 1
    return faster, slower, none


def summarize():
    rows = []
    for f in sorted(os.listdir(RES)):
        if f.endswith(".jsonl"):
            rows += [dict(json.loads(l), _tag=f[:-6].split("-", 1)[1] if "-" in f else "")
                     for l in open(os.path.join(RES, f)) if l.strip()]
    if not rows:
        return print("no results")
    groups = {}
    for r in rows:
        host = "linux" if "linux" in r.get("host", "") or r.get("wrap") else "mac"
        if r["_tag"] not in ("", "linux"):
            host += f" ({r['_tag']})"
        groups.setdefault((host, r["mode"], r["variant"], r["samples"], r["runs"]), []).append(r)
    print("| host | mode | variant | LB samples / LP runs | trials | load 1m (min-max) | "
          "LeanBench delta % (median, range) | LB regress any / >=5% / >=10% | LB improve <=-5% / <=-10% | "
          "leanprof delta % (median, range) | leanprof KEEP / DISCARD slower / DISCARD exact / no evidence | "
          "s per verdict LB / LP | time verdicts, judge after this study: faster / slower / none |")
    print("|---|---|---|---|---:|---|---|---|---|---|---|---|---|")
    for (host, mode, v, s, rr), g in sorted(groups.items()):
        loads = [x[t]["base"]["load"] for x in g for t in ("lb", "lp") if t in x]
        cells = [host, mode, v, f"{s} / {rr}", str(len(g)), f"{min(loads):.0f}-{max(loads):.0f}"]
        lb = [x["lb"] for x in g if "lb" in x]
        if lb:
            d = [x["delta_pct"] for x in lb]
            cells += [f"{statistics.median(d):+.1f} ({min(d):+.1f}..{max(d):+.1f})",
                      " / ".join(str(sum(lb_verdict(x, t) for x in d)) for t in (None, 5, 10)),
                      " / ".join(str(sum(x <= -t for x in d)) for t in (5, 10))]
        else:
            cells += ["-", "-", "-"]
        lp = [x["lp"] for x in g if "lp" in x]
        if lp:
            d = [x["delta_pct"] for x in lp]
            keep = sum(x["judge"]["verdict"] == "KEEP" for x in lp)
            slower = sum(x["judge"]["verdict"] == "DISCARD" and any("slower" in w for w in x["judge"]["worse"]) for x in lp)
            exact = sum(x["judge"]["verdict"] == "DISCARD" and any("slower" not in w for w in x["judge"]["worse"]) for x in lp)
            neutral = sum(x["judge"]["verdict"] == "DISCARD" and not x["judge"]["worse"] for x in lp)
            cells += [f"{statistics.median(d):+.1f} ({min(d):+.1f}..{max(d):+.1f})", f"{keep} / {slower} / {exact} / {neutral}"]
        else:
            cells += ["-", "-"]
        # cost of one verdict: two measurements (median wall of each, so the
        # rebuild `lake exe` does after a leanprof run, about one LeanBench
        # measurement in four, is left out; see the case study) plus judge
        lbw = [x[s]["wall_s"] for x in lb for s in ("base", "new")]
        lpw = [x[s]["wall_s"] for x in lp for s in ("base", "new")]
        if lbw and lpw:
            jw = statistics.median(x["judge"]["judge_s"] for x in lp)
            cells.append(f"{2 * statistics.median(lbw):.1f} / {2 * statistics.median(lpw) + jw:.1f}")
        else:
            cells.append("-")
        cells.append(" / ".join(map(str, retro_time(lp, g[0].get("cpus") or (32 if host == "linux" else 18)))) if lp else "-")
        print("| " + " | ".join(cells) + " |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["noise", "detect", "sweep", "summary"])
    ap.add_argument("--trials", type=int, default=5)
    ap.add_argument("--samples", type=int, default=20)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--variants", default=",".join(VARIANTS))
    ap.add_argument("--tools", default="lb,lp")
    ap.add_argument("--leanprof", default=LP_DEFAULT)
    ap.add_argument("--tag", default="", help="suffix of the results file, e.g. -linux")
    ap.add_argument("--append", action="store_true")
    a = ap.parse_args()
    if a.mode == "summary":
        return summarize()
    os.makedirs(RES, exist_ok=True)
    subprocess.run(["lake", "build", "work", "bench"], cwd=PROJ, check=True, capture_output=True)
    a.allocs = True
    plan = []
    if a.mode == "noise":
        plan = [("base", a.samples, a.runs)]
    elif a.mode == "detect":
        plan = [(v, a.samples, a.runs) for v in a.variants.split(",")]
    else:  # sweep: fewer and more samples/runs than the defaults
        a.allocs = False
        plan = [(v, s, r) for (s, r) in [(5, 3), (100, 10)] for v in ("base", "slow5", "slow10")]
    out = os.path.join(RES, f"{a.mode}{a.tag}.jsonl")
    if os.path.exists(out) and not a.append:
        sys.exit(f"{out} exists; pass --append or another --tag")
    with tempfile.TemporaryDirectory() as tmp, open(out, "a") as f:
        for v, s, r in plan:
            a.samples, a.runs = s, r
            for i in range(a.trials):
                rec = trial(a, v, i, tmp)
                rec["mode"] = a.mode
                for t in ("lb", "lp"):
                    for side in ("base", "new"):
                        if t in rec:
                            rec[t][side].pop("path", None)
                    if t == "lp" and "allocs" in rec.get("lp", {}):
                        for side in ("base", "new"):
                            rec["lp"]["allocs"][side].pop("path", None)
                f.write(json.dumps(rec) + "\n")
                f.flush()
                lb = rec.get("lb", {}); lp = rec.get("lp", {})
                print(f"{a.mode} {v} s={s} r={r} #{i} load={load()} "
                      f"LB {lb.get('delta_pct', '-')}% fail10={lb.get('fail_at_10pct', '-')} | "
                      f"LP {lp.get('delta_pct', '-')}% {lp.get('judge', {}).get('verdict', '-')} "
                      f"{'; '.join(lp.get('judge', {}).get('worse', []) + lp.get('judge', {}).get('better', []))[:120]}"
                      + (f" allocs-md exit={lp['allocs']['report_md']['exit']}" if 'allocs' in lp else ""),
                      flush=True)


if __name__ == "__main__":
    main()
