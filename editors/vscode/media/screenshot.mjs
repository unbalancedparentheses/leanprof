// Renders the README's screenshots headlessly from a real VS Code window:
// starts the VS Code that `npm test` downloaded, with this extension and the
// repository open, drives it over the Chrome DevTools protocol (command
// palette, input box), and saves PNGs of the window.
//   node media/screenshot.mjs            (from editors/vscode, after `npm test`
//                                         and a `leanprof run` + `leanprof elab` in the repository)
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ext = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repo = path.resolve(ext, "..", "..");
const leanprof = process.env.LEANPROF || path.join(repo, ".lake/build/bin/leanprof");
const testDir = path.join(ext, ".vscode-test");
const build = fs.readdirSync(testDir).find((d) => d.startsWith("vscode-"));
const code =
  process.platform === "darwin"
    ? path.join(testDir, build, "Visual Studio Code.app/Contents/MacOS/Code")
    : path.join(testDir, build, "code");
const userData = fs.mkdtempSync(path.join(os.tmpdir(), "lps-"));
// the repository opened through a link named leanprof, whatever the checkout is called
const workspace = path.join(userData, "leanprof");
fs.symlinkSync(repo, workspace);
fs.mkdirSync(path.join(userData, "User"), { recursive: true });
fs.writeFileSync(
  path.join(userData, "User", "settings.json"),
  JSON.stringify({
    "leanprof.path": leanprof,
    "workbench.colorTheme": "Default Dark Modern",
    "workbench.startupEditor": "none",
    "window.restoreWindows": "none",
    "workbench.tips.enabled": false,
    "chat.disableAIFeatures": true,
    "workbench.secondarySideBar.defaultVisibility": "hidden",
    "workbench.layoutControl.enabled": false,
  }),
);
// a key for Run… with its target and options, so no input box is needed
fs.writeFileSync(
  path.join(userData, "User", "keybindings.json"),
  JSON.stringify([
    {
      key: "ctrl+alt+r",
      command: "leanprof.run",
      args: { target: "copybug -- 2000", options: ["--allocs", "--trace"] },
    },
  ]),
);
const port = 9333;
const vsc = spawn(
  code,
  [
    workspace,
    `--extensionDevelopmentPath=${ext}`,
    `--user-data-dir=${userData}`,
    "--disable-workspace-trust",
    "--skip-welcome",
    "--skip-release-notes",
    `--remote-debugging-port=${port}`,
  ],
  { stdio: "ignore" },
);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function page() {
  for (let i = 0; i < 60; i++) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
      const t = targets.find((t) => t.type === "page" && t.url.includes("workbench"));
      if (t) return t;
    } catch {}
    await sleep(500);
  }
  throw new Error("no VS Code window");
}

const target = await page();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let id = 0;
const waiting = new Map();
ws.addEventListener("message", (e) => {
  const m = JSON.parse(e.data);
  if (m.id && waiting.has(m.id)) {
    waiting.get(m.id)(m);
    waiting.delete(m.id);
  }
});
const send = (method, params = {}) =>
  new Promise((resolve, reject) => {
    const n = ++id;
    if (process.env.DEBUG) console.log(method);
    waiting.set(n, (m) => (m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result)));
    ws.send(JSON.stringify({ id: n, method, params }));
  });

await send("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
await sleep(4000);

async function key(k, code, keyCode, modifiers = 0) {
  await send("Input.dispatchKeyEvent", { type: "keyDown", key: k, code, windowsVirtualKeyCode: keyCode, modifiers });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: keyCode, modifiers });
}
const enter = () => key("Enter", "Enter", 13);
async function palette(command) {
  await key("F1", "F1", 112);
  await sleep(800);
  await send("Input.insertText", { text: command });
  await sleep(800);
  await enter();
}
async function shot(file) {
  const { data } = await send("Page.captureScreenshot", { format: "png" });
  fs.writeFileSync(path.join(ext, "media", file), Buffer.from(data, "base64"));
  console.log(`wrote media/${file}`);
}

// Run… copybug, then the HTML report of that run (and the last elab) in a webview
await key("r", "KeyR", 82, 1 | 2);
await sleep(12000);
await palette("Notifications: Clear All Notifications");
await sleep(500);
await palette("View: Hide Panel");
await sleep(500);
await palette("leanprof: Open report");
await sleep(6000);
await shot("report.png");

// the live view of a program that runs until stopped
await palette("leanprof: Live view");
await sleep(800);
await send("Input.insertText", { text: "server -- 0 20" });
await enter();
await sleep(9000);
await shot("live.png");

ws.close();
vsc.kill();
process.exit(0);
