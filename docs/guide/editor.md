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
| `⚙ cost` | `leanprof elab` | a tactic step on this line, inside a proof |

Hover a hint for details: self time, mean and percentiles, why a copy
happened, or the line's costliest compile-time operations and the
definitions behind them ("73 ms unfolding `Foo.bar` (Foo.lean:12), reached
from 40 call sites"). The infoview at
`#leanprof` lists everything for the file.

The hints describe the code as it was when the report was made; rerun after
editing.

To run leanprof itself from VS Code (profile, compile cost of a file, the
HTML report and a live view in tabs), see the [VS Code extension](vscode.md).
