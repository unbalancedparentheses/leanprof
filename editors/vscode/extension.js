// leanprof for VS Code: runs the `leanprof` command and shows what it writes.
// Everything is computed by the command line; this file only starts it, with
// the arguments the user typed, and displays its output (a task's terminal, the
// page of `leanprof html`, the frames of `leanprof top --plain`).
"use strict";
const vscode = require("vscode");
const cp = require("child_process");
const fs = require("fs");
const path = require("path");

/** The configured `leanprof` command. */
function leanprofPath() {
  return vscode.workspace.getConfiguration("leanprof").get("path") || "leanprof";
}

/** The Lake project of a file (the nearest directory with a lakefile), or the
 * first workspace folder. */
function projectRoot(uri) {
  let file = uri || (vscode.window.activeTextEditor && vscode.window.activeTextEditor.document.uri);
  if (file && file.scheme === "file") {
    let dir = path.dirname(file.fsPath);
    for (;;) {
      if (["lakefile.lean", "lakefile.toml"].some((f) => fs.existsSync(path.join(dir, f)))) return dir;
      const up = path.dirname(dir);
      if (up === dir) break;
      dir = up;
    }
  }
  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length) return folders[0].uri.fsPath;
  return undefined;
}

/** Splits what the user typed into arguments: spaces separate, quotes group. */
function splitArgs(text) {
  const out = [];
  const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let m;
  while ((m = re.exec(text)) !== null) out.push(m[1] !== undefined ? m[1] : m[2] !== undefined ? m[2] : m[3]);
  return out;
}

function needRoot() {
  const root = projectRoot();
  if (!root) vscode.window.showErrorMessage("leanprof: open a Lake project (a folder with a lakefile) first");
  return root;
}

/** Asks for `EXE [-- ARGS...]`, remembering the last answer per command.
 * A command given its target as an argument (from a keybinding's `args`, or
 * another extension) does not ask. */
async function askTarget(context, key, prompt, given) {
  if (given && typeof given === "object") given = given.target;
  if (typeof given === "string" && given.trim()) return splitArgs(given);
  const last = context.workspaceState.get(key, "");
  const text = await vscode.window.showInputBox({
    prompt,
    value: last,
    placeHolder: "myapp -- input.txt   (a lean_exe target of this project, then its arguments)",
    ignoreFocusOut: true,
  });
  if (text === undefined || !text.trim()) return undefined;
  await context.workspaceState.update(key, text);
  return splitArgs(text);
}

/** Runs `leanprof ARGS` as a task in the project's terminal; resolves with
 * its exit code. */
function runTask(name, args, cwd) {
  const task = new vscode.Task(
    { type: "leanprof", args },
    vscode.TaskScope.Workspace,
    name,
    "leanprof",
    new vscode.ProcessExecution(leanprofPath(), args, { cwd }),
  );
  task.presentationOptions = { reveal: vscode.TaskRevealKind.Always, clear: true };
  return new Promise((resolve, reject) => {
    vscode.tasks.executeTask(task).then((execution) => {
      const sub = vscode.tasks.onDidEndTaskProcess((e) => {
        if (e.execution !== execution) return;
        sub.dispose();
        resolve(e.exitCode);
      });
    }, reject);
  });
}

/** After a profile: offer the HTML report. */
function offerReport(context, what, code, cwd) {
  if (code !== 0) {
    vscode.window.showWarningMessage(`leanprof ${what} exited with code ${code}; see the terminal`);
    return;
  }
  vscode.window
    .showInformationMessage(`leanprof ${what} finished; the report is in .lake/leanprof/`, "Open report")
    .then((pick) => pick === "Open report" && openReport(context, cwd));
}

async function runCmd(context, given, givenOptions) {
  // from a keybinding: "args": { "target": "myapp -- input.txt", "options": ["--allocs"] }
  if (given && typeof given === "object") [given, givenOptions] = [given.target, given.options];
  const cwd = needRoot();
  if (!cwd) return;
  const target = await askTarget(context, "leanprof.run.target", "leanprof run: executable and arguments", given);
  if (!target) return;
  const known = [
    { label: "--auto", description: "every function's time and calls" },
    { label: "--allocs", description: "allocations per function" },
    { label: "--counters", description: "failed reuse, closure calls" },
    { label: "--frees", description: "freeing pauses" },
    { label: "--core", description: "also inside Lean's own libraries (needs llvm-objcopy)" },
    { label: "--trace", description: "a timeline: the report's flame graph (larger, slower runs)" },
  ];
  const lastOpts = context.workspaceState.get("leanprof.run.options", []);
  for (const k of known) k.picked = lastOpts.includes(k.label);
  const opts = Array.isArray(givenOptions)
    ? givenOptions.map((label) => ({ label }))
    : await vscode.window.showQuickPick(known, {
        canPickMany: true,
        title: "leanprof run: options (none for copies, tasks and memory only)",
      });
  if (opts === undefined) return;
  const chosen = opts.map((o) => o.label);
  await context.workspaceState.update("leanprof.run.options", chosen);
  const options = chosen.flatMap((o) => (o === "--trace" ? ["--trace", traceFile(cwd)] : [o]));
  const code = await runTask("run", ["run", ...options, ...target], cwd);
  await context.workspaceState.update("leanprof.traced", chosen.includes("--trace"));
  offerReport(context, "run", code, cwd);
  return code;
}

async function sampleCmd(context, given) {
  const cwd = needRoot();
  if (!cwd) return;
  const target = await askTarget(context, "leanprof.sample.target", "leanprof sample: executable and arguments", given);
  if (!target) return;
  const code = await runTask("sample", ["sample", ...target], cwd);
  await context.workspaceState.update("leanprof.traced", false);
  offerReport(context, "sample", code, cwd);
  return code;
}

async function elabCmd(context, uri) {
  const file = uri || (vscode.window.activeTextEditor && vscode.window.activeTextEditor.document.uri);
  if (!file || file.scheme !== "file" || !file.fsPath.endsWith(".lean")) {
    vscode.window.showErrorMessage("leanprof: open a .lean file first");
    return;
  }
  const doc = vscode.workspace.textDocuments.find((d) => d.uri.toString() === file.toString());
  if (doc && doc.isDirty) await doc.save();
  const cwd = projectRoot(file);
  const rel = path.relative(cwd, file.fsPath);
  const code = await runTask("elab", ["elab", "--heartbeats", rel], cwd);
  offerReport(context, "elab", code, cwd);
  return code;
}

function execLeanprof(args, cwd) {
  return new Promise((resolve, reject) => {
    cp.execFile(leanprofPath(), args, { cwd, maxBuffer: 64 << 20 }, (err, stdout, stderr) => {
      if (err) reject(new Error((stderr || stdout || err.message).trim()));
      else resolve(stdout);
    });
  });
}

/** Where Run… with --trace writes the timeline. */
function traceFile(cwd) {
  return path.join(cwd, ".lake", "leanprof", "trace.json");
}

let reportPanel;

/** `leanprof html` in the project, shown in a webview. */
async function openReport(context, root) {
  const cwd = root || needRoot();
  if (!cwd) return;
  const out = path.join(cwd, ".lake", "leanprof", "report.html");
  // the timeline of the last run, if that run wrote one, gives the flame graph
  const trace = traceFile(cwd);
  const withTrace = context.workspaceState.get("leanprof.traced") && fs.existsSync(trace) ? ["--trace", trace] : [];
  try {
    await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Window, title: "leanprof html" },
      () => execLeanprof(["html", "-o", out, ...withTrace], cwd),
    );
  } catch (e) {
    vscode.window.showErrorMessage(`leanprof html failed: ${e.message}`);
    return;
  }
  const html = fs.readFileSync(out, "utf8");
  if (!reportPanel) {
    reportPanel = vscode.window.createWebviewPanel("leanprof.report", "leanprof report", vscode.ViewColumn.Active, {
      enableScripts: true,
      enableFindWidget: true,
      retainContextWhenHidden: true,
      localResourceRoots: [],
    });
    reportPanel.onDidDispose(() => (reportPanel = undefined));
  }
  reportPanel.webview.html = html;
  reportPanel.reveal();
  return reportPanel;
}

let live;

function liveHtml() {
  return `<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<style>
  body { font-family: var(--vscode-editor-font-family); font-size: var(--vscode-editor-font-size); color: var(--vscode-editor-foreground); background: var(--vscode-editor-background); }
  #status { color: var(--vscode-descriptionForeground); margin: 0 0 8px; }
  pre { margin: 0; white-space: pre; }
  #log { color: var(--vscode-descriptionForeground); margin-top: 12px; }
</style></head>
<body>
<div id="status">starting…</div>
<pre id="frame"></pre>
<pre id="log"></pre>
<script>
  const frame = document.getElementById("frame"), log = document.getElementById("log"), status = document.getElementById("status");
  window.addEventListener("message", (e) => {
    const m = e.data;
    if (m.frame !== undefined) frame.textContent = m.frame;
    if (m.log !== undefined) log.textContent = m.log;
    if (m.status !== undefined) status.textContent = m.status;
  });
  acquireVsCodeApi().postMessage("ready");
</script>
</body></html>`;
}

/** `leanprof top --plain ARGS`: each frame it prints replaces the last one in a panel. */
async function liveCmd(context, given) {
  const cwd = needRoot();
  if (!cwd) return;
  const target = await askTarget(
    context,
    "leanprof.live.target",
    "leanprof top: executable and arguments (or --attach FILE, --pid PID)",
    given,
  );
  if (!target) return;
  if (live) live.panel.dispose();
  const interval = String(vscode.workspace.getConfiguration("leanprof").get("liveInterval") || 500);
  const args = ["top", "--plain", "--interval", interval, ...target];
  const panel = vscode.window.createWebviewPanel("leanprof.live", "leanprof live", vscode.ViewColumn.Active, {
    enableScripts: true,
    retainContextWhenHidden: true,
    localResourceRoots: [],
  });
  panel.webview.html = liveHtml();
  const child = cp.spawn(leanprofPath(), args, {
    cwd,
    detached: process.platform !== "win32",
    env: { ...process.env, COLUMNS: "200", LINES: "60" },
  });
  const state = { panel, child, frame: [], log: "", status: "", exited: false };
  live = state;
  // the panel asks for everything again when its page (re)loads
  const shown = () => ({ frame: state.frame.join("\n").trimEnd(), log: state.log, status: state.status });
  const post = (m) => panel.webview.postMessage(m);
  panel.webview.onDidReceiveMessage((m) => m === "ready" && post(shown()));
  const command = `leanprof ${args.join(" ")}`;
  const setStatus = (s) => post({ status: (state.status = s) });
  setStatus(`${command}  (running)`);
  let pending = "";
  child.stdout.on("data", (chunk) => {
    pending += chunk.toString();
    const lines = pending.split("\n");
    pending = lines.pop();
    // a frame starts with its title line and is printed in one write
    for (const line of lines) {
      if (line.startsWith("leanprof top ")) state.frame = [line];
      else state.frame.push(line);
    }
    post({ frame: shown().frame });
  });
  child.stderr.on("data", (chunk) => {
    state.log = (state.log + chunk.toString()).slice(-20000);
    post({ log: state.log });
  });
  const finished = new Promise((resolve) => {
    child.on("error", (e) => {
      state.exited = true;
      setStatus(`${command}: ${e.message}`);
      resolve({ code: -1, frame: "", log: e.message });
    });
    child.on("close", (code) => {
      state.exited = true;
      if (pending) state.frame.push(pending);
      post({ frame: shown().frame });
      setStatus(`${command}  (finished, exit code ${code})`);
      resolve({ code, frame: shown().frame, log: state.log });
    });
  });
  panel.onDidDispose(() => {
    if (!state.exited) {
      try {
        if (process.platform !== "win32") process.kill(-child.pid, "SIGINT");
        else child.kill();
      } catch (e) {
        child.kill();
      }
    }
    if (live === state) live = undefined;
  });
  return { panel, finished };
}

function activate(context) {
  const reg = (id, f) => context.subscriptions.push(vscode.commands.registerCommand(id, (...a) => f(context, ...a)));
  reg("leanprof.run", runCmd);
  reg("leanprof.sample", sampleCmd);
  reg("leanprof.elabFile", elabCmd);
  reg("leanprof.openReport", (ctx) => openReport(ctx));
  reg("leanprof.live", liveCmd);
}

function deactivate() {
  if (live) live.panel.dispose();
}

module.exports = { activate, deactivate, splitArgs };
