#!/usr/bin/env python3
"""A scripted MCP session against `leanprof mcp` (newline-delimited JSON-RPC
on stdio), for CI. Run from leanprof's checkout after `lake build leanprof
copybug server`:

    python3 scripts/mcp-check.py .lake/build/bin/leanprof

It runs copybug twice through the `run` tool and checks the answers of
initialize, tools/list, run, report, hot, explain, static_copies, compare, judge, live,
the experiment tools (on a copy of Tests/Experiment),
dump, ping, an unknown tool, an unknown method and a malformed line.
"""
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


def tool(tool_name, **args):
    r = call("tools/call", {"name": tool_name, "arguments": args})
    res = r["result"]
    return res["content"][0]["text"], res["isError"]


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

names = {t["name"] for t in call("tools/list")["result"]["tools"]}
want = {"run", "sample", "stat", "elab", "measure", "measure_pair", "report", "hot", "explain", "static_copies", "compare",
        "judge", "live", "dump",
        "experiment_start", "experiment_try", "experiment_finish", "experiment_status"}
check("tools/list", want <= names, names)

text, err = tool("run", executable="copybug", args=["1000"], json=".lake/leanprof/mcp-small.json")
check("run", not err and "exit code 0" in text and "buildWithHistory" in text and "copies" in text, text)
text, err = tool("run", executable="copybug", args=["2000"], json=".lake/leanprof/mcp-large.json")
check("run (second report)", not err and "1,999 copies" in text, text)

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

# judge takes measure summaries: two of the same program agree
text, err = tool("measure", executable="copybug", args=["500"], runs=2, out=".lake/leanprof/mcp-m1.json")
check("measure", not err, text)
text, err = tool("measure", executable="copybug", args=["500"], runs=2, out=".lake/leanprof/mcp-m2.json")
text, err = tool("judge", base=".lake/leanprof/mcp-m1.json", new=".lake/leanprof/mcp-m2.json")
check("judge", not err and ("KEEP" in text or "DISCARD" in text), text)

# a paired session of two prebuilt binaries, judged from one file
text, err = tool("measure_pair", base=".lake/build/bin/copybug", candidate=".lake/build/bin/copybug",
                 args=["500"], runs=6, warmup=1, out=".lake/leanprof/mcp-pair.json")
check("measure_pair", not err and "6 pairs" in text, text)
text, err = tool("judge", pair=".lake/leanprof/mcp-pair.json", min_change="1")
check("judge (paired)", not err and "paired time" in text, text)

# refused: arbitrary programs, writes outside the project, signals to every process
text, err = tool("measure_pair", base="/bin/echo", candidate="/bin/echo", runs=6)
check("measure_pair refuses a binary Lake did not build", err and "not a binary built by Lake" in text, text)
text, err = tool("measure_pair", base=".lake/build/bin/copybug", candidate=".lake/build/bin/copybug",
                 base_cwd="/", runs=6)
check("measure_pair refuses a working directory that is not a Lake project", err and "not a Lake project" in text, text)
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
