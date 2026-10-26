// The extension's commands against the real `leanprof` command, in this
// repository: run copybug, the compile cost of its file, the HTML report, what
// changed on save (compile time, and the copies of a workload), why a file is
// slow, and a live view. Each command is given its target as an argument, so nothing
// waits for an input box.
"use strict";
const assert = require("assert");
const fs = require("fs");
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

  await step("the commands are registered", async () => {
    await ext.activate();
    const all = await vscode.commands.getCommands(true);
    for (const c of ["leanprof.run", "leanprof.sample", "leanprof.elabFile", "leanprof.openReport", "leanprof.live", "leanprof.whySlow", "leanprof.resetOnSave"])
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

  const api = ext.exports;
  const config = vscode.workspace.getConfiguration("leanprof.onSave");
  const G = vscode.ConfigurationTarget.Global;
  // the job a save started (the save event arrives after `save()` resolves)
  const nextJob = async (key, before) => {
    for (let i = 0; i < 100; i++) {
      const job = api.lastOnSave(key);
      if (job && job !== before) return job;
      await new Promise((r) => setTimeout(r, 50));
    }
    throw new Error(`no on-save job for ${key}`);
  };
  const setText = async (doc, text) => {
    const edit = new vscode.WorkspaceEdit();
    edit.replace(doc.uri, new vscode.Range(0, 0, doc.lineCount, 0), text);
    await vscode.workspace.applyEdit(edit);
    await doc.save();
  };
  const scratch = path.join(root, "Examples", "OnSaveScratch.lean");
  fs.writeFileSync(scratch, "theorem t (a b : Nat) : a + b = b + a := by omega\n");
  try {
    await step("on save: a declaration that costs more is shown with what changed inside it", async () => {
      await config.update("compileTime", true, G);
      await config.update("delay", 0, G);
      await vscode.commands.executeCommand("leanprof.resetOnSave");
      const doc = await vscode.workspace.openTextDocument(scratch);
      await vscode.window.showTextDocument(doc);
      const key = `elab:${scratch}`;
      await setText(doc, "theorem t (a b : Nat) : a + b = b + a := by omega\n\n");
      const first = await nextJob(key);
      const r1 = await first;
      assert.strictEqual(r1.code, 0);
      assert.ok(r1.delta.first, JSON.stringify(r1.delta));
      await setText(doc, "theorem t (a b : Nat) : a + b = b + a := by simp [Nat.add_comm]\n\n");
      const r2 = await (await nextJob(key, first));
      assert.strictEqual(r2.code, 0);
      const d = (r2.delta.decls || []).find((x) => x.key === "Examples/OnSaveScratch.lean t");
      assert.ok(d && d.pos === "Examples/OnSaveScratch.lean:1", JSON.stringify(r2.delta));
      assert.ok(d.why && d.why.rows.some((row) => row.name === "Nat.add_comm"), JSON.stringify(d.why));
      console.log(`     on-save profile: ${r1.ms} ms, then ${r2.ms} ms`);
    });

    await step("leanprof: Why is this file slow?", async () => {
      const job = await vscode.commands.executeCommand("leanprof.whySlow");
      const r = await job;
      assert.strictEqual(r.code, 0);
      assert.ok(fs.existsSync(r.report), r.report);
    });

    await step("on save: copies of a workload that changed are shown at their line", async () => {
      await config.update("compileTime", false, G);
      await config.update("runOptions", [], G);
      const doc = await vscode.workspace.openTextDocument(scratch);
      const key = `run:${root}`;
      await config.update("workload", "copybug -- 2000", G);
      await setText(doc, "theorem t (a b : Nat) : a + b = b + a := by omega\n");
      const first = await nextJob(key);
      assert.strictEqual((await first).code, 0);
      await config.update("workload", "copybug -- 3000", G);
      await setText(doc, "theorem t (a b : Nat) : a + b = b + a := by omega\n\n");
      const r = await (await nextJob(key, first));
      assert.strictEqual(r.code, 0);
      const c = (r.delta.copies || []).find((x) => x.where === "Examples/CopyBug.lean:17");
      assert.ok(c && c.change > 0, JSON.stringify(r.delta.copies));
    });
  } finally {
    for (const k of ["compileTime", "delay", "workload", "runOptions"]) await config.update(k, undefined, G);
    await vscode.commands.executeCommand("workbench.action.closeActiveEditor");
    fs.rmSync(scratch, { force: true });
  }

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
