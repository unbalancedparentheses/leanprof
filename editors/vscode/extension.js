// leanprof for VS Code: runs the `leanprof` command and shows what it writes.
// Everything is computed by the command line; this file only starts it, with
// the arguments the user typed, and displays its output (a task's terminal, the
// page of `leanprof html`, the frames of `leanprof top --plain`, and on save the
// difference from the previous profile at the end of each line; lib.js reads
// those files).
"use strict";
const vscode = require("vscode");
const cp = require("child_process");
const fs = require("fs");
const path = require("path");
const lib = require("./lib");

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
  const post = (m) => state.disposed || panel.webview.postMessage(m);
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
    state.disposed = true;
    if (!state.exited) {
      // leanprof top and the program it started, which share its process group
      try {
        if (process.platform !== "win32") process.kill(-child.pid, "SIGTERM");
        else child.kill();
      } catch (e) {
        child.kill();
      }
    }
    if (live === state) live = undefined;
  });
  return { panel, finished };
}

// ---------------------------------------------------------------------------
// On save: `leanprof elab --heartbeats --since-last FILE` (compile time) and,
// with a workload, `leanprof run --since-last EXE -- ARGS` (copies and
// allocations). The command compares each profile with the previous one and
// writes the difference (`.lake/leanprof/onsave/NAME.delta.json`); this shows
// it at the end of each line it concerns, with the cause in the hover.

const onSave = {
  debouncer: undefined,
  /** absolute file -> items of its last compile-time difference */
  elab: new Map(),
  /** project root -> run difference (concerns every file of the project) */
  run: new Map(),
  types: undefined,
  status: undefined,
  log: undefined,
  /** key -> promise of the last scheduled job, for the tests */
  last: new Map(),
};

function onSaveConfig() {
  const c = vscode.workspace.getConfiguration("leanprof.onSave");
  return {
    compileTime: c.get("compileTime", false),
    delay: c.get("delay", 500),
    redAbove: c.get("highlightAbove", 10) * 1000,
    workload: (c.get("workload", "") || "").trim(),
    runCommand: c.get("runCommand", "run") === "stat" ? "stat" : "run",
    runOptions: c.get("runOptions", ["--allocs"]) || [],
    keepBase: c.get("keepBase", false),
  };
}

function decorationTypes() {
  const after = (color) => ({ after: { color: new vscode.ThemeColor(color), margin: "0 0 0 2em", fontStyle: "italic" } });
  return {
    red: vscode.window.createTextEditorDecorationType(after("editorError.foreground")),
    up: vscode.window.createTextEditorDecorationType(after("editorWarning.foreground")),
    down: vscode.window.createTextEditorDecorationType(after("testing.iconPassed")),
    new: vscode.window.createTextEditorDecorationType(after("editorCodeLens.foreground")),
  };
}

/** Runs `leanprof ARGS` in `cwd`; `signal` stops it and what it started. */
function spawnLeanprof(args, cwd, signal) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const child = cp.spawn(leanprofPath(), args, { cwd, detached: process.platform !== "win32" });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr = (stderr + d).slice(-20000)));
    const stop = () => {
      try {
        if (process.platform !== "win32") process.kill(-child.pid, "SIGTERM");
        else child.kill();
      } catch (e) {
        child.kill();
      }
    };
    if (signal) signal.addEventListener("abort", stop, { once: true });
    child.on("error", (e) => resolve({ code: -1, stdout, stderr: e.message, ms: Date.now() - t0 }));
    child.on("close", (code) => {
      if (signal) signal.removeEventListener("abort", stop);
      resolve({ code, stdout, stderr, ms: Date.now() - t0 });
    });
  });
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (e) {
    return undefined;
  }
}

/** Shows the differences of `editor`'s file (its own compile time, and the
 * project's last run). */
function decorate(editor) {
  if (!onSave.types || !editor || editor.document.uri.scheme !== "file") return;
  const file = editor.document.uri.fsPath;
  const root = projectRoot(editor.document.uri);
  const rel = root ? path.relative(root, file) : file;
  const { redAbove } = onSaveConfig();
  const items = [...(onSave.elab.get(file) || [])];
  const run = root && onSave.run.get(root);
  if (run) items.push(...lib.deltaItems(run, rel, { redAbove }));
  const byLevel = { red: [], up: [], down: [], new: [] };
  for (const it of items) {
    if (it.line < 0 || it.line >= editor.document.lineCount) continue;
    const line = editor.document.lineAt(it.line);
    byLevel[it.level].push({
      range: new vscode.Range(it.line, line.firstNonWhitespaceCharacterIndex, it.line, line.range.end.character),
      hoverMessage: new vscode.MarkdownString(it.hover),
      renderOptions: { after: { contentText: it.text } },
    });
  }
  for (const [level, type] of Object.entries(onSave.types)) editor.setDecorations(type, byLevel[level]);
}

function decorateAll() {
  for (const e of vscode.window.visibleTextEditors) decorate(e);
}

function setStatus(text, tooltip) {
  if (!onSave.status) return;
  onSave.status.text = text;
  onSave.status.tooltip = tooltip || "leanprof on save: click for the log";
  onSave.status.show();
}

/** `leanprof elab --heartbeats --since-last` on a saved file. */
async function elabOnSave(doc, signal) {
  const root = projectRoot(doc.uri);
  if (!root) return;
  const file = doc.uri.fsPath;
  const rel = path.relative(root, file);
  const { redAbove, keepBase } = onSaveConfig();
  setStatus(`$(sync~spin) leanprof: ${path.basename(file)}`);
  const args = ["elab", "--heartbeats", "--since-last", ...(keepBase ? ["--keep-base"] : []), rel];
  const r = await spawnLeanprof(args, root, signal);
  if (signal && signal.aborted) return;
  const report = lib.onSaveReport(root, rel);
  const delta = readJson(lib.deltaOf(report));
  const summary = r.code === 0 ? lib.deltaSummary(delta) : `exit code ${r.code}`;
  onSave.log.appendLine(`[${new Date().toLocaleTimeString()}] leanprof ${args.join(" ")}: ${(r.ms / 1000).toFixed(2)} s, ${summary}`);
  if (r.code !== 0) onSave.log.appendLine(r.stderr.trim());
  if (r.code === 0) {
    onSave.elab.set(file, lib.deltaItems(delta, rel, { redAbove }));
    decorateAll();
    if (slowestView) slowestView.refresh();
  }
  setStatus(`leanprof: ${summary}`, `${path.basename(file)} profiled in ${(r.ms / 1000).toFixed(2)} s`);
  return { code: r.code, ms: r.ms, delta, report };
}

/** `leanprof run|stat --since-last` on the configured workload. */
async function runOnSave(root, signal) {
  const { workload, runCommand, runOptions, keepBase } = onSaveConfig();
  const target = splitArgs(workload);
  if (!target.length) return;
  const args = [runCommand, "--since-last", ...(keepBase ? ["--keep-base"] : []), ...runOptions, ...target];
  setStatus(`$(sync~spin) leanprof ${runCommand} ${target[0]}`);
  const r = await spawnLeanprof(args, root, signal);
  if (signal && signal.aborted) return;
  const delta = readJson(lib.deltaOf(lib.onSaveRunReport(root, target[0])));
  const summary = r.code === 0 ? lib.deltaSummary(delta) : `exit code ${r.code}`;
  onSave.log.appendLine(`[${new Date().toLocaleTimeString()}] leanprof ${args.join(" ")}: ${(r.ms / 1000).toFixed(2)} s, ${summary}`);
  if (r.code !== 0) onSave.log.appendLine(r.stderr.trim());
  if (r.code === 0 && delta) {
    onSave.run.set(root, delta);
    decorateAll();
  }
  setStatus(`leanprof ${target[0]}: ${summary}`, `${runCommand} took ${(r.ms / 1000).toFixed(1)} s`);
  return { code: r.code, ms: r.ms, delta };
}

function didSave(doc) {
  if (doc.uri.scheme !== "file" || !doc.uri.fsPath.endsWith(".lean")) return;
  const c = onSaveConfig();
  onSave.debouncer.delay = c.delay;
  if (c.compileTime) {
    const key = `elab:${doc.uri.fsPath}`;
    onSave.last.set(key, onSave.debouncer.schedule(key, (signal) => elabOnSave(doc, signal)));
  }
  const root = projectRoot(doc.uri);
  if (c.workload && root) {
    const key = `run:${root}`;
    onSave.last.set(key, onSave.debouncer.schedule(key, (signal) => runOnSave(root, signal)));
  }
}

/** Removes the kept bases, so that the next save starts over. */
function resetOnSave() {
  const root = needRoot();
  if (!root) return;
  const dir = path.join(root, ".lake", "leanprof", "onsave");
  const walk = (d) => {
    for (const e of fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }) : []) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".base.json") || e.name.endsWith(".delta.json")) fs.unlinkSync(p);
    }
  };
  walk(dir);
  onSave.elab.clear();
  onSave.run.delete(root);
  decorateAll();
  setStatus("leanprof: the next save starts over");
}

// ---------------------------------------------------------------------------
// Why a file is slow: its costliest declarations (`elab` on the file, as Lake
// builds it), in a view of the explorer.

let slowestView;

class SlowestView {
  constructor() {
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this.emitter.event;
  }

  refresh() {
    this.emitter.fire();
  }

  /** The active file's last profile: on-save's, else `.lake/leanprof/elab.json`. */
  current() {
    const ed = vscode.window.activeTextEditor;
    if (!ed || ed.document.uri.scheme !== "file" || !ed.document.uri.fsPath.endsWith(".lean")) return undefined;
    const root = projectRoot(ed.document.uri);
    if (!root) return undefined;
    const rel = path.relative(root, ed.document.uri.fsPath);
    for (const f of [lib.onSaveReport(root, rel), path.join(root, ".lake", "leanprof", "elab.json")]) {
      const s = lib.slowest(readJson(f), rel, 10);
      if (s.decls.length) return { ...s, uri: ed.document.uri, rel, source: f };
    }
    return { decls: [], uri: ed.document.uri, rel };
  }

  getTreeItem(x) {
    return x;
  }

  getChildren(parent) {
    if (parent) return [];
    const cur = this.current();
    if (!cur) return [new vscode.TreeItem("open a .lean file")];
    if (!cur.decls.length) {
      const it = new vscode.TreeItem(`no profile of ${path.basename(cur.rel)}: run "Why is this file slow?"`);
      it.command = { command: "leanprof.whySlow", title: "Why is this file slow?" };
      return [it];
    }
    const hb = cur.unit === "heartbeats";
    const amount = hb ? lib.fmtKHB : lib.fmtNs;
    const head = new vscode.TreeItem(`${path.basename(cur.rel)}: ${amount(cur.total)}` +
      (cur.wallNs ? `, ${(cur.wallNs / 1e9).toFixed(2)} s to elaborate (with its imports)` : ""));
    head.tooltip = `from ${cur.source}${cur.errors ? `\n${cur.errors} errors: costs stop at the first` : ""}`;
    const rows = cur.decls.map((d) => {
      const it = new vscode.TreeItem(d.name);
      it.description = `${amount(d.total)} · ${(d.share * 100).toFixed(0)}%`;
      const parts = Object.entries(d.parts).filter(([, x]) => x > 0).map(([k, x]) => `${k} ${amount(x)}`).join(", ");
      it.tooltip = new vscode.MarkdownString(
        `**${d.name}** (line ${d.line + 1}): ${amount(d.total)}, ${(d.share * 100).toFixed(1)}% of the file\n\n${parts}` +
          (d.top.length ? "\n\ncostliest operations:\n" + d.top.map((o) => `- ${amount(o.amount)} ${o.op.replace(/[`*_]/g, " ")}`).join("\n") : ""),
      );
      it.command = {
        command: "vscode.open",
        title: "Go to declaration",
        arguments: [cur.uri, { selection: new vscode.Range(d.line, 0, d.line, 0) }],
      };
      return it;
    });
    return [head, ...rows];
  }
}

/** Profiles the active file now (as on save) and shows its costliest declarations. */
async function whySlowCmd() {
  const ed = vscode.window.activeTextEditor;
  if (!ed || !ed.document.uri.fsPath.endsWith(".lean")) {
    vscode.window.showErrorMessage("leanprof: open a .lean file first");
    return;
  }
  if (ed.document.isDirty) await ed.document.save();
  const key = `elab:${ed.document.uri.fsPath}`;
  const job = onSave.debouncer.schedule(key, (signal) => elabOnSave(ed.document, signal), 0);
  onSave.last.set(key, job);
  await vscode.commands.executeCommand("leanprof.slowest.focus");
  return job;
}

function activateOnSave(context) {
  onSave.debouncer = new lib.Debouncer(onSaveConfig().delay);
  onSave.types = decorationTypes();
  onSave.log = vscode.window.createOutputChannel("leanprof on save");
  onSave.status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
  onSave.status.command = "leanprof.onSaveLog";
  slowestView = new SlowestView();
  context.subscriptions.push(
    ...Object.values(onSave.types),
    onSave.log,
    onSave.status,
    { dispose: () => onSave.debouncer.dispose() },
    vscode.workspace.onDidSaveTextDocument(didSave),
    vscode.window.onDidChangeVisibleTextEditors(decorateAll),
    vscode.window.onDidChangeActiveTextEditor(() => slowestView.refresh()),
    vscode.window.registerTreeDataProvider("leanprof.slowest", slowestView),
    vscode.commands.registerCommand("leanprof.whySlow", whySlowCmd),
    vscode.commands.registerCommand("leanprof.resetOnSave", resetOnSave),
    vscode.commands.registerCommand("leanprof.onSaveLog", () => onSave.log.show(true)),
  );
}

function activate(context) {
  const reg = (id, f) => context.subscriptions.push(vscode.commands.registerCommand(id, (...a) => f(context, ...a)));
  reg("leanprof.run", runCmd);
  reg("leanprof.sample", sampleCmd);
  reg("leanprof.elabFile", elabCmd);
  reg("leanprof.openReport", (ctx) => openReport(ctx));
  reg("leanprof.live", liveCmd);
  activateOnSave(context);
  // for the tests: the last on-save job of a key (`elab:FILE`, `run:ROOT`)
  return { lastOnSave: (key) => onSave.last.get(key) };
}

function deactivate() {
  if (live) live.panel.dispose();
}

module.exports = { activate, deactivate, splitArgs };
