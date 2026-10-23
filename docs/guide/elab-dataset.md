# Compile-time datasets: elab.json and the module files

`leanprof elab` writes two things:

- **the report**, `elab.json` (`--out`, by default `.lake/leanprof/elab.json`):
  the aggregate over every file profiled, which `#leanprof`, `compare`,
  `report-md` and `html` read;
- **the dataset** (`--dataset DIR`, by default `elab/` next to the report;
  `--no-dataset` for none): an index, a copy of the report and one file per
  module with every term and tactic and the timeline of its elaboration.

Both are documented, versioned JSON, so that other tools can read them. The
schemas are in [`docs/schema/`](../schema/) (JSON Schema 2020-12), and
`scripts/check-elab-dataset.py DIR` checks a dataset against them and for
consistency (it needs nothing but Python).

```
DIR/
  index.json            leanprof-elab-dataset, version 1
  elab.json             leanprof-elab, version 4 (the report, paths relative to DIR)
  modules/
    Batteries.Data.List.Lemmas.json      leanprof-elab-module, version 1
    ...
```

## Versions

Each file says what it is: `"schema"` (`leanprof-elab`, `leanprof-elab-module`,
`leanprof-elab-dataset`) and `"version"`. Fields are only added within a
version, so a reader should ignore fields it does not know; a field that is
removed or changes meaning gets a new version, and the old one is documented
here. `elab.json` was version 3 before datasets (no `schema`, `files[].detail`,
`imports_ns`, `events`, `lean_version`, `term_threshold`, `dataset`); readers of
version 3 read version 4.

## Amounts

`unit` is `ns` (wall time) or `heartbeats` (`--heartbeats`). The report writes
amounts as numbers (`total_ns` and the like hold heartbeats in heartbeats mode,
for compatibility); the module files write them as whole numbers. Totals are
sums of traced time: Lean elaborates proofs on several threads, so a file's
`total` can exceed its `wall_ns` (the time of the process, imports included).

## A module file

```json
{
  "schema": "leanprof-elab-module", "version": 1,
  "file": "Batteries/Recycling/RBTree/WF.lean", "module": "Batteries.Recycling.RBTree.WF",
  "lean_version": "4.35.0", "unit": "ns", "exact_ranges": true, "compact": false,
  "threshold": 1, "term_threshold": 0,
  "wall_ns": 1984000000, "imports_ns": 241000000, "errors": 0,
  "total": 4512000000, "elab": 4400000000, "kernel": 90000000, "compile": 0, "lint": 22000000,
  "declarations": [{"line": 290, "name": "theorem reverse_ins ...", "total": 656110000, "elab": ..., "kernel": ..., "compile": ..., "lint": ...}],
  "ranges": [{"range": "293:3-294:71", "kind": "tactic", "syntax": "Lean.Parser.Tactic.focus",
              "text": "fun_cases balLeft l v r <;> ...", "amount": 369720000, "count": 1}],
  "classes": ["Elab.command", "Leanprof.tactic", "Leanprof.term", "Meta.isDefEq", ...],
  "event_fields": ["parent", "class", "start_ns", "dur_ns", "thread", "range", "text"],
  "events": [[-1, 0, 241500000, 8691333, 0, null, "theorem reverse_ins ..."],
             [0, 1, 241600000, 1204583, 0, "290:3-290:40", "suffices"], ...]
}
```

- `declarations`: each line with a cost, as in the report's `scopes` (kernel and
  compiler work can sit on a line of its own).
- `ranges`: **every** term and tactic (unless `--term-threshold N` was given),
  by exact range `line:col-line:col` (from 1; the end column is one past the
  last character), with its inclusive cost and how many times it ran. A range
  elaborated inside itself (a macro's expansion) is counted once.
- `events`: the timeline. Each event is an array, in the order of
  `event_fields`: the index of the event it ran in (`-1` for a command, or
  for work Lean ran asynchronously: proofs, the kernel, the compiler,
  linters), its class (an index into `classes`), its start (ns after the
  driver started; the imports are loaded first, `imports_ns`), its duration,
  the thread, its range (terms and tactics: `Leanprof.term`,
  `Leanprof.tactic`) and a text (the syntax kind of a term or tactic, a
  command's source, or an operation's description). A parent comes before its
  children and contains them in time. Operations other than terms and
  tactics are there when they took longer than `threshold` (1 ms by default);
  with `--compact` there are none. Heartbeat profiles and profiles made
  without the driver (`lean --json`) have no timeline (`events` is empty).

## The index

`index.json` names the dataset's modules (`files[]`: `file`, `module`,
`path` of the module file relative to the dataset, `total`, `wall_ns`,
`imports_ns`, `errors`, `events`) and how it was made (`lean_version`, `unit`,
`compact`, `exact_ranges`, `threshold`, `term_threshold`). `report` names the
report in the dataset.

## The report

`elab.json` (`leanprof-elab`, version 4) has, besides what the [compile-time
guide](compile-time.md) describes (`scopes`, `repeated`, `constants`, `kinds`,
`tactics`, the costliest 20,000 `ranges`), `files[]` with each file's `detail`
(its module file, relative to the report), `imports_ns` and `events`, and
`dataset` (the dataset's directory, relative to the report).

## Profiling a whole project into a dataset

```
sh scripts/elab-dataset.sh PROJECT_DIR OUT_DIR [leanprof elab options...]
```

builds the project, profiles every module of it (`elab --project`, in
parallel), writes the dataset to `OUT_DIR` with a Chrome trace of every
timeline (`trace.json`, for [Perfetto](https://ui.perfetto.dev)) and a
`provenance.json` (the project's commit and remote, the Lean version, the
machine, the options), and checks it. `LEANPROF=PATH` names the leanprof to
run. For example, all of Batteries:

```
sh scripts/elab-dataset.sh ~/src/batteries datasets/batteries-v4.35.0            # full profiles
sh scripts/elab-dataset.sh ~/src/batteries datasets/batteries-compact --compact  # terms and tactics only
```

Nothing is uploaded; publishing a dataset is up to you.

## Timelines elsewhere

- `leanprof html` draws the timelines of the report's slowest files in its
  **Timeline** tab ([HTML report](html-report.md)).
- `leanprof elab --chrome-trace FILE` writes every file's timeline as a Chrome
  trace (one process per file, one thread per Lean thread, files placed at the
  time they were elaborated), for [Perfetto](https://ui.perfetto.dev) or
  `chrome://tracing`.
