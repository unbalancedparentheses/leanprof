#!/usr/bin/env python3
"""leanprof's JSON contract: real outputs checked against schemas/*.schema.json.

    python3 scripts/contract-check.py .lake/build/bin/leanprof
        runs every command that writes JSON (run, elab, measure, measure-pair,
        judge, explain, compare, experiment, fix, doctor, build, the live snapshot)
        on leanprof's own examples and validates each output; run from the
        repository root after `lake build leanprof copybug server`.

    python3 scripts/contract-check.py --validate NAME FILE...
        validates files against schemas/NAME.schema.json (other scripts use
        this for the outputs of their own runs).

The validator implements the part of JSON Schema 2020-12 the schemas use
(type, properties, required, items, enum, const, minimum, maxItems,
pattern, anyOf, allOf, if/then, $ref within and across the files), so the
check needs nothing beyond Python. Every document must also name its schema
in its `schema` field. Exits 1 on any failure.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMAS = os.path.join(ROOT, "schemas")
_cache = {}


def load_schema(file):
    if file not in _cache:
        with open(os.path.join(SCHEMAS, file)) as f:
            _cache[file] = json.load(f)
    return _cache[file]


def resolve(ref, file):
    target, _, pointer = ref.partition("#")
    file = target or file
    node = load_schema(file)
    for part in [p for p in pointer.split("/") if p]:
        node = node[part]
    return node, file


TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool) or (isinstance(v, float) and v.is_integer()),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


def errors(v, s, file, path="$"):
    """The ways `v` fails schema `s` (from `file`), as messages."""
    out = []
    if s is True or s == {}:
        return out
    if "$ref" in s:
        target, tfile = resolve(s["$ref"], file)
        out += errors(v, target, tfile, path)
    if "type" in s:
        ts = s["type"] if isinstance(s["type"], list) else [s["type"]]
        if not any(TYPES[t](v) for t in ts):
            return out + [f"{path}: {json.dumps(v)[:80]} is not of type {s['type']}"]
    if "const" in s and v != s["const"]:
        out.append(f"{path}: {json.dumps(v)[:80]} is not {json.dumps(s['const'])}")
    if "enum" in s and v not in s["enum"]:
        out.append(f"{path}: {json.dumps(v)[:80]} is not one of {s['enum']}")
    if "minimum" in s and TYPES["number"](v) and v < s["minimum"]:
        out.append(f"{path}: {v} is below {s['minimum']}")
    if "pattern" in s and isinstance(v, str) and not re.search(s["pattern"], v):
        out.append(f"{path}: {v!r} does not match {s['pattern']}")
    if isinstance(v, dict):
        for k in s.get("required", []):
            if k not in v:
                out.append(f"{path}: missing {k}")
        for k, sub in s.get("properties", {}).items():
            if k in v:
                out += errors(v[k], sub, file, f"{path}.{k}")
        extra = s.get("additionalProperties", True)
        if extra is not True:
            for k in v:
                if k not in s.get("properties", {}):
                    out += [f"{path}: unexpected {k}"] if extra is False else errors(v[k], extra, file, f"{path}.{k}")
    if isinstance(v, list):
        if "maxItems" in s and len(v) > s["maxItems"]:
            out.append(f"{path}: more than {s['maxItems']} items")
        if "items" in s:
            for i, x in enumerate(v):
                out += errors(x, s["items"], file, f"{path}[{i}]")
    if "anyOf" in s and not any(not errors(v, sub, file, path) for sub in s["anyOf"]):
        out.append(f"{path}: matches none of anyOf ({errors(v, s['anyOf'][0], file, path)[:2]})")
    for sub in s.get("allOf", []):
        out += errors(v, sub, file, path)
    if "if" in s and not errors(v, s["if"], file, path):
        out += errors(v, s.get("then", True), file, path)
    return out


def validate(name, doc):
    """Messages for `doc` against schemas/NAME.schema.json, and its `schema` tag."""
    file = f"{name}.schema.json"
    out = errors(doc, load_schema(file), file)
    tag = doc.get("schema") if isinstance(doc, dict) else None
    if not (isinstance(tag, dict) and tag.get("name") == f"leanprof.{name}"):
        out.append(f"$.schema: {tag!r} does not name leanprof.{name}")
    return out


failures = 0


def check(what, ok, detail=""):
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures += 1
        print("     " + str(detail)[:3000])


def check_doc(what, name, doc):
    errs = validate(name, doc)
    check(f"{what} ({name}.schema.json)", not errs, "\n     ".join(errs[:20]))
    return doc


def check_file(what, name, path):
    try:
        with open(path) as f:
            doc = json.load(f)
    except Exception as e:  # noqa: BLE001
        check(f"{what} ({name}.schema.json)", False, f"cannot read {path}: {e}")
        return {}
    return check_doc(what, name, doc)


def schemas_are_well_formed():
    names = sorted(f for f in os.listdir(SCHEMAS) if f.endswith(".schema.json"))
    for f in names:
        s = load_schema(f)
        check(f"schemas/{f} is a 2020-12 schema with an $id",
              s.get("$schema", "").endswith("2020-12/schema") and s.get("$id", "").endswith(f), s.get("$id"))
    # every $ref resolves
    def refs(node, file):
        if isinstance(node, dict):
            if "$ref" in node:
                try:
                    resolve(node["$ref"], file)
                except (KeyError, FileNotFoundError) as e:
                    check(f"{file}: $ref {node['$ref']} resolves", False, e)
            for v in node.values():
                refs(v, file)
        elif isinstance(node, list):
            for v in node:
                refs(v, file)
    for f in names:
        refs(load_schema(f), f)
    return names


def run(args, cwd=None, env=None, ok_codes=(0,)):
    e = dict(os.environ, LEANPROF_QUIET="1")
    e.update(env or {})
    p = subprocess.run(args, cwd=cwd, env=e, capture_output=True, text=True)
    if p.returncode not in ok_codes:
        print(f"     {' '.join(args)}: exit code {p.returncode}\n{p.stdout[-1500:]}\n{p.stderr[-1500:]}")
    return p


def stdout_json(what, p):
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError as e:
        check(f"{what} prints JSON", False, f"{e}: {p.stdout[:500]} {p.stderr[-500:]}")
        return {}


def full(lp):
    lp = os.path.abspath(lp)
    d = ".lake/leanprof/contract"
    os.makedirs(d, exist_ok=True)
    schemas_are_well_formed()
    # the validator itself: it must reject what the schemas rule out
    bad = {"schema": {"name": "leanprof.measure", "version": 1}, "version": 1, "leanprof": "measure", "runs": "3"}
    check("the validator rejects a summary with a missing field and a wrong type",
          any("missing time_ns" in e for e in validate("measure", bad)) and any("runs" in e for e in validate("measure", bad)))
    check("the validator rejects a document naming another schema", validate("judge", {"schema": {"name": "leanprof.fix"}}))

    run([lp, "run", "--allocs", "--counters", "--frees", "--json", f"{d}/run.json", "copybug", "--", "1000"])
    check_file("run --allocs --counters --frees", "run", f"{d}/run.json")
    run([lp, "run", "--json", f"{d}/run2.json", "copybug", "--", "2000"])
    r = check_file("run", "run", f"{d}/run2.json")
    p = r.get("provenance", {})
    check("run: provenance (Lean, platform, revision, flags, workload)",
          p.get("lean", {}).get("version") and p.get("platform", {}).get("target") and "rev" in (p.get("git") or {"rev": 1})
          and p.get("build", {}).get("mode") == "run" and p.get("workload", {}).get("executable") == "copybug"
          and p["workload"]["args"] == ["2000"] and p["workload"]["binary_hash"], p)
    if shutil.which("samply"):
        p = run([lp, "sample", "--json", f"{d}/sample.json", "copybug", "--", "2000"], ok_codes=(0, 1, 2))
        if p.returncode == 0:
            check_file("sample", "run", f"{d}/sample.json")
    run([lp, "elab", "--heartbeats", "--out", f"{d}/elab.json", "Examples/CopyBug.lean"])
    e = check_file("elab --heartbeats", "elab", f"{d}/elab.json")
    check("elab: provenance with the files' hashes", e.get("provenance", {}).get("build", {}).get("heartbeats") is True
          and [i["path"] for i in e["provenance"]["workload"]["inputs"]] == ["Examples/CopyBug.lean"], e.get("provenance"))

    for k in ("1", "2"):
        run([lp, "measure", "--runs", "2", "--warmup", "0", "--out", f"{d}/m{k}.json", "copybug", "--", "300"])
        check_file(f"measure ({k})", "measure", f"{d}/m{k}.json")
    j = check_doc("judge --json (summaries)", "judge",
                  stdout_json("judge", run([lp, "judge", "--json", f"{d}/m1.json", f"{d}/m2.json"], ok_codes=(0, 1))))
    check("judge: the verdict and the outcome agree",
          (j.get("verdict") == "KEEP") == (j.get("outcome") == "improved"), j)
    run([lp, "measure-pair", "--base", ".lake/build/bin/copybug", "--candidate", ".lake/build/bin/copybug",
         "--runs", "6", "--warmup", "0", "--out", f"{d}/pair.json", "--", "300"])
    check_file("measure-pair", "measure-pair", f"{d}/pair.json")
    j = check_doc("judge --json (paired)", "judge",
                  stdout_json("judge", run([lp, "judge", "--json", f"{d}/pair.json"], ok_codes=(0, 1))))
    check("judge: the same binary twice is never a correctness failure or a regression",
          j.get("outcome") in ("no_improvement", "insufficient_evidence", "improved"), j)
    # changed output: a correctness failure, never a mere no_improvement
    m2 = json.load(open(f"{d}/m2.json"))
    m2["output"]["hash"] = "fnv1a64:0000000000000000"
    json.dump(m2, open(f"{d}/m-wrong.json", "w"))
    j = stdout_json("judge", run([lp, "judge", "--json", f"{d}/m1.json", f"{d}/m-wrong.json"], ok_codes=(1,)))
    check("judge: changed output is a correctness_failure", j.get("outcome") == "correctness_failure"
          and j.get("measurement_valid") is True and j.get("correctness"), j)
    j = stdout_json("judge", run([lp, "judge", "--json", f"{d}/m1.json", f"{d}/m2.json"], ok_codes=(0, 1)))
    check("judge: the same program twice is compatible", j.get("provenance", {}).get("compatible") is True, j)
    # a damaged summary: an error naming the missing metric, never a verdict
    m2 = json.load(open(f"{d}/m2.json"))
    del m2["copies_total"]
    del m2["output"]["stable"]
    json.dump(m2, open(f"{d}/m-cut.json", "w"))
    p = run([lp, "judge", "--json", f"{d}/m1.json", f"{d}/m-cut.json"], ok_codes=(2,))
    check("judge: a summary without a metric is an error, not a verdict",
          p.returncode == 2 and "missing" in p.stderr and not p.stdout.strip(), p.stdout[:300] + p.stderr[-300:])
    m2 = json.load(open(f"{d}/m2.json"))
    m2["provenance"]["lean"]["version"] = "4.30.0"
    json.dump(m2, open(f"{d}/m-lean.json", "w"))
    j = stdout_json("judge", run([lp, "judge", "--json", f"{d}/m1.json", f"{d}/m-lean.json"], ok_codes=(1,)))
    check("judge: another Lean version is incompatible, not a valid DISCARD",
          j.get("outcome") == "incompatible" and j["provenance"]["compatible"] is False
          and any("different Lean versions" in r for r in j.get("incompatible", [])), j)
    j = stdout_json("judge", run([lp, "judge", "--json", "--allow-incompatible", f"{d}/m1.json", f"{d}/m-lean.json"],
                                 ok_codes=(0, 1)))
    check("judge --allow-incompatible: judged, and said so", j.get("outcome") != "incompatible"
          and any("--allow-incompatible" in n for n in j.get("notes", [])), j)
    r2 = json.load(open(f"{d}/run2.json"))
    r2["provenance"]["platform"]["target"] = "x86_64-unknown-linux-gnu"
    json.dump(r2, open(f"{d}/run-other.json", "w"))
    p = run([lp, "compare", f"{d}/run2.json", f"{d}/run-other.json"], ok_codes=(0, 1))
    check("compare: another platform is warned about", "warning: different platforms" in p.stdout, p.stdout[:500])
    j = stdout_json("compare", run([lp, "compare", "--json", f"{d}/run2.json", f"{d}/run-other.json"], ok_codes=(0, 1)))
    check("compare --json: the provenance check", j.get("provenance", {}).get("compatible") is False, j.get("provenance"))
    m2 = json.load(open(f"{d}/m2.json"))
    m2["command"] = ["other"]
    json.dump(m2, open(f"{d}/m-other.json", "w"))
    j = stdout_json("judge", run([lp, "judge", "--json", f"{d}/m1.json", f"{d}/m-other.json"], ok_codes=(1,)))
    check("judge: another command is incompatible, not a valid DISCARD",
          j.get("outcome") == "incompatible" and j.get("measurement_valid") is False, j)

    j = check_doc("explain --json", "explain",
                  stdout_json("explain", run([lp, "explain", "--json", "--report", f"{d}/run2.json"])))
    check("explain: one finding, ranked, its source as profiled", len(j.get("findings", [])) >= 1
          and j["findings"][0].get("rank") == 1 and j["findings"][0].get("stale") is False and j["stale_sources"] == []
          and j["provenance"]["workload"]["executable"] == "copybug", j)
    # a report older than its source: the lines may have moved
    shutil.copy(f"{d}/run2.json", f"{d}/run-old.json")
    os.utime(f"{d}/run-old.json", (1000000000, 1000000000))
    j = check_doc("explain --json of an old report", "explain",
                  stdout_json("explain", run([lp, "explain", "--json", "--report", f"{d}/run-old.json"])))
    check("explain: a source changed since the report is stale", j["findings"][0].get("stale") is True
          and j["stale_sources"][0]["file"] == "Examples/CopyBug.lean", j.get("stale_sources"))
    p = run([lp, "explain", "--report", f"{d}/run-old.json"])
    check("explain: and says so", "warning: Examples/CopyBug.lean modified after the report was written" in p.stdout,
          p.stdout[-500:])
    p = run([lp, "compare", "--json", f"{d}/run.json", f"{d}/run2.json"], ok_codes=(1,))
    j = check_doc("compare --json (run reports)", "compare", stdout_json("compare", p))
    check("compare: the regression and the exit code agree", j.get("regressed") is True and p.returncode == 1, j)
    check_doc("compare --json (elab reports)", "compare",
              stdout_json("compare", run([lp, "compare", "--json", f"{d}/elab.json", f"{d}/elab.json"])))

    # discovery
    p = run([lp, "doctor", "--json"])
    j = check_doc("doctor --json", "doctor", stdout_json("doctor", p))
    check("doctor: this project's targets and modes", j.get("ok") is True and p.returncode == 0
          and "copybug" in j["project"]["executables"] and j["project"]["test_driver"] == "tests"
          and j["modes"]["run"]["available"] and j["lean"]["supported"], j)
    empty = tempfile.mkdtemp(prefix="leanprof-contract-doctor-")
    p = run([lp, "doctor", "--json"], cwd=empty, ok_codes=(1,))
    j = check_doc("doctor --json outside a project", "doctor", stdout_json("doctor", p))
    check("doctor outside a project: a not_lake_project setup failure",
          j.get("ok") is False and "not_lake_project" in [f["code"] for f in j.get("setup_failures", [])], j)
    shutil.rmtree(empty, ignore_errors=True)

    # an error recorded for the caller (LEANPROF_ERROR_JSON)
    for args, want in [(["judge", f"{d}/no-such.json"], "not_found"), (["measure", "--bogus", "copybug"], "bad_argument")]:
        ef = os.path.abspath(f"{d}/error.json")
        if os.path.exists(ef):
            os.remove(ef)
        run([lp, *args], env={"LEANPROF_ERROR_JSON": ef}, ok_codes=(2,))
        e = check_file(f"the error of `leanprof {' '.join(args)}`", "error", ef)
        check(f"`leanprof {' '.join(args)}`: {want}", e.get("code") == want, e)

    # static copies, from the IR (nothing run), checked against the last run report
    j = check_doc("explain --static --json", "static",
                  stdout_json("explain --static", run([lp, "explain", "--static", "--json", "--no-build",
                                                       "--report", f"{d}/run2.json", "Examples.CopyBug"], ok_codes=(0, 1))))
    check("explain --static: a flag in CopyBug", any(f.get("file") == "Examples/CopyBug.lean" for f in j.get("flags", [])),
          j.get("flags"))

    # a measured build of Tests/Build (scripts/build-check.sh runs its experiments)
    bdir = tempfile.mkdtemp(prefix="leanprof-contract-build-")
    shutil.copytree("Tests/Build", bdir, dirs_exist_ok=True, ignore=shutil.ignore_patterns(".lake"))
    run([lp, "build", "--clean", "--quiet", "--json", "build.json"], cwd=bdir)
    b = check_file("build --clean", "build", os.path.join(bdir, "build.json"))
    check("build: every job with its peak memory, a critical path", b.get("jobs") and b["critical_path"]["steps"]
          and all(j["max_rss_bytes"] > 0 for j in b["jobs"]), b.get("critical_path"))
    shutil.rmtree(bdir, ignore_errors=True)

    # a live snapshot
    snap = f"{d}/live.json"
    subprocess.run([".lake/build/bin/server", "5", "5"], env=dict(os.environ, LEANPROF_LIVE=snap, LEANPROF_QUIET="1"),
                   stdout=subprocess.DEVNULL, check=True)
    check_file("live snapshot", "live", snap)

    # fix: a dry run of the last report (copybug's cause has no mechanical fix)
    p = run([lp, "fix", "--dry-run", "--json", "--report", f"{d}/run-old.json"], ok_codes=(0, 1))
    j = check_doc("fix --dry-run --json", "fix", stdout_json("fix", p))
    check("fix: warns that the source changed since the report",
          (j.get("stale_sources") or [{}])[0].get("file") == "Examples/CopyBug.lean"
          , j)
    check("fix: status and exit code agree", j.get("status") in ("dry_run", "no_mechanical_fix")
          and j.get("exit_code") == p.returncode, j)
    check_file("fix result.json", "fix", ".lake/leanprof/fix/result.json")

    # experiments, in compile-heartbeat mode on a copy of Tests/Experiment
    exp = tempfile.mkdtemp(prefix="leanprof-contract-")
    shutil.copytree("Tests/Experiment", exp, dirs_exist_ok=True, ignore=shutil.ignore_patterns(".lake", "result.txt"))
    genv = dict(os.environ, GIT_AUTHOR_NAME="contract", GIT_AUTHOR_EMAIL="contract@example.invalid",
                GIT_COMMITTER_NAME="contract", GIT_COMMITTER_EMAIL="contract@example.invalid")

    def git(*args):
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=exp, env=genv, check=True,
                       capture_output=True)
    with open(os.path.join(exp, ".gitignore"), "w") as f:
        f.write(".lake\n")
    git("init", "-q", "-b", "main")
    git("add", "-A")
    git("commit", "-q", "-m", "fixture")
    spec = os.path.join(exp, "Exp", "Spec.lean")
    src = open(spec).read()
    open(spec, "w").write(src.replace(":= by\n  intro v hv\n  unfold bucketOf\n  omega",
                                      ":=\n  fun v _ => Nat.mod_lt _ (by decide)"))
    run([lp, "experiment", "start", "--no-test", "--id", "contract"], cwd=exp, env=genv)
    p = run([lp, "experiment", "try", "--working-tree", "--no-commit", "--json"], cwd=exp, env=genv, ok_codes=(0, 1, 3))
    j = check_doc("experiment try --json", "experiment-try", stdout_json("experiment try", p))
    check("experiment try: the outcome matches the verdict",
          {"KEEP": "improved"}.get(j.get("verdict"), j.get("outcome")) == j.get("outcome"), j)
    check_doc("experiment status --json", "experiment-status",
              stdout_json("experiment status", run([lp, "experiment", "status", "--json"], cwd=exp, env=genv)))
    check_doc("experiment finish --json", "experiment-finish",
              stdout_json("experiment finish", run([lp, "experiment", "finish", "--json"], cwd=exp, env=genv)))
    shutil.rmtree(exp, ignore_errors=True)


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--validate":
        for path in sys.argv[3:]:
            check_file(path, sys.argv[2], path)
    else:
        full(sys.argv[1] if len(sys.argv) > 1 else ".lake/build/bin/leanprof")
    print(f"contract-check: {failures} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
