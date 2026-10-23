# Lean API

`import Leanprof` (in a `module` file: `public import Leanprof`) gives:

## Marking code

| | |
|---|---|
| `profile! "name" e` | time `e`, a pure term or a monadic action; records file:line |
| `Leanprof.scope "name" fun _ => e` | the same without the macro (positions not recorded) |
| `Leanprof.scopeM "name" act` | time a monadic action; closes on exceptions |
| `set_option leanprof.enabled false` | `profile!` becomes the bare term |
| `#leanprof` / `#leanprof "file.json"` | show reports as inlay hints in this file ([editor](editor.md)) |

Labels must be string literals: the runtime keys its tables by the literal's
address.

Without the module system, `import Leanprof` makes the program link Lean's
front end (it is needed by `profile!`'s elaborator); `import Leanprof.Core`
avoids that and gives everything except `profile!` and `#leanprof`.

## Assertions for tests

| | |
|---|---|
| `Leanprof.expectNoCopies x` | fail if `x` copies a shared or multi-threaded value |
| `Leanprof.expectAllocsAtMost n x` | fail if `x` makes more than `n` allocations |

The test executable needs leanprof's `copyFlags` (and `allocFlags` for
allocations) in its `moreLeancArgs`.

## Queries while running

| | |
|---|---|
| `Leanprof.copies : BaseIO Nat` | copies of shared or multi-threaded values so far |
| `Leanprof.allocs : BaseIO Nat` | allocations so far (with `allocFlags`) |
| `Leanprof.calls "name" : BaseIO Nat` | completed calls of scopes named `name` |
| `Leanprof.totalNs "name" : BaseIO Float` | their total time, overhead removed |
| `Leanprof.overheadNs : BaseIO Float` | measured cost of one scope |
| `Leanprof.depth : BaseIO Nat` | open scopes on this thread |
| `Leanprof.whereIs "decl" : BaseIO String` | `File.lean:line` of a declaration |
| `Leanprof.demangle "sym" : String` | the name leanprof reports for a C symbol |
