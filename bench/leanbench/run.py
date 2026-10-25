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
  python3 bench/leanbench/run.py pair                  # adds measure-pair (below)
  python3 bench/leanbench/run.py summary               # tables from results/*.jsonl

`pair` (fixed before it was first run): unchanged code 20 trials, then
slow2, slow5 and slow10 5 trials each; every trial runs LeanBench (20
samples), measure + judge (5 runs), measure-pair (20 pairs) and `measure
--scope work` + judge (5 runs, on scoped/: the 20 actions in one `profile!`
scope), the tools in rotating order. measure-pair compares two real builds: two copies of the
project, base unchanged and the candidate's Work.lean edited to hard-code the
variant (plus a comment naming the trial, so every trial changes it); each
trial times `lake build work` in both copies, then `measure-pair --runs 20`.
Its verdicts at 6 and 10 pairs are `judge` on the first 6 and 10 pairs of
the same session (what `--runs 6` or `--runs 10` would have measured). No
trial is rerun. On a shared machine, LB_MAX_LOAD=L makes every trial wait
until the 1-minute load average is below L (the load is still recorded
before every measurement).
LB_WRAP="flock ~/bench.lock taskset -c 0-7" prefixes every measured command
(the load average is then read before the lock is taken).
Options: --samples S (LeanBench, default 20), --runs R (leanprof, default 5),
--leanprof PATH (default ../../.lake/build/bin/leanprof), --tools lb,lp.
"""
import argparse, json, os, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.join(HERE, "project")
SCOPED = os.path.join(HERE, "scoped")   # the same workload in one profile! scope
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


def sh(cmd, env_extra, capture=True, cwd=PROJ):
    env = dict(os.environ, **env_extra)
    cmd = WRAP + cmd
    t0 = time.monotonic()
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=capture, text=True)
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


def lp_measure(lp, variant, runs, tmp, scoped=False):
    out = os.path.join(tmp, f"lp-{variant}-{time.monotonic_ns()}.json")
    la = load()
    target = ["--scope", "work", "workscope"] if scoped else ["work"]
    p, wall = sh([lp, "measure", "--runs", str(runs), "--out", out] + target, {"LB_VARIANT": variant},
                 cwd=SCOPED if scoped else PROJ)
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


def mp_setup(tmp):
    """Two copies of the built project for measure-pair: base and candidate."""
    dirs = {s: os.path.join(tmp, s) for s in ("mp-base", "mp-cand")}
    for d in dirs.values():
        subprocess.run(["cp", "-R", PROJ, d], check=True)
    return dirs


def mp_parse(stdout):
    """measure-pair's or judge's verdict, and what it said about time."""
    lines = [l for l in stdout.splitlines() if l.strip()]
    i = next((n for n, l in enumerate(lines) if l in ("KEEP", "DISCARD")), None)
    if i is None:
        return {"verdict": "?", "time": "?", "line": stdout[-300:]}
    t = next((l.strip() for l in lines[i + 1:] if "paired time" in l), "")
    kind = ("not judged" if "not judged" in t else "inconclusive" if "inconclusive" in t
            else "faster" if t.startswith("+") else "slower" if t.startswith("-") else "?")
    return {"verdict": lines[i], "time": kind, "line": t}


def mp_judge_prefix(lp, path, k):
    """`judge` on the first k pairs of a measure-pair session."""
    j = json.load(open(path))
    j["runs"] = k
    j["samples"] = j["samples"][:2 * k]
    j["machine"]["pair_loads"] = j["machine"]["pair_loads"][:k]
    out = f"{path[:-5]}-{k}.json"
    json.dump(j, open(out, "w"))
    return mp_parse(sh([lp, "judge", out], {})[0].stdout)


def mp_trial(lp, dirs, variant, i, runs, tmp):
    """Rebuild the candidate with `variant` hard-coded, then measure-pair."""
    src = open(os.path.join(PROJ, "Work.lean")).read()
    old = '(← IO.getEnv "LB_VARIANT").getD "base"'
    assert old in src
    with open(os.path.join(dirs["mp-cand"], "Work.lean"), "w") as f:
        f.write(src.replace(old, f'"{variant}"') + f"\n-- measure-pair trial {variant} {i}\n")
    env = {k: v for k, v in os.environ.items() if k != "LB_VARIANT"}
    builds = {}
    for side in ("mp-base", "mp-cand"):
        t0 = time.monotonic()
        subprocess.run(WRAP + ["lake", "build", "work"], cwd=dirs[side], env=env, check=True, capture_output=True)
        builds[side] = round(time.monotonic() - t0, 3)
    out = os.path.join(tmp, f"mp-{variant}-{time.monotonic_ns()}.json")
    bins = [os.path.join(dirs[s], ".lake", "build", "bin", "work") for s in ("mp-base", "mp-cand")]
    la = load()
    t0 = time.monotonic()
    p = subprocess.run(WRAP + [lp, "measure-pair", "--base", bins[0], "--candidate", bins[1],
                               "--base-cwd", dirs["mp-base"], "--candidate-cwd", dirs["mp-cand"],
                               "--runs", str(runs), "--out", out],
                       cwd=PROJ, env=env, capture_output=True, text=True)
    wall = round(time.monotonic() - t0, 3)
    if p.returncode != 0:
        sys.exit(f"measure-pair failed: {p.stderr[-2000:]}")
    j = json.load(open(out))
    ch = []
    for k in range(runs):
        t = {r["side"]: r["time_ns"] for r in j["samples"][2 * k:2 * k + 2]}
        ch.append(round((t["candidate"] / t["base"] - 1) * 100, 3))
    rec = {"load": la, "pair_loads": j["machine"]["pair_loads"], "overloaded": j["machine"]["overloaded"],
           "build_base_s": builds["mp-base"], "build_cand_s": builds["mp-cand"], "wall_s": wall,
           "changes_pct": ch, "delta_pct": round(statistics.median(ch), 3),
           "verdict": {str(runs): mp_parse(p.stdout)}}
    for k in (6, 10):
        if k < runs:
            rec["verdict"][str(k)] = mp_judge_prefix(lp, out, k)
    return rec


def trial(args, variant, i, tmp):
    """One A/B trial of `variant` against base with each selected tool."""
    rec = {"variant": variant, "trial": i, "samples": args.samples, "runs": args.runs,
           "host": os.uname().nodename, "cpus": os.cpu_count(), "wrap": " ".join(WRAP),
           "time": time.strftime("%Y-%m-%dT%H:%M:%S")}
    tools = args.tools.split(",")
    if len(tools) > 2:   # each tool takes every place in the order in turn
        tools = tools[i % len(tools):] + tools[:i % len(tools)]
    elif i % 2 == 1:
        tools = tools[::-1]
    base_first = (i // 2) % 2 == 0   # base/new order flips every two trials
    for tool in tools:
        if tool == "mp":
            rec["mp"] = mp_trial(args.leanprof, args.mp_dirs, variant, i, args.pairs, tmp)
        elif tool == "lb":
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
        else:  # lp, or lps: measure --scope work
            sc = tool == "lps"
            if base_first:
                b = lp_measure(args.leanprof, "base", args.runs, tmp, sc)
                n = lp_measure(args.leanprof, variant, args.runs, tmp, sc)
            else:
                n = lp_measure(args.leanprof, variant, args.runs, tmp, sc)
                b = lp_measure(args.leanprof, "base", args.runs, tmp, sc)
            j = lp_judge(args.leanprof, b["path"], n["path"])
            rec[tool] = {"base": b, "new": n, "judge": j,
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
    pair = [r for r in rows if r["mode"] == "pair"]
    rows = [r for r in rows if r["mode"] != "pair"]
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
    if pair:
        pair_summary(pair)


def pair_summary(rows):
    """`pair` mode: LeanBench, measure + judge, measure --scope + judge and
    measure-pair on the same trials. Seconds per verdict are medians: for
    LeanBench and measure, two measurements (+ judge); for measure-pair, the
    candidate's and base's `lake build work` plus the 20-pair session."""
    med = statistics.median
    print("\n| variant | trials | load 1m (min-max) | LeanBench delta % | LB >=5% / >=10% | "
          "measure delta % | measure KEEP / slower / no time verdict | "
          "--scope delta % | --scope KEEP / slower / no time verdict | "
          "measure-pair delta % | pairs: slower / faster / inconclusive / not judged | "
          "s per verdict: LB / measure / --scope / pair (build + run) |")
    print("|---|---:|---|---|---|---|---|---|---|---|---|---|")
    order = ["base", "slow2", "slow5", "slow10"]
    for v in sorted({r["variant"] for r in rows}, key=lambda x: order.index(x) if x in order else 9):
        g = [r for r in rows if r["variant"] == v]
        loads = [x[t][s]["load"] for x in g for t in ("lb", "lp", "lps") if t in x for s in ("base", "new")]
        loads += [l for x in g if "mp" in x for l in [x["mp"]["load"]] + x["mp"]["pair_loads"] if l is not None]
        rng = lambda d: f"{med(d):+.1f} ({min(d):+.1f}..{max(d):+.1f})"
        cells = [v, str(len(g)), f"{min(loads):.1f}-{max(loads):.1f}"]
        d = [x["lb"]["delta_pct"] for x in g]
        cells += [rng(d), f"{sum(x >= 5 for x in d)} / {sum(x >= 10 for x in d)}"]
        for t in ("lp", "lps"):
            d = [x[t]["delta_pct"] for x in g]
            js = [x[t]["judge"] for x in g]
            keep = sum(j["verdict"] == "KEEP" for j in js)
            slow = sum(any("slower" in w for w in j["worse"]) for j in js)
            cells += [rng(d), f"{keep} / {slow} / {len(js) - keep - slow}"]
        cells.append(rng([x["mp"]["delta_pct"] for x in g]))
        parts = []
        for k in ("20", "10", "6"):
            ts = [x["mp"]["verdict"][k]["time"] for x in g]
            parts.append(f"{k}: " + " / ".join(str(ts.count(c)) for c in ("slower", "faster", "inconclusive", "not judged")))
        cells.append("; ".join(parts))
        lbw = med(x["lb"]["base"]["wall_s"] + x["lb"]["new"]["wall_s"] for x in g)
        lpw = [med(x[t]["base"]["wall_s"] + x[t]["new"]["wall_s"] + x[t]["judge"]["judge_s"] for x in g) for t in ("lp", "lps")]
        mb = med(x["mp"]["build_base_s"] + x["mp"]["build_cand_s"] for x in g)
        mw = med(x["mp"]["wall_s"] for x in g)
        cells.append(f"{lbw:.1f} / {lpw[0]:.1f} / {lpw[1]:.1f} / {mb + mw:.1f} ({mb:.1f} + {mw:.1f})")
        print("| " + " | ".join(cells) + " |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["noise", "detect", "sweep", "pair", "summary"])
    ap.add_argument("--pairs", type=int, default=20, help="measure-pair --runs (pair mode)")
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
        plan = [("base", a.samples, a.runs, a.trials)]
    elif a.mode == "detect":
        plan = [(v, a.samples, a.runs, a.trials) for v in a.variants.split(",")]
    elif a.mode == "pair":  # the protocol in the docstring
        a.allocs = False
        if a.tools == "lb,lp":
            a.tools = "lb,lp,mp,lps"
        subprocess.run(["lake", "build", "workscope"], cwd=SCOPED, check=True, capture_output=True)
        plan = [("base", a.samples, a.runs, 20)] + [(v, a.samples, a.runs, 5) for v in ("slow2", "slow5", "slow10")]
    else:  # sweep: fewer and more samples/runs than the defaults
        a.allocs = False
        plan = [(v, s, r, a.trials) for (s, r) in [(5, 3), (100, 10)] for v in ("base", "slow5", "slow10")]
    out = os.path.join(RES, f"{a.mode}{a.tag}.jsonl")
    if os.path.exists(out) and not a.append:
        sys.exit(f"{out} exists; pass --append or another --tag")
    with tempfile.TemporaryDirectory() as tmp, open(out, "a") as f:
        if "mp" in a.tools.split(","):
            a.mp_dirs = mp_setup(tmp)
        for v, s, r, trials in plan:
            a.samples, a.runs = s, r
            for i in range(trials):
                waited = 0
                while os.environ.get("LB_MAX_LOAD") and load() >= float(os.environ["LB_MAX_LOAD"]):
                    time.sleep(30)
                    waited += 30
                rec = trial(a, v, i, tmp)
                rec["waited_s"] = waited
                rec["mode"] = a.mode
                for t in ("lb", "lp", "lps"):
                    for side in ("base", "new"):
                        if t in rec:
                            rec[t][side].pop("path", None)
                    if t == "lp" and "allocs" in rec.get("lp", {}):
                        for side in ("base", "new"):
                            rec["lp"]["allocs"][side].pop("path", None)
                f.write(json.dumps(rec) + "\n")
                f.flush()
                lb = rec.get("lb", {}); lp = rec.get("lp", {}); mp = rec.get("mp", {})
                print(f"{a.mode} {v} s={s} r={r} #{i} load={load()} "
                      f"LB {lb.get('delta_pct', '-')}% fail10={lb.get('fail_at_10pct', '-')} | "
                      f"LP {lp.get('delta_pct', '-')}% {lp.get('judge', {}).get('verdict', '-')} "
                      f"{'; '.join(lp.get('judge', {}).get('worse', []) + lp.get('judge', {}).get('better', []))[:120]}"
                      + (f" allocs-md exit={lp['allocs']['report_md']['exit']}" if 'allocs' in lp else "")
                      + (f" | MP {mp['delta_pct']}% " + " ".join(f"{k}:{x['verdict']}/{x['time']}" for k, x in mp["verdict"].items())
                         + f" build {mp['build_cand_s']} s, pair {mp['wall_s']} s" if mp else "")
                      + (f" | LPS {rec['lps']['delta_pct']}% {rec['lps']['judge']['verdict']}" if "lps" in rec else ""),
                      flush=True)


if __name__ == "__main__":
    main()
