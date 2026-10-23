"""Scripted LSP session: open FILE, wait until elaborated, append a declaration N times
(waiting for each), shut down. Prints the time of each step. Usage:
  lsp-session.py ROOT FILE EDITS -- SERVER_CMD...
Anything the server command prints that is not LSP (e.g. a profiler's report) is echoed."""
import json, os, subprocess, sys, threading, queue, time

root, rel, edits = sys.argv[1], sys.argv[2], int(sys.argv[3])
cmd = sys.argv[sys.argv.index("--") + 1:]
path = os.path.abspath(os.path.join(root, rel))
uri = "file://" + path
proc = subprocess.Popen(cmd, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
msgs = queue.Queue()
other = []

def reader():
    f = proc.stdout
    while True:
        line = f.readline()
        if not line:
            msgs.put(None); return
        if line.startswith(b"Content-Length:"):
            n = int(line.split(b":")[1]); f.readline()
            msgs.put(json.loads(f.read(n)))
        else:
            other.append(line.decode(errors="replace"))

threading.Thread(target=reader, daemon=True).start()
def send(obj):
    b = json.dumps(obj).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b); proc.stdin.flush()

def wait_done(version, timeout=600):
    t = time.time()
    while time.time() - t < timeout:
        m = msgs.get(timeout=timeout)
        if m is None: raise SystemExit("server exited")
        if m.get("method") == "$/lean/fileProgress" and m["params"]["processing"] == [] \
                and m["params"]["textDocument"].get("version", version) == version:
            return
    raise SystemExit("timeout")

t0 = time.time()
send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": "file://" + os.path.abspath(root), "capabilities": {}}})
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
text = open(path).read()
send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "lean4", "version": 1, "text": text}}})
wait_done(1)
print(f"open: {time.time() - t0:.3f} s", flush=True)
lines = text.count("\n")
for k in range(edits):
    t = time.time()
    v = k + 2
    new = f"\ntheorem leanprof_edit_{k} : {k} + 1 = {k + 1} := rfl\n"
    send({"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {"textDocument": {"uri": uri, "version": v},
          "contentChanges": [{"range": {"start": {"line": lines + k * 2, "character": 0}, "end": {"line": lines + k * 2, "character": 0}}, "text": new}]}})
    wait_done(v)
    print(f"edit {k + 1}: {time.time() - t:.3f} s", flush=True)
send({"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": None})
send({"jsonrpc": "2.0", "method": "exit", "params": None})
try:
    proc.stdin.close()
except Exception:
    pass
proc.wait(timeout=600)
time.sleep(0.5)
sys.stdout.write("".join(other))
