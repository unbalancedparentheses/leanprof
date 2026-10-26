# leanprof for VS Code

Runs [leanprof](https://github.com/unbalancedparentheses/leanprof), the
profiler for Lean 4, from the command palette and shows its reports in the
editor. Everything is done by the `leanprof` command; the extension starts
it in the project of the open file and displays what it writes.

![The HTML report of `leanprof run` in VS Code](media/report.png)

| command | runs | shows |
|---|---|---|
| **leanprof: Run…** | `leanprof run [options] EXE -- ARGS` | the report in a terminal; offers the HTML report |
| **leanprof: Sample…** | `leanprof sample EXE -- ARGS` | the same, for sampled CPU time (needs samply) |
| **leanprof: Compile cost of this file** | `leanprof elab --heartbeats FILE` | compile cost per line and declaration |
| **leanprof: Open report** | `leanprof html` | the report page (flame graph, tables, source) in a tab |
| **leanprof: Live view** | `leanprof top --plain EXE -- ARGS` | the running program's hot scopes, copies and tasks, refreshed |
| **leanprof: Why is this file slow?** | `leanprof elab --heartbeats --since-last FILE` | the file's costliest declarations, in the explorer |

Run… asks for the executable (a `lean_exe` target) and its arguments, then
for options (`--auto`, `--allocs`, `--counters`, `--frees`, `--core`,
`--trace`; with `--trace`, Open report shows the run's flame graph). Live
view also takes `--attach FILE` or `--pid PID` for a program started with
`LEANPROF_LIVE`.

![leanprof top in a panel](media/live.png)

## On save

Opt in with **leanprof.onSave.compileTime**: each save of a `.lean` file
runs `leanprof elab --heartbeats --since-last` on it, and every declaration
whose compile cost changed since the previous save shows the change at the
end of its line (`+25.0 kHB since the last save`, in the error color above
**leanprof.onSave.highlightAbove**). The hover says what changed inside it:
the definitions unfolded, instances and simp lemmas, before and after. With
**leanprof.onSave.workload** (`myapp -- input.txt`), a save also runs
`leanprof run --since-last` and shows the copies and allocations that
changed at their lines (`+2,000 copies`). Saves are debounced
(**leanprof.onSave.delay**), and a new save stops a profile still running.

![Compile-time changes since the last save, and the slowest declarations view](media/onsave.png)

## Requirements

The `leanprof` command, Lean through elan, and for Sample… samply. One
command installs leanprof:

```
curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh
```

If `leanprof` is not on the `PATH` VS Code sees, set **leanprof.path** to
its full path. `leanprof doctor` in the project checks the rest.

## Settings

| setting | default | |
|---|---|---|
| `leanprof.path` | `leanprof` | the command, a name on `PATH` or a full path |
| `leanprof.liveInterval` | `500` | milliseconds between frames of the live view |
| `leanprof.onSave.compileTime` | off | profile a `.lean` file's compile time on save and show what changed |
| `leanprof.onSave.workload` | empty | a program to profile on save (`EXE -- ARGS`) |
| `leanprof.onSave.runCommand`, `runOptions` | `run`, `["--allocs"]` | how the workload is profiled |
| `leanprof.onSave.delay` | `500` | milliseconds to wait after a save |
| `leanprof.onSave.highlightAbove` | `10` | kHB: larger increases in the error color |
| `leanprof.onSave.keepBase` | off | compare with the first on-save profile instead of the previous |

## Keybindings

Each command takes its target as an argument, to skip the questions:

```json
{ "key": "ctrl+alt+r", "command": "leanprof.run",
  "args": { "target": "myapp -- input.txt", "options": ["--allocs", "--trace"] } }
```

`leanprof.sample` and `leanprof.live` take `{ "target": "..." }`.

## Install

The extension is not on the Marketplace. Each
[release](https://github.com/unbalancedparentheses/leanprof/releases) has a
`.vsix`:

```
code --install-extension leanprof-0.1.0.vsix
```

More in [the guide](https://github.com/unbalancedparentheses/leanprof/blob/main/docs/guide/vscode.md).
Inline hints (`#leanprof`) work without this extension, through the Lean
extension's language server.
