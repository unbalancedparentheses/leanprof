# In the editor

Add `#leanprof` anywhere in a file that imports `Leanprof`:

```lean
#leanprof                         -- reads .lake/leanprof/report.json and elab.json
#leanprof "reports/before.json"   -- or a given report
```

Every line the reports mention gets an inlay hint at its end:

```
def buildWithHistory (n : Nat) ... := profile! "buildWithHistory" Id.run do   ⏱ 2.7 ms · 13.7% · 1×   ⚠ 1999 copies · 15.3 MiB · 2.7 ms   ⚙ 13.0 ms to compile
  | n + 2 => profile! "fib" (fib n + fib (n + 1))                              ⏱ 132.9 µs · 0.7% · 10945×
```

| hint | from | means |
|---|---|---|
| `⏱ time · % · calls` | `leanprof run` | run time of a `profile!` scope or function |
| `≈ time CPU · %` | `leanprof sample` | sampled CPU time of a declaration |
| `⚠ copies · bytes · time` | `leanprof run` | copies of shared values made by this declaration |
| `⚙ cost to compile` | `leanprof elab` | compile cost of this declaration or line |
| `⚙ cost` | `leanprof elab` | a tactic or term that starts on this line, inside a proof |

Hover a hint for details: self time, mean and percentiles, why a copy
happened, or the line's costliest compile-time operations and the
definitions behind them ("73 ms unfolding `Foo.bar` (Foo.lean:12), reached
from 40 call sites"), and the terms and tactics that start on it, each with
its exact range (`12:3-12:40  41.2 ms  tactic simp: simp [foo]`; see
[compile time](compile-time.md)). The infoview at
`#leanprof` lists everything for the file.

The hints describe the code as it was when the report was made; rerun after
editing.

## What changed since the last profile

`--since-last` compares a profile with the previous one of the same file or
program and writes the difference next to it
([difference file](reference.md#difference-file)):

```
leanprof elab --heartbeats --since-last Foo/Bar.lean   # compile time of one file
leanprof run --allocs --since-last myapp -- input.txt   # copies and allocations of a program
```

`elab` prints the declarations whose heartbeats moved by more than 1,000 and
what changed inside each, as `compare` explains a regression:

```
since the last profile (.lake/leanprof/onsave/Foo/Bar.lean.delta.json):
  1 declaration changed; file 94.28 kHB -> 120.30 kHB (+26.02 kHB)
    +25.00 kHB  Foo/Bar.lean t2 (Foo/Bar.lean:5); whnf reduces Foo.f (Foo/Bar.lean:1) +20.00 kHB
```

and `run` the copy and allocation sites whose counts changed (`+2,000
build [Array] in build (Foo/Bar.lean:17)`). Without a previous profile it
says so, and the next run is compared with this one. Each run becomes the
base of the next (`--keep-base` keeps the first). `elab --since-last` reuses
`lake env`'s paths and the module's setup while the package's
configuration and the file's imports are unchanged, which saves 0.3–0.7 s a
run, so it can run on every save.

`#leanprof` shows these differences too, as hints at each declaration or
call site:

```
theorem t2 (a b : Nat) : a + b = b + a := by simp [foo]      Δ +25.0 kHB since the last profile
```

and its hover lists what changed inside the declaration (definitions
unfolded, instances, simp lemmas, with before and after). The
[VS Code extension](vscode.md#on-save) runs `--since-last` on every save and
shows the same at the end of each line. In another editor, run it from a
save hook, in the background, from the project's directory; for example in
Neovim:

```lua
vim.api.nvim_create_autocmd("BufWritePost", { pattern = "*.lean", callback = function(a)
  vim.fn.jobstart({ "leanprof", "elab", "--heartbeats", "--since-last", vim.fn.fnamemodify(a.file, ":.") })
end })
```

and the `#leanprof` hints pick the difference up when the file is next
elaborated.

To run leanprof itself from VS Code (profile, compile cost of a file, what
changed on save, the HTML report and a live view in tabs), see the
[VS Code extension](vscode.md).
