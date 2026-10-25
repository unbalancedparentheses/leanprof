### leanprof: regress fixture: ❌ regression

| metric | base | head | change | check |
|---|---:|---:|---:|---|
| copies | 0 | 299 | +299 | ❌ fail |
| allocations | 5 | 305 | +300 (+6000.00%) | ⚠️ worse (not enforced) |
| calls | 0 | 0 | 0 | ✅ pass |
| compile heartbeats | 667.45 kHB | 790.92 kHB | +123.47 kHB (+18.50%) | ❌ fail |
| time (wall, noisy) | 11.32 ms | 15.27 ms | +3.95 ms (+34.89%) | noisy, not checked |

Exact metrics (copies, allocations, calls, heartbeats) do not vary between runs; time does, so it is shown but never checked. Enforced: copies, heartbeats.

<details><summary>why <code>Regress.lean simp_case</code> got more expensive: +56.97 kHB; most changed: simp lemma rewrote with <code>step_eq</code> +41×</summary>

`Regress.lean:15`: 562.89 kHB → 619.86 kHB (elaboration +49.03 kHB, kernel +7.94 kHB)

| what changed | | defined at | base | head | change |
|---|---|---|---:|---:|---:|
| simp lemma rewrote with | `step_eq` | `Regress.lean:9` | 0× | 41× | +41× |
| simp lemma used (count) | `Nat.reduceAdd (builtin simproc)` |  | 39 | 80 | +41 |
| simp lemma used (count) | `step_eq` | `Regress.lean:9` | 0 | 41 | +41 |
| kernel unfolded (count) | `OfNat.ofNat` | `Init/Prelude.lean:1393` | 80 | 84 | +4 |
| kernel unfolded (count) | `Add.add` | `Init/Prelude.lean:1638` | 197 | 199 | +2 |
| kernel unfolded (count) | `HAdd.hAdd` | `Init/Prelude.lean:1481` | 197 | 199 | +2 |

… and 1 more changed (`leanprof compare` lists them)

- no constant is credited with more heartbeats (only how often each was used changed): the 56,966 heartbeats are in work not credited to a named constant (operations under 10,000 heartbeats are not timed: `--threshold` lowers it)

</details>

<details><summary>why <code>Regress.lean unfold_case</code> got more expensive: +50.53 kHB; most changed: whnf reduces <code>tri</code> +46.16 kHB</summary>

`Regress.lean:21`: 6.95 kHB → 57.47 kHB (elaboration +50.53 kHB)

| what changed | | defined at | base | head | change |
|---|---|---|---:|---:|---:|
| whnf reduces | `Decidable.decide` | `Init/Prelude.lean:1158` | 0.00 kHB, 0× | 46.40 kHB, 1× | +46.40 kHB |
| whnf reduces | `tri` | `Regress.lean:11` | 0.00 kHB, 0× | 46.16 kHB, 162× | +46.16 kHB |
| unfolded (count) | `Add.add` | `Init/Prelude.lean:1638` | 1 | 144 | +143 |
| unfolded (count) | `HAdd.hAdd` | `Init/Prelude.lean:1481` | 1 | 144 | +143 |
| unfolded (count) | `tri` | `Regress.lean:11` | 1 | 72 | +71 |
| kernel unfolded (count) | `OfNat.ofNat` | `Init/Prelude.lean:1393` | 4 | 0 | −4 |
| kernel unfolded (count) | `instOfNatNat` | `Init/Prelude.lean:1395` | 4 | 0 | −4 |

… and 15 more changed (`leanprof compare` lists them)

- heartbeats credited to different constants overlap (reducing one can unfold another), so they need not add up to the change

</details>

<details><summary>why <code>Regress.lean tri</code> got more expensive: +15.52 kHB; most changed: isDefEq unfolds <code>outParam</code> −4×</summary>

`Regress.lean:11`: 50.50 kHB → 66.03 kHB (elaboration +13.53 kHB, compiler +1.99 kHB)

| what changed | | defined at | base | head | change |
|---|---|---|---:|---:|---:|
| isDefEq unfolds | `outParam` | `Init/Prelude.lean:733` | 9× | 5× | −4× |
| unfolded (count) | `outParam` | `Init/Prelude.lean:733` | 27 | 15 | −12 |
| unfolded (count) | `Nat.below` | `Init/Prelude.lean:1349` | 0 | 11 | +11 |
| unfolded (count) | `Nat.rec` | `Init/Prelude.lean:1349` | 0 | 6 | +6 |
| unfolded (count) | `Unit` | `Init/Prelude.lean:214` | 0 | 4 | +4 |
| unfolded (count) | `OfNat.ofNat` | `Init/Prelude.lean:1393` | 0 | 3 | +3 |

… and 12 more changed (`leanprof compare` lists them)

- no constant is credited with more heartbeats (only how often each was used changed): the 15,521 heartbeats are in work not credited to a named constant (operations under 10,000 heartbeats are not timed: `--threshold` lowers it)

</details>

<details><summary>why: 1 copy site copies more (causes from leanprof explain on the head)</summary>

- `collect (in Std.Legacy.Range.forIn'.loop) [Array] in -`: +299 copies. field-of-kept-structure: `fst` is a field of a structure \(`b`\) that is rebuilt with the same field, so the structure and the Array.push both refer to the Array: the update copies it.

</details>

<details><summary>why: 1 allocation site allocates more</summary>

- `collect (in Std.Legacy.Range.forIn'.loop) in -`: +300 (+30000.00%) allocations. Cause not attributed: explain explains copies, not allocations. The same function copies more too (`collect (in Std.Legacy.Range.forIn'.loop) [Array] in -` +299).

</details>

<details open><summary>copies: 1 changed, 1 regressed (a regression is any increase at a call site)</summary>

| where | base | head | change |
|---|---:|---:|---:|
| `collect (in Std.Legacy.Range.forIn'.loop) [Array] in -` | 0 | 299 | +299 ❌ |

</details>

<details open><summary>allocations: 1 changed, 1 regressed (a regression is a larger total)</summary>

| where | base | head | change |
|---|---:|---:|---:|
| `collect (in Std.Legacy.Range.forIn'.loop) in -` | 1 | 301 | +300 (+30000.00%) ⚠️ |

</details>

<details open><summary>compile heartbeats: 3 changed, 3 regressed (a regression is a declaration up by more than 1% and 1,000 heartbeats; smaller changes not listed)</summary>

| declaration | base | head | change |
|---|---:|---:|---:|
| `Regress.lean simp_case` | 562.89 kHB | 619.86 kHB | +56.97 kHB (+10.12%) ❌ |
| `Regress.lean unfold_case` | 6.95 kHB | 57.47 kHB | +50.53 kHB (+727.41%) ❌ |
| `Regress.lean tri` | 50.50 kHB | 66.03 kHB | +15.52 kHB (+30.73%) ❌ |

</details>
