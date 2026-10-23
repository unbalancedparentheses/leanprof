import Leanprof import Leanprof.Explain import Tests.Elab import Tests.ExplainFixes

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

/-- A pure scope around a loop whose result is taken apart (a structure
projection is a branch the compiler could move `enterPure` into). -/
def scopedHistory (n : Nat) : Array Nat × Array (Array Nat) := profile! "test.history" (withHistory n)

/-- Scalar results pass through `profile!` unboxed. -/
def scopedU64 (n : UInt64) : UInt64 := profile! "test.u64" (n * 3 + 1)
def scopedFloat (x : Float) : Float := profile! "test.float" (x * 2.0)
def scopedBool (n : Nat) : Bool := profile! "test.bool" (n % 2 == 0)

def plain : Nat → Nat := fun n =>
  set_option leanprof.enabled false in profile! "test.disabled" (n + 1)

/-- Counted delta of `copies` around `x`. -/
def copiesIn (x : Unit → α) : IO (α × Nat) := do
  let before ← copies
  -- evaluated here, between the two readings: a `let` of a pure value may be
  -- moved to its first use by the compiler (Lean 4.34 does)
  let r ← IO.lazyPure x
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
  -- a specialization made inside another one (lambdaclass/concrete): the user code is the last caller
  ("lp_concrete_List_filterMapTR_go___at___00List_filterMapTR_go___at___00Concrete_elabModule_spec__107_spec__119",
   "Concrete.elabModule (in List.filterMapTR.go)"),
  ("l___private_Lean_Elab_PreDefinition_WF_Unfold_0____regBuiltin___private_Lean_Elab_PreDefinition_WF_Unfold_0__Lean_Elab_WF_matcherPushArg_declare__19_00___x40_Lean_Elab_PreDefinition_WF_Unfold_300889135____hygCtx___hyg_10_",
   "_regBuiltin.Lean.Elab.WF.matcherPushArg.declare_19"),
  -- packages this project does not know: escapes in the package name
  ("lp_lean_x2dcompiler_x2dbackend_LeanCompilerBackend_Memory_blit.cold.2", "LeanCompilerBackend.Memory.blit"),
  ("lp_odd_x2dnames__v2_Odd_callAll", "Odd.callAll"),
  ("lp_caf_u00e9_Foo_bar", "Foo.bar")
]

/-- One pair (and its string) referenced `n` times from an array. -/
def sharedPair (n : Nat) : Array (String × Nat) := Array.replicate n (toString n, n)

/-- `n`, but unknown to the compiler, so calls using it are not hoisted into
constants computed at startup. -/
def opaqueNat (n : Nat) : IO Nat := do
  return n + (← IO.monoMsNow) * 0

unsafe def depthInTaskImpl (v : Nat) : Nat := unsafeBaseIO depth + v * 0

/-- Scopes open on the thread that evaluates it: a task run by leanprof's
wrapper has one (its `task <- scope`), an unwrapped one has none. -/
@[implemented_by depthInTaskImpl] opaque depthInTask (v : Nat) : Nat

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
  let v ← IO.lazyPure fun _ => fib n20
  let after ← calls "test.fib"
  check "pure scope counts every call" (v == 6765 && after - before == 10945) s!"calls={after - before}"
  let ov ← overheadNs
  check "calibrated overhead is plausible" (ov > 0.5 && ov < 1000) s!"overhead={ov}"
  let tot ← totalNs "test.fib"
  -- fib's calls take a few ns each, about what their probes cost, so what is
  -- left after subtracting them can be 0 on a busy machine (the report flags
  -- such rows); never negative. A scope with real work is checked below.
  check "scope total of tiny calls is never negative" (tot ≥ 0) s!"total={tot}"
  -- under a sanitizer (CI) only leanprof's runtime is slowed down, and the
  -- calibration then removes more than the probes cost in the program
  let sanitized := (← IO.getEnv "LEANPROF_SANITIZE").any (· != "")
  let t0 ← IO.monoNanosNow
  let (ha, hh) ← IO.lazyPure fun _ => scopedHistory (n500 * 4)
  let wall := (← IO.monoNanosNow) - t0
  let inside ← totalNs "test.history"
  check "pure scope times the work inside it, not before it"
    (ha.size == 2000 && hh.size == 2000 && (inside > 0.5 * wall.toFloat || sanitized) && (← calls "test.history") == 1)
    s!"inside={inside} wall={wall}"
  let u ← IO.lazyPure fun _ => scopedU64 n20.toUInt64
  let fl ← IO.lazyPure fun _ => scopedFloat n20.toFloat
  let bo ← IO.lazyPure fun _ => scopedBool n20
  check "pure scopes pass scalars through"
    (u == 61 && fl == 40.0 && bo && (← calls "test.u64") == 1 && (← calls "test.float") == 1 &&
      (← calls "test.bool") == 1)
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
  -- ===== frees and memory (built with freeFlags; docs/guide/memory.md) =====
  -- `frees` counts objects freed by cascades; the monadic code between two
  -- queries frees a few objects of its own (strings of earlier checks)
  let f0 ← frees
  let len ← IO.lazyPure fun _ => (mkPairs n500).length
  let freed := (← frees) - f0
  check "frees count every object of a cascade (500 cells, 500 pairs)"
    (freed ≥ 1000 && freed ≤ 1004 && len == 500) s!"freed={freed}"
  let f0 ← frees
  let size ← IO.lazyPure fun _ => (sharedPair n100).size
  let freed := (← frees) - f0
  -- the array, then the pair once its 100 references are gone, then its string
  check "a shared child is freed once, with its last reference"
    (freed ≥ 3 && freed ≤ 7 && size == 100) s!"freed={freed}"
  let p0 ← peakMemory
  check "peak memory is sampled" (p0 > 0) s!"peak={p0}"
  let big ← IO.lazyPure fun _ => Array.replicate (n500 * 5000) (0 : Nat)
  let p1 ← peakMemory
  check "peak memory includes a large array" (p1 ≥ p0 && p1 ≥ big.size * 8) s!"peak={p1} size={big.size}"
  -- ===== end of frees and memory =====
  -- >>> task continuations (Task.map/bind, IO.mapTask/bindTask); `run --core` is tested in CI
  let v ← opaqueNat 7
  let src := Task.spawn fun _ => v
  check "Task.map runs inside a task scope" ((src.map depthInTask).get ≥ 1)
  check "Task.bind runs inside a task scope" ((src.bind fun x => .pure (depthInTask x)).get ≥ 1)
  let t ← IO.mapTask (fun _ => depth) src
  check "IO.mapTask runs inside a task scope" (match t.get with | .ok d => d ≥ 1 | .error _ => false)
  let t ← IO.bindTask src fun _ => do return .pure (.ok (← depth))
  check "IO.bindTask runs inside a task scope" (match t.get with | .ok d => d ≥ 1 | .error _ => false)
  let t ← IO.mapTask (fun x => pure (x + 1)) src
  check "IO.mapTask passes the value through" (match t.get with | .ok r => r == 8 | .error _ => false)
  -- <<< task continuations
  -- BEGIN leanprof explain: why copies happen, from the emitted C (Leanprof/Explain.lean)
  check "explain: C variable names" (Explain.sourceName "v_as_x27_256_" == some "as'" &&
    Explain.sourceName "v___x_12_" == none && Explain.sourceName "v_namePrefix_90_" == some "namePrefix")
  check "explain: modify rewrite"
    (Explain.modifyRewrite "  xs := xs.set! i (xs[i]!.push t)" == some "xs := xs.modify i (·.push t)")
  -- this file's own C: `withHistory` stores `acc` in `history`, then pushes to it
  let cache ← IO.mkRef ({} : Explain.CCache)
  let cfile : System.FilePath := ".lake/build/ir/Tests/Main.c"
  let clines ← Explain.readLines cache cfile
  let funs := ((List.range clines.size).filter fun i =>
    let l := clines[i]!
    l.endsWith "{" && Explain.has l "withHistory" && Explain.has l "_spec_" && !Explain.has l "_boxed(").toArray.map
      (Explain.parseFun cfile clines ·)
  let src := ((← IO.FS.readFile "Tests/Main.lean").splitOn "\n").toArray
  let decl := Explain.declLines src 12
  let found := funs.flatMap fun f => (Explain.analyzeFun f "Array").filterMap fun fd =>
    if fd.holder matches .storedBy _ && fd.strength == 3 then some (Explain.explainFinding f fd "Array" 8 decl) else none
  check "explain: the IR shows acc stored before the push" (!found.isEmpty) s!"{funs.size} functions"
  let lines := found.flatMap (·.lines)
  check "explain: source lines of the store and the push" (lines.contains 17 && lines.contains 18) s!"{lines}"
  -- END leanprof explain
  -- leanprof explain: the fixes it prints remove the copies (Tests/ExplainFixes.lean)
  Tests.ExplainFixes.run fun n ok d => check n ok d
  -- leanprof elab: reading traces (Tests/Elab.lean)
  Tests.Elab.run fun n ok d => check n ok d

def main : IO UInt32 := do
  let ((), failures) ← tests.run 0
  if failures == 0 then
    IO.println "all tests passed"
    return 0
  IO.println s!"{failures} failed"
  return 1
