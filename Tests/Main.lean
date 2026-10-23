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

/-- Allocates in this module's compiled code: a pair and a list cell per step. -/
def mkPairs : Nat → List (Nat × Nat)
  | 0 => []
  | n + 1 => (n, n) :: mkPairs n

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
  ("lean_array_push", "lean_array_push"),
  -- found by `demangle-check` (Tests/DemangleCheck.lean) against Lean's demangler:
  -- a name whose first component needs the `00` disambiguation
  ("l_00_u03b5_u03bb", "«ελ»"),
  ("l_Odd_001st", "Odd.«1st»"),
  -- names are shown like `Name.toString`, which is how .ilean files key them
  ("l_Odd_weird_x20name___boxed", "Odd.«weird name»"),
  ("l_Odd_a_x2eb", "Odd.«a.b»"),
  ("l_Odd_emoji_U0001f389", "Odd.«emoji🎉»"),
  ("l_Odd_x_u2081", "Odd.x₁"),
  ("l_Odd_get_x21", "Odd.get!"),
  ("l_Array___aux__Init__Data__Array__Perm______macroRules__Array__term___x7e____1",
   "Array.«_aux_Init_Data_Array_Perm___macroRules_Array_term_~__1»"),
  -- user components starting with `_` are not compiler suffixes
  ("l_Odd___under", "Odd._under"),
  ("l_Odd_00____", "Odd.__"),
  ("l_Odd_00_____00__boxed", "Odd.__"),
  ("l_Odd_00__x41", "Odd._x41"),
  ("l_Odd_foo___00bar", "Odd.foo_.bar"),
  ("l_a___00__b", "a_._b"),
  -- numeric components
  ("l_foo___1_", "foo_.1"),
  ("l_foo_1__bar", "foo.1.bar"),
  -- compiler parts inside the name, and the C compiler's outlined parts
  ("l_Foo_bar___closed__3_value_aux_0", "Foo.bar"),
  ("l_Foo_bar.cold.1", "Foo.bar"),
  -- macro scopes: dropped, also inside a name and before a specialization
  ("l_Odd_helper_00___x40_OddNames_Basic_28371510____hygCtx___hyg_3_", "Odd.helper"),
  ("l_Lean_Widget_RpcEncodablePacket_00___x40_Lean_Server_FileWorker_WidgetRequests_2377472685____hygCtx___hyg_1__ctorElim___redArg",
   "Lean.Widget.RpcEncodablePacket.ctorElim"),
  ("l_Lean_Widget_instRpcEncodableDiagnosticWith_enc_00___x40_Lean_Widget_InteractiveDiagnostic_2989700264____hygCtx___hyg_2____at___00Lean_Server_FileWorker_handlePreRequestSpecialCases_x3f_spec__4",
   "Lean.Server.FileWorker.handlePreRequestSpecialCases? (in Lean.Widget.instRpcEncodableDiagnosticWith.enc)"),
  -- private callers, and private names inside a name
  ("lp_leanprof___private_Init_Data_Range_Basic_0__Std_Legacy_Range_forIn_x27_loop___at___00__private_OddNames_Basic_0__Odd_secretSum_spec__0___redArg",
   "Odd.secretSum (in Std.Legacy.Range.forIn'.loop)"),
  ("l___private_Lean_Elab_PreDefinition_WF_Unfold_0____regBuiltin___private_Lean_Elab_PreDefinition_WF_Unfold_0__Lean_Elab_WF_matcherPushArg_declare__19_00___x40_Lean_Elab_PreDefinition_WF_Unfold_300889135____hygCtx___hyg_10_",
   "_regBuiltin.Lean.Elab.WF.matcherPushArg.declare_19"),
  -- packages this project does not know: escapes in the package name
  ("lp_lean_x2dcompiler_x2dbackend_LeanCompilerBackend_Memory_blit.cold.2", "LeanCompilerBackend.Memory.blit"),
  ("lp_odd_x2dnames__v2_Odd_callAll", "Odd.callAll"),
  ("lp_caf_u00e9_Foo_bar", "Foo.bar")
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
  -- allocations (the test executable is built with allocFlags)
  let a0 ← allocs
  let xs ← IO.lazyPure fun _ => mkPairs n500
  let made := (← allocs) - a0
  check "allocations are counted" (made ≥ 1000 && xs.length == 500) s!"allocs={made}"
  let r ← (expectAllocsAtMost 10 (IO.lazyPure fun _ => (mkPairs n500).length)).toBaseIO
  check "expectAllocsAtMost rejects allocating code" (r matches .error _)
  let r ← (expectAllocsAtMost 1000000 (pure 1)).toBaseIO
  check "expectAllocsAtMost passes" (r matches .ok _)
  -- positions
  check "copy sites resolve to their declaration" ((← whereIs "withHistory") == "Tests/Main.lean:13")
  check "specializations resolve to the caller"
    ((← whereIs "withHistory (in Std.Legacy.Range.forIn'.loop)") == "Tests/Main.lean:13")
  check "unknown names have no position" ((← whereIs "No.Such.decl") == "")
  -- names
  for (sym, want) in demangleCases do
    let got := demangle sym
    check s!"demangle {sym}" (got == want) s!"got {got}"
  -- ===== counters: constructor reuse and closure applications (counterFlags) =====
  -- `step` rebuilds the pair from `p`; reuse succeeds when `p` is exclusive.
  let rec step : Nat → Nat × Nat → Nat × Nat
    | 0, p => p
    | n + 1, p => step n (p.1 + 1, p.2)
  -- `keep` stores every pair in the list too, so the next rebuild finds it shared.
  let rec keep : Nat → Nat × Nat → List (Nat × Nat)
    | 0, _ => []
    | n + 1, p => let q := (p.1 + 1, p.2); q :: keep n q
  let rec applyN (f : Nat → Nat) : Nat → Nat → Nat
    | 0, x => x
    | n + 1, x => applyN f n (f x)
  let start := (n20, n50)
  let c0 ← reuseChecks
  let f0 ← reuseFailures
  let p ← IO.lazyPure fun _ => step n500 (n20, n50)
  let checked := (← reuseChecks) - c0
  let failed := (← reuseFailures) - f0
  -- the first step may fail: the starting pair is captured by the thunk, which is still alive
  check "exclusive constructor is reused in place"
    (p.1 == 520 && checked ≥ 499 && failed ≤ 1) s!"checks={checked} failed={failed}"
  let f0 ← reuseFailures
  let ps ← IO.lazyPure fun _ => keep n500 start
  let failed := (← reuseFailures) - f0
  check "shared constructor fails reuse once per step" (ps.length == 500 && failed ≥ 499) s!"failed={failed}"
  let r ← (expectNoReuseFailures (IO.lazyPure fun _ => (keep n50 start).length)).toBaseIO
  check "expectNoReuseFailures rejects shared code" (r matches .error _)
  let r ← (expectNoReuseFailures (IO.lazyPure fun _ => (step n50 (n20, n50)).1)).toBaseIO
  check "expectNoReuseFailures passes exclusive code" (r matches .ok _)
  let a0 ← closureApplications
  let v ← IO.lazyPure fun _ => applyN (· + n20) n500 0
  let applied := (← closureApplications) - a0
  check "closure applications are counted" (v == 10000 && applied ≥ 500) s!"applications={applied}"
  let r ← (expectClosureApplicationsAtMost 10 (IO.lazyPure fun _ => applyN (· * 1) n50 1)).toBaseIO
  check "expectClosureApplicationsAtMost rejects unspecialized code" (r matches .error _)
  -- ===== end counters =====

def main : IO UInt32 := do
  let ((), failures) ← tests.run 0
  if failures == 0 then
    IO.println "all tests passed"
    return 0
  IO.println s!"{failures} failed"
  return 1
