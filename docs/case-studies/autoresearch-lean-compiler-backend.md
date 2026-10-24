# Case study: the autoresearch loop on lean-compiler-backend

An agent ran [`research/program.md`](../../research/program.md) on
[lean-compiler-backend](https://github.com/unbalancedparentheses/lean-compiler-backend)
(`lcb`) for about three hours on 2026-10-23: one idea per experiment, a
fixed measure command, and `leanprof judge` deciding KEEP or DISCARD. It
started where [the hand-made fixes](lean-compiler-backend.md) left off
(main at `854fcc2`, with the tokenizer, `CFG.build` and `Parser.peek`
fixes merged). The result is the branch
[`autoresearch/zlib-2026-10-23`](https://github.com/unbalancedparentheses/lean-compiler-backend/tree/autoresearch/zlib-2026-10-23):
12 commits, not merged into main.

**Result:** 25 experiments, 12 kept. The zlib workload makes 16.3% fewer
allocations (7,719,273 → 6,460,575; 200.1 → 167.7 MiB) and 55% fewer copies
of shared values (86,449 → 38,911). Wall time fell 24% (median of 30 runs
each, 648 → 492 ms, measured with probes, base and head alternating). The
output is byte-identical on 340 input/target/option combinations. Most of
the gain came from one finding: each function was validated about ten times
on its way through the compiler, and each validation rebuilt the CFG.

## Setup

| | |
|---|---|
| program | `lcb` at `854fcc2`, Lean 4.34.1, Apple M5 Max shared with other agents (load average 20 to 54 during the session) |
| measuring tool | leanprof `origin/main` (`3eac66c`) built in its own worktree, never edited |
| workload | `lcb --target aarch64-macos --optimize --allocate deflate.ssa inflate.ssa trees.ssa crc32.ssa -o zlib.s`: zlib 1.3.1 compiled to QBE IL by cproc, 562 KB of input (the same files as the hand-made fixes) |
| measure (fixed) | `leanprof measure --runs 5 --warmup 1 --check-output .lake/research/zlib.s --out NEW.json lcb -- <workload>` |
| allocations (extra rule) | `leanprof run --allocs` on the same workload; any increase in total allocations is a DISCARD even when judge says KEEP |
| TEST | `lake build lcb lcb-tests`, then every step of the project's `scripts/check.sh --require-native` (102 steps: build-identity check, `lcb-tests`, the proof-axiom audit, about 95 native and cross-target scripts), then a byte-identity check |
| byte identity | all 17 zlib units × 5 targets (aarch64-macos/linux, x86_64-linux/macos, riscv64-linux) × 4 option sets (none, `--optimize`, `--allocate`, both) = 340 combinations, outputs, stderr and exit codes compared with the outputs of `854fcc2` generated once before any change |
| build identity | `scripts/build_identity.py --write` before every build; `compiler-build.json` and `BuildIdentity.lean` are committed with each change, as the project's CI requires |

Three `check.sh` steps fail on this machine already at `854fcc2`
(`allocation.py`: a callee-save corruption check whose sentinel isn't
triggered by the local toolchain; `macos_x86.py` under Rosetta;
`memory.py`), while CI passes them. Because `check.sh` stops at its first
failure, TEST ran each step separately and required exactly the same steps
to pass as at baseline. A full TEST takes 26 to 38 minutes. So each
experiment was first built, checked for byte identity, measured and judged
(about 90 s), and the full TEST ran for kept commits in a separate worktree
while the loop went on. It ran on the head after the first KEEP and on two
later heads; the first two passed, and the run on the final head had not
finished when the session stopped (an API usage limit). The project's CI
(macOS, Linux x86-64 and Linux arm64, including the native checks that fail
locally) passed on the final head, `f9ed557`.

## Experiments

Time is the new summary's median, min and max (5 runs, with probes). Because
the machine was shared, every experiment re-measured the current base right
before the candidate, from a second worktree at the base commit, and judged
against that (see friction 1). `allocs` is the total from
`run --allocs`; copies are judge's `copies_total`.

| # | verdict | median ms (min–max) | copies | allocs | idea |
|---|---|---|---|---|---|
| base | | 603.8 (600.2–607.2) | 86,449 | 7,719,273 | main `854fcc2` |
| 1 | crash | | | | `validIdentifier` with `String.all`/`front`: a `decide +kernel` proof in `PhiExamples.lean` no longer reduces |
| 2 | DISCARD | 703.8 (623.5–736.0) | 86,449 | 7,719,273 | `validIdentifier` builds the char list once instead of three times: within noise |
| 3 | DISCARD | 859.6 (782.8–909.9) | 86,449 | 7,744,357 | HashSet for block labels on the scalable path: allocs +0.32% |
| 4 | DISCARD | 890.6 (855.2–1146.9) | 86,449 | 7,719,273 | `Optimize.function`: take arrays out of their structures before mapping: no effect, the compiler fuses the two structure updates |
| **5** | **KEEP** `1ba8968` | 638.0 (609.2–694.7) | **39,816** | 7,718,385 | `Optimize.function`: check phi incoming values in place instead of mapping them into a temporary array (`explain --why` pointed at the line) |
| 6 | DISCARD* | 834.5 (745.5–870.2) | 39,816 | 7,718,385 | pre-size `CFG.build`'s label map: judge said KEEP on time, overridden (friction 1) |
| 7 | DISCARD | 802.9 (718.6–920.4) | 39,816 | 7,718,385 | pre-size the validator's definitions map: counts unchanged |
| **8** | **KEEP** `e60f471` | 861.7 (860.2–883.7) | 39,816 | **7,613,960** | CSE keys are a structural `Expression` with derived `BEq`/`Hashable` instead of `reprStr` strings (no pretty printer per instruction) |
| 9 | DISCARD | 954.2 (853.3–1015.0) | 39,816 | 7,613,960 | call `checkOperand` directly instead of per-instruction closures: allocs exactly unchanged, the compiler had already inlined them |
| 10 | DISCARD | 845.2 (767.8–884.7) | 39,816 | **7,222,731** | `@[inline] Statement.definition`: −5.1% allocations, but time within noise |
| 11 | DISCARD | 778.5 (750.5–791.8) | 37,790 | 7,769,760 | `CFG.build` rows as fresh arrays: judge KEEP on copies, allocations +2.05% (friction 3) |
| 12 | DISCARD | 842.2 (763.3–1000.9) | 39,816 | **7,238,375** | `Cleanup.copies`: a definition's class as a `Nat` code instead of a pair: −4.9% allocations, time within noise |
| **13** | **KEEP** `1db5ced` | 671.9 (599.1–714.3) | 39,816 | 7,561,097 | scalable `validateFunction`: let `CFG.build` (needed anyway) check labels, instead of quadratic `eraseDups`/`List.contains` |
| 14 | DISCARD | 702.8 (607.9–755.6) | 39,816 | 7,481,453 | phi predecessor lookup through the CFG index: −1% allocations, within noise |
| 15 | DISCARD | 745.2 (713.1–784.9) | **35,119** | 7,561,097 | `Memory.promote`: build each promoted name once: −4,697 copies, but every new run slower (friction 1) |
| 16 | DISCARD | 775.8 (568.4–908.8) | 39,816 | 7,558,721 | parser comparison names by `match` instead of `stem ++ suffix` per candidate (348k copies of constant strings): within noise |
| **17** | **KEEP** `2795a19` | 625.9 (550.9–687.7) | 39,708 | 7,429,823 | `Allocation.allocate`: HomeFlow no longer re-validates the function Liveness just validated |
| **18** | **KEEP** `a18d6a9` | 646.2 (587.7–699.0) | 39,602 | 7,169,312 | `Memory.promote`: drop the re-validation of the value `SSA.construct` already validated |
| **19** | **KEEP** `cc72059` | 723.6 (705.0–744.1) | 39,494 | 7,038,038 | AArch64/RV64 emission: `allocateValidated` skips re-validating the function the emitter validated |
| **20** | **KEEP** `fc4be73` | 763.9 (687.3–787.8) | 39,386 | 6,797,642 | CLI: `Optimize.moduleValidated` skips re-validating the module SSA construction just validated |
| **21** | **KEEP** `e9e4721` | 638.3 (573.7–662.6) | 39,278 | 6,666,368 | AArch64 `emitFunctions`: no per-function re-validation after `emitModule`'s `validateModule` |
| **22** | **KEEP** `2a3e84f` | 767.9 (740.5–157,810) | 39,170 | 6,492,839 | CLI: `emitModuleValidated` in all three back ends (one run stalled for 158 s; judge still KEEP on copies) |
| 23 | DISCARD | 669.7 (615.2–726.2) | 39,170 | 6,494,037 | group SSA-generated phis by block once: allocs +0.02% |
| 24 | DISCARD | 786.6 (724.5–1000.8) | 39,170 | 6,590,046 | identifier check by `String.all` on the indexed path: allocs +1.5% (friction 3) |
| **25** | **KEEP** `0606faa` | 656.6 (538.3–799.5) | 39,062 | 6,481,630 | `Liveness.analyze` reuses the CFG validation built |
| **26** | **KEEP** `a980983` | 550.0 (536.7–659.8) | 38,954 | 6,470,378 | HomeFlow reuses the liveness CFG |
| **27** | **KEEP** `f9ed557` | 503.5 (488.0–546.8) | 38,911 | 6,460,575 | `Memory.promote` passes its CFG to SSA construction (only instructions changed) |
| 28 | DISCARD | 494.5 (483.0–513.2) | 38,911 | 6,449,131 | CSE reuses validation's dominators: within noise on a quiet machine (< 1%) |
| 29 | DISCARD | 564.0 (517.1–693.3) | 38,911 | 6,460,575 | identifier check by scanning UTF-8 bytes in place: within noise |

(Experiment 10 ran twice: the first run's `sed` did not match, so it
measured unchanged code. It is not counted.)

### What the kept changes have in common

- **Copies found with `explain --why`** (5): the 46,633 copies in
  `Optimize.function` were not where `explain` guessed statically (an
  `Array.map` over blocks), but `--why` recorded the second reference at
  run time on line 73, `phi.incoming.map (value …)`: a temporary array
  built for each phi in each of eight rounds. Checking the values in place
  removed all of them.
- **Allocations from the pretty printer** (8): `reprStr` in a hash key.
  `sample` showed `Std.Format.pretty` at 5% of CPU.
- **Redundant work** (13, 17–22, 25–27): `sample` showed `validateFunction`
  at 29% of CPU, and reading its callers showed the same function value
  being validated again and again (by `Liveness.analyze`, `HomeFlow.check`,
  `Memory.promote`, `Optimize.module`, each back end's `emitModule` and
  `emitFunction`). Each repeated validation also rebuilt the CFG, so each
  removal cut `CFG.build`'s copies by exactly 108, which is what judge saw.
  The public functions still validate. Only internal paths whose input was
  provably just validated (same value, nothing in between) skip it, and
  error precedence is unchanged. After these changes `validateFunction` is
  12.5% of CPU.

## Totals

Base `854fcc2` against head `f9ed557`, measured with the fixed measure
command, six rounds of base then head (30 runs each):

| | base | head | change |
|---|---|---|---|
| time with probes (median of 30) | 648.0 ms (602.8–884.5) | 492.2 ms (480.9–605.2) | −24% (judge: KEEP in all 6 rounds) |
| time without probes (median of 15, alternating) | 626.1 ms | 458.4 ms | −27% |
| allocations | 7,719,273 (200.1 MiB) | 6,460,575 (167.7 MiB) | −16.3% |
| copies of shared values | 86,449 | 38,911 | −55% |
| `sample` CPU | 554 ms | 465 ms | −16% (one run each) |
| output | | | byte-identical on 340 combinations |

Times are from a machine at load average 25 to 40, so only the direction and
rough size are reliable. Allocations and copies are exact.

## Compared with the three hand-made fixes

| | hand-made (tokenizer, `CFG.build`, `Parser.peek`) | autoresearch loop |
|---|---|---|
| allocations | 11,946,202 → 7,719,273 (−35%) | 7,719,273 → 6,460,575 (−16%) |
| copies | 121,054 in `CFG.build` → 43,899 | 86,449 → 38,911 (all shared copies in `Optimize.function`, and 108 per removed `CFG.build`) |
| time | not measurable on the loaded machine | −24% (paired, 30 runs) |
| how found | `run --allocs` tables, `explain` | `sample` (inclusive CPU), `run --allocs`, `explain --why`, then reading callers |
| kind of change | rewriting hot loops | removing repeated work across passes, plus two local fixes |

The hand-made fixes went after the largest allocation sites, one at a time.
The loop found a different kind of waste, repeated validation that no
single site table shows: `validateFunction`'s own allocation site was only
11%, but it was called about ten times per function. Inclusive CPU time
from `sample` showed it.

## Friction in the loop (for v0.2.0)

1. **Judge compares runs taken at different times on a loaded machine.**
   With load averages of 20 to 54, five runs varied by ±15% and drifted
   between the base and the new measurement. The base summary in
   `program.md` is measured once, so it went stale within minutes (re-measured
   later, the same base commit took 604 to 1,005 ms). The agent had to keep a second worktree
   at the base commit and re-measure it right before each candidate. Even
   then, drift produced a false KEEP (6: copies and allocations exactly
   unchanged, "every new run faster") and a probably false DISCARD (15: 4,697
   fewer copies, "every new run slower"). `measure` should be able to run
   base and new **interleaved** (ABAB…) from two binaries, and judge should
   use a paired or rank test instead of max < min. CPU time (user+sys) or
   instruction counts would be less sensitive to load than wall time.
2. **Judge ignores allocations.** Three experiments cut allocations by 4 to
   5% (10, 12) or 1% (14) and were DISCARDed because time was within noise.
   Allocation counts are exact, like copies, and should be judged like them
   (on the `findings` branch).
3. **Allocation counts don't count everything that allocates.** Copies of
   constants (`Array.replicate n #[]`, `""`), runtime copies, and code in
   Lean's precompiled libraries (`String.toList`, `List.eraseDups`) are not
   counted. So replacing a constant copy with an explicit `emptyWithCapacity`
   (11) or a core `List` function with a specialized `HashSet` or
   `String.all` (3, 24) shows as more allocations even when the real work
   went down. Count constant copies as allocations, or report `--core`
   allocations in `measure`.
4. **`copies_total` excludes copies of constants**, while `explain` lists
   them (231,728 in `Parser.floatComparisonName`). Experiment 16 removed
   348k of them and judge couldn't see it.
5. **No way to run the project's slow TEST off the critical path.**
   `program.md` puts build and TEST before measure. With a 26 to 38 minute
   TEST (three platforms' native checks), that allows about five experiments
   in three hours. The agent measured first and ran the full TEST on kept
   heads in parallel worktrees. `program.md` should describe this (a quick
   TEST per experiment, the full TEST per KEEP or per batch, with bisection
   if it fails).
6. **TEST must match the baseline, not be all green.** Three steps fail on
   this machine at baseline. A runner that records per-step pass/fail at
   baseline and compares later runs with it had to be written ad hoc.
7. **`--heartbeats-files` must be chosen before the files to edit are
   known.** The session left it out (compile cost was not judged). Measuring
   compile heartbeats of the files changed by the diff, automatically, would
   fix that.
8. **`results.tsv` has no column for allocations, base re-measures or
   overrides**, and `program.md` asks for it inside the project's tree (with
   an exclude entry in the shared `.git/info/exclude` of a repository that
   has 40 other worktrees). The log lived outside the repository instead.
9. **Kernel-reduced proofs constrain changes in ways the loop can't see
   ahead.** Experiments 1 and 3 broke `decide +kernel` proofs that evaluate
   `validateFunction`. The pattern that worked was to keep the reference
   path list-based and optimize only the `scalable` path. A note in
   `program.md` would save a crash per project.
10. **`explain`'s static guess pointed at the wrong map** (4), and only
    `--why` found the real line. `explain` could suggest `--why` whenever its
    confidence is low.
11. **The 160-combination identity check of the hand-made study was not
    reproducible from the docs**: neither the script nor the exact
    combinations are recorded. This session used a superset (340); its
    script should live in `research/` or the case study.

## Reproducing

The scripts used (measure, identity check, per-step TEST runner, experiment
runner) were kept outside both repositories during the session; the fixed
commands are in the Setup table above. The branch's commits each say which
experiment they came from and how many allocations they removed.
