"""Ask `lake serve` for the inlay hints of one file. Usage: hints.py PROJECT FILE"""
import json, os, subprocess, sys, time, threading, queue

root, rel = sys.argv[1], sys.argv[2]
path = os.path.join(root, rel)
uri = "file://" + path
proc = subprocess.Popen(["lake", "serve"], cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
msgs = queue.Queue()

def reader():
    f = proc.stdout
    while True:
        line = f.readline()
        if not line: return
        if line.startswith(b"Content-Length:"):
            n = int(line.split(b":")[1]); f.readline()
            msgs.put(json.loads(f.read(n)))

threading.Thread(target=reader, daemon=True).start()
def send(obj):
    b = json.dumps(obj).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b); proc.stdin.flush()

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": "file://" + root, "capabilities": {}}})
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
text = open(path).read()
send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "lean4", "version": 1, "text": text}}})
# wait until the file is fully elaborated
deadline = time.time() + 240
while time.time() < deadline:
    try: m = msgs.get(timeout=1)
    except queue.Empty: continue
    if m.get("method") == "$/lean/fileProgress" and m["params"]["processing"] == []: break
nlines = text.count("\n") + 1
send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/inlayHint", "params": {"textDocument": {"uri": uri}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": nlines, "character": 0}}}})
while time.time() < deadline:
    m = msgs.get(timeout=60)
    if m.get("id") == 2:
        for h in m.get("result") or []:
            lab = h["label"] if isinstance(h["label"], str) else "".join(p["value"] for p in h["label"])
            print(f'line {h["position"]["line"] + 1}: {lab}')
            if os.environ.get("SHOW_TOOLTIPS") and h.get("tooltip"):
                tip = h["tooltip"] if isinstance(h["tooltip"], str) else h["tooltip"].get("value", "")
                print("    " + tip.replace("\n", "\n    "))
        break
proc.kill()
