#!/usr/bin/env python3
"""A scripted MCP session against `leanprof mcp` (newline-delimited JSON-RPC
on stdio), for CI. Run from leanprof's checkout after `lake build leanprof
copybug server`:

    python3 scripts/mcp-check.py .lake/build/bin/leanprof

It runs copybug twice through the `run` tool and checks the answers of
initialize, tools/list, run, report, hot, explain, compare, judge, live,
dump, ping, an unknown tool, an unknown method and a malformed line.
"""
import json
import os
import subprocess
import sys
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
want = {"run", "sample", "stat", "elab", "measure", "measure_pair", "report", "hot", "explain", "compare", "judge", "live", "dump"}
check("tools/list", want <= names, names)

text, err = tool("run", executable="copybug", args=["1000"], json=".lake/leanprof/mcp-small.json")
check("run", not err and "exit code 0" in text and "buildWithHistory" in text and "copies" in text, text)
text, err = tool("run", executable="copybug", args=["2000"], json=".lake/leanprof/mcp-large.json")
check("run (second report)", not err and "1,999 copies" in text, text)

text, err = tool("report", path=".lake/leanprof/mcp-small.json")
check("report", not err and "wall" in text and "scopes:" in text, text)
text, err = tool("hot", kind="copies", path=".lake/leanprof/mcp-large.json", limit=3)
check("hot copies has file:line", not err and "Examples/CopyBug.lean:17" in text and "1,999 copies" in text, text)
text, err = tool("hot", kind="scopes", path=".lake/leanprof/mcp-large.json")
check("hot scopes", not err and "buildWithHistory" in text and "fib" in text, text)
text, err = tool("explain", path=".lake/leanprof/mcp-large.json", name="buildWithHistory")
check("explain", not err and "COPY" in text and "another reference" in text and "SCOPE buildWithHistory" in text, text)

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
