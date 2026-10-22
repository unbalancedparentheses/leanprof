import Leanprof

/-! Tests run in-process: the test executable is built with `copyFlags`. -/

open Leanprof

def check (name : String) (ok : Bool) (detail : String := "") : StateT Nat IO Unit := do
  if ok then IO.println s!"ok   {name}"
  else
    IO.println s!"FAIL {name} {detail}"
    modify (· + 1)

def withHistory (n : Nat) : Array Nat × Array (Array Nat) := Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut history : Array (Array Nat) := #[]
  for i in [0:n] do
    history := history.push acc
    acc := acc.push i
  return (acc, history)

def linear (n : Nat) : Array Nat := Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  for i in [0:n] do
    acc := acc.push i
  return acc

def strings (n : Nat) : String × Array String := Id.run do
  let mut s := ""
  let mut seen : Array String := #[]
  for _ in [0:n] do
    seen := seen.push s
    s := s.push 'a'
  return (s, seen)

def fib : Nat → Nat
  | 0 => 0
  | 1 => 1
  | n + 2 => profile! "test.fib" (fib n + fib (n + 1))

def plain : Nat → Nat := fun n =>
  set_option leanprof.enabled false in profile! "test.disabled" (n + 1)

/-- Counted delta of `copies` around `x`. -/
def copiesIn (x : Unit → α) : IO (α × Nat) := do
  let before ← copies
  let r := x ()
  let after ← copies
  return (r, after - before)

def demangleCases : List (String × String) := [
  ("l_Foo_bar", "Foo.bar"),
  ("l_a__b", "a_b"),
  ("l_Foo_x27_bar", "Foo'.bar"),
  ("lp_leanprof_Foo_bar___lam__0", "Foo.bar"),
  ("lp_my__pkg_Foo_bar___boxed", "Foo.bar"),
  ("l___private_Foo_Basic_0__Foo_secret", "Foo.secret"),
  ("lp_leanprof___private_Init_Data_Range_Basic_0__Std_Legacy_Range_forIn_x27_loop___at___00buildWithHistory_spec__0___redArg",
   "buildWithHistory (in Std.Legacy.Range.forIn'.loop)"),
  ("lean_main", "main"),
  ("lean_array_push", "lean_array_push")
]

/-- `n`, but unknown to the compiler, so calls using it are not hoisted into
constants computed at startup. -/
def opaqueNat (n : Nat) : IO Nat := do
  return n + (← IO.monoMsNow) * 0

def tests : StateT Nat IO Unit := do
  let n500 ← opaqueNat 500
  let n300 ← opaqueNat 300
  let n100 ← opaqueNat 100
  let n50 ← opaqueNat 50
  let n20 ← opaqueNat 20
  -- copies
  let ((a, h), n) ← copiesIn fun _ => withHistory n500
  check "shared array push copies once per iteration" (n ≥ 499 && a.size == 500 && h.size == 500) s!"copies={n}"
  let (b, n) ← copiesIn fun _ => linear n500
  check "linear array push does not copy" (n == 0 && b.size == 500) s!"copies={n}"
  let ((s, seen), n) ← copiesIn fun _ => strings n300
  check "shared string push copies" (n ≥ 299 && s.length == 300 && seen.size == 300) s!"copies={n}"
  let r ← (expectNoCopies (pure (linear n100)) |>.toBaseIO)
  check "expectNoCopies passes linear code" (r matches .ok _)
  let r ← (expectNoCopies (IO.lazyPure fun _ => (withHistory n50).1.size) |>.toBaseIO)
  check "expectNoCopies rejects shared code" (r matches .error _)
  -- scopes
  let before ← calls "test.fib"
  let v := fib n20
  let after ← calls "test.fib"
  check "pure scope counts every call" (v == 6765 && after - before == 10945) s!"calls={after - before}"
  let ov ← overheadNs
  check "calibrated overhead is plausible" (ov > 0.5 && ov < 1000) s!"overhead={ov}"
  let tot ← totalNs "test.fib"
  check "scope total is reported" (tot > 0) s!"total={tot}"
  let _ := plain 3
  check "disabled profile! records nothing" ((← calls "test.disabled") == 0)
  let d ← depth
  let r ← (profile! "test.throws" (throw (IO.userError "boom") : IO Unit)).toBaseIO
  check "monadic scope closes on exceptions"
    ((r matches .error _) && (← depth) == d && (← calls "test.throws") == 1)
  let x ← profile! "test.io" (pure 41 : IO Nat)
  check "monadic scope returns the value" (x == 41 && (← calls "test.io") == 1)
  -- positions
  check "copy sites resolve to their declaration" ((← whereIs "withHistory") == "Tests/Main.lean:13")
  check "specializations resolve to the caller"
    ((← whereIs "withHistory (in Std.Legacy.Range.forIn'.loop)") == "Tests/Main.lean:13")
  check "unknown names have no position" ((← whereIs "No.Such.decl") == "")
  -- names
  for (sym, want) in demangleCases do
    let got := demangle sym
    check s!"demangle {sym}" (got == want) s!"got {got}"

def main : IO UInt32 := do
  let ((), failures) ← tests.run 0
  if failures == 0 then
    IO.println "all tests passed"
    return 0
  IO.println s!"{failures} failed"
  return 1
