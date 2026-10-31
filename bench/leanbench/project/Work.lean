/-!
The workload both tools measure. `LB_VARIANT` (read once, at run time)
selects a seeded change; every variant prints the same result, so
`leanprof judge` compares like with like.

* `base`: 100 passes of real work over an array plus 25 passes of a
  validation (125 units).
* `slowP` (`slow2`, `slow5`, `slow10`, `slow30`): `P`% more units of the
  same kind of work, whose result is checked but does not change the output.
* `pct1`, `pct2`, `pct5`: 1%, 2% and 5% more of the same work (whole
  passes, and one pass over a copy of a prefix of the array made in
  `setup`), for `bench/verdicts/`.
* `fast`: skips the redundant validation (125 -> 100 units, a 20% speedup).
* `copy`: one hidden copy of a 64-element state array per round (125 per
  action), negligible time.
* `alloc`: an 8-element list allocated and folded per round (1,000 small
  allocations per action), little time.
-/
namespace Work

structure Cfg where
  units : Nat := 100       -- passes of real work
  check : Nat := 25        -- passes of validation (same result either way)
  extra : Nat := 0         -- seeded extra passes
  extraPm : Nat := 0       -- seeded extra work, per mille of units + check
  part : Array UInt64 := #[] -- with extraPm: the prefix for the part of a pass
  copy : Bool := false
  alloc : Bool := false
  deriving Inhabited

def cfgOf : String → Cfg
  | "slow2"  => { extra := 3 }     -- 2.4% of 125
  | "slow5"  => { extra := 6 }     -- 4.8%
  | "slow10" => { extra := 13 }    -- 10.4%
  | "slow30" => { extra := 38 }    -- 30.4%
  | "pct1"   => { extraPm := 10 }
  | "pct2"   => { extraPm := 20 }
  | "pct5"   => { extraPm := 50 }
  | "fast"   => { check := 0 }     -- -20%
  | "copy"   => { copy := true }
  | "alloc"  => { alloc := true }
  | _        => {}

/-- One pass of real work: mix every element into the accumulator. -/
@[noinline] def pass (a : Array UInt64) (seed : UInt64) : UInt64 := Id.run do
  let mut h := seed
  for x in a do
    h := (h ^^^ x) * 1099511628211
    h := h ^^^ (h >>> 29)
  return h

@[noinline] def state0 (n : Nat) : Array UInt64 := (Array.range n).map (·.toUInt64)

/-- One action: `units + check + extra` rounds; each round does one pass and
updates a small state array in place (or, for `copy`, while an old version is
still alive, so it is copied). -/
@[noinline] def run (cfg : Cfg) (a : Array UInt64) : UInt64 := Id.run do
  let mut st := state0 64
  let mut acc : UInt64 := 0
  let mut junk : UInt64 := 0
  for r in [0:cfg.units] do
    acc := pass a (acc + r.toUInt64)
    if cfg.copy then
      let old := st
      st := st.set! (r % 64) acc
      junk := junk + old[0]!
    else
      st := st.set! (r % 64) acc
    if cfg.alloc then
      let xs := List.replicate 8 acc
      junk := junk + xs.foldl (· + ·) 0
  -- validation: recomputes a pass and compares (always equal)
  for _ in [0:cfg.check] do
    if pass a 7 == 0 then junk := junk + 1
  for _ in [0:cfg.extra] do
    if pass a 11 == 0 then junk := junk + 1
  if cfg.extraPm > 0 && a.size > 0 then
    let steps := cfg.extraPm * (cfg.units + cfg.check) * a.size / 1000
    for _ in [0:steps / a.size] do
      if pass a 13 == 0 then junk := junk + 1
    if pass cfg.part 17 == 0 then junk := junk + 1
  -- `junk` keeps the seeded work alive without changing the result
  return acc + st[3]! + (if junk == 0xdeadbeef then 1 else 0)

initialize cfgRef : IO.Ref Cfg ← IO.mkRef {}
initialize arrRef : IO.Ref (Array UInt64) ← IO.mkRef #[]
initialize sink : IO.Ref UInt64 ← IO.mkRef 0

/-- Read `LB_VARIANT` and `LB_N` (array size, default 40000). -/
def setup : IO Unit := do
  let v := (← IO.getEnv "LB_VARIANT").getD "base"
  let n := ((← IO.getEnv "LB_N").bind String.toNat?).getD 40000
  let a := (Array.range n).map fun i => (i * 2654435761 % 1000003).toUInt64
  let cfg := cfgOf v
  let k := cfg.extraPm * (cfg.units + cfg.check) * n / 1000 % Nat.max n 1
  -- (no array at all for the other variants: their allocation counts are published)
  cfgRef.set (if cfg.extraPm > 0 then { cfg with part := a.extract 0 k } else cfg)
  arrRef.set a

/-- The benchmarked action. -/
def action : IO Unit := do
  let cfg ← cfgRef.get
  let a ← arrRef.get
  sink.modify (· + run cfg a)

end Work
