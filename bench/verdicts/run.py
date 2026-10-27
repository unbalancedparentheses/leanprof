#!/usr/bin/env python3
"""Calibrated time verdicts: how often `leanprof measure-pair` calls
identical binaries slower or faster, how often it catches seeded 1%, 2% and
5% slowdowns, how often it stays inconclusive, and what each verdict costs,
on a quiet and on a loaded machine. Results: bench/verdicts/RESULTS.md.

    python3 bench/verdicts/run.py trials --condition quiet
    python3 bench/verdicts/run.py trials --condition loaded --yes 12
    python3 bench/verdicts/run.py reps --yes 14 --variant base   # raw repetitions, for `simulate`
    python3 bench/verdicts/run.py simulate                       # sessions resampled from `reps` data
    python3 bench/verdicts/run.py summary                        # writes RESULTS.md

The protocol, fixed before its first run (2026-10-26) and not changed after:

* Workload: bench/leanbench/project, the region `work` of `workbench` (one
  action, about 7 ms on an M5 Max) through `measure-pair --scope work`. A
  git copy of the project has the base committed; every trial writes the
  variant into Work.lean (plus a definition naming the trial), so the candidate
  is a real rebuild and the base comes from `--base-rev HEAD`'s cache. Each
  configuration gets its own edit (the definition names it too), so each pays
  the rebuild of Work.lean and its executable.
* Variants, one trial each, in an order shuffled once with seed 2026: `base`
  (identical code, 60 trials), `pct1`, `pct2`, `pct5` (1%, 2% and 5% more of
  the same work, 30 trials each).
* Configurations, in every trial, in an order rotated by the trial number:
  `r1` (measure-pair's defaults: one region per run), `r5` (`--repeat 5`:
  the region five times per run, the fastest counting; opt-in), and
  `lb` (LeanBench, 20 samples: `lake build bench`, a baseline run of the base
  build and a compare run of the candidate; slower when the mean grew by 5%
  or more, its threshold in the case study). Wall time is end to end: the
  candidate's build, the base from its cache, and the session.
* Verdicts: measure-pair's own (`judge --allow-overloaded`: on the loaded
  machine the load passes the CPU count at times, and the claim's error bound
  does not depend on the load; the session's `overloaded` flag is recorded).
  On `base`, "slower" or "faster" is a false positive; on `pctN`, "slower"
  is a detection; "inconclusive" is neither.
* Conditions: `quiet`, nothing added, each trial waiting (at most 10
  minutes) until the 1-minute load is below 0.4 of the CPU count; `loaded`,
  `--yes N` processes of `yes > /dev/null` for the whole condition, started
  60 s before the first trial. Every trial holds the machine-wide benchmark
  lock (~/.leanprof-bench.lock), and the loaded condition holds it
  throughout, so no other agent's timing run shares the machine with it.
* One uncounted warmup trial first (`base`, every configuration) builds the
  caches. No trial is rerun: a failed command is recorded as an error.

Amended before any complete run, twice. The configurations were `auto`
(repetitions chosen from the load, then the default) and `r1`; review made
repetitions opt-in, so they became `r1` (the default) and `r5`. And the first loaded run (2026-10-26
21:13) was stopped after 4 trials, because other work had taken the
machine's load to 160–250 (on 18 CPUs; verdicts took 4–43 s); its rows are
in results/aborted/, with the two `reps` files collected during it. Since
then the loaded condition (and `reps` with `yes`) first waits, at most 30
minutes, until the load is below 0.4 of the CPU count, so that the added
load is the `yes` processes.
"""
import argparse, fcntl, json, math, os, random, shutil, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
PROJ = os.path.join(ROOT, "bench", "leanbench", "project")
RES = os.path.join(HERE, "results")
WORK = os.path.join(HERE, ".work")
# LEANPROF_BIN: a copy of the binary to measure, so that rebuilding the
# checkout during a long run does not change it
LP = os.environ.get("LEANPROF_BIN", os.path.join(ROOT, ".lake", "build", "bin", "leanprof"))
LOCK = os.path.expanduser("~/.leanprof-bench.lock")
VARIANTS = {"base": 60, "pct1": 30, "pct2": 30, "pct5": 30}
CONFIGS = ["r1", "r5", "lb"]
OLD = '(← IO.getEnv "LB_VARIANT").getD "base"'
ENV = dict(os.environ, PATH=os.path.expanduser("~/.elan/bin") + os.pathsep + os.environ.get("PATH", ""))
ENV.pop("LB_VARIANT", None)


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def load():
    return round(os.getloadavg()[0], 2)


def run(cmd, cwd, check=True):
    t0 = time.monotonic()
    p = subprocess.run(cmd, cwd=cwd, env=ENV, capture_output=True, text=True)
    wall = time.monotonic() - t0
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed ({p.returncode}): {p.stderr[-1500:]}{p.stdout[-500:]}")
    return p, wall


def git(d, *a):
    run(["git", "-c", "user.name=v", "-c", "user.email=v@example.com", *a], d)


def setup():
    """A git copy of the project (base committed) and a copy for LeanBench's
    baseline, both built."""
    os.makedirs(WORK, exist_ok=True)
    g, b = os.path.join(WORK, "git"), os.path.join(WORK, "lbbase")
    if not os.path.isdir(g):
        shutil.copytree(PROJ, g, ignore=shutil.ignore_patterns(".lake"))
        open(os.path.join(g, ".gitignore"), "w").write(".lake\n")
        git(g, "init", "-q")
        git(g, "add", "-A")
        git(g, "commit", "-qm", "base")
    run(["lake", "build", "workbench", "bench"], g)
    if not os.path.isdir(b):  # with its .git and the packages' own: git must never reach this repository
        shutil.copytree(g, b, symlinks=True)
    run(["lake", "build", "bench"], b)
    return g, b


def write_variant(g, variant, tag):
    """Work.lean with the variant hard-coded, plus a definition naming the
    edit, which changes the C code too (a comment would not: Lake would
    then reuse the object file and the link)."""
    src = open(os.path.join(PROJ, "Work.lean")).read()
    assert OLD in src
    with open(os.path.join(g, "Work.lean"), "w") as f:
        f.write(src.replace(OLD, f'"{variant}"') + f'\n/-- verdicts trial -/\ndef verdictsEdit : String := "{tag}"\n')


def judge_line(stdout):
    """measure-pair's time verdict from `judge` output."""
    for l in stdout.splitlines():
        if "paired time" not in l:
            continue
        if l.startswith("  - "):
            return "slower"
        if l.startswith("  + "):
            return "faster"
        if "no change beyond" in l:
            return "same"
        return "inconclusive"
    return "error"


def lp_session(g, cfg, tmp):
    out = os.path.join(tmp, f"{cfg}-{time.monotonic_ns()}.json")
    cmd = [LP, "measure-pair", "--base-rev", "HEAD", "--exe", "workbench", "--candidate-cwd", g,
           "--scope", "work", "--out", out]
    if cfg == "r5":
        cmd += ["--repeat", "5"]
    la = load()
    p, wall = run(cmd, g)
    j = json.load(open(out))
    jp, _ = run([LP, "judge", "--allow-overloaded", out], g, check=False)
    ch = []
    for k in range(j["runs"]):
        t = {r["side"]: r["time_ns"] for r in j["samples"][2 * k:2 * k + 2]}
        ch.append(round((t["candidate"] / t["base"] - 1) * 100, 3))
    b = j.get("builds") or {}
    return {"verdict": judge_line(jp.stdout), "wall_s": round(wall, 3), "pairs": j["runs"],
            "repeat": j.get("repeat", 1), "load": la, "overloaded": j["machine"]["overloaded"],
            "max_load": j["machine"]["load_avg_1m"], "candidate_build_s": b.get("candidate_build_s"),
            "base_cache": b.get("cache"), "median_change_pct": round(statistics.median(ch), 3), "changes_pct": ch}


def lb_session(g, b, base_first, tmp):
    out = os.path.join(tmp, f"lb-{time.monotonic_ns()}.json")
    bj, nj = out + ".base", out + ".new"
    la = load()
    t0 = time.monotonic()
    run(["lake", "build", "bench"], g)
    tb = time.monotonic()
    common = ["lake", "exe", "bench", "--match", "work", "--samples", "20", "--warmup", "2", "--format", "json"]
    if base_first:
        run(common + ["--json-out", bj], b)
        run(common + ["--json-out", nj, "--compare", bj, "--fail-on-regressions", "--regress-pct", "5"], g, check=False)
    else:
        run(common + ["--json-out", nj], g)
        run(common + ["--json-out", bj], b)
    wall = time.monotonic() - t0
    mb = json.load(open(bj))["results"][0]["mean_ns"]
    mn = json.load(open(nj))["results"][0]["mean_ns"]
    delta = (mn / mb - 1) * 100
    return {"verdict": "slower" if delta >= 5 else "faster" if delta <= -5 else "inconclusive",
            "wall_s": round(wall, 3), "build_s": round(tb - t0, 3), "load": la, "delta_pct": round(delta, 3)}


def trial(g, b, variant, tag, i, configs, tmp):
    rec = {"trial": tag, "variant": variant, "load": load(), "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
           "order": configs[i % len(configs):] + configs[:i % len(configs)]}
    for cfg in rec["order"]:
        # each configuration after its own edit, so each pays a rebuild
        write_variant(g, variant, f"{tag} {cfg}")
        try:
            rec[cfg] = lb_session(g, b, i % 2 == 0, tmp) if cfg == "lb" else lp_session(g, cfg, tmp)
        except Exception as e:  # recorded, never rerun
            rec[cfg] = {"verdict": "error", "error": str(e)[-800:]}
    return rec


class Lock:
    def __enter__(self):
        self.f = open(LOCK, "w")
        t0 = time.monotonic()
        fcntl.flock(self.f, fcntl.LOCK_EX)
        self.waited = time.monotonic() - t0
        return self

    def __exit__(self, *a):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def cmd_trials(a):
    if not os.path.exists(LP):
        sys.exit(f"build leanprof first: {LP}")
    g, b = setup()
    order = [v for v, n in VARIANTS.items() for _ in range(n)]
    random.Random(2026).shuffle(order)
    os.makedirs(RES, exist_ok=True)
    path = os.path.join(RES, f"{a.condition}{a.tag}.jsonl")
    if os.path.exists(path) and not a.append:
        sys.exit(f"{path} exists: the protocol is run once (move it away to start over)")
    done = sum(1 for _ in open(path)) if os.path.exists(path) else 0
    tmp = os.path.join(WORK, "tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    cpus = os.cpu_count()
    import hashlib
    version = {"commit": subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True,
                                        text=True).stdout.strip(),
               "sha256": hashlib.sha256(open(LP, "rb").read()).hexdigest()[:16]}
    out = open(path, "a")
    yes = []
    if a.condition == "loaded":
        # the machine itself first (at most 30 minutes): the added load is
        # to be the `yes` processes, not something else
        t0 = time.monotonic()
        while load() >= 0.4 * cpus and time.monotonic() - t0 < 1800:
            time.sleep(10)
    outer = Lock().__enter__() if a.condition == "loaded" else None
    try:
        if a.condition == "loaded":
            yes =[subprocess.Popen(["yes"], stdout=subprocess.DEVNULL) for _ in range(a.yes)]
            log(f"{a.yes} yes processes; waiting 60 s for the load to settle")
            time.sleep(60)
        for i, variant in enumerate(["warmup"] + order):
            if i - 1 < done and i > 0:
                continue
            if a.limit is not None and i > a.limit:
                break
            if a.condition == "quiet":
                t0 = time.monotonic()
                while load() >= 0.4 * cpus and time.monotonic() - t0 < 600:
                    time.sleep(5)
            with (Lock() if outer is None else open(os.devnull)) as lk:
                rec = trial(g, b, "base" if i == 0 else variant, f"{a.condition}-{i}", i, CONFIGS, tmp)
            rec.update(condition=a.condition, yes=a.yes if a.condition == "loaded" else 0, cpus=cpus,
                       host=os.uname().nodename, warmup=i == 0, leanprof=version)
            if i > 0:
                out.write(json.dumps(rec) + "\n")
                out.flush()
            log(f"{i:3d} {rec['variant']:5s} load {rec['load']:5.1f}  " +
                "  ".join(f"{c} {rec[c]['verdict']} {rec[c].get('wall_s', 0):.2f}s" for c in CONFIGS))
    finally:
        for p in yes:
            p.kill()
        if outer is not None:
            outer.__exit__()


def cmd_reps(a):
    """Raw repetitions for `simulate`: `pairs` pairs of runs of the base
    `workbench` and a copy of it (or the variant), each run repeating the
    region `repeat` times, under the lock, with `yes` processes."""
    g, _ = setup()
    write_variant(g, "base", "reps")
    run(["lake", "build", "workbench"], g)
    os.makedirs(os.path.join(WORK, "reps"), exist_ok=True)
    bins = [os.path.join(WORK, "reps", "a"), os.path.join(WORK, "reps", "b")]
    for x in bins:
        shutil.copy2(os.path.join(g, ".lake", "build", "bin", "workbench"), x)
    variants = ["base", a.variant]
    bf = os.path.join(WORK, "reps", "bench.tmp")
    os.makedirs(RES, exist_ok=True)
    path = os.path.join(RES, f"reps-yes{a.yes}-{a.variant}.jsonl")
    t0 = time.monotonic()
    while a.yes and load() >= 0.4 * os.cpu_count() and time.monotonic() - t0 < 1800:
        time.sleep(10)
    with Lock():
        yes =[subprocess.Popen(["yes"], stdout=subprocess.DEVNULL) for _ in range(a.yes)]
        try:
            time.sleep(60 if a.yes else 0)
            rows = []
            for i in range(a.pairs + 1):
                rec = {"pair": i - 1, "load": load()}
                for off in range(2):
                    side = (i + off) % 2
                    if os.path.exists(bf):
                        os.remove(bf)
                    env = dict(ENV, LB_VARIANT=variants[side], LEANPROF_BENCH_REPEAT=str(a.repeat), LEANPROF_BENCH_OUT=bf)
                    t0 = time.monotonic_ns()
                    subprocess.run([bins[side]], env=env, stdout=subprocess.DEVNULL, check=True)
                    wall = time.monotonic_ns() - t0
                    reps = [int(l.split("\t")[1]) for l in open(bf).read().splitlines()]
                    assert len(reps) == a.repeat
                    rec["ab"[side]] = {"wall": wall, "reps": reps}
                if i > 0:  # the first pair warms up
                    rows.append(rec)
        finally:
            for p in yes:
                p.kill()
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    log(f"wrote {path}")


# ---------------------------------------------------------------- the rule, in Python (Leanprof.Judge)

def looks(mx, first=6, step=2):
    return list(range(first, mx, step)) + [mx]


def seq_bounds(mx, alpha=0.05):
    dist, n, spent, out = [1.0], 0, 0.0, []
    for look in looks(mx):
        for _ in range(n, look):
            prev = dist
            dist = [((prev[s] if s < len(prev) else 0) + (prev[s - 1] if s > 0 else 0)) / 2 for s in range(len(prev) + 1)]
        n = look
        allow = alpha / 2 * look / mx
        k, cum = None, 0.0
        for s in range(len(dist)):
            if spent + cum + dist[s] <= allow * (1 + 1e-12):
                cum += dist[s]
                k = s
            else:
                break
        spent += cum
        if k is not None:
            dist = [0 if i <= k else p for i, p in enumerate(dist)]
        out.append((look, k))
    return out


def session(bounds, mx, draw, m=1.0):
    ch, lookset = [], {n for n, _ in bounds}
    while True:
        ch.append(draw())
        n = len(ch)
        if n in lookset:
            acc = None
            for ln, k in bounds:
                if ln > n:
                    break
                if k is None:
                    continue
                s = sorted(ch[:ln])
                lo, hi = s[k], s[ln - k - 1]
                acc = (lo, hi) if acc is None else (max(acc[0], lo), min(acc[1], hi))
            if acc is not None:
                lo, hi = acc
                if lo <= hi:
                    if lo > m:
                        return "slower", n
                    if hi < -m:
                        return "faster", n
                    if -m <= lo and hi <= m:
                        return "same", n
            if n >= mx:
                return "inconclusive", n


def cmd_simulate(a):
    """Sessions resampled (3,000 each) from the pairs of every reps-*.jsonl:
    each pair's change is the fastest of the first R repetitions of each side."""
    bounds = seq_bounds(30)
    rng = random.Random(7)
    lines = ["| data | load | R | verdicts | mean pairs | seconds per session |", "|---|---|---|---|---|---|"]
    for f in sorted(os.listdir(RES)):
        if not (f.startswith("reps-") and f.endswith(".jsonl")):
            continue
        rows = [json.loads(l) for l in open(os.path.join(RES, f))]
        act = statistics.median(x for r in rows for s in "ab" for x in r[s]["reps"])
        over = statistics.median(r[s]["wall"] - sum(r[s]["reps"]) for r in rows for s in "ab")
        ld = statistics.median(r["load"] for r in rows)
        for R in [1, 2, 3, 5, 10]:
            if R > len(rows[0]["a"]["reps"]):
                continue
            ch = [(min(r["b"]["reps"][:R]) / min(r["a"]["reps"][:R]) - 1) * 100 for r in rows]
            res, ns = {}, []
            for _ in range(3000):
                v, n = session(bounds, 30, lambda: rng.choice(ch))
                res[v] = res.get(v, 0) + 1
                ns.append(n)
            mp = statistics.mean(ns)
            cost = 2 * (over + R * act) / 1e9 * mp
            verdicts = ", ".join(f"{k} {100 * v / 3000:.1f}%" for k, v in sorted(res.items()))
            lines.append(f"| `{f}` | {ld:.1f} | {R} | {verdicts} | {mp:.1f} | {cost:.2f} |")
    text = "\n".join(lines)
    print(text)
    open(os.path.join(RES, "simulate.md"), "w").write(text + "\n")


# ---------------------------------------------------------------- summary

def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def rate(k, n):
    lo, hi = wilson(k, n)
    return f"{k}/{n} ({100 * lo:.0f}–{100 * hi:.0f}%)"


def cmd_summary(a):
    out = ["# Calibrated time verdicts", "",
           "Generated by `python3 bench/verdicts/run.py summary` from `results/*.jsonl`; the protocol is in "
           "[`run.py`](run.py)'s docstring. Rates are counts of trials, with a 95% Wilson interval.", ""]
    for f in sorted(os.listdir(RES)):
        if not f.endswith(".jsonl") or f.startswith("reps-"):
            continue
        rows = [json.loads(l) for l in open(os.path.join(RES, f))]
        if not rows:
            continue
        r0 = rows[0]
        loads = [r["load"] for r in rows]
        out += [f"## `{f}`: {r0['condition']}" + (f", {r0['yes']} `yes` processes" if r0["yes"] else ""), "",
                f"{r0['host']}, {r0['cpus']} CPUs, {rows[0]['time']} to {rows[-1]['time']}; "
                f"1-minute load at the start of each trial {min(loads):.1f}–{max(loads):.1f} "
                f"(median {statistics.median(loads):.1f}). {len(rows)} trials.", ""]
        out += ["| | `measure-pair --scope` (default: one region per run) | `measure-pair --scope --repeat 5` (fastest of 5) | LeanBench at 5% |",
                "|---|---|---|---|"]
        def cell(cfg, fn):
            return fn([r[cfg] for r in rows if cfg in r], [r["variant"] for r in rows if cfg in r])
        def fp(xs, vs):
            n = sum(1 for v in vs if v == "base")
            k = sum(1 for x, v in zip(xs, vs) if v == "base" and x["verdict"] in ("slower", "faster"))
            return rate(k, n)
        def det(var):
            def f(xs, vs):
                n = sum(1 for v in vs if v == var)
                k = sum(1 for x, v in zip(xs, vs) if v == var and x["verdict"] == "slower")
                return rate(k, n)
            return f
        def inc(var):
            def f(xs, vs):
                sel = [x for x, v in zip(xs, vs) if v == var]
                n = len(sel)
                k = sum(1 for x in sel if x["verdict"] == "inconclusive")
                return rate(k, n)
            return f
        def same(xs, vs):
            n = sum(1 for v in vs if v == "base")
            k = sum(1 for x, v in zip(xs, vs) if v == "base" and x["verdict"] == "same")
            return rate(k, n)
        def errs(xs, vs):
            return str(sum(1 for x in xs if x["verdict"] == "error"))
        def wall(var):
            def f(xs, vs):
                w = [x["wall_s"] for x, v in zip(xs, vs) if "wall_s" in x and (var == "*" or v == var)]
                return f"{statistics.median(w):.2f} s ({min(w):.2f}–{max(w):.2f})" if w else "–"
            return f
        def total(xs, vs):
            return f"{sum(x.get('wall_s', 0) for x in xs) / 60:.1f} min"
        def pairs(xs, vs):
            p = [x["pairs"] for x in xs if "pairs" in x]
            return f"{statistics.median(p):.0f} ({min(p)}–{max(p)})" if p else "–"
        def reps(xs, vs):
            p = [x["repeat"] for x in xs if "repeat" in x]
            return ", ".join(f"{k}: {p.count(k)}" for k in sorted(set(p))) if p else "–"
        def over(xs, vs):
            p = [x for x in xs if "overloaded" in x]
            return f"{sum(1 for x in p if x['overloaded'])}/{len(p)}" if p else "–"
        rowsdef = [("identical code: false positives (slower or faster)", fp),
                   ("identical code: settled \"no change beyond ±1%\"", same),
                   ("identical code: inconclusive", inc("base")),
                   ("+1% (pct1): caught as slower", det("pct1")), ("+1%: inconclusive", inc("pct1")),
                   ("+2% (pct2): caught as slower", det("pct2")), ("+2%: inconclusive", inc("pct2")),
                   ("+5% (pct5): caught as slower", det("pct5")), ("+5%: inconclusive", inc("pct5")),
                   ("seconds per verdict, median (range): all trials", wall("*")),
                   ("identical code", wall("base")), ("+5%", wall("pct5")),
                   ("total time", total), ("pairs per session, median (range)", pairs),
                   ("repetitions per run: sessions", reps), ("sessions with the load above the CPU count", over),
                   ("errors", errs)]
        for name, fn in rowsdef:
            vals = []
            for cfg in CONFIGS:
                if cfg == "lb" and fn in (same, pairs, reps, over):
                    vals.append("–")
                else:
                    vals.append(cell(cfg, fn))
            out.append(f"| {name} | " + " | ".join(vals) + " |")
        out.append("")
    if os.path.exists(os.path.join(RES, "simulate.md")):
        out += ["## Repetitions per run, simulated", "",
                "`run.py reps` data (pairs of runs of identical binaries, `base`, or base against a variant, "
                "each run repeating the region 10 times), resampled into 3,000 sessions per row "
                "(`run.py simulate`): what the fastest of the first R repetitions would have given.", "",
                open(os.path.join(RES, "simulate.md")).read()]
    open(os.path.join(HERE, "RESULTS.md"), "w").write("\n".join(out) + "\n")
    log(f"wrote {os.path.join(HERE, 'RESULTS.md')}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("trials")
    t.add_argument("--condition", choices=["quiet", "loaded"], required=True)
    t.add_argument("--yes", type=int, default=12)
    t.add_argument("--tag", default="")
    t.add_argument("--append", action="store_true", help="continue an interrupted run (trials already written are kept)")
    t.add_argument("--limit", type=int, help="stop after this many trials (a smoke test of the script)")
    r = sub.add_parser("reps")
    r.add_argument("--yes", type=int, default=0)
    r.add_argument("--variant", default="base")
    r.add_argument("--pairs", type=int, default=200)
    r.add_argument("--repeat", type=int, default=10)
    sub.add_parser("simulate")
    sub.add_parser("summary")
    a = ap.parse_args()
    # a TERM (or HUP) still stops the `yes` processes and releases the lock
    import signal
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(1))
    {"trials": cmd_trials, "reps": cmd_reps, "simulate": cmd_simulate, "summary": cmd_summary}[a.cmd](a)


if __name__ == "__main__":
    main()
