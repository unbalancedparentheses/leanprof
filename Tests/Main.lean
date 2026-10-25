import Leanprof import Leanprof.Explain import Leanprof.Judge import Tests.Elab import Tests.ExplainFixes import Tests.Regress

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
  -- END leanprof judge
  -- leanprof elab: reading traces (Tests/Elab.lean)
  Tests.Elab.run fun n ok d => check n ok d
  -- why a declaration or copy site got worse (Tests/Regress.lean)
  Tests.Regress.run fun n ok d => check n ok d

def main : IO UInt32 := do
  let ((), failures) ← tests.run 0
  if failures == 0 then
    IO.println "all tests passed"
    return 0
  IO.println s!"{failures} failed"
  return 1
