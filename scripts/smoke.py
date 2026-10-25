#!/usr/bin/env python3
"""Run every leanprof command on the examples and record what must not change.

    python3 scripts/smoke.py --save    # write scripts/smoke-baseline.json
    python3 scripts/smoke.py --check   # compare with it, exit 1 on a difference
    python3 scripts/smoke.py --add     # add facts the baseline lacks, keep the rest

Only deterministic facts are recorded: names, positions, call and copy counts,
which definitions and lines are blamed, exit codes. Times, sizes and heartbeat
amounts are left out, so the check holds across machines and runs. Run from
the repository root with Lean on PATH.
"""
import json, os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "scripts", "smoke-baseline.json")
LP = os.path.join(ROOT, ".lake", "build", "bin", "leanprof")
ENV = dict(os.environ, LEANPROF_QUIET="1")


def sh(*args, check=True, env=ENV, cwd=ROOT):
    p = subprocess.run(list(args), cwd=cwd, env=env, capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.exit(f"failed ({p.returncode}): {' '.join(args)}\n{p.stdout[-2000:]}\n{p.stderr[-2000:]}")
    return p


def load(path):
    with open(os.path.join(ROOT, path)) as f:
        return json.load(f)


def other_project():
    """Tests/Smoke, a project that does not depend on leanprof, profiled from a
    copy outside this repository by the command as packaged for a release, so
    a file missing from the package or a path relative to this checkout fails
    here (the release package once lacked runtime files, and every check run
    on leanprof itself passed)."""
    out = {}
    tag = "smoke-check"
    sh("sh", "scripts/package-release.sh", tag, "local")
    pkg = os.path.join(ROOT, "dist", f"leanprof-{tag}-local")
    lp = os.path.join(pkg, "bin", "leanprof")
    work = tempfile.mkdtemp(prefix="leanprof-smoke-")
    try:
        for f in ("lakefile.toml", "lake-manifest.json", "lean-toolchain", "Main.lean"):
            shutil.copy(os.path.join(ROOT, "Tests", "Smoke", f), work)
        def report(name):
            with open(os.path.join(work, name)) as f:
                return json.load(f)
        sh("lake", "build", "smoke", cwd=work)  # the normal build, which profiling must leave in place
        sh(lp, "run", "--json", "run.json", "smoke", "--", "2000", cwd=work)
        r = report("run.json")
        out["smoke.copies"] = sorted((c["function"], c["where"], c["kind"], c["shared"], c["multi_threaded"])
                                     for c in r["copies"] if c["shared"] + c["multi_threaded"] > 0)
        out["smoke.self_check"] = [r["self_check"]["ok"], r["self_check"]["warning"]]
        # the runtime `run` compiles for a project without leanprof: no outlined
        # code (Apple clang's outliner made the probes differ from calibration's)
        syms = sh("nm", os.path.join(work, ".lake", "leanprof", "runtime-core.o")).stdout
        out["smoke.runtime_outlined"] = syms.count("OUTLINED_FUNCTION")
        sh(lp, "run", "--auto", "--json", "auto.json", "smoke", "--", "2000", cwd=work)
        out["smoke.auto"] = sorted((s["name"], s["pos"], s["calls"]) for s in report("auto.json")["scopes"]
                                   if s["name"] in ("main", "buildWithHistory", "strings", "fib"))
        st = sh(lp, "stat", "--json", "stat.json", "smoke", "--", "2000", cwd=work)
        out["smoke.stat"] = [l.split()[1] for l in st.stdout.splitlines() if l.strip().startswith("copies")]
        sh(lp, "measure", "--runs", "1", "--warmup", "0", "--out", "measure.json", "smoke", "--", "2000", cwd=work)
        out["smoke.measure.copies"] = report("measure.json")["copies_total"]
        # the normal build is back: the program runs without writing a report
        p = sh(os.path.join(work, ".lake", "build", "bin", "smoke"), "10", cwd=work,
               env=dict(os.environ, LEANPROF_JSON=os.path.join(work, "plain.json")))
        out["smoke.restored"] = not os.path.exists(os.path.join(work, "plain.json")) and p.stdout.split()[0] == "10"
        out["smoke.doctor"] = sh(lp, "doctor", check=False, cwd=work).returncode
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(pkg, ignore_errors=True)
        tarball = pkg + ".tar.gz"
        if os.path.exists(tarball):
            os.remove(tarball)
    return out


def facts():
    out = {}
    sh("lake", "build", "leanprof", "copybug", "tasks", "taskchains", "server", "tests", "demangle-check")
    # tests
    t = sh(os.path.join(ROOT, ".lake", "build", "bin", "tests"), check=False)
    out["tests"] = "all tests passed" in t.stdout and t.returncode == 0
    # run: scopes and copies
    sh(LP, "run", "--json", "/tmp/smoke-run.json", "copybug", "--", "2000")
    r = load("/tmp/smoke-run.json")
    out["run.scopes"] = sorted((s["name"], s["pos"], s["calls"]) for s in r["scopes"])
    out["run.copies"] = sorted((c["function"], c["where"], c["kind"], c["shared"], c["multi_threaded"])
                               for c in r["copies"] if c["shared"] + c["multi_threaded"] > 0)
    # run with every opt-in probe
    sh(LP, "run", "--allocs", "--counters", "--frees", "--json", "/tmp/smoke-all.json", "copybug", "--", "2000")
    a = load("/tmp/smoke-all.json")
    out["all.copies"] = sum(c["shared"] + c["multi_threaded"] for c in a["copies"])
    out["all.allocs>0"] = sum(x["allocs"] for x in a["allocations"]) > 0
    out["all.reuse>0"] = sum(x["checks"] for x in a.get("reuse", [])) > 0
    out["all.frees"] = "frees" in a and "memory" in a
    # --auto: one row per declaration
    sh(LP, "run", "--auto", "--json", "/tmp/smoke-auto.json", "copybug", "--", "2000")
    au = load("/tmp/smoke-auto.json")
    calls = {s["name"]: s["calls"] for s in au["scopes"] if s.get("auto")}
    out["auto.calls"] = {k: calls.get(k) for k in ("main", "buildWithHistory", "build")}
    # tasks
    sh(LP, "run", "--json", "/tmp/smoke-tasks.json", "tasks")
    tk = load("/tmp/smoke-tasks.json")
    out["tasks"] = sorted((x["spawned_by"], x["tasks"]) for x in tk["tasks"])
    out["waits"] = sorted((w["function"], w["waits"]) for w in tk["waits"])
    sh(LP, "run", "--json", "/tmp/smoke-chains.json", "taskchains")
    out["taskchains"] = sorted((x["spawned_by"], x["tasks"]) for x in load("/tmp/smoke-chains.json")["tasks"])
    # explain: the lines it blames
    sh(LP, "run", "--json", ".lake/leanprof/report.json", "copybug", "--", "2000")
    e = sh(LP, "explain")
    out["explain"] = [l.strip() for l in e.stdout.splitlines() if l.strip().startswith(("why:", "where:"))]
    # measure --scope: one profile! scope's total instead of the process; an unknown scope fails
    sh(LP, "measure", "--runs", "1", "--warmup", "0", "--scope", "build", "--out", "/tmp/smoke-scope.json",
       "copybug", "--", "2000")
    sc = load("/tmp/smoke-scope.json")
    out["measure.scope"] = [sc["scope"], 0 < sc["time_ns"]["median"] < 1e9]
    out["measure.scope.missing"] = sh(LP, "measure", "--runs", "1", "--warmup", "0", "--scope", "nosuch",
                                      "--out", "/tmp/smoke-scope.json", "copybug", "--", "2000", check=False).returncode
    # compare: a report against itself
    out["compare.self"] = sh(LP, "compare", "/tmp/smoke-run.json", "/tmp/smoke-run.json", check=False).returncode
    # elab: what it blames (not amounts)
    sh(LP, "elab", "--heartbeats", "--threshold", "0", "--out", "/tmp/smoke-elab.json", "Examples/ElabHeavy.lean")
    el = load("/tmp/smoke-elab.json")
    out["elab.lines"] = sorted({s["pos"] for s in el["scopes"]})
    out["elab.ranges"] = sorted({r["range"].split(":", 1)[1].rsplit("-", 1)[0] for r in el.get("ranges", [])})
    out["elab.constants"] = sorted({c["name"] for c in el.get("constants", [])})[:40]
    # html renders
    sh(LP, "html", "-o", "/tmp/smoke.html", "/tmp/smoke-run.json")
    with open("/tmp/smoke.html") as f:
        page = f.read()
    out["html"] = all(n in page for n in ("buildWithHistory", "fib"))
    # demangler against Lean's own
    d = sh(os.path.join(ROOT, ".lake", "build", "bin", "demangle-check"), os.path.join(ROOT, ".lake", "build", "bin", "tests"))
    out["demangle"] = "0 mismatches" in d.stdout
    # live view, without a terminal
    tp = sh(LP, "top", "--plain", "--interval", "300", "--frames", "2", "server", "--", "60", "20", check=False)
    out["top"] = tp.returncode == 0 and "handle  (Examples/Server.lean:" in tp.stdout
    # doctor and help
    out["doctor"] = sh(LP, "doctor", check=False).returncode
    out["help.commands"] = sorted(l.split()[0] for l in sh(LP, "help").stdout.splitlines()
                                  if l.startswith("  ") and l.strip())
    out.update(other_project())
    return out


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    got = json.loads(json.dumps(facts()))  # tuples become lists, as in the file
    if mode == "--save":
        with open(BASELINE, "w") as f:
            json.dump(got, f, indent=1, sort_keys=True)
            f.write("\n")
        print(f"saved {BASELINE}")
        return
    with open(BASELINE) as f:
        want = json.load(f)
    if mode == "--add":
        new = sorted(set(got) - set(want))
        want.update({k: got[k] for k in new})
        with open(BASELINE, "w") as f:
            json.dump(want, f, indent=1, sort_keys=True)
            f.write("\n")
        print(f"added {', '.join(new) or 'nothing'} to {BASELINE}")
        return
    bad = [k for k in sorted(set(want) | set(got)) if want.get(k) != got.get(k)]
    for k in bad:
        print(f"DIFFERENT {k}:\n  baseline: {want.get(k)}\n  now:      {got.get(k)}")
    if bad:
        sys.exit(1)
    print(f"smoke: all {len(want)} facts match the baseline")


if __name__ == "__main__":
    main()
