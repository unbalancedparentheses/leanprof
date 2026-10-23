// The extension's commands against the real `leanprof` command, in this
// repository: run copybug, the compile cost of its file, the HTML report and
// a live view. Each command is given its target as an argument, so nothing
// waits for an input box.
"use strict";
const assert = require("assert");
const path = require("path");
const vscode = require("vscode");

async function step(name, f) {
  const t = Date.now();
  try {
    await f();
    console.log(`ok   ${name} (${Date.now() - t} ms)`);
  } catch (e) {
    console.log(`FAIL ${name}: ${e.stack || e}`);
    throw e;
  }
}

async function run() {
  const root = vscode.workspace.workspaceFolders[0].uri.fsPath;
  await vscode.workspace.getConfiguration("leanprof").update("path", process.env.LEANPROF, vscode.ConfigurationTarget.Global);
  const ext = vscode.extensions.getExtension("unbalancedparentheses.leanprof");
  assert.ok(ext, "extension found");

  await step("the five commands are registered", async () => {
    await ext.activate();
    const all = await vscode.commands.getCommands(true);
    for (const c of ["leanprof.run", "leanprof.sample", "leanprof.elabFile", "leanprof.openReport", "leanprof.live"])
      assert.ok(all.includes(c), c);
  });

  await step("leanprof: Run… copybug", async () => {
    const code = await vscode.commands.executeCommand("leanprof.run", {
      target: "copybug -- 2000",
      options: ["--allocs", "--trace"],
    });
    assert.strictEqual(code, 0);
  });

  await step("leanprof: Compile cost of this file", async () => {
    const doc = await vscode.workspace.openTextDocument(path.join(root, "Examples", "CopyBug.lean"));
    await vscode.window.showTextDocument(doc);
    const code = await vscode.commands.executeCommand("leanprof.elabFile");
    assert.strictEqual(code, 0);
  });

  await step("leanprof: Open report", async () => {
    const panel = await vscode.commands.executeCommand("leanprof.openReport");
    assert.ok(panel, "a panel");
    const html = panel.webview.html;
    assert.ok(html.includes('"n":"buildWithHistory"'), "the run's timeline is the flame graph");
    assert.ok(html.includes('"elab":true'), "the compile-time report is in it");
  });

  await step("leanprof: Live view", async () => {
    const { panel, finished } = await vscode.commands.executeCommand("leanprof.live", "server -- 40 20");
    assert.ok(panel, "a panel");
    const { code, frame, log } = await finished;
    assert.strictEqual(code, 0, log);
    assert.ok(frame.includes("leanprof top"), frame);
    assert.ok(frame.includes("handle"), frame);
    panel.dispose();
  });

  await step("leanprof: Live view stops the program when its tab is closed", async () => {
    // a server that runs until stopped
    const { panel, finished } = await vscode.commands.executeCommand("leanprof.live", "server -- 0 20");
    await new Promise((r) => setTimeout(r, 4000));
    panel.dispose();
    const timeout = new Promise((r) => setTimeout(() => r("still running"), 10000));
    const r = await Promise.race([finished, timeout]);
    assert.notStrictEqual(r, "still running");
  });
}

module.exports = { run };
