# Case study: lean-regex

[lean-regex](https://github.com/pandaman64/lean-regex) is a verified regular
expression engine for Lean 4: a backtracker and a Pike VM over a compiled
NFA, with correctness proofs in a separate package. The runs below used the
`regex` package at commit `32af6f3` (Lean 4.34.0-rc1, its own toolchain) and
leanprof's command from another checkout, on an Apple M5 Max. The project
has no dependency on leanprof.

The workload is the project's own benchmark executable, `Bench`
(`scripts/Bench.lean`), counting the matches of `[a-zA-Z_]+_(lt|le)\b` in
4.58 MB of Lean source (every `Init/Data/*/*.lean` of Lean 4.35.0
concatenated), three times:

```
leanprof sample Bench -- -e '[a-zA-Z_]+_(lt|le)\b' -n 3 corpus.txt
```

Uninstrumented, one search takes 0.67 s (2.0 s for three), finding 4,878
matches.

## Where run time goes (`leanprof sample`)

| self CPU | |
|---|---|
| 25% | `Regex.VM.εClosure` (`Regex/VM/Basic.lean:58`) |
| 23% | allocation (`mi_malloc_small`, `lean_inc_heartbeat`, ...) |
| 11% | freeing objects |
| 7% | `Regex.VM.eachStepChar.go` (`Regex/VM/Basic.lean:114`) |
| 7% | `Regex.VM.stepChar` (`Regex/VM/Basic.lean:82`) |
| 7% | `Regex.Data.SparseSet.insert` (`Regex/Data/SparseSet/Basic.lean:83`) |
| 6% | `Regex.Data.Classes.mem` (`Regex/Data/Classes.lean:58`) |
| 3% | thread-local variable lookups (`tlv_get_addr`, from the allocator) |

A third of the CPU time is the memory allocator and freeing, and
`εClosure`'s own time is mostly building and taking apart the cells below.

## Allocations (`leanprof run --allocs`)

204,911,040 allocations (4.58 GiB) for 13.7 million input characters:
**15 allocations per character**.

| allocations | share | function | where |
|---|---|---|---|
| 117,325,311 | 57% | `Regex.VM.εClosure` | `Regex/VM/Basic.lean:58` |
| 74,087,541 | 36% | `Regex.VM.stepChar` | `Regex/VM/Basic.lean:82` |
| 13,347,033 | 7% | `Regex.VM.captureNext.go` | `Regex/VM/Basic.lean:139` |

The ε-closure keeps its work stack as a `List (σ.Update × Fin nfa.size)`
(`εStack`, line 21): every push in `pushNext` (lines 35–48) allocates a
cons cell and a pair, and `.split` pushes two. `εClosure` returns
`Option σ.Update × SearchState σ nfa` and rebuilds the `SearchState`
structure at every step (line 75), and `stepChar` starts each closure with a
fresh one-element list `[(update, state')]` (line 101). With `--frees`, the
same run frees 131.8 million objects, one per cascade.

**What a fix looks like**: keep the stack as an `Array` in the search state
(pushed and popped in place, allocated once per search), and pass `matched`
and the state separately instead of in a fresh pair per step. The Rust
`regex-lite` crate this VM follows (as the file says) does exactly that.

## Closures (`leanprof run --counters`)

13,702,767 closure applications, all from one site:

```
   applies   share  call site  (where)  ->  target
  13702767  100.0%  Regex.VM.εClosure  (Regex/VM/Basic.lean:58)  ->  Regex.BufferStrategy
```

`εClosure` is generic over a `Strategy` structure whose `write` field is a
function; it is not specialized (the comment above it says "we may want to
test specialization by `@[specialize σ]`"), so each capture write goes
through `lean_apply_3` to the lambda in `BufferStrategy`
(`Regex/Strategy.lean:22`). `@[specialize σ]` on `εClosure`, `stepChar` and
`eachStepChar` (or making the strategy a class) would turn this into a
direct call and let the compiler unbox `σ.Update`.

## Copies (`leanprof run`)

| copies | bytes | time | function | where |
|---|---|---|---|---|
| 13,376,304 | 204.1 MiB | 84 ms | `Regex.BufferStrategy` (`Vector.setIfInBounds`) | `Regex/Strategy.lean:22` |
| 43,911 | 5.4 MiB | 0.5 ms | `Regex.Data.SparseSet.insert` | `Regex/Data/SparseSet/Basic.lean:83` |

One capture buffer copy per input position (`eachStepChar.go` runs
13,376,301 times): `pushNext` writes to `update` on a `.save` node (line
39) while the same buffer is still in `current.updates` (`stepChar` reads
it at line 100) and, after a `.split`, in a second stack entry. The buffers
are small (16 bytes on average), so this is 4% of the run. It is the price
of persistent capture buffers, which the VM's proofs rely on, and not
worth changing on its own.

Constructor reuse (`--counters`): 9.4% of `εClosure`'s 158.6 million reuse
checks fail on shared cells, the stack entries above.

## Compile time (`leanprof elab --heartbeats`)

Four files, 108.5M heartbeats (108,457 kHB; `maxHeartbeats` counts in kHB).
These heartbeats were measured with leanprof `8caf3fd` and reproduce
exactly with it (`scripts/reproduce.sh lean-regex`, see
[reproduce.md](../reproduce.md)); later versions of `elab` trace less and
report fewer for the same files (`eachStepChar` 12.0M instead of 13.5M).

- Kind of work: `isDefEq` 21%, `whnf` 20%, elaboration steps 18%, instance
  search 10%, code generation 8%, kernel 5%.
- **`eachStepChar` (`Regex/VM/Basic.lean:105`) costs 13.5M heartbeats**,
  almost all in `decreasing_tactic`: its local `go` has no `termination_by`
  (the other loops in the file have one), so Lean guesses a measure and
  proves the decrease for each candidate. `termination_by current.states.count - i`
  would skip the search.
- The two `mutual` blocks of the parser (`Regex/Syntax/Parser/Basic.lean:169`
  and `:273`) spend 25.2M heartbeats in 32 `decreasing_tactic` runs,
  proving the lexicographic `(pos, n)` measures at every recursive call.
- `Regex/NFA/Compile/ProofData/Basic.lean`: the 26 `get` theorems proved
  by `grind` cost 26.9M heartbeats, and **the same check
  `i < nfa'.size =?= i < nfa'.size` is done 76 times at 585k heartbeats
  each (25.7M)**: the two sides go through different `ProofData` instances
  (`whnf` of `inst.toProofData` runs 13,560 times and of `nfa'` 5,766
  times), so the check unfolds `nfa'`, a `pushRegex` call. Stating the
  theorems against the instance the proof uses, or making `nfa'`
  irreducible in these sections, would avoid it.

## What broke or confused leanprof here, and was fixed

- Positions of the benchmark pointed at `Bench.lean`; the file is
  `scripts/Bench.lean` (a `lean_exe` with `srcDir`). Positions now look for
  a module's source in the package and one directory down.
- With `--auto`, `main` showed 17.7% of wall time: totals have the probes'
  cost removed, the wall time did not. `%wall` is now against the wall time
  without the probes' calibrated cost (here 1.79 s of 7.06 s, against 2.0 s
  measured without probes).
- With `--auto`, `Regex.BufferStrategy` was counted 27.4 million times: its
  lambda and `_boxed` wrapper were separate scopes with the same name.
  They now count as one declaration (13.7 million calls, one per write).
- `--frees` made the program 6.3 times slower (13.0 s): after each cascade
  it cleared an 8 KiB table of shared children. It now clears only the
  slots it used: 3.6 s.
- `sample` showed `[libdyld.dylib] 0x1d394` (3% of the time) and
  `OUTLINED_FUNCTION_39` (6%): the first is `tlv_get_addr`, now named from
  `dyld_info` and counted as thread-local variable lookups; the second is
  code the linker outlined from `mi_free`, now counted in its caller.
  `lean_inc_heartbeat` (5%), which every small allocation calls, is now
  counted as allocation.
