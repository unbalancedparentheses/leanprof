#!/usr/bin/env python3
"""A scripted MCP session against `leanprof mcp` (newline-delimited JSON-RPC
on stdio), for CI. Run from leanprof's checkout after `lake build leanprof
copybug server`:

    python3 scripts/mcp-check.py .lake/build/bin/leanprof

It runs copybug twice through the `run` tool and checks the answers of
initialize, tools/list, run, report, hot, explain, static_copies, compare, judge, live, build,
the experiment tools (on a copy of Tests/Experiment),
dump, ping, an unknown tool, an unknown method and a malformed line.
Every tool result must carry `structuredContent` that follows the tool's
`outputSchema`, and failures a typed `error` (code, retryable, hint).
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

exe = sys.argv[1] if len(sys.argv) > 1 else ".lake/build/bin/leanprof"
proc = subprocess.Popen([exe, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
failures = 0
next_id = 0


def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


def call(method, params=None):
    global next_id
    next_id += 1
    send({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params or {}})
    line = proc.stdout.readline()
    reply = json.loads(line)
    assert reply.get("id") == next_id, reply
    return reply


spec = importlib.util.spec_from_file_location("contract", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                         "contract-check.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
output_schemas = {}
last = {}


def tool(tool_name, **args):
    """A tool call's text and isError; its structured result is checked against
    the tool's outputSchema and kept in `last`."""
    r = call("tools/call", {"name": tool_name, "arguments": args})
    res = r["result"]
    sc = res.get("structuredContent")
    last.clear()
    last.update(sc or {})
    errs = ["no structuredContent"] if sc is None else contract.errors(sc, output_schemas.get(tool_name, {}), "")
    if sc is not None and sc.get("ok") == res["isError"]:
        errs.append("ok and isError disagree")
    if sc is not None and not sc.get("ok") and "error" not in sc:
        errs.append("a failure without an error")
    if errs:
        check(f"{tool_name}: structuredContent follows its outputSchema", False, errs[:10])
    return res["content"][0]["text"], res["isError"]


def code():
    """The error code of the last tool result, or None."""
    return (last.get("error") or {}).get("code")


def check(name, ok, detail=""):
    global failures
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures += 1
        print("     " + str(detail)[:3000])


r = call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                        "clientInfo": {"name": "mcp-check", "version": "1"}})
check("initialize", r["result"]["protocolVersion"] == "2025-06-18" and "tools" in r["result"]["capabilities"], r)
send({"jsonrpc": "2.0", "method": "notifications/initialized"})  # no reply expected

listed = call("tools/list")["result"]["tools"]
names = {t["name"] for t in listed}
output_schemas.update({t["name"]: t.get("outputSchema", {}) for t in listed})
check("every tool has an outputSchema (an object with ok, tool and error)",
      all(t.get("outputSchema", {}).get("type") == "object" and {"ok", "tool"} <= set(t["outputSchema"].get("required", []))
          and "error" in t["outputSchema"].get("properties", {}) for t in listed), [t["name"] for t in listed])
want = {"doctor", "findings", "finding", "run", "sample", "stat", "elab", "build", "measure", "measure_pair", "report", "hot", "explain", "static_copies", "compare", "judge",
        "live", "dump",
        "experiment_start", "experiment_try", "experiment_finish", "experiment_status"}
check("tools/list", want <= names, names)

# discovery first: what this project has and which modes work
text, err = tool("doctor")
check("doctor", not err and last.get("ready") is True and "copybug" in last["doctor"]["project"]["executables"]
      and last["doctor"]["project"]["test_driver"] == "tests" and last["modes"]["run"]["available"] is True
      and last["doctor"]["lean"]["supported"] is True and last["doctor"]["elab_driver"]["status"] != "unavailable"
      and "leanprof doctor" in text, last)
text, err = tool("doctor", cwd=tempfile.mkdtemp(prefix="leanprof-mcp-doctor-"))
check("doctor outside a project: not ready, with a not_lake_project setup failure",
      not err and last.get("ready") is False and "not_lake_project" in [f["code"] for f in last["setup_failures"]]
      and last["modes"]["run"]["available"] is False and last["modes"]["run"]["why"], last)

text, err = tool("run", executable="copybug", args=["1000"], json=".lake/leanprof/mcp-small.json")
check("run", not err and "exit code 0" in text and "buildWithHistory" in text and "copies" in text, text)
check("run: structured", last.get("ok") is True and last.get("exit_code") == 0 and last.get("copies") == 999
      and last.get("report") == ".lake/leanprof/mcp-small.json", last)
text, err = tool("run", executable="copybug", args=["2000"], json=".lake/leanprof/mcp-large.json")
check("run (second report)", not err and "1,999 copies" in text, text)

check("run: the top findings first, with ids", last.get("findings") and last["findings"][0]["rank"] == 1
      and all(f["id"].split("-")[0] in ("scope", "copy", "alloc", "wait", "task", "reuse", "closure") for f in last["findings"])
      and last["total"] >= len(last["findings"]) and last["truncated"] == (last["total"] > len(last["findings"])), last)

# compact, queryable evidence: pages, filters, stable ids, one finding in full
small, large = ".lake/leanprof/mcp-small.json", ".lake/leanprof/mcp-large.json"
text, err = tool("findings", path=large, limit=2)
check("findings: the first page says it is not all", not err and last["returned"] == 2 and last["total"] > 2
      and last["truncated"] is True and last["next_offset"] == 2 and "more: offset 2" in text, last)
first_two = [f["id"] for f in last["findings"]]
text, err = tool("findings", path=large, offset=2, limit=2)
check("findings: the next page", not err and last["findings"][0]["rank"] == 3
      and not set(first_two) & {f["id"] for f in last["findings"]}, last)
text, err = tool("findings", path=large, kind="copy")
copy = last["findings"][0] if last.get("findings") else {}
check("findings: by kind", not err and last["total"] >= 1 and all(f["kind"] == "copy" for f in last["findings"])
      and copy.get("pos") == "Examples/CopyBug.lean:17" and copy.get("value") == 1999, last)
text, err = tool("findings", path=small, kind="copy")
check("findings: the same site has the same id in another report", not err and last["findings"]
      and last["findings"][0]["id"] == copy.get("id") and last["findings"][0]["value"] == 999, last)
text, err = tool("findings", path=large, module="Examples.CopyBug", declaration="fib")
check("findings: by module and declaration", not err and last["total"] >= 1
      and all(f["module"] == "Examples.CopyBug" and "fib" in (f["name"] + f["scope"]) for f in last["findings"]), last)
text, err = tool("findings", path=large, module="No.Such.Module")
check("findings: an empty match is not an error", not err and last["total"] == 0 and last["truncated"] is False, last)
text, err = tool("finding", id=copy.get("id", "?"), path=large, base=small)
cause = (last.get("cause") or [{}])[0]
check("finding: a copy with explain's cause, source, confidence and before/after",
      not err and cause.get("cause") == "stored-then-updated" and cause.get("confidence", "").startswith("high")
      and cause.get("fix") and any(l["line"] == 21 and "history.push acc" in l["text"] for l in last["source"]["lines"])
      and last["before_after"] == {"status": "changed", "before": 999, "after": 1999, "change": 1000,
                                   "change_pct": last["before_after"]["change_pct"], "unit": "copies"}
      and last["row"]["shared"] == 1999 and last["stale"] is False and "stored-then-updated" in text, last)
text, err = tool("findings", path=large, kind="scope", declaration="buildWithHistory")
scope_id = last["findings"][0]["id"] if last.get("findings") else "?"
text, err = tool("finding", id=scope_id, path=large)
check("finding: a scope, with where its time goes", not err and last["finding"]["kind"] == "scope"
      and last["cause"] and all(c["confidence"] == "measured" for c in last["cause"]) and last["before_after"] is None, last)
shutil.copy(large, ".lake/leanprof/mcp-old.json")
os.utime(".lake/leanprof/mcp-old.json", (1000000000, 1000000000))
text, err = tool("finding", id=copy.get("id", "?"), path=".lake/leanprof/mcp-old.json")
check("finding: a source changed since the report is a stale_source warning", not err and last["stale"] is True
      and [w["code"] for w in last.get("warnings", [])] == ["stale_source"] and "may not be the ones measured" in text, last)
text, err = tool("finding", id="copy-0000000000", path=large)
check("finding: an unknown id is not_found", err and code() == "not_found", last)
text, err = tool("elab", files=["Examples/CopyBug.lean"], heartbeats=True)
text, err = tool("findings", path=".lake/leanprof/elab.json", kind="declaration", limit=3)
decl = last["findings"][0] if last.get("findings") else {}
check("findings of a compile-time report: declarations in heartbeats", not err and decl.get("unit") == "heartbeats"
      and decl.get("module") == "Examples.CopyBug", last)
text, err = tool("finding", id=decl.get("id", "?"), path=".lake/leanprof/elab.json")
check("finding: a declaration, with what its compile time went to", not err and last["cause"]
      and "phases" in last["cause"][0], last)

text, err = tool("report", path=".lake/leanprof/mcp-small.json")
check("report", not err and "wall" in text and "scopes:" in text, text)
text, err = tool("hot", kind="copies", path=".lake/leanprof/mcp-large.json", limit=3)
check("hot copies has file:line", not err and "Examples/CopyBug.lean:17" in text and "1,999 copies" in text, text)
# copies of tiny values are summarized, as `leanprof run` does, not listed first
tiny = {"copies": [
    {"function": "Big.site", "where": "B.lean:1", "kind": "Array", "scope": "-", "shared": 10, "multi_threaded": 0,
     "copies": 10, "bytes": 100000, "copy_ns": 1000},
    {"function": "Tiny.site", "where": "T.lean:1", "kind": "String", "scope": "-", "shared": 9000, "multi_threaded": 0,
     "copies": 9000, "bytes": 81000, "copy_ns": 90000, "tiny": True}]}
with open(".lake/leanprof/mcp-tiny.json", "w") as f:
    json.dump(tiny, f)
text, err = tool("hot", kind="copies", path=".lake/leanprof/mcp-tiny.json")
check("hot copies leaves out tiny values", not err and "Big.site" in text and "Tiny.site" not in text
      and "1 sites that copied only empty or tiny values" in text, text)
text, err = tool("hot", kind="scopes", path=".lake/leanprof/mcp-large.json")
check("hot scopes", not err and "buildWithHistory" in text and "fib" in text, text)
text, err = tool("explain", path=".lake/leanprof/mcp-large.json", name="buildWithHistory")
# the command's IR-based diagnosis, as `leanprof explain` gives it
check("explain", not err and "COPY" in text and "stored in `history` at line 21" in text and "fix:" in text
      and "confidence: high" in text and "SCOPE buildWithHistory" in text, text)
# likely copies without running: copybug's module, checked against the run's report
text, err = tool("static_copies", modules=["Examples.CopyBug"], no_build=True, report=".lake/leanprof/mcp-large.json")
check("static_copies", not err and "FLAG  Examples/CopyBug.lean:22" in text and "stored in `history` at line 21" in text
      and "confirmed by the report: 1,999 copies" in text and "fix:" in text, text)
with open(".lake/leanprof/mcp-sampled.json", "w") as f:
    json.dump({"version": 3, "sampled": True, "wall_ns": 1e6, "copies": [],
               "scopes": [{"name": "f", "pos": "F.lean:1", "total_ns": 1e6, "self_ns": 1e6, "calls": 0}]}, f)
text, err = tool("explain", path=".lake/leanprof/mcp-sampled.json")
check("explain refuses a sampled report", err and "leanprof sample" in text and "0 calls" not in text, text)
check("explain: a sampled report is a bad_argument", code() == "bad_argument", last)
text, err = tool("report", path=".lake/leanprof/no-such-report.json")
check("report: a missing report is not_found, with a hint", err and code() == "not_found"
      and last["error"]["hint"] and last["error"]["retryable"] is False, last)
text, err = tool("run", executable="nosuchexe")
check("run: an executable the project does not have is build_failed", err and code() == "build_failed", last)

# compile time: why the costliest declarations are slow, and a heartbeat budget
text, err = tool("elab", files=["Examples/ElabHeavy.lean"], heartbeats=True, why=True, top=5)
check("elab why", not err and "why the costliest declarations are slow" in text and "observed" in text
      and "suggested" in text, text)
text, err = tool("explain", path=".lake/leanprof/elab.json", limit=3)
check("explain on an elab report", not err and "compile-time report" in text and "observed" in text, text)
text, err = tool("elab", files=["Examples/ElabHeavy.lean"], max_heartbeats=1, top=3)
check("elab max_heartbeats", not err and text.startswith("OVER BUDGET") and "heartbeat budget:" in text, text)

text, err = tool("compare", base=".lake/leanprof/mcp-small.json", new=".lake/leanprof/mcp-small.json")
check("compare (same)", not err and text.startswith("no regressions"), text)
text, err = tool("compare", base=".lake/leanprof/mcp-small.json", new=".lake/leanprof/mcp-large.json")
check("compare (regression)", not err and text.startswith("REGRESSION"), text)
check("compare: structured", last.get("regressed") is True and last["comparison"]["schema"]["name"] == "leanprof.compare"
      and last["comparison"]["copies"][0]["regression"] is True, last)

# judge takes measure summaries: two of the same program agree
text, err = tool("measure", executable="copybug", args=["500"], runs=2, out=".lake/leanprof/mcp-m1.json")
check("measure", not err, text)
text, err = tool("measure", executable="copybug", args=["500"], runs=2, out=".lake/leanprof/mcp-m2.json")
text, err = tool("judge", base=".lake/leanprof/mcp-m1.json", new=".lake/leanprof/mcp-m2.json")
check("judge", not err and ("KEEP" in text or "DISCARD" in text), text)
check("judge: structured verdict with an outcome", last.get("verdict") in ("KEEP", "DISCARD")
      and last.get("outcome") in ("improved", "no_improvement", "insufficient_evidence") and last.get("measurement_valid") is True,
      last)
m2 = json.load(open(".lake/leanprof/mcp-m2.json"))
m2["output"]["hash"] = "fnv1a64:0000000000000000"
json.dump(m2, open(".lake/leanprof/mcp-m-wrong.json", "w"))
text, err = tool("judge", base=".lake/leanprof/mcp-m1.json", new=".lake/leanprof/mcp-m-wrong.json")
check("judge: changed output is a valid DISCARD of kind correctness_failure",
      not err and last.get("verdict") == "DISCARD" and last.get("outcome") == "correctness_failure"
      and last.get("measurement_valid") is True, last)

# a paired session of two prebuilt binaries, judged from one file
text, err = tool("measure_pair", base=".lake/build/bin/copybug", candidate=".lake/build/bin/copybug",
                 args=["500"], runs=6, warmup=1, out=".lake/leanprof/mcp-pair.json")
check("measure_pair", not err and "6 pairs" in text, text)
text, err = tool("judge", pair=".lake/leanprof/mcp-pair.json", min_change="1")
check("judge (paired)", not err and "paired time" in text, text)
pair = json.load(open(".lake/leanprof/mcp-pair.json"))
pair["machine"]["overloaded"] = True
json.dump(pair, open(".lake/leanprof/mcp-pair-loaded.json", "w"))
text, err = tool("judge", pair=".lake/leanprof/mcp-pair-loaded.json")
check("judge: an overloaded session is insufficient evidence, with a retryable overloaded warning",
      not err and last.get("outcome") == "insufficient_evidence" and last.get("retryable") is True
      and [w["code"] for w in last.get("warnings", [])] == ["overloaded"] and last["warnings"][0]["retryable"] is True, last)

# refused: arbitrary programs, writes outside the project, signals to every process
text, err = tool("measure_pair", base="/bin/echo", candidate="/bin/echo", runs=6)
check("measure_pair refuses a binary Lake did not build", err and "not a binary built by Lake" in text, text)
check("measure_pair: that refusal is a bad_argument", code() == "bad_argument", last)
text, err = tool("measure_pair", base=".lake/build/bin/copybug", candidate=".lake/build/bin/copybug",
                 base_cwd="/", runs=6)
check("measure_pair refuses a working directory that is not a Lake project", err and "not a Lake project" in text, text)
check("measure_pair: that refusal is not_lake_project", code() == "not_lake_project", last)
text, err = tool("run", cwd=tempfile.mkdtemp(prefix="leanprof-mcp-noproject-"), executable="x")
check("run outside a Lake project: not_lake_project", err and code() == "not_lake_project", last)
# the directories it runs in by default: `cwd` names a directory that is not
# a project, the binaries are absolute, and `check_output` (deleted before
# each run) is a file there
outside_cwd = tempfile.mkdtemp(prefix="leanprof-mcp-cwd-")
important = os.path.join(outside_cwd, "important.txt")
with open(important, "w") as f:
    f.write("keep me\n")
copybug = os.path.abspath(".lake/build/bin/copybug")
text, err = tool("measure_pair", cwd=outside_cwd, base=copybug, candidate=copybug, check_output="important.txt",
                 runs=6, warmup=0, out="pair.json")
check("measure_pair refuses a default working directory that is not a Lake project",
      err and "not a Lake project" in text and os.path.exists(important), text)
text, err = tool("measure_pair", cwd=outside_cwd, base=copybug, candidate=copybug, base_cwd=os.getcwd(),
                 candidate_cwd=os.getcwd(), runs=6, warmup=0, out="pair.json")
check("measure_pair refuses to write its session outside a Lake project",
      err and "not a Lake project" in text and not os.path.exists(os.path.join(outside_cwd, "pair.json")), text)
text, err = tool("measure_pair", base=".lake/build/bin/copybug", candidate=".lake/build/bin/copybug",
                 check_output="../x", runs=6)
check("measure_pair refuses an output file outside the project", err and "inside the project" in text, text)
text, err = tool("run", executable="copybug", json="/tmp/leanprof-mcp-outside.json")
check("run refuses a report path outside the project", err and "inside the project" in text, text)
check("run: a path outside the project is a bad_argument", code() == "bad_argument", last)
text, err = tool("measure", executable="copybug", out="../outside.json")
check("measure refuses a summary path outside the project", err and "inside the project" in text, text)
# through a symbolic link: a directory in the project pointing out of it, and
# the file itself a link
outside_dir = tempfile.mkdtemp(prefix="leanprof-mcp-outside-")
os.makedirs(".lake/leanprof", exist_ok=True)
links = [".lake/leanprof/mcp-external", ".lake/leanprof/mcp-link.json"]
for l in links:
    if os.path.lexists(l):
        os.remove(l)
os.symlink(outside_dir, links[0])
os.symlink(os.path.join(outside_dir, "link-target.json"), links[1])
text, err = tool("run", executable="copybug", args=["10"], json=".lake/leanprof/mcp-external/result.json")
check("run refuses a report path through a symbolic link out of the project",
      err and "inside the project" in text and not os.path.exists(os.path.join(outside_dir, "result.json")), text)
text, err = tool("measure", executable="copybug", args=["10"], runs=1, out=".lake/leanprof/mcp-link.json")
check("measure refuses a summary path that is a symbolic link",
      err and "inside the project" in text and not os.path.exists(os.path.join(outside_dir, "link-target.json")), text)
# options among elab's files (`--out FILE` would write anywhere)
text, err = tool("elab", files=["--out", os.path.join(outside_dir, "elab.json"), "Examples/CopyBug.lean"])
check("elab refuses an option among its files",
      err and "not a file name" in text and not os.path.exists(os.path.join(outside_dir, "elab.json")), text)
text, err = tool("compare", base="--explain", new=".lake/leanprof/mcp-small.json")
check("compare refuses an option as a report", err and "not a file name" in text, text)
for l in links:
    os.remove(l)
text, err = tool("run", executable="--core")
check("run refuses an option as the executable", err and "not an executable name" in text, text)
for pid in ["-1", "0", "../../etc/x"]:
    text, err = tool("dump", pid=pid)
    check(f"dump refuses pid {pid!r}", err and "not a process id" in text, text)
    text, err = tool("live", pid=pid)
    check(f"live refuses pid {pid!r}", err and "not a process id" in text, text)

# a running program: live snapshot and flight-recorder dump
env = dict(os.environ, LEANPROF_LIVE="1", LEANPROF_FLIGHT=".lake/leanprof", LEANPROF_QUIET="1")
server = subprocess.Popen([".lake/build/bin/server", "0", "20"], env=env, stdout=subprocess.DEVNULL)
time.sleep(1.5)
text, err = tool("live", pid=str(server.pid), seconds=1)
check("live", not err and "handle" in text and "calls/s" in text and "now  thread" in text, text)
text, err = tool("dump", pid=str(server.pid))
path = text.split()[1] if text.startswith("wrote ") else ""
ok = not err and os.path.exists(path)
if ok:
    names_in = {e.get("name") for e in json.load(open(path))["traceEvents"]}
    ok = "handle" in names_in and "parse" in names_in
check("dump", ok, text)
server.terminate()
server.wait()

# live snapshots mark copies of tiny values (`tiny`), and the live view and
# `hot` summarize them as `run` does; LEANPROF_ALL_COPIES=1 lists them
snap = ".lake/leanprof/mcp-live-tiny.json"
for all_copies in ("0", "1"):
    env = dict(os.environ, LEANPROF_LIVE=snap, LEANPROF_QUIET="1", LEANPROF_ALL_COPIES=all_copies)
    subprocess.run([".lake/build/bin/server", "5", "5"], env=env, stdout=subprocess.DEVNULL, check=True)
    rows = json.load(open(snap))["copies"]
    text, err = tool("live", path=snap)
    copies = text.split("copies of shared values")[-1].split("\n\n")[0]
    if all_copies == "0":
        check("live snapshot marks tiny copies", rows and all(r["tiny"] for r in rows), rows)
        check("live view summarizes tiny copies", not err and "copying only empty or tiny values" in copies
              and "Examples/Server.lean" not in copies, text)
        text, err = tool("hot", kind="copies", path=snap)
        check("hot copies of a live snapshot leaves out tiny values",
              not err and "copied only empty or tiny values" in text and "Server.lean" not in text, text)
    else:
        check("LEANPROF_ALL_COPIES=1 lists tiny copies live", not err and rows and not any(r["tiny"] for r in rows)
              and "Examples/Server.lean:26" in copies, text)

# experiments, on a copy of Tests/Experiment in a fresh git repository; without
# an executable the measure is compile heartbeats (no instrumented build)
exp = tempfile.mkdtemp(prefix="leanprof-mcp-experiment-")
shutil.copytree("Tests/Experiment", exp, dirs_exist_ok=True, ignore=shutil.ignore_patterns(".lake", "result.txt"))
genv = dict(os.environ, GIT_AUTHOR_NAME="mcp-check", GIT_AUTHOR_EMAIL="mcp@example.invalid",
            GIT_COMMITTER_NAME="mcp-check", GIT_COMMITTER_EMAIL="mcp@example.invalid")


def git(*args):
    subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=exp, env=genv, check=True, capture_output=True)


with open(os.path.join(exp, ".gitignore"), "w") as f:
    f.write(".lake\n")
git("init", "-q", "-b", "main")
git("add", "-A")
git("commit", "-q", "-m", "fixture")
git("checkout", "-q", "-b", "fast")
spec = os.path.join(exp, "Exp", "Spec.lean")
src = open(spec).read()
open(spec, "w").write(src.replace(":= by\n  intro v hv\n  unfold bucketOf\n  omega", ":=\n  fun v _ => Nat.mod_lt _ (by decide)"))
git("commit", "-q", "-am", "a cheaper proof")
git("checkout", "-q", "main")
text, err = tool("experiment_start", cwd=exp, id="mcp", no_test=True)
check("experiment_start (compile heartbeats)", not err and "recorded in" in text, text)
text, err = tool("experiment_try", cwd=exp, rev="fast")
evidence = json.loads(text.split("\n", 1)[1].rsplit("\n\n", 1)[0]) if text.startswith("KEEP\n") else {}
check("experiment_try: KEEP with the evidence", not err and evidence.get("verdict") == "KEEP"
      and evidence.get("guard", {}).get("status") == "PASS" and "heartbeats" in evidence, text)
text, err = tool("experiment_status", cwd=exp)
check("experiment_status", not err and len(json.loads(text.split("\n\n")[0])["tries"]) == 1, text)
text, err = tool("experiment_try", cwd=exp, rev="--working-tree")
check("experiment_try refuses an option as the revision", err and "not a revision" in text, text)
text, err = tool("experiment_status", cwd=exp, id="../../x")
check("experiment_status refuses an id that is a path", err and "not an experiment id" in text, text)
text, err = tool("experiment_start", cwd=exp, executable="bench", check_output=["../outside.txt"])
check("experiment_start refuses an output file outside the project", err and "inside the project" in text, text)
text, err = tool("experiment_finish", cwd=exp)
check("experiment_finish", not err and '"experiment-finish"' in text, text)
shutil.rmtree(exp, ignore_errors=True)

# build: a measured clean build of Tests/Build (no experiments, so no git needed)
bdir = tempfile.mkdtemp(prefix="leanprof-mcp-build-")
shutil.copytree("Tests/Build", bdir, dirs_exist_ok=True, ignore=shutil.ignore_patterns(".lake"))
text, err = tool("build", cwd=bdir, clean=True, html="timeline.html")
report = json.load(open(os.path.join(bdir, ".lake/leanprof/build.json"))) if not err else {}
check("build: critical path and timeline", not err and "Critical path:" in text and report.get("leanprof") == "build"
      and report["critical_path"]["steps"] and os.path.exists(os.path.join(bdir, "timeline.html")), text)
text, err = tool("build", cwd=bdir, targets=["--clean"])
check("build refuses an option as a target", err and "not a file name" in text, text)
text, err = tool("build", cwd=bdir, html="../outside.html")
check("build refuses an HTML file outside the project", err and "inside the project" in text, text)
shutil.rmtree(bdir, ignore_errors=True)
# a server whose PATH has no Lean: lean_not_found, before anything runs
bare = subprocess.Popen([os.path.abspath(exe), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                        env=dict(os.environ, PATH="/usr/bin:/bin"))
bare.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                             "params": {"name": "run", "arguments": {"executable": "copybug"}}}) + "\n")
bare.stdin.flush()
r = json.loads(bare.stdout.readline())["result"]
bare.stdin.close()
bare.wait(timeout=10)
check("run without lake on PATH: lean_not_found", r["isError"] and r["structuredContent"]["error"]["code"] == "lean_not_found",
      r)
# sample: samply_missing when there is no samply (else a result)
text, err = tool("sample", executable="copybug", args=["300"])
check("sample: a result, or samply_missing", (not err) or code() == "samply_missing", last)

check("ping", call("ping")["result"] == {})
r = call("tools/call", {"name": "nope", "arguments": {}})
check("unknown tool", r.get("error", {}).get("code") == -32602, r)
r = call("no/such/method")
check("unknown method", r.get("error", {}).get("code") == -32601, r)
proc.stdin.write("{not json\n")
proc.stdin.flush()
r = json.loads(proc.stdout.readline())
check("parse error", r.get("error", {}).get("code") == -32700 and r.get("id") is None, r)

proc.stdin.close()
check("exits at end of input", proc.wait(timeout=10) == 0)
sys.exit(1 if failures else 0)
