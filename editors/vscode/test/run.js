// Runs test/suite.js inside VS Code (downloaded by @vscode/test-electron), with
// this repository as the workspace and the extension loaded from source.
//   LEANPROF=/path/to/leanprof npm test     (from editors/vscode, after `lake build leanprof copybug`)
// On Linux without a display, run it under xvfb-run.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { runTests } = require("@vscode/test-electron");

async function main() {
  const extensionDevelopmentPath = path.resolve(__dirname, "..");
  const workspace = path.resolve(extensionDevelopmentPath, "..", "..");
  process.env.LEANPROF = path.resolve(process.env.LEANPROF || path.join(workspace, ".lake/build/bin/leanprof"));
  await runTests({
    version: process.env.VSCODE_VERSION || "stable",
    extensionDevelopmentPath,
    extensionTestsPath: path.join(__dirname, "suite.js"),
    // a short user data directory: its IPC socket path must fit in 103 bytes
    launchArgs: [workspace, "--disable-extensions", "--disable-workspace-trust",
      "--user-data-dir", fs.mkdtempSync(path.join(os.tmpdir(), "lpv-"))],
    extensionTestsEnv: { LEANPROF: process.env.LEANPROF },
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
