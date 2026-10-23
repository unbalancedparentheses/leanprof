# VS Code extension

The extension in [`editors/vscode/`](../../editors/vscode) runs the
`leanprof` command from the command palette and shows what it writes in the
editor. It has no profiling logic of its own: every number comes from the
command, so the extension and the command line always agree.

![The HTML report in VS Code](../../editors/vscode/media/report.png)

## Install

1. Install the command ([getting started](getting-started.md#install-the-command)):

   ```
   curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh
   ```

2. Download `leanprof-X.Y.Z.vsix` from the
   [latest release](https://github.com/unbalancedparentheses/leanprof/releases/latest)
   and install it:

   ```
   code --install-extension leanprof-0.1.0.vsix
   ```

   or, in VS Code, **Extensions: Install from VSIX…** from the command
   palette. (The extension is not on the Marketplace.) Every CI run also
   keeps the `.vsix` of its commit as the `leanprof-vscode` artifact.

3. If VS Code does not see `leanprof` on its `PATH` (common when VS Code is
   started from the Dock or a desktop launcher), set **leanprof.path** to
   the full path, for example `~/.local/bin/leanprof`.

To build it yourself: `cd editors/vscode && npm ci && npm run package`.

## Commands

All are under **leanprof:** in the command palette, and run in the Lake
project of the open file (the nearest directory with a lakefile), or the
first workspace folder.

| command | runs | shows |
|---|---|---|
| **Run…** | `leanprof run [options] EXE -- ARGS` | the report in a terminal, then offers the HTML report |
| **Sample…** | `leanprof sample EXE -- ARGS` | the same for sampled CPU time; needs samply |
| **Compile cost of this file** | `leanprof elab --heartbeats FILE` | compile cost per line and declaration; also in the editor's context menu on `.lean` files |
| **Open report** | `leanprof html` | the [HTML report](html-report.md) (flame graph, tables, source, comparison) in a tab |
| **Live view** | `leanprof top --plain EXE -- ARGS` | the running program, refreshed: hot scopes, copies, allocations, tasks, waits |

**Run…** asks for the executable (a `lean_exe` target) and its arguments,
as you would type them after `leanprof run`, then for options: `--auto`,
`--allocs`, `--counters`, `--frees`, `--core`, and `--trace`, which records
a timeline so that **Open report** shows the run's flame graph. The answers
are remembered per workspace.

**Open report** shows whatever reports are in `.lake/leanprof/` (the last
`run` or `sample`, and the last `elab`), the same page `leanprof html`
writes.

**Live view** stops the program when its tab is closed. It also takes
`--attach FILE` or `--pid PID` instead of an executable, for a program
already running with `LEANPROF_LIVE` ([live view](live.md)).

![leanprof top in a panel](../../editors/vscode/media/live.png)

Inline hints next to the code are not part of this extension: add
`#leanprof` to a file ([in the editor](editor.md)), which works through the
Lean extension's language server in any editor.

## Settings

| setting | default | |
|---|---|---|
| `leanprof.path` | `leanprof` | the command: a name on `PATH` or a full path (`.lake/build/bin/leanprof` of a checkout works too) |
| `leanprof.liveInterval` | `500` | milliseconds between frames of the live view |

## Keybindings

A command given its target as an argument does not ask for it:

```json
[
  { "key": "ctrl+alt+r", "command": "leanprof.run",
    "args": { "target": "myapp -- input.txt", "options": ["--allocs", "--trace"] } },
  { "key": "ctrl+alt+s", "command": "leanprof.sample", "args": { "target": "myapp -- input.txt" } },
  { "key": "ctrl+alt+t", "command": "leanprof.live", "args": { "target": "server -- 8080" } }
]
```

## Development

`editors/vscode/extension.js` is the whole extension. Its tests run its
commands in a real VS Code (downloaded by `@vscode/test-electron`) against
this repository:

```
lake build leanprof copybug server
cd editors/vscode && npm ci
npm test                          # xvfb-run -a npm test on a Linux server
node media/screenshot.mjs         # the screenshots above, from that VS Code
```
