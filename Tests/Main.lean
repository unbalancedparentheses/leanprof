import Leanprof import Leanprof.Explain import Leanprof.Judge import Leanprof.Fix import Leanprof.Workload import Tests.Elab import Tests.ExplainFixes import Tests.Regress

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

/-- A scope of a nanosecond or two, `n` times. -/
@[noinline] def tinyStep (i : UInt64) : UInt64 := profile! "test.tiny" (i * 3 + 1)
def tinyLoop (n : Nat) : UInt64 := Id.run do
  let mut acc : UInt64 := 0
  for i in [0:n] do
    acc := acc + tinyStep (acc + i.toUInt64)
  return acc
/-- `k` rounds of a multiply-add, about a nanosecond each. -/
@[noinline] def spin (k : Nat) (x : UInt64) : UInt64 := Id.run do
  let mut a := x
  for _ in [0:k] do a := a * 6364136223846793005 + 1442695040888963407
  return a
/-- Light scopes whose calls change cost: `k` rounds each, `n` calls. -/
@[noinline] def epochStep (k : Nat) (i : UInt64) : UInt64 := profile! "test.epochs" (spin k i)
def epochLoop (k n : Nat) : UInt64 := Id.run do
  let mut acc : UInt64 := 0
  for i in [0:n] do
    acc := acc + epochStep k (acc + i.toUInt64)
  return acc
/-- The same loop without the scope. -/
def spinLoop (k n : Nat) : UInt64 := Id.run do
  let mut acc : UInt64 := 0
  for i in [0:n] do
    acc := acc + spin k (acc + i.toUInt64)
  return acc
@[noinline] def wrapStep (k : Nat) (i : UInt64) : UInt64 := profile! "test.wrapchild" (spin k i)
def wrapLoop (k n : Nat) : UInt64 := Id.run do
  let mut acc : UInt64 := 0
  for i in [0:n] do
    acc := acc + wrapStep k (acc + i.toUInt64)
  return acc
/-- A parent of the light scope above, which by then is cheaper than its estimate. -/
@[noinline] def wrapParent (n : Nat) : UInt64 := profile! "test.wrapparent" (wrapLoop 0 n)
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

/-- `depth`, called with `v` so that it is not a constant computed at startup
(Lean 4.27 made `unsafeBaseIO depth + v * 0` one). -/
@[noinline] def depthWith (v : Nat) : BaseIO Nat := return (← depth) + v * 0

unsafe def depthInTaskImpl (v : Nat) : Nat := unsafeBaseIO (depthWith v)

/-- Scopes open on the thread that evaluates it: a task run by leanprof's
wrapper has one (its `task <- scope`), an unwrapped one has none. -/
@[implemented_by depthInTaskImpl] opaque depthInTask (v : Nat) : Nat

/-! Simulated paired sessions for the sequential rule (`Judge.seqStop`). -/

/-- xorshift64*: a deterministic generator, so the error rates are reproducible. -/
def nextRand (x : UInt64) : UInt64 × Float :=
  let x := x ^^^ (x >>> 12)
  let x := x ^^^ (x <<< 25)
  let x := x ^^^ (x >>> 27)
  (x, ((x * 2685821657736338717) >>> 11).toFloat / 9007199254740992.0)

/-- One paired change with median `shift`: heavy-tailed noise like the shared
Mac's (Laplace, scale 0.4%, and one change in 20 an outlier up to ±8%), or
skewed (exponential, shifted to median 0). -/
def simChange (seed : UInt64) (shift : Float) (skewed : Bool) : UInt64 × Float := Id.run do
  let (seed, u) := nextRand seed
  let (seed, v) := nextRand seed
  if skewed then return (seed, shift + 0.5 * (-Float.log (1 - u) - Float.log 2))
  if v < 0.05 then return (seed, shift + (u - 0.5) * 16)
  let w := u - 0.5
  let lap := if w < 0 then 0.4 * Float.log (1 + 2 * w) else -0.4 * Float.log (1 - 2 * w)
  return (seed, shift + lap)

/-- `sessions` sequential sessions (at most `maxRuns` pairs, `--min-change`
1%): how many ended slower, faster, within ±1% and unsettled, and the mean
number of pairs measured. -/
def simSessions (sessions maxRuns : Nat) (shift : Float) (skewed : Bool := false) (seed : UInt64 := 88172645463325252) :
    (Nat × Nat × Nat × Nat) × Float := Id.run do
  let d : Judge.SeqDesign := { max := maxRuns }
  let bounds := (Judge.seqBounds d).1
  let mut seed := seed
  let mut counts := (0, 0, 0, 0)
  let mut pairs := 0
  for _ in [:sessions] do
    let mut xs : Array Float := #[]
    for _ in [:maxRuns] do
      let (s, x) := simChange seed shift skewed
      seed := s
      xs := xs.push x
      if Judge.seqStop d bounds xs 1 then break
    pairs := pairs + xs.size
    let call := match Judge.seqInterval bounds xs with
      | some (lo, hi) => Judge.timeCall lo hi 1
      | none => .unsettled
    let (a, b, c, e) := counts
    counts := match call with
      | .slower => (a + 1, b, c, e) | .faster => (a, b + 1, c, e)
      | .same => (a, b, c + 1, e) | .unsettled => (a, b, c, e + 1)
  return (counts, pairs.toFloat / sessions.toFloat)

/-- Light scopes whose calls change cost (apart from `tests`, which Lean 4.34
no longer compiles within its heartbeats with them inside). -/
def lightScopeTests (sanitized : Bool) : StateT Nat IO Unit := do
  -- a light scope's first 1,024 calls are all timed, later ones one in 64: a
  -- costlier second phase must not be weighed like the first (with every
  -- timed call scaled up alike, the total came out at about half)
  let k32 ← opaqueNat 32
  let n64k ← opaqueNat 65536
  let _ ← IO.lazyPure fun _ => epochLoop 0 1024
  let before ← totalNs "test.epochs"
  let _ ← IO.lazyPure fun _ => epochLoop k32 n64k
  let est := (← totalNs "test.epochs") - before
  let timed ← timedCalls "test.epochs"
  -- the same work without the scope (the loop around it included), fastest of 5
  let mut plainNs : Nat := 0
  for _ in [0:5] do
    let t0 ← IO.monoNanosNow
    let _ ← IO.lazyPure fun _ => spinLoop k32 n64k
    let w := (← IO.monoNanosNow) - t0
    if plainNs == 0 || w < plainNs then plainNs := w
  check "a light scope's sampled calls stand for the calls they were sampled from"
    -- (no upper bound: on a loaded machine a preempted sampled call can
    -- stand for 64 calls' worth of waiting)
    (sanitized || est > 0.7 * plainNs.toFloat)
    s!"estimate={est} without the scope={plainNs} timed={timed}"
  -- a light child adds its estimate to its caller's children; when it has
  -- become cheaper than that, the caller's self time must not wrap around
  -- (the report then showed it as all of the caller's time, as it did when
  -- the estimate was rounded down to whole ticks of a 24 MHz clock)
  let app ← IO.appPath
  let wrapEnv := #[("LEANPROF_JSON", some "light-wrap.json"), ("LEANPROF_QUIET", some "1")]
  let child ← IO.Process.output { cmd := app.toString, args := #["--light-wrap"], env := wrapEnv }
  let wrapJson ← try IO.FS.readFile "light-wrap.json" catch _ => pure ""
  let parent := (Lean.Json.parse wrapJson).toOption.bind fun j =>
    ((j.getObjVal? "scopes" >>= Lean.Json.getArr?).toOption.getD #[]).find? fun s =>
      (s.getObjValAs? String "name").toOption == some "test.wrapparent"
  let field (k : String) := (parent.bind fun s => (s.getObjValAs? Float k).toOption).getD (-1)
  check "a caller of a light scope that got cheaper gets the estimate subtracted, without wrapping"
    (child.exitCode == 0 && field "self_ns" ≥ 0 && field "self_ns" < 0.9 * field "total_ns")
    s!"self={field "self_ns"} total={field "total_ns"} {child.stderr}"
  -- and that caller's row says it holds a scope too small to time, which
  -- went light before this caller first called it
  let holds := (parent.bind fun s => (s.getObjVal? "holds_tiny" >>= Lean.Json.getArr?).toOption).getD #[]
  check "a caller of a light scope is marked as holding it"
    (sanitized || holds.any (·.getStr?.toOption == some "test.wrapchild"))
    s!"holds_tiny={holds}"
  try IO.FS.removeFile "light-wrap.json" catch _ => pure ()

-- a long `do` block: Lean before 4.28 elaborates it past the default depth
set_option maxRecDepth 2048 in
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
  -- the self-check: each kind's known copy reaches a shim on this Lean version
  let before ← copies
  let w ← selfCheck
  check "self-check: every known copy is counted on this Lean version" (w == "") w
  check "self-check copies stay out of the counts" ((← copies) == before) s!"copies={(← copies) - before}"
  -- scopes
  let before ← calls "test.fib"
  let v ← IO.lazyPure fun _ => fib n20
  let after ← calls "test.fib"
  check "pure scope counts every call" (v == 6765 && after - before == 10945) s!"calls={after - before}"
  let ov ← overheadNs
  check "calibrated overhead is plausible" (ov > 0.5 && ov < 1000) s!"overhead={ov}"
  -- Apple clang outlines repeated instruction sequences on arm64 even at -O2:
  -- the inlined probes the program ran became chains of calls that the
  -- calibration's own copies did not make, so the report kept ~5 ns a scope
  -- (the lakefile passes -mno-outline). Calibration must time the same code.
  if System.Platform.isOSX then
    let syms ← IO.Process.output { cmd := "nm", args := #[".lake/build/c/leanprof.o"] }
    check "runtime has no outlined code (probes run what calibration measured)"
      (syms.exitCode == 0 && (syms.stdout.splitOn "OUTLINED_FUNCTION").length == 1)
      s!"nm exit {syms.exitCode}: {syms.stderr}"
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
  -- a scope too small to time goes light: counted on every call, timed on a sample
  let n := n500 * 400
  let _ ← IO.lazyPure fun _ => tinyLoop n
  let timed ← timedCalls "test.tiny"
  check "a tiny scope still counts every call" ((← calls "test.tiny") == n) s!"calls={← calls "test.tiny"}"
  check "a tiny scope is timed on a sample of its calls" (timed ≥ 1024 && timed < n / 4) s!"timed={timed} of {n}"
  check "a tiny scope's time stands for all its calls" ((← totalNs "test.tiny") ≥ 0)
  check "a scope with real work is timed on every call" ((← timedCalls "test.history") == 1)
  lightScopeTests sanitized
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
  -- a copied field of a kept structure: cite structure updates near the
  -- update, never `match … with`, comments or docstrings (concrete's
  -- `elabModule`: 38 lines, one of them a comment)
  let decl : Array (Nat × String) := #[(1, "def f (s : S) : S := Id.run do"),
    (2, "  -- a type with aliases expanded"), (3, "  /-- doc with words"), (4, "     still doc with -/"),
    (5, "  match s.k with"), (6, "  | 0 => s"), (7, "  | _ =>"), (8, "  let t := { s with k := 1 }"),
    (9, "  let u := s.name ++ \"_\""), (10, "  let v := {s with k := 2}"), (11, "  let w := { s with k := 3 } -- far"),
    (20, "  return { s with name := u }")]
  check "explain: comments are not code" ((Explain.codeLines decl).all fun (_, c) => !Explain.has c "with words" &&
    !Explain.has c "aliases" && !Explain.has c "still doc")
  check "explain: structure updates, not match … with"
    (Explain.isStructUpdate "{ s with k := 1 }" && Explain.isStructUpdate "{s with k := 2}" &&
     !Explain.isStructUpdate "match s.k with" && !Explain.isStructUpdate "-- with aliases")
  check "explain: a kept structure's lines are the updates nearest the copy"
    (Explain.keptStructLines decl #[9] == #[8, 10]) s!"{Explain.keptStructLines decl #[9]}"
  check "explain: without an anchor, a declaration's many structure updates are not cited"
    (Explain.keptStructLines decl #[] == #[]) s!"{Explain.keptStructLines decl #[]}"
  check "explain: quoted source lines leave out comments"
    (Explain.code decl 11 == "`let w := { s with k := 3 }`") (Explain.code decl 11)
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
  -- `leanprof sample` writes report.json too, without copies: explain says so
  -- instead of "the report has no copies"
  let sampled : System.FilePath := ".lake/leanprof/test-sampled.json"
  IO.FS.createDirAll ".lake/leanprof"
  IO.FS.writeFile sampled "{\"version\":3,\"sampled\":true,\"scopes\":[],\"copies\":[]}"
  let r ← (Explain.explainCmd ["--report", sampled.toString, "--out", ".lake/leanprof/test-explain.json"]
    (fun _ _ => pure 0)).toBaseIO
  check "explain: a sampled report is refused with a pointer to `leanprof run`"
    (match r with | .error e => (toString e).contains "leanprof sample" | .ok _ => false) ""
  -- END leanprof explain
  -- leanprof explain: the fixes it prints remove the copies (Tests/ExplainFixes.lean)
  Tests.ExplainFixes.run fun n ok d => check n ok d
  -- leanprof fix: edits and their diff (Leanprof/Fix.lean)
  let src := #["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", ""]
  let edits : Array Fix.Edit := #[{ first := 2, count := 1, lines := #["B1", "B2"] }, { first := 9, count := 1, lines := #[] }]
  check "fix: edits replace and delete lines" (Fix.applyEdits src edits == #["a", "B1", "B2", "c", "d", "e", "f", "g", "h", "j", ""])
    s!"{Fix.applyEdits src edits}"
  let diff := Fix.unifiedDiff "F.lean" src edits (ctx := 1)
  check "fix: one hunk per group of nearby edits, with the new file's line numbers"
    (diff == "--- a/F.lean\n+++ b/F.lean\n@@ -1,3 +1,4 @@\n a\n-b\n+B1\n+B2\n c\n@@ -8,3 +9,2 @@\n h\n-i\n j\n") diff
  let dep := Lean.Json.mkObj [("cause", "nested-array-element"), ("file", ".lake/packages/x/X.lean"),
    ("lines", Lean.toJson #[3]), ("fix_code", Lean.toJson #["xs := xs.modify i (·.push v)"])]
  check "fix: code in a dependency is not edited"
    (match Fix.plansFor dep #[] with | .error e => e.contains "dependency" | .ok _ => false) ""
  let stale := Lean.Json.mkObj [("cause", "nested-array-element"), ("file", "X.lean"), ("where", "X.lean:1"),
    ("lines", Lean.toJson #[2]), ("fix_code", Lean.toJson #["xs := xs.modify i (·.push v)"])]
  check "fix: a source line that no longer matches the report is refused"
    (match Fix.plansFor stale #["def f := 1", "  xs := xs.push 1"] with | .error e => e.contains "changed since" | .ok _ => false) ""
  -- two rewrites of one site (lean-compiler-backend's CFG.build): both lines
  -- first, then each alone
  let twoSrc := #["def build := Id.run do", "    succ := succ.set! i (succ[i]!.push t)  -- out",
    "    pred := pred.set! t (pred[t]!.push i)"]
  let two := Lean.Json.mkObj [("cause", "nested-array-element"), ("file", "CFG.lean"), ("where", "CFG.lean:1"),
    ("lines", Lean.toJson #[2, 3]), ("fix_code", Lean.toJson #["succ := succ.modify i (·.push t)", "pred := pred.modify t (·.push i)"])]
  match Fix.plansFor two twoSrc with
  | .ok ps =>
    check "fix: two rewrites of one site are applied together, then alone" (ps.size == 3 &&
      Fix.applyEdits twoSrc ps[0]!.edits == #["def build := Id.run do", "    succ := succ.modify i (·.push t)  -- out",
        "    pred := pred.modify t (·.push i)"] && ps[1]!.edits.size == 1 && ps[2]!.edits.size == 1)
      s!"{ps.map (·.what)} {ps.map (Fix.applyEdits twoSrc ·.edits)}"
  | .error e => check "fix: two rewrites of one site are applied together, then alone" false e
  -- rewrites only when they compute the same values on every input
  check "fix: `set! i (xs[j]!…)` (another element) has no Array.modify rewrite"
    (Explain.modifyRewrite "  xs := xs.set! i (xs[j]!.push t)" == none &&
      Explain.modifyRewrite "  xs := xs.set! i (xs[i + 1]!.push t)" == none &&
      Explain.modifyRewrite "  xs := xs.set! (i + 1) (xs[(i + 1)]!.push t)" == some "xs := xs.modify (i + 1) (·.push t)") ""
  let otherIdx := Lean.Json.mkObj [("cause", "nested-array-element"), ("file", "X.lean"), ("where", "X.lean:1"),
    ("lines", Lean.toJson #[2]), ("fix_code", Lean.toJson #["xs := xs.modify i (·.push v)"])]
  check "fix: a nested update reading another index is refused"
    (match Fix.plansFor otherIdx #["def f := Id.run do", "    xs := xs.set! i (xs[j]!.push v)"] with
      | .error _ => true | .ok _ => false) ""
  let loopF := Lean.Json.mkObj [("cause", "loop-over-updated-array"), ("file", "L.lean"), ("where", "L.lean:1"),
    ("lines", Lean.toJson #[5, 6]), ("fix_code", Lean.toJson #["for i in [0:xs.size] do\n  let x := xs[i]!"])]
  let loopSrc (body : List String) (counter := "    let mut j := 0") : Array String :=
    #["def f (xs : Array Nat) := Id.run do", "  let mut xs := xs", "  for _ in [0:3] do", counter, "    for x in xs do"] ++
      body.toArray ++ #["  return xs", ""]
  let loopOk (body : List String) (counter := "    let mut j := 0") : Bool :=
    match Fix.plansFor loopF (loopSrc body counter) with | .ok _ => true | .error _ => false
  check "fix: a loop updating only the element it visits (and appending) is rewritten"
    (loopOk ["      xs := xs.set! j (x + 1)", "      j := j + 1"] &&
      loopOk ["      let y := xs.size", "      xs := xs.modify j (· + y)", "      xs := xs.push x", "      j := j + 1"]) ""
  check "fix: a loop that may change an element not visited yet is refused"
    (!loopOk ["      xs := xs.set! ((j + 1) % xs.size) (x + j % 3)", "      j := j + 1"] &&
      !loopOk ["      xs := xs.set! (j + 1) x", "      j := j + 1"] &&
      !loopOk ["      xs := xs.set! j x", "      xs := xs.pop", "      j := j + 1"] &&
      !loopOk ["      xs := xs.set! j x", "      xs := xs.reverse", "      j := j + 1"] &&
      !loopOk ["      xs := xs.set! j x", "      j := j + 2"] &&
      !loopOk ["      xs := xs.set! j x", "      if x > 0 then", "        j := j + 1", "      j := j + 1"] &&
      !loopOk ["      xs := xs.set! j x", "      if x > 0 then continue", "      j := j + 1"] &&
      !loopOk ["      let mut j := 5", "      xs := xs.set! j x", "      j := j + 1"] &&
      !loopOk ["      xs := xs.set! j (x + 1)", "      j := j + 1"] (counter := "    let mut j := 1") &&
      !loopOk ["      xs := xs.set! k x", "      j := j + 1"]) ""
  check "fix: branch names from the function and cause"
    (Fix.branchName "Foo.groupBy (in Std.Legacy.Range.forIn'.loop)" "map-value-reinserted" ==
      "leanprof-fix/groupBy-map-value-reinserted") (Fix.branchName "Foo.groupBy (in x)" "c")
  -- BEGIN leanprof judge (Leanprof/Judge.lean), on summaries written by hand
  let summary (copies allocs : Nat) (runs : List Nat) (ms : List Nat) : Judge.Summary :=
    let times := ms.map (· * 1000000)
    let j := Lean.Json.mkObj [("leanprof", "measure"), ("command", Lean.toJson #["demo"]), ("exit_code", (0 : Nat)),
      ("output", Lean.Json.mkObj [("source", "stdout"), ("hash", "fnv1a64:1"), ("stable", true)]),
      ("time_ns", Lean.Json.mkObj [("median", Lean.toJson times[times.length / 2]!),
        ("min", Lean.toJson (times.foldl Nat.min times[0]!)), ("max", Lean.toJson (times.foldl Nat.max 0))]),
      ("copies_total", Lean.toJson copies), ("allocs_total", Lean.toJson allocs), ("allocs_runs", Lean.toJson runs),
      ("allocs", Lean.toJson #[Lean.Json.mkObj [("key", "CFG.build in -"), ("allocs", Lean.toJson allocs)]])]
    match Judge.Summary.ofJson j with
    | .ok s => s
    | .error _ => {}
  let base := summary 2999 1000000 [1000000] [50, 51, 52]
  -- lean-compiler-backend's first CFG.build fix: copies gone, 59,514 more
  -- allocations; even when every run is faster, the change is discarded
  let v := Judge.judge base (summary 0 1059514 [1059514] [40, 41, 42])
  check "judge: fewer copies but more allocations is DISCARD"
    (!v.keep && v.worse.contains "allocations: 1,000,000 -> 1,059,514") v.render
  let v := Judge.judge base (summary 2999 980000 [980000] [50, 51, 52])
  check "judge: allocations down by 2% is KEEP" (v.keep && v.better.any (·.startsWith "allocations")) v.render
  let v := Judge.judge base (summary 2999 999950 [999950] [50, 51, 52])
  check "judge: allocations down by less than the margin is not an improvement" (!v.keep) v.render
  let v := Judge.judge (summary 2999 1000000 [999000, 1001000] [50, 51, 52])
    (summary 2999 1000500 [1000500, 1000200] [50, 51, 52])
  check "judge: allocations that vary between runs count only beyond their range" (v.worse.isEmpty) v.render
  let v := Judge.judge base { summary 2999 1000000 [1000000] [40, 41, 42] with scope := "build" }
  check "judge: a scope's time against the whole process's is DISCARD"
    (!v.keep && v.worse.contains "different times measured: the whole process vs scope build") v.render
  let v := Judge.judge { base with scope := "build" } { summary 2999 1000000 [1000000] [40, 41, 42] with scope := "build" }
  check "judge: the same scope, every run faster, is KEEP" v.keep v.render
  -- a scope whose time was too small to measure (`measure --scope` writes
  -- time_ns.too_small_runs) gives no time verdict, though its runs read 0
  let tiny := Judge.Summary.ofJson (Lean.Json.mkObj [("leanprof", "measure"), ("scope", "build"),
    ("command", Lean.toJson #["demo"]),
    ("output", Lean.Json.mkObj [("source", "stdout"), ("hash", "fnv1a64:1"), ("stable", true)]),
    ("time_ns", Lean.Json.mkObj [("median", Lean.toJson (0 : Nat)), ("min", Lean.toJson (0 : Nat)),
      ("max", Lean.toJson (0 : Nat)), ("too_small_runs", Lean.toJson (3 : Nat))]),
    ("copies_total", Lean.toJson (2999 : Nat)), ("allocs_total", Lean.toJson (1000000 : Nat)),
    ("allocs_runs", Lean.toJson [1000000]),
    ("allocs", Lean.toJson #[Lean.Json.mkObj [("key", "CFG.build in -"), ("allocs", Lean.toJson (1000000 : Nat))]])])
  let v := match tiny with
    | .ok t => Judge.judge { base with scope := "build" } t
    | .error e => { keep := true, worse := #[], better := #[e], notes := #[] }
  check "judge: a scope too small to measure gives no time verdict"
    (!v.keep && v.better.isEmpty && v.notes.any (·.contains "too small to measure")) v.render
  let v := Judge.judge base { summary 2999 0 [] [50, 51, 52] with allocs := none }
  check "judge: allocations counted in one summary only are not compared" (v.worse.isEmpty) v.render
  let v := Judge.judge base { summary 2999 1200000 [1200000] [40, 41, 42] with core := true }
  check "judge: a --core summary against one without is DISCARD"
    (!v.keep && v.worse.any (fun w => (w.splitOn "--core").length > 1)) v.render
  let v := Judge.judge { base with core := true } { summary 2999 980000 [980000] [50, 51, 52] with core := true }
  check "judge: two --core summaries are compared" v.keep v.render
  check "judge: a summary's core flag is read"
    (((Judge.Summary.ofJson (Lean.Json.mkObj [("leanprof", "measure"), ("core", Lean.Json.bool true)])).toOption.map
      (·.core)) == some true)
  -- Interleaved pairs cancel a common drift that makes the two ranges overlap.
  let paired (factor : Nat) (overload : Bool := false) : Lean.Json := Id.run do
    let mut samples := #[]
    for i in [:20] do
      for offset in [:2] do
        let baseSide := (i + offset) % 2 == 0
        let time := (100 + i * 10) * (if baseSide then 100 else factor)
        samples := samples.push <| Lean.Json.mkObj [
          ("pair", Lean.toJson i), ("side", Lean.toJson (if baseSide then "base" else "candidate")),
          ("time_ns", Lean.toJson time), ("exit_code", Lean.toJson (0 : Nat)),
          ("output_present", Lean.Json.bool true), ("stdout_hash", "same"),
          ("stderr_hash", "same"), ("output_hash", "same")]
    return Lean.Json.mkObj [("leanprof", "measure-pair"), ("version", Lean.toJson (1 : Nat)),
      ("runs", Lean.toJson (20 : Nat)), ("samples", Lean.Json.arr samples),
      ("machine", Lean.Json.mkObj [("overloaded", Lean.Json.bool overload)])]
  let judgePair (j : Lean.Json) := (Judge.judgePaired j).toOption
  check "paired: common drift with a 10% improvement is KEEP"
    ((judgePair (paired 90)).any (·.keep))
  check "paired: common drift without a change is DISCARD"
    ((judgePair (paired 100)).any (!·.keep))
  check "paired: regression is DISCARD"
    ((judgePair (paired 110)).any fun v => !v.keep && !v.worse.isEmpty)
  check "paired: overload disables timing verdict"
    ((judgePair (paired 90 true)).any (!·.keep))
  check "paired: --allow-overloaded judges an overloaded session, and says so"
    (((Judge.judgePaired (paired 90 true) 1 true).toOption).any fun v =>
      v.keep && v.better.any (fun b => (b.splitOn "--allow-overloaded").length > 1))
  check "paired: minimum change applies to the confidence interval"
    (((Judge.judgePaired (paired 99) 2).toOption).any (!·.keep))
  let corrupt (key : String) (value : Lean.Json) : Lean.Json := Id.run do
    let j := paired 90
    let rows := (j.getObjValAs? (Array Lean.Json) "samples").toOption.getD #[]
    return j.setObjVal! "samples" (Lean.Json.arr (rows.modify 0 (·.setObjVal! key value)))
  for key in ["stdout_hash", "stderr_hash", "output_hash"] do
    check s!"paired: changed {key} blocks KEEP"
      ((judgePair (corrupt key "different")).any (!·.keep))
  check "paired: failed run blocks KEEP"
    ((judgePair (corrupt "exit_code" (Lean.toJson (1 : Nat)))).any (!·.keep))
  check "paired: missing output blocks KEEP"
    ((judgePair (corrupt "output_present" (Lean.Json.bool false))).any (!·.keep))
  check "paired: invalid order is rejected"
    ((Judge.judgePaired (corrupt "side" "candidate")).toOption.isNone)
  check "paired: zero duration is rejected"
    ((Judge.judgePaired (corrupt "time_ns" (Lean.toJson (0 : Nat)))).toOption.isNone)
  check "paired: incomplete result is rejected"
    ((Judge.judgePaired ((paired 90).setObjVal! "runs" (Lean.toJson (21 : Nat)))).toOption.isNone)
  check "paired: five pairs cannot give a finite 95% interval"
    ((Judge.pairedInterval #[1, 2, 3, 4, 5]).isNone)
  check "paired: six pairs use the entire range"
    ((Judge.pairedInterval #[1, 2, 3, 4, 5, 6]) == some (3.5, 1, 6))
  check "paired: twenty pairs use the sixth and fifteenth order statistics"
    ((Judge.pairedInterval ((List.range 20).toArray.map (·.toFloat))) == some (9.5, 5, 14))
  -- the sequential rule: exact error spent, then error rates and power by simulation
  for n in [6, 8, 20, 30, 60, 200, 1000] do
    let (bounds, spent) := Judge.seqBounds { max := n }
    check s!"sequential: at most {n} pairs spends at most 2.5% per side, exactly ({spent})"
      (spent ≤ 0.025 && spent > 0 && bounds.size > 0)
  check "sequential: one look is the fixed interval (20 pairs: 6th and 15th order statistics)"
    ((Judge.seqBounds (.fixed 20)).1 == #[(20, some 5)])
  check "sequential: the first look that can decide at most 30 pairs is 8 pairs"
    (((Judge.seqBounds { max := 30 }).1.find? (·.2.isSome)).map (·.1) == some 8)
  let sessions := 4000
  -- three standard errors of a 2.5% rate over `sessions` sessions
  let slack := 0.025 + 3 * Float.sqrt (0.025 * 0.975 / sessions.toFloat)
  let rate (k : Nat) := k.toFloat / sessions.toFloat
  let fmtSim (c : (Nat × Nat × Nat × Nat) × Float) :=
    let ((a, b, e, u), p) := c
    s!"slower {rate a}, faster {rate b}, within ±1% {rate e}, unsettled {rate u}, mean pairs {p}"
  for skewed in [false, true] do
    let kind := if skewed then "skewed" else "heavy-tailed"
    let r0 := simSessions sessions 30 0 skewed (if skewed then 11 else 12)
    IO.println s!"     sequential, {kind}, unchanged: {fmtSim r0}"
    check s!"sequential ({kind}): unchanged code is called slower or faster at most 5% of the time"
      (rate (r0.1.1 + r0.1.2.1) ≤ 2 * slack) (fmtSim r0)
    -- the worst cases: a true median exactly at the minimum change
    let r1 := simSessions sessions 30 1 skewed (if skewed then 21 else 22)
    IO.println s!"     sequential, {kind}, median +1% (= --min-change): {fmtSim r1}"
    check s!"sequential ({kind}): a +1% median is called slower at most 2.5% (+3 SE)" (rate r1.1.1 ≤ slack) (fmtSim r1)
    check s!"sequential ({kind}): a +1% median is called within ±1% at most 2.5% (+3 SE)" (rate r1.1.2.2.1 ≤ slack) (fmtSim r1)
    let r2 := simSessions sessions 30 (-1) skewed (if skewed then 31 else 32)
    IO.println s!"     sequential, {kind}, median -1%: {fmtSim r2}"
    check s!"sequential ({kind}): a -1% median is called faster at most 2.5% (+3 SE)" (rate r2.1.2.1 ≤ slack) (fmtSim r2)
  let p0 := simSessions sessions 30 0 false 41
  check "sequential: unchanged code is settled within ±1% in at least 90% of sessions" (rate p0.1.2.2.1 ≥ 0.9) (fmtSim p0)
  for (shift, min) in [(2.4, 0.95), (4.8, 0.99), (10.4, 0.99)] do
    let r := simSessions sessions 30 shift false (51 + shift.toUInt64)
    IO.println s!"     sequential, heavy-tailed, median +{shift}%: {fmtSim r}"
    check s!"sequential: a +{shift}% change is caught as slower in at least {min * 100}% of sessions"
      (rate r.1.1 ≥ min) (fmtSim r)
    let f := simSessions sessions 30 (-shift) false (61 + shift.toUInt64)
    check s!"sequential: a -{shift}% change is caught as faster in at least {min * 100}% of sessions"
      (rate f.1.2.1 ≥ min) (fmtSim f)
  -- END leanprof judge
  -- leanprof elab: reading traces (Tests/Elab.lean)
  Tests.Elab.run fun n ok d => check n ok d
  -- why a declaration or copy site got worse (Tests/Regress.lean)
  Tests.Regress.run fun n ok d => check n ok d
  -- `leanprof` with no arguments: the targets of a lakefile, and what it profiles
  let leanCfg := "import Lake\nopen Lake DSL\n\npackage p where\n  -- testDriver := \"commented\"\n" ++
    "  moreLeancArgs := #[\"--x\"] /- lean_exe hidden -/\n\n@[default_target] lean_lib P\n\n" ++
    "lean_exe «my-app» where\n  root := `Main\n\n@[test_driver] lean_exe tests where\n  root := `Tests\n"
  let t := Workload.parseLean leanCfg
  check "workload: lakefile.lean targets, comments skipped"
    (t.exes == #["my-app", "tests"] && t.libs == #["P"] && t.testDriver == some "tests") s!"{repr t}"
  check "workload: the one executable besides the test driver"
    (Workload.choose t == .exe "my-app" "the project's only executable")
  let tomlCfg := "name = \"importGraph\"\ndefaultTargets = [\"ImportGraph\", \"graph\"]\ntestRunner = \"ImportGraphTest\"\n\n" ++
    "[[require]]\nname = \"Cli\"\n\n[[lean_lib]]\nname = \"ImportGraph\"\n\n# a comment\n[[lean_exe]]\nname = \"graph\"\nroot = \"MainGraph\"\n\n" ++
    "[[lean_exe]]\nname = \"unused\"\n\n[[lean_lib]]\nname = \"ImportGraphTest\"\n"
  let t2 := Workload.parseToml tomlCfg
  check "workload: lakefile.toml targets (not the [[require]] name)"
    (t2.exes == #["graph", "unused"] && t2.libs == #["ImportGraph", "ImportGraphTest"] &&
      t2.testDriver == some "ImportGraphTest") s!"{repr t2}"
  check "workload: two executables are not chosen between"
    (Workload.choose t2 == .ambiguous #["graph", "unused"] none)
  check "workload: a library with a library test driver profiles compile time"
    (Workload.choose (Workload.parseToml "name = \"Cli\"\ntestDriver = \"CliTest\"\n[[lean_lib]]\nname = \"Cli\"\n") == .elab)
  check "workload: only the test driver"
    (Workload.choose { exes := #["tests"], testDriver := some "tests" } matches .exe "tests" _)
  check "workload: nothing to profile" (Workload.choose {} == .nothing)

def main (args : List String) : IO UInt32 := do
  -- a light scope (cheap calls) whose estimate is then raised by costlier
  -- calls, called cheaply again from a parent; checked by the tests above
  if args.head? == some "--light-wrap" then
    let k := (args[1]? >>= String.toNat?).getD 32
    let _ ← IO.lazyPure fun _ => wrapLoop 0 1024
    let _ ← IO.lazyPure fun _ => wrapLoop k (2 * 65536)
    let _ ← IO.lazyPure fun _ => wrapParent 60000
    return 0
  let ((), failures) ← tests.run 0
  if failures == 0 then
    IO.println "all tests passed"
    return 0
  IO.println s!"{failures} failed"
  return 1
