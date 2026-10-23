# HTML report

`leanprof html` turns reports into one HTML file you can open offline or
attach to an issue: everything (data, styles, script) is inside the file,
nothing is fetched from the network.

```
leanprof sample myapp            # or: leanprof run myapp
leanprof elab --heartbeats Main.lean
leanprof html                    # writes .lake/leanprof/report.html
open .lake/leanprof/report.html
```

![leanprof html: summary and sampled flame graph](../images/html-report.png)

```
leanprof html [-o FILE] [--trace FILE] [--profile FILE] [--threshold PCT] [--min-ms MS]
              [--context N] [--title T] [REPORT.json...]
```

Without arguments it reads `report.json`, `elab.json` and `measure.json` from
`.lake/leanprof/`, whichever exist. A page for copybug is 60 to 160 KiB.

## What the page shows

- **Summary**: wall and CPU time, peak memory, allocations, copies, frees,
  tasks, failed reuse and closure calls, top scope; for compile reports the
  total cost, repeated work and the costliest line. Tiles only appear for
  what the report measured.
- **Flame graph** (icicle: callers above callees). Click a frame to zoom,
  search to highlight, hover for time, share and `file:line`. Direct
  recursion is folded into one frame unless you untick it.
  - For `leanprof sample`, the sampled call stacks, read from samply's profile
    next to the report (`EXE.json` and `EXE.syms.json`, as `sample` leaves
    them; `--profile FILE` picks another). Frames are coloured by what they
    are: Lean code, the Lean runtime, copying, freeing, leanprof, system
    libraries.
  - For `leanprof run`, a report has time per scope but not who called whom.
    Pass the timeline of `leanprof run --trace trace.json` as `--trace
    trace.json` for the call tree; without it the graph shows self time per
    scope.
  - For `leanprof elab`, compile cost by file, line and phase (elaboration,
    kernel, compiler, linters).
- **Tables**, sortable by any column and filterable: scopes (or sampled
  declarations and self time per function), copies with why
  (shared, multi-threaded, persistent) and their share of the scope's time,
  allocations, reuse failures, closures, tasks, waits, frees, memory per
  scope, compile cost per line, repeated work, and operation kinds.
- **Source**: every `file:line` in a table is a link that opens the lines
  around it, read from the project when the page was made, with the hints
  `#leanprof` shows in the editor (`⏱` time, `≈` sampled CPU, `⚠` copies,
  `▲` allocations, `⚙` compile cost). The Source tab lists all of them per
  file. `--context N` sets how many lines around each position are kept
  (default 3).

## Comparing two reports

Given two reports of the same kind, the first is the base and the second the
new one:

```
leanprof html -o pr.html base.json head.json
leanprof html -o pr.html base.json head.json base-elab.json head-elab.json
```

The page shows the new report, each summary tile with its change from the
base, and a Comparison tab that applies the rules of
[`leanprof compare`](ci-and-regressions.md): more copies of shared values at
a site, a changed call count, a scope slower by more than `--threshold`
percent (default 10) and `--min-ms` (default 1), or, for `elab --heartbeats`
reports, a declaration up by more than 1% and 1,000 heartbeats. Regressions
are listed first and counted in a banner at the top. Two `measure` summaries
are compared the way `leanprof judge` does.

![The Comparison tab in dark mode](../images/html-report-compare.png)

The page follows the system's light or dark setting; the button at the top
right switches it.

## In CI

Render the page in a job and upload it as an artifact:

```yaml
- run: |
    leanprof run --json head.json myapp
    leanprof html -o leanprof.html base.json head.json
- uses: actions/upload-artifact@v4
  with:
    name: leanprof-report
    path: leanprof.html
```

`scripts/check-html.py PAGE --expect NAME` checks a page: well-formed,
self-contained, data and script valid, at most 300 KiB, and naming `NAME`.
