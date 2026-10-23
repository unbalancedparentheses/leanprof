# Compile time

```
leanprof elab [--heartbeats] [--top N] [--out FILE] FILE.lean...
```

elaborates the files with Lean's `trace.profiler` (through `lake lean`, so
plugins and the shared libraries of precompiled modules load as in the
build; if Lean fails on a file, leanprof says so and shows the error),
reads the full trace
trees (every `isDefEq`, `whnf`, instance search, tactic step, kernel check
and compiler pass, with its own and total cost) and reports:

- **where compile time went**: self cost by kind of operation;
- **the costliest lines**, each with its most expensive nested operations;
- **repeated work**: the same operation done many times.

```
  costliest lines (elab / kernel / compiler / lint)
  12279.47 kHB  12272.25 kHB/ 1.14 kHB / 0.00 kHB / 6.08 kHB   Verified/PhiExamples.lean:154  theorem assembly_cycle_run ...
      12236.09 kHB [Elab.step] cases w <;> decide +kernel

  repeated work (the same operation done more than once)
  51878.55 kHB  11×    [Elab.step] cases w <;> decide +kernel
  3823.21 kHB   132×   [Meta.synthInstance] CoeT LineBuffer x (List String)
```

Repeated work usually means a missing instance, a coercion found the long
way every time, or a definition that should be reducible.

## Heartbeats: exact compile cost

With `--heartbeats` the numbers are Lean heartbeats (a count of allocations
during elaboration) instead of time, shown in kHB: 1 kHB is the unit of
`maxHeartbeats`, whose default limit is 200,000 per declaration. They are
the same on every run, so they
can be compared without noise. Editing one declaration moves its neighbours
by a few heartbeats, so `leanprof compare` counts an increase above 1% and
1,000 heartbeats as a regression. Declarations are matched by name, so edits
that move lines still compare.

## In the editor

The report goes to `.lake/leanprof/elab.json`; `#leanprof` shows it as
`⚙ 17.3 kHB to compile` hints at the end of each line, and hovering lists the
line's costliest operations. See [editor](editor.md).

For deeper compile-time work,
[lean-source-profiler](https://github.com/Vilin97/lean-source-profiler) links
slow operations to the definitions they unfold and has profiled all of
Mathlib.
