#!/usr/bin/env python3
"""Benchmark and accuracy suite for leanprof (see bench/README.md).

    python3 bench/run.py              # full suite, writes bench/RESULTS.md and bench/results.json
    python3 bench/run.py --quick      # smaller inputs, 3 runs (CI)
    python3 bench/run.py --quick --check   # and fail unless counts are exact and totals in tolerance

Workloads come from WlPlain.lean (one program, built plain, with `profile!`
scopes and with LeanProfiler spans). Every tool configuration runs every
workload several times, interleaved and in shuffled order, and the program
reports the wall time of each phase itself. The plain build's phase times are
the ground truth: each tool's share of time per phase is compared with them,
and its reported call counts with the exact counts the program prints.
"""

import argparse
import glob
import json
import os
import platform
import random
import re
import shutil
import statistics
import subprocess
import sys
import time

BENCH = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BENCH)
WORK = os.path.join(BENCH, ".lake", "suite")
BINS = os.path.join(WORK, "bins")
OUT = os.path.join(WORK, "out")
LP = os.path.join(ROOT, ".lake", "build", "bin", "leanprof")

WORKLOADS = ["tiny", "rec", "mix", "alloc", "copy", "tasks"]
WORKLOAD_INFO = {
    "tiny": "tight loops of tiny functions (10M + 20M calls)",
    "rec": "recursion 100, 1,000 and 10,000 deep; fib (7M calls)",
    "mix": "hot/warm/cool/cold functions, same kernel, work 60:25:10:5",
    "alloc": "allocation-heavy: lists of structures, binary trees",
    "copy": "copy-heavy: an array copied on every push, against pushes in place",
    "tasks": "the same work on 2, 4 and 8 threads, a tiny scope per step",
}

# name -> (description, executable, how it is built or run)
#   build None: a plain `lake build`; a list: `leanprof run --keep` with those flags;
#   a string: a sampler or LeanProfiler, run on the given executable.
CONFIGS = {
    "plain": ("no profiler (baseline)", "wl", None),
    "profile": ("`profile!` scopes, normal build", "wlp", None),
    "run": ("`leanprof run` (profile! + copy/task shims)", "wlp", []),
    "auto": ("`leanprof run --auto` (every function)", "wl", ["--auto"]),
    "allocs": ("`leanprof run --allocs` (profile!)", "wlp", ["--allocs"]),
    "counters": ("`leanprof run --counters` (profile!)", "wlp", ["--counters"]),
    "frees": ("`leanprof run --frees` (profile!)", "wlp", ["--frees"]),
    "sample": ("`leanprof sample` (samply, 4 kHz)", "wl", "sample"),
    "samply": ("`samply record` directly (1 kHz default)", "wl", "samply"),
    "leanprofiler": ("LeanProfiler spans (phases and tasks only)", "wls", "leanprofiler"),
}
LEANPROF_EXACT = ["profile", "run", "auto", "allocs", "counters", "frees"]
LABEL_ONLY = {"taskStep"}
SHIMS = ["run", "auto", "allocs", "counters", "frees"]  # builds with copy shims

# Tolerance for --check: the sum of leanprof's reported times for a workload's
# components (after it subtracts its own overhead) over the plain program's
# time, where every timed scope or function does at least a microsecond of
# work per call. Where they do a few nanoseconds (tiny, rec, tasks; alloc's
# and copy's helper functions under --auto; every Array.push through `run`'s
# copy shims) the residual is as large as the work itself, so those are
# reported but not checked (see RESULTS.md). The band is wide for CI's shared
# virtual machines; on a quiet machine these are within 0.9-1.1.
TOL = (0.75, 1.35)
TOL_CHECKED = {"profile": {"mix", "alloc", "copy"}, "run": {"mix", "alloc"}, "auto": {"mix"}}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def sh(cmd, cwd=BENCH, env=None, check=True, capture=True):
    e = dict(os.environ)
    if env:
        e.update(env)
    r = subprocess.run(cmd, cwd=cwd, env=e, text=True,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.PIPE if capture else None)
    if check and r.returncode != 0:
        log(f"command failed ({r.returncode}): {' '.join(cmd)}")
        if capture:
            log(r.stdout[-4000:])
            log(r.stderr[-4000:])
        sys.exit(1)
    return r


def remove_objects(project):
    """What `leanprof run` does before an instrumented build, and what
    undoes one: Lake does not notice a new LEAN_CC."""
    for pat in [".lake/build/ir/**/*.c.o*", ".lake/packages/*/.lake/build/ir/**/*.c.o*"]:
        for f in glob.glob(os.path.join(project, pat), recursive=True):
            os.remove(f)


def remove_exes(project, exes):
    for exe in exes:
        for f in glob.glob(os.path.join(project, ".lake", "build", "bin", exe)) + \
                glob.glob(os.path.join(project, ".lake", "build", "bin", exe + ".*")):
            os.remove(f)
    shutil.rmtree(os.path.join(project, ".lake", "leanprof", "saved"), ignore_errors=True)


def binpath(cfg, exe):
    return os.path.join(BINS, cfg, exe)


def build(configs, project=BENCH, exes=("wl", "wlp", "wls"), bins=BINS, smoke=("tiny", "1")):
    """Build every configuration once and keep its executable in `bins`."""
    sh(["lake", "build", "leanprof"], cwd=ROOT)
    remove_objects(project)
    remove_exes(project, exes)
    sh(["lake", "build", *exes], cwd=project)
    for cfg in configs:
        desc, exe, how = CONFIGS[cfg]
        if exe not in exes:
            exe = exes[0]
        os.makedirs(os.path.join(bins, cfg), exist_ok=True)
        if how is None or isinstance(how, str):
            shutil.copy2(os.path.join(project, ".lake", "build", "bin", exe), os.path.join(bins, cfg, exe))
    for cfg in configs:
        desc, exe, how = CONFIGS[cfg]
        if not isinstance(how, list):
            continue
        if exe not in exes:
            exe = exes[0]
        log(f"  building {cfg}: leanprof run --keep {' '.join(how)} {exe}")
        t0 = time.time()
        sh([LP, "run", "--keep", *how, exe, "--", *smoke], cwd=project,
           env={"LEANPROF_QUIET": "1", "LEANPROF_JSON": os.path.join(OUT, "smoke.json")})
        shutil.copy2(os.path.join(project, ".lake", "build", "bin", exe), os.path.join(bins, cfg, exe))
        log(f"    {time.time() - t0:.1f} s")
    # back to the normal build, which `leanprof sample` uses
    remove_objects(project)
    remove_exes(project, exes)
    sh(["lake", "build", *exes], cwd=project)


# ---------------------------------------------------------------- tools


def have_samply():
    if shutil.which("samply") is None:
        return "samply is not installed"
    if sys.platform.startswith("linux"):
        try:
            p = int(open("/proc/sys/kernel/perf_event_paranoid").read().strip())
        except OSError:
            p = None
        if p is not None and p > 1:
            return f"kernel.perf_event_paranoid is {p} (samply needs 1 or less)"
    test = os.path.join(OUT, "samply-test.json")
    r = subprocess.run(["samply", "record", "--save-only", "-o", test, "--", binpath("plain", "wl"), "tiny", "1"],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0 or not os.path.exists(test):
        return "samply record failed: " + r.stdout.strip().splitlines()[-1][:200] if r.stdout.strip() else "samply record failed"
    return None


def parse_bench(stdout):
    for line in stdout.splitlines():
        if line.startswith("BENCH_JSON "):
            return json.loads(line[len("BENCH_JSON "):])
    return None


def short(name):
    """`W.phHot` -> `phHot`; None for specializations and lambdas' parents."""
    if " (in " in name:
        return None
    return name.split(".")[-1]


def leanprof_report(path):
    d = json.load(open(path))
    times, calls, allocs, near = {}, {}, {}, {}
    for s in d.get("scopes", []):
        n = short(s["name"])
        if n is None:
            continue
        times[n] = times.get(n, 0) + s["total_ns"]
        near[n] = near.get(n, False) or s.get("near_probe_cost", False)
        calls[n] = calls.get(n, 0) + s["calls"]
        if "allocs" in s:
            allocs[n] = allocs.get(n, 0) + s["allocs"]
    copies = {}
    for c in d.get("copies", []):
        # copies of shared values; `persistent` ones are of compile-time constants
        # (the empty array literal a loop starts from), not the hidden copy
        n = c["function"].split(" (in ")[0].split(".")[-1]
        copies[n] = copies.get(n, 0) + c.get("shared", c["copies"])
    return {"times": times, "calls": calls, "allocs": allocs, "copies": copies, "near": near,
            "overhead_ns": d.get("overhead_ns"), "dropped": d.get("dropped", 0)}


def sample_report(path):
    d = json.load(open(path))
    times = {}
    for s in d.get("scopes", []):
        n = short(s["name"])
        if n is not None:
            times[n] = times.get(n, 0) + s["total_ns"]
    return {"times": times}


def samply_profile(prof_path, components, exe):
    """Inclusive CPU time per component from a samply profile, matching the
    mangled C names (`l_W_phHot`, `..._at___W_phHot_spec_0`) of each frame."""
    prof = json.load(open(prof_path))
    syms = json.load(open(prof_path[:-5] + ".syms.json"))
    strings = syms["string_table"]
    tables = []
    for lib in prof["libs"]:
        entry = next((e for e in syms["data"] if e["debug_name"] == lib["debugName"]), None)
        tbl = []
        if entry:
            for e in entry["symbol_table"]:
                tbl.append((e["rva"], e["rva"] + e["size"], strings[e["symbol"]]))
        tbl.sort()
        tables.append(tbl)
    import bisect
    pats = {c: re.compile(r"(^|_)W_" + re.escape(c) + r"($|_)") for c in components}
    times = {c: 0.0 for c in components}
    total = 0.0
    for t in prof["threads"]:
        st, ft, fu, rt = t["stackTable"], t["frameTable"], t["funcTable"], t["resourceTable"]
        names = []
        for i, addr in enumerate(ft["address"]):
            func = ft["func"][i]
            res = fu["resource"][func]
            lib = rt["lib"][res] if res is not None and res >= 0 else None
            nm = ""
            if lib is not None and lib < len(tables) and addr is not None and addr >= 0:
                tbl = tables[lib]
                k = bisect.bisect_right(tbl, (addr, float("inf"), "")) - 1
                if k >= 0 and tbl[k][0] <= addr < tbl[k][1]:
                    nm = tbl[k][2]
            names.append(nm)
        frame_comp = [next((c for c, p in pats.items() if p.search(nm)), None) for nm in names]
        samples = t["samples"]
        deltas = samples.get("threadCPUDelta")
        for i, s in enumerate(samples["stack"]):
            if s is None:
                continue
            w = deltas[i] if deltas and deltas[i] is not None else 1000
            if w == 0:
                continue
            total += w
            seen = set()
            while s is not None:
                c = frame_comp[st["frame"][s]]
                if c is not None:
                    seen.add(c)
                s = st["prefix"][s]
            for c in seen:
                times[c] += w
    return {"times": {c: v * 1000 for c, v in times.items()}, "total_ns": total * 1000}


def leanprofiler_report(path):
    d = json.load(open(path))
    times, calls = {}, {}
    for r in d["rows"]:
        n = r["key"]["name"]
        times[n] = times.get(n, 0) + r["total_ns"]
        calls[n] = calls.get(n, 0) + r["calls"]
    return {"times": times, "calls": calls}


def components(bench):
    """Ground-truth components of a workload: its phases, by wall time; for
    tasks, the task functions, by the sum of the tasks' own durations."""
    out = []
    for p in bench["phases"]:
        if bench["workload"] == "tasks":
            out.append(("taskWork" + p["name"][len("phTasks"):], p["cpu_ns"]))
        else:
            out.append((p["name"], p["wall_ns"]))
    return out


def run_one(cfg, workload, scale, bins=BINS):
    desc, exe, how = CONFIGS[cfg]
    tag = f"{cfg}-{workload}"
    rep_json = os.path.join(OUT, tag + ".json")
    if os.path.exists(rep_json):
        os.remove(rep_json)
    env = {"LEANPROF_QUIET": "1"}
    args = [workload, str(scale)]
    if how == "sample":
        cmd = [LP, "sample", "--out", os.path.join(OUT, tag + ".samply.json"), exe, "--", *args]
    elif how == "samply":
        cmd = ["samply", "record", "--save-only", "--unstable-presymbolicate", "-o",
               os.path.join(OUT, tag + ".samply.json"), binpath(cfg, exe), *args]
    elif how == "leanprofiler":
        cmd = [binpath(cfg, exe), *args]
        env.update({"LEAN_PROFILE": "1", "LEAN_PROFILE_SUMMARY_OUT": rep_json,
                    "LEAN_PROFILE_OUT": os.path.join(OUT, tag + ".trace.json")})
    else:
        cmd = [binpath(cfg, exe), *args]
        env["LEANPROF_JSON"] = rep_json
    t0 = time.perf_counter()
    r = sh(cmd, env=env, check=False)
    ext = time.perf_counter() - t0
    bench = parse_bench(r.stdout)
    if r.returncode != 0 or bench is None:
        log(f"  {tag} failed ({r.returncode}): {r.stderr[-800:]}")
        return None
    comps = [c for c, _ in components(bench)]
    rep = None
    try:
        if how == "sample":
            rep = sample_report(os.path.join(BENCH, ".lake", "leanprof", "report.json"))
        elif how == "samply":
            rep = samply_profile(os.path.join(OUT, tag + ".samply.json"), comps, exe)
        elif how == "leanprofiler":
            rep = leanprofiler_report(rep_json)
        elif cfg != "plain":
            rep = leanprof_report(rep_json)
    except (OSError, ValueError, KeyError) as e:
        log(f"  {tag}: cannot read the report: {e}")
    return {"bench": bench, "external_s": ext, "report": rep}


# ---------------------------------------------------------------- analysis


def med(xs):
    return statistics.median(xs) if xs else None


def analyse(runs, configs):
    """runs[cfg][workload] = list of run results."""
    res = {}
    for w in WORKLOADS:
        plain = [r for r in runs.get("plain", {}).get(w, []) if r]
        if not plain:
            continue
        truth = {}
        for r in plain:
            for c, ns in components(r["bench"]):
                truth.setdefault(c, []).append(ns)
        truth = {c: med(v) for c, v in truth.items()}
        tsum = sum(truth.values())
        tshare = {c: v / tsum for c, v in truth.items()}
        plain_wall = med([sum(p["wall_ns"] for p in r["bench"]["phases"]) for r in plain])
        expected_calls = plain[0]["bench"]["calls"]
        expected_copies = plain[0]["bench"]["copies"]
        expected_allocs = plain[0]["bench"]["allocs"]
        total_scopes = sum(v for k, v in expected_calls.items())
        res[w] = {"truth_ns": truth, "truth_share": tshare, "plain_wall_ns": plain_wall,
                  "expected_calls": expected_calls, "configs": {}}
        for cfg in configs:
            rs = [r for r in runs.get(cfg, {}).get(w, []) if r]
            if not rs:
                continue
            walls = [sum(p["wall_ns"] for p in r["bench"]["phases"]) for r in rs]
            slow = [x / plain_wall for x in walls]
            out = {"runs": len(rs), "slowdown": med(slow), "slowdown_min": min(slow), "slowdown_max": max(slow),
                   "wall_ns": med(walls), "external_s": med([r["external_s"] for r in rs])}
            if cfg not in ("plain",) and cfg in LEANPROF_EXACT:
                out["ns_per_scope"] = (med(walls) - plain_wall) / total_scopes
            reps = [r["report"] for r in rs if r["report"]]
            if cfg != "plain" and reps:
                maes, maxes, ratios, per_comp, per_near = [], [], [], {}, {}
                for rep in reps:
                    got = {c: rep["times"].get(c) for c in truth}
                    if any(v is None for v in got.values()):
                        continue
                    gsum = sum(got.values())
                    if gsum <= 0:
                        continue
                    errs = [abs(got[c] / gsum - tshare[c]) * 100 for c in truth]
                    maes.append(sum(errs) / len(errs))
                    maxes.append(max(errs))
                    ratios.append(gsum / tsum)
                    for c in truth:
                        per_comp.setdefault(c, []).append(got[c] / truth[c])
                        if "near" in rep:
                            per_near.setdefault(c, []).append(bool(rep["near"].get(c)))
                if maes:
                    out["share_mae_pp"] = med(maes)
                    out["share_mae_pp_max"] = max(maes)
                    out["share_max_err_pp"] = med(maxes)
                    out["total_ratio"] = med(ratios)
                    if cfg in LEANPROF_EXACT:
                        # what each scope still adds to the report after the subtraction
                        out["residual_ns_per_scope"] = (med(ratios) - 1) * tsum / total_scopes
                    out["total_ratio_min"] = min(ratios)
                    out["total_ratio_max"] = max(ratios)
                    out["component_ratio"] = {c: med(v) for c, v in per_comp.items()}
                    if per_near:
                        # flagged "near the probe cost" in most runs
                        out["component_near"] = {c: sum(v) * 2 > len(v) for c, v in per_near.items()}
                else:
                    out["share_note"] = "components missing from the report"
                # call counts
                if "calls" in reps[0]:
                    checked, wrong = 0, {}
                    for rep in reps:
                        for name, n in expected_calls.items():
                            if cfg == "leanprofiler" and name not in rep["calls"]:
                                continue  # only phases and tasks are spans
                            if cfg == "auto" and name in LABEL_ONLY:
                                continue  # a `profile!` label inside a function, not a function
                            checked += 1
                            got = rep["calls"].get(name, 0)
                            if got != n:
                                wrong[name] = (got, n)
                    out["calls_checked"] = checked
                    out["calls_wrong"] = wrong
                if cfg in SHIMS and expected_copies:
                    wrong = {}
                    for rep in reps:
                        for name, n in expected_copies.items():
                            got = rep["copies"].get(name, 0)
                            if got != n:
                                wrong[name] = (got, n)
                    out["copies_wrong"] = wrong
                if cfg == "allocs" and expected_allocs:
                    got = {name: reps[0]["allocs"].get(name, 0) for name in expected_allocs}
                    out["allocs"] = {name: (got[name], n) for name, n in expected_allocs.items()}
            res[w]["configs"][cfg] = out
    return res


def check(res, configs):
    problems = []
    for w, wr in res.items():
        for cfg in configs:
            o = wr["configs"].get(cfg)
            if o is None:
                if cfg in LEANPROF_EXACT or cfg == "plain":
                    problems.append(f"{w}/{cfg}: no result")
                continue
            if cfg in LEANPROF_EXACT:
                if o.get("calls_wrong"):
                    problems.append(f"{w}/{cfg}: call counts not exact: {o['calls_wrong']}")
                if not o.get("calls_checked"):
                    problems.append(f"{w}/{cfg}: no call counts checked")
                if o.get("copies_wrong"):
                    problems.append(f"{w}/{cfg}: copy counts not exact: {o['copies_wrong']}")
            if w in TOL_CHECKED.get(cfg, ()):
                ratio = o.get("total_ratio")
                lo, hi = TOL
                if ratio is None or not (lo <= ratio <= hi):
                    problems.append(f"{w}/{cfg}: reported total is {fx(ratio)}x the plain time "
                                    f"(tolerance {lo:.2f}-{hi:.2f})")
    return problems


# ---------------------------------------------------------------- report


def machine():
    def out(cmd, cwd=BENCH):
        try:
            return subprocess.run(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT).stdout.strip()
        except OSError:
            return "?"
    cpu = platform.processor()
    if sys.platform == "darwin":
        cpu = out(["sysctl", "-n", "machdep.cpu.brand_string"])
        osv = "macOS " + out(["sw_vers", "-productVersion"])
    else:
        try:
            cpu = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
        except (OSError, StopIteration):
            pass
        osv = platform.platform()
    return {
        "cpu": cpu, "cores": os.cpu_count(), "os": osv, "arch": platform.machine(),
        "lean": out(["lean", "--version"]),
        "cc": out(["cc", "--version"]).splitlines()[0] if out(["cc", "--version"]) else "?",
        "samply": out(["samply", "--version"]) if shutil.which("samply") else "not installed",
        "commit": out(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT),
        "date": time.strftime("%Y-%m-%d %H:%M"),
        "load": " ".join(f"{x:.1f}" for x in os.getloadavg()),
    }


def fx(x, digits=2):
    return "–" if x is None else f"{x:.{digits}f}"


def write_md(path, meta, res, configs, skipped, lcb, before):
    L = []
    m = meta["machine"]
    L.append("# Benchmark and accuracy results\n")
    L.append(f"Generated by `python3 bench/run.py{' --quick' if meta['quick'] else ''}` "
             f"({meta['reps']} runs of each workload and configuration, interleaved in shuffled order; "
             f"scale {meta['scale']}%). Raw numbers: [`{os.path.basename(meta['json'])}`]({os.path.basename(meta['json'])}).\n")
    L.append(f"- Machine: {m['cpu']}, {m['cores']} cores, {m['os']} ({m['arch']})")
    L.append(f"- {m['lean']}; {m['cc']}; samply {m['samply']}")
    L.append(f"- leanprof commit `{m['commit']}`, {m['date']}; load average at start {meta['load_start']}, at end {meta['load_end']}")
    L.append(f"- Total suite time {meta['elapsed_s'] / 60:.1f} min\n")
    if meta.get("noisy"):
        L.append("> Other jobs were running on this machine, so timings are noisy. Each cell is the "
                 "median of the runs, with the range (min–max) where it matters; compare medians, "
                 "and treat differences inside the range as noise.\n")
    for cfg, why in skipped.items():
        L.append(f"> **{cfg} skipped**: {why}\n")
    headline(L, res, configs)
    L.append("## Configurations\n")
    L.append("| config | what runs |\n|---|---|")
    for cfg in configs:
        L.append(f"| `{cfg}` | {CONFIGS[cfg][0]} |")
    L.append("")
    L.append("## Workloads\n")
    L.append("| workload | what | plain time (median) | components (ground truth share) |\n|---|---|---|---|")
    for w, wr in res.items():
        comps = ", ".join(f"`{c}` {wr['truth_share'][c] * 100:.1f}%" for c in wr["truth_ns"])
        L.append(f"| `{w}` | {WORKLOAD_INFO[w]} | {wr['plain_wall_ns'] / 1e6:.1f} ms | {comps} |")
    L.append("\nGround truth: the plain build's own clock reads around each phase (for `tasks`, "
             "around each task, summed). A tool's share for a component is its reported inclusive time "
             "of that function or scope over the sum for all components of the workload.\n")

    cols = [c for c in configs if c != "plain"]

    def table(title, key, fmt, note=None, cfgs=None):
        cfgs = cfgs or cols
        L.append(f"## {title}\n")
        if note:
            L.append(note + "\n")
        L.append("| workload | " + " | ".join(f"`{c}`" for c in cfgs) + " |")
        L.append("|---|" + "---|" * len(cfgs))
        for w, wr in res.items():
            row = []
            for c in cfgs:
                o = wr["configs"].get(c)
                row.append(fmt(o) if o else "–")
            L.append(f"| `{w}` | " + " | ".join(row) + " |")
        L.append("")

    table("Slowdown against plain", "slowdown",
          lambda o: f"{o['slowdown']:.2f}× ({o['slowdown_min']:.2f}–{o['slowdown_max']:.2f})",
          "Program time (sum of its phases) over the plain build's median; median of runs, range in brackets.")
    table("Cost per scope", "ns_per_scope",
          lambda o: fx(o.get("ns_per_scope"), 1) + " ns" if o.get("ns_per_scope") is not None else "–",
          "(time with the tool − plain time) / number of scopes or calls the workload makes; "
          "meaningful where scopes are many and small (`tiny`, `rec`, `tasks`).",
          cfgs=[c for c in cols if c in LEANPROF_EXACT])
    table("Accuracy: error in share of time", "share_mae_pp",
          lambda o: (f"{o['share_mae_pp']:.1f} (max {o['share_max_err_pp']:.1f})" if "share_mae_pp" in o
                     else o.get("share_note", "–")),
          "Mean absolute error of each component's share of time against the ground truth, in "
          "percentage points (median of runs; in brackets the largest single-component error). 0 is perfect.")
    table("Residual per scope after subtraction", "residual_ns_per_scope",
          lambda o: (f"{o['residual_ns_per_scope']:+.1f} ns" if "residual_ns_per_scope" in o else "–"),
          "(reported total − plain time) / the workload's counted calls (the `calls` it prints; `run --auto` "
          "also times functions not counted there, such as `K.spin`). Positive: time leanprof leaves in "
          "the report; negative: it subtracts more than its probes cost.",
          cfgs=[c for c in cols if c in LEANPROF_EXACT])
    table("Accuracy: reported total over plain time", "total_ratio",
          lambda o: (f"{o['total_ratio']:.2f} ({o['total_ratio_min']:.2f}–{o['total_ratio_max']:.2f})"
                     if "total_ratio" in o else "–"),
          "Sum of the tool's reported times for the components over the plain build's. For leanprof this "
          "is after it subtracts its own overhead, so 1.00 means the report matches the uninstrumented "
          "program; for samplers it is sampled CPU time.")
    table("Exact call counts", "calls",
          lambda o: ("–" if "calls_checked" not in o else
                     ("✅ exact" if not o["calls_wrong"] else
                      "❌ " + ", ".join(f"{k} {g:,} of {n:,}" for k, (g, n) in o["calls_wrong"].items()))),
          "Every function or scope with a known call count (samplers have no counts; LeanProfiler only "
          "has phase and task spans).",
          cfgs=[c for c in cols if c in LEANPROF_EXACT or c == "leanprofiler"])

    L.append("## Per component\n")
    L.append("Reported time of each component over its plain time (median of runs). `*`: leanprof "
             "flagged the row as near the probe cost (in most runs), telling the reader to take its time "
             "from `leanprof sample`.\n")
    flagged, clean = [], []
    for w, wr in res.items():
        for c in [c for c in cols if c in ("profile", "run", "auto")]:  # the others add costs they do not subtract
            o = wr["configs"].get(c) or {}
            for comp, r in (o.get("component_ratio") or {}).items():
                if r is None or "component_near" not in o:
                    continue
                (flagged if o["component_near"].get(comp) else clean).append((abs(r - 1), f"`{w}`/`{comp}` `{c}`"))
    if flagged or clean:
        flagged.sort()
        clean.sort()
        fe = [e for e, _ in flagged]
        line = (f"Flag calibration (`profile`, `run`, `auto`; the other modes add costs they do not subtract): "
                f"{len(clean)} unflagged component rows, {len(flagged)} flagged.")
        if clean:
            line += (f" Unflagged: median error {med([e for e, _ in clean]) * 100:.0f}%, largest "
                     f"{clean[-1][0] * 100:.0f}% ({clean[-1][1]}).")
        if fe:
            line += (f" Flagged: median error {med(fe) * 100:.0f}%, "
                     f"{sum(e > 0.1 for e in fe)} of {len(fe)} off by more than 10%.")
        L.append(line + "\n")
    for w, wr in res.items():
        L.append(f"**{w}**\n")
        L.append("| component | truth | " + " | ".join(f"`{c}`" for c in cols) + " |")
        L.append("|---|---|" + "---|" * len(cols))
        for comp, ns in wr["truth_ns"].items():
            row = []
            for c in cols:
                o = wr["configs"].get(c) or {}
                row.append(fx((o.get("component_ratio") or {}).get(comp)) +
                           ("*" if (o.get("component_near") or {}).get(comp) else ""))
            L.append(f"| `{comp}` | {ns / 1e6:.2f} ms | " + " | ".join(row) + " |")
        L.append("")

    extra = []
    for w, wr in res.items():
        for c, o in wr["configs"].items():
            if o.get("copies_wrong") is not None and c in SHIMS:
                extra.append(f"- `{w}`/`{c}`: copies " + ("exact" if not o["copies_wrong"] else
                             ", ".join(f"{k} {g:,} of {n:,}" for k, (g, n) in o["copies_wrong"].items())))
            if o.get("allocs"):
                extra.append(f"- `{w}`/`{c}`: allocations " + ", ".join(
                    f"`{k}` {g:,} (expected {n:,})" for k, (g, n) in o["allocs"].items()))
    if extra:
        L.append("## Copies and allocations\n")
        L.extend(extra)
        L.append("")

    if lcb:
        L.append("## Real program: lean-compiler-backend\n")
        L.append(lcb["note"] + "\n")
        L.append("| config | slowdown (median, range) |\n|---|---|")
        for c, o in lcb["configs"].items():
            L.append(f"| `{c}` | {o['slowdown']:.2f}× ({o['slowdown_min']:.2f}–{o['slowdown_max']:.2f}) |")
        L.append("")
        if lcb.get("agreement"):
            L.append("Inclusive time of the top Lean declarations (by samply), as a share of the run, per tool. "
                     "No ground truth here: this shows where the tools agree.\n")
            tools = lcb["agreement_tools"]
            L.append("| declaration | " + " | ".join(f"`{t}`" for t in tools) + " |")
            L.append("|---|" + "---|" * len(tools))
            for name, vals in lcb["agreement"]:
                L.append(f"| `{name}` | " + " | ".join(fx(vals.get(t), 1) + "%" if vals.get(t) is not None else "–"
                                                      for t in tools) + " |")
            L.append("")
            if lcb.get("agreement_mae"):
                L.append("Mean absolute difference from samply: " + ", ".join(
                    f"`{t}` {v:.1f} pp" for t, v in lcb["agreement_mae"].items()) + "\n")

    if before:
        L.append("## Before and after the runtime fixes\n")
        L.append(before["note"] + "\n")
        L.append("| workload | config | metric | before | after |\n|---|---|---|---|---|")
        for row in before["rows"]:
            L.append("| " + " | ".join(row) + " |")
        L.append("")
    open(path, "w").write("\n".join(L) + "\n")


HEAD_TOOLS = [("profile", "leanprof `profile!`"), ("auto", "leanprof `run --auto`"),
              ("sample", "leanprof `sample`"), ("samply", "samply"), ("leanprofiler", "LeanProfiler")]


def headline(L, res, configs):
    """The compact tables at the top: accuracy first, then cost."""
    tools = [(c, n) for c, n in HEAD_TOOLS if c in configs]
    L.append("## Headline\n")
    L.append("Error in each function's share of time against the ground truth, in percentage points "
             "(mean over the workload's functions, median of runs; lower is better), and whether "
             "leanprof's call counts are exact in every mode. Samplers report no counts; LeanProfiler "
             "only has phase and task spans.\n")
    L.append("| workload | " + " | ".join(n for _, n in tools) + " | leanprof calls |")
    L.append("|---|" + "---|" * (len(tools) + 1))
    for w, wr in res.items():
        row = []
        for c, _ in tools:
            o = wr["configs"].get(c) or {}
            row.append(fx(o.get("share_mae_pp"), 1))
        exact = [wr["configs"][c].get("calls_wrong") for c in LEANPROF_EXACT if c in wr["configs"]]
        bad = sorted({k for e in exact if e for k in e})
        calls = "–" if not exact else ("✅ exact" if not bad else "❌ " + ", ".join(bad))
        L.append(f"| `{w}` | " + " | ".join(row) + f" | {calls} |")
    L.append("")
    L.append("Reported total over the plain program's time (1.00: the report matches the uninstrumented "
             "program; for leanprof after it subtracts its own overhead) / slowdown of the program:\n")
    L.append("| workload | " + " | ".join(n for _, n in tools) + " |")
    L.append("|---|" + "---|" * len(tools))
    for w, wr in res.items():
        row = []
        for c, _ in tools:
            o = wr["configs"].get(c)
            row.append(f"{fx(o.get('total_ratio'))} / {fx(o.get('slowdown'))}×" if o else "–")
        L.append(f"| `{w}` | " + " | ".join(row) + " |")
    L.append("")
    worse = []
    for w, wr in res.items():
        ref = (wr["configs"].get("samply") or {}).get("share_mae_pp")
        if ref is None:
            continue
        for c in ("profile", "auto", "sample"):
            v = (wr["configs"].get(c) or {}).get("share_mae_pp")
            if v is not None and v > ref + 0.5:
                worse.append(f"`{w}`: {dict(HEAD_TOOLS)[c]} {v:.1f} pp against samply's {ref:.1f} pp")
    if worse:
        L.append("**Where leanprof is less accurate than samply** (by more than 0.5 pp): " +
                 "; ".join(worse) + ".\n")
    elif "samply" in configs:
        L.append("leanprof is within 0.5 pp of samply, or better, on every workload.\n")


def before_after(before_json, res):
    b = json.load(open(before_json))
    rows = []
    for w, wr in res.items():
        bw = b["results"].get(w)
        if not bw:
            continue
        for cfg in ("profile", "run", "auto", "allocs", "counters", "frees"):
            o, bo = wr["configs"].get(cfg), bw["configs"].get(cfg)
            if not o or not bo:
                continue
            for key, label, f in [("total_ratio", "reported/plain", lambda x: fx(x)),
                                  ("share_mae_pp", "share error (pp)", lambda x: fx(x, 1)),
                                  ("slowdown", "slowdown", lambda x: fx(x) + "×")]:
                if key in o and key in bo:
                    rows.append([f"`{w}`", f"`{cfg}`", label, f(bo[key]), f(o[key])])
            bw_, aw_ = bo.get("calls_wrong"), o.get("calls_wrong")
            if bw_ is not None and aw_ is not None and (bw_ or aw_):
                fmt = lambda d: "exact" if not d else ", ".join(f"{k} {g:,}/{n:,}" for k, (g, n) in d.items())
                rows.append([f"`{w}`", f"`{cfg}`", "calls", fmt(bw_), fmt(aw_)])
    note = (f"`before`: the same suite and machine with `c/leanprof.c` as it was before the fixes "
            f"({b['meta']['reps']} runs, {b['meta']['machine']['date']}). Rows where something changed "
            "beyond noise are the point; the rest show the fixes cost nothing.")
    return {"note": note, "rows": rows}


# ---------------------------------------------------------------- lcb


def lcb_suite(src, reps, configs, skipped):
    """The real program: lean-compiler-backend compiling zlib, on a copy of
    the project (leanprof run rebuilds it)."""
    work = os.path.join(WORK, "lcb")
    if not os.path.isdir(work):
        log(f"copying {src} to {work}")
        shutil.copytree(src, work, symlinks=True)
    inputs = sorted(glob.glob(os.path.join(work, "zlib", "*.ssa")))
    target = "aarch64-macos" if platform.machine() in ("arm64", "aarch64") else "x86_64-linux"
    args = ["--target", target, "--optimize", "--allocate", *inputs, "-o", os.path.join(OUT, "lcb.s")]
    cfgs = [c for c in ["plain", "run", "auto", "allocs", "counters", "frees", "sample", "samply"]
            if c in configs and c not in skipped]
    bins = os.path.join(WORK, "lcb-bins")
    log("building lean-compiler-backend")
    sh(["lake", "build", "leanprof"], cwd=ROOT)
    remove_objects(work)
    remove_exes(work, ["lcb"])
    sh(["lake", "build", "lcb"], cwd=work)
    for cfg in cfgs:
        os.makedirs(os.path.join(bins, cfg), exist_ok=True)
        how = CONFIGS[cfg][2]
        if isinstance(how, list):
            log(f"  building lcb for {cfg}")
            sh([LP, "run", "--keep", *how, "lcb", "--", *args], cwd=work, env={"LEANPROF_QUIET": "1"})
        else:
            remove_objects(work)
            remove_exes(work, ["lcb"])
            sh(["lake", "build", "lcb"], cwd=work)
        shutil.copy2(os.path.join(work, ".lake", "build", "bin", "lcb"), os.path.join(bins, cfg, "lcb"))
    remove_objects(work)
    remove_exes(work, ["lcb"])
    sh(["lake", "build", "lcb"], cwd=work)
    times = {c: [] for c in cfgs}
    reports = {c: None for c in cfgs}
    order = list(cfgs)
    rnd = random.Random(7)
    for rep in range(-1, reps):  # run -1 warms the caches and is not counted
        rnd.shuffle(order)
        for cfg in order:
            how = CONFIGS[cfg][2]
            exe = os.path.join(bins, cfg, "lcb")
            rj = os.path.join(OUT, f"lcb-{cfg}.json")
            env = {"LEANPROF_QUIET": "1", "LEANPROF_JSON": rj}
            if how == "sample":
                cmd = [LP, "sample", "--out", os.path.join(OUT, "lcb-sample.samply.json"), "lcb", "--", *args]
            elif how == "samply":
                cmd = ["samply", "record", "--save-only", "--unstable-presymbolicate", "-o",
                       os.path.join(OUT, "lcb-samply.samply.json"), exe, *args]
            else:
                cmd = [exe, *args]
            t0 = time.perf_counter()
            r = sh(cmd, cwd=work, env=env, check=False)
            dt = time.perf_counter() - t0
            if r.returncode != 0:
                log(f"  lcb {cfg} failed: {r.stderr[-500:]}")
                continue
            if rep < 0:
                continue
            if how == "sample":
                # `leanprof sample` also runs `lake build` and its own analysis: time samply only
                times[cfg].append(dt)
                reports[cfg] = json.load(open(os.path.join(work, ".lake", "leanprof", "report.json")))
            else:
                times[cfg].append(dt)
                if os.path.exists(rj):
                    reports[cfg] = json.load(open(rj))
    base = med(times.get("plain", []))
    out = {"configs": {}, "note": (
        f"`lcb --target {target} --optimize --allocate` on zlib's four `.ssa` files, on a copy of the project; "
        f"process wall time, {reps} runs each (plain: {base:.3f} s median). The `sample` row includes "
        "`leanprof sample`'s no-op `lake build` and its analysis of the profile, so it overstates "
        "samply's cost; the `samply` row is samply alone. lcb has no `profile!` scopes, so `run`, "
        "`--allocs`, `--counters` and `--frees` time nothing here: their rows are the cost of the "
        "probes alone.")}
    for c in cfgs:
        if times[c]:
            s = [t / base for t in times[c]]
            out["configs"][c] = {"slowdown": med(s), "slowdown_min": min(s), "slowdown_max": max(s),
                                 "wall_s": med(times[c])}
    # agreement on inclusive time of top declarations
    shares = {}
    if reports.get("auto"):
        d = reports["auto"]
        # the program's time with leanprof's overhead removed: its outermost
        # scope (`main`), not the wall time of the slowed-down process
        wall = max(s["total_ns"] for s in d["scopes"])
        shares["auto"] = {s["name"]: s["total_ns"] / wall * 100 for s in d["scopes"]}
    if reports.get("sample"):
        d = reports["sample"]
        shares["sample"] = {s["name"]: s["total_ns"] / d["wall_ns"] * 100 for s in d["scopes"]}
    if "samply" in cfgs and os.path.exists(os.path.join(OUT, "lcb-samply.samply.json")):
        shares["samply"] = samply_decls(os.path.join(OUT, "lcb-samply.samply.json"), work)
    ref = "samply" if "samply" in shares else ("sample" if "sample" in shares else None)
    if ref:
        top = sorted(((n, v) for n, v in shares[ref].items()
                      if not n.startswith("initialize") and n not in ("main", "lean_main")),
                     key=lambda x: -x[1])[:12]
        tools = [t for t in ("samply", "sample", "auto") if t in shares]
        out["agreement_tools"] = tools
        out["agreement"] = [(n, {t: shares[t].get(n) for t in tools}) for n, _ in top]
        out["agreement_mae"] = {}
        for t in tools:
            if t == ref:
                continue
            diffs = [abs(shares[t][n] - v) for n, v in top if shares[t].get(n) is not None]
            if diffs:
                out["agreement_mae"][t] = sum(diffs) / len(diffs)
    return out


def samply_decls(prof_path, work):
    """Inclusive share per Lean declaration in a samply profile, with names
    demangled by leanprof (the same names `run --auto` reports)."""
    prof = json.load(open(prof_path))
    syms = json.load(open(prof_path[:-5] + ".syms.json"))
    strings = syms["string_table"]
    import bisect
    tables = []
    for lib in prof["libs"]:
        entry = next((e for e in syms["data"] if e["debug_name"] == lib["debugName"]), None)
        tbl = sorted((e["rva"], e["rva"] + e["size"], strings[e["symbol"]]) for e in (entry or {}).get("symbol_table", []))
        tables.append(tbl)
    raw_names = set()
    per_thread = []
    for t in prof["threads"]:
        ft, fu, rt = t["frameTable"], t["funcTable"], t["resourceTable"]
        names = []
        for i, addr in enumerate(ft["address"]):
            res = fu["resource"][ft["func"][i]]
            lib = rt["lib"][res] if res is not None and res >= 0 else None
            nm = ""
            if lib is not None and addr is not None and addr >= 0:
                tbl = tables[lib]
                k = bisect.bisect_right(tbl, (addr, float("inf"), "")) - 1
                if k >= 0 and tbl[k][0] <= addr < tbl[k][1]:
                    nm = tbl[k][2]
            names.append(nm)
            raw_names.add(nm)
        per_thread.append(names)
    lean = sorted(n for n in raw_names if re.match(r"_?(l_|lp_)", n))
    # demangle through leanprof's own demangler (`leanprof` has no subcommand
    # for it; the demangle-check tool prints pairs) - fall back to raw names
    demangled = demangle_names(lean, work)
    incl, total = {}, 0.0
    for t, names in zip(prof["threads"], per_thread):
        st = t["stackTable"]
        samples = t["samples"]
        deltas = samples.get("threadCPUDelta")
        for i, s in enumerate(samples["stack"]):
            if s is None:
                continue
            w = deltas[i] if deltas and deltas[i] is not None else 1000
            if not w:
                continue
            total += w
            seen = set()
            while s is not None:
                n = names[st["frame"][s]]
                d = demangled.get(n)
                if d:
                    seen.add(d)
                s = st["prefix"][s]
            for d in seen:
                incl[d] = incl.get(d, 0) + w
    return {n: v / total * 100 for n, v in incl.items()} if total else {}


def demangle_names(names, work):
    """Lean names for C symbols, via a small Lean helper in this package."""
    helper = os.path.join(BENCH, ".lake", "build", "bin", "demangle")
    if not os.path.exists(helper):
        sh(["lake", "build", "demangle"])
    inp = os.path.join(OUT, "symbols.txt")
    open(inp, "w").write("\n".join(names))
    r = sh([helper, inp], cwd=work, check=False)
    out = r.stdout.split("\n")[:len(names)]
    if r.returncode != 0 or len(out) != len(names):
        return {n: n for n in names}
    return dict(zip(names, out))


# ---------------------------------------------------------------- main


def main():
    global WORKLOADS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="smaller inputs and 3 runs (CI)")
    ap.add_argument("--reps", type=int, help="runs of each workload and configuration (default 7, quick 3)")
    ap.add_argument("--scale", type=int, help="input size in percent (default 100, quick 30)")
    ap.add_argument("--workloads", help="comma-separated subset of " + ",".join(WORKLOADS))
    ap.add_argument("--configs", help="comma-separated subset of " + ",".join(CONFIGS))
    ap.add_argument("--lcb", help="lean-compiler-backend checkout to benchmark as the real program "
                                  "(copied first; default $LCB_DIR; skipped when unset or with --quick)")
    ap.add_argument("--lcb-reps", type=int, default=5)
    ap.add_argument("--no-build", action="store_true", help="reuse the executables of the last build")
    ap.add_argument("--tolerance", default=None,
                    help="LO,HI: band for --check's reported/plain totals (default 0.75,1.35)")
    ap.add_argument("--check", action="store_true", help="exit 1 unless leanprof's counts are exact and "
                                                         "its totals are within tolerance of plain time")
    ap.add_argument("--before", help="results JSON of an earlier run, for a before/after table")
    ap.add_argument("--md", default=os.path.join(BENCH, "RESULTS.md"))
    ap.add_argument("--json", default=os.path.join(BENCH, "results.json"))
    ap.add_argument("--noisy", action="store_true", help="say in RESULTS.md that the machine was shared")
    a = ap.parse_args()
    if a.tolerance:
        global TOL
        lo, hi = (float(x) for x in a.tolerance.split(","))
        TOL = (lo, hi)
    reps = a.reps or (3 if a.quick else 7)
    scale = a.scale or (30 if a.quick else 100)
    if a.workloads:
        WORKLOADS = [w for w in a.workloads.split(",") if w]
    configs = [c for c in (a.configs.split(",") if a.configs else CONFIGS) if c]
    if "plain" not in configs:
        configs.insert(0, "plain")
    os.makedirs(OUT, exist_ok=True)
    start = time.time()
    load_start = " ".join(f"{x:.1f}" for x in os.getloadavg())

    skipped = {}
    if not a.no_build:
        log("building all configurations")
        build(configs)
    # samply needs perf events on Linux and a binary it may attach to on macOS:
    # try it on the plain build (a system binary such as sleep is refused)
    if "sample" in configs or "samply" in configs:
        why = have_samply()
        if why:
            for c in ("sample", "samply"):
                if c in configs:
                    skipped[c] = why
                    log(f"skipping {c}: {why}")
    configs_run = [c for c in configs if c not in skipped]

    runs = {c: {w: [] for w in WORKLOADS} for c in configs_run}
    rnd = random.Random(1)
    jobs = [(c, w) for c in configs_run for w in WORKLOADS]
    for rep in range(reps):
        rnd.shuffle(jobs)
        log(f"run {rep + 1}/{reps}")
        for c, w in jobs:
            runs[c][w].append(run_one(c, w, scale))
    # a configuration whose every run failed is reported as skipped
    for c in configs_run:
        if all(r is None for w in WORKLOADS for r in runs[c][w]):
            skipped[c] = "every run failed (see the log)"

    res = analyse(runs, configs_run)
    lcb = None
    lcb_dir = a.lcb or os.environ.get("LCB_DIR")
    if lcb_dir and not a.quick:
        lcb = lcb_suite(lcb_dir, a.lcb_reps, configs_run, skipped)
    meta = {"quick": a.quick, "reps": reps, "scale": scale, "machine": machine(), "json": a.json,
            "load_start": load_start, "load_end": " ".join(f"{x:.1f}" for x in os.getloadavg()),
            "elapsed_s": time.time() - start, "noisy": a.noisy, "configs": configs_run}
    before = before_after(a.before, res) if a.before else None
    json.dump({"meta": meta, "skipped": skipped, "results": res, "lcb": lcb,
               "raw": {c: {w: [r for r in rs] for w, rs in ws.items()} for c, ws in runs.items()}},
              open(a.json, "w"), indent=1, default=str)
    write_md(a.md, meta, res, configs_run, skipped, lcb, before)
    log(f"wrote {a.md} and {a.json} ({(time.time() - start) / 60:.1f} min)")
    if a.check:
        problems = check(res, configs_run)
        for p in problems:
            log("CHECK FAILED: " + p)
        if problems:
            sys.exit(1)
        log("check passed: call and copy counts exact, reported totals within tolerance")


if __name__ == "__main__":
    main()
