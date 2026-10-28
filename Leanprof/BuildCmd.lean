import Leanprof.Build
import Leanprof.BuildShim
import Leanprof.Contract

/-!
# `leanprof build`: the command

Measures one `lake build` (Leanprof/Build.lean), then optionally checks the
rebuild estimates against real builds (`--validate K`) and tries removing
imports (`--imports K`), both in a git worktree of the working tree, so the
project itself is never edited. Writes `.lake/leanprof/build.json` (or
`--json FILE`), prints the text report, and with `--html FILE` a timeline.
-/

namespace Leanprof.Build
open Lean System
open Leanprof.Explain (trim jstr jarr jnum)
open Leanprof.Fix (capture tailOf)

structure Opts where
  targets : Array String := #[]
  clean : Bool := false
  workers : Option Nat := none
  validate : Nat := 0
  imports : Nat := 0
  top : Nat := 10
  json : Option String := none
  html : Option String := none
  from_ : Option String := none
  keep : Bool := false
  quiet : Bool := false

partial def parseOpts (o : Opts) : List String → Except String Opts
  | [] => .ok o
  | "--clean" :: r => parseOpts { o with clean := true } r
  | "--keep-worktree" :: r => parseOpts { o with keep := true } r
  | "--quiet" :: r => parseOpts { o with quiet := true } r
  | "--jobs" :: n :: r => match n.toNat? with
    | some k => if k > 0 then parseOpts { o with workers := some k } r else .error "--jobs needs a positive number"
    | none => .error s!"--jobs needs a number, not {n}"
  | "--validate" :: n :: r => match n.toNat? with
    | some k => parseOpts { o with validate := k } r
    | none => .error s!"--validate needs a number, not {n}"
  | "--imports" :: n :: r => match n.toNat? with
    | some k => parseOpts { o with imports := k } r
    | none => .error s!"--imports needs a number, not {n}"
  | "--top" :: n :: r => match n.toNat? with
    | some k => parseOpts { o with top := max k 1 } r
    | none => .error s!"--top needs a number, not {n}"
  | "--json" :: f :: r => parseOpts { o with json := some f } r
  | "--out" :: f :: r => parseOpts { o with json := some f } r
  | "--html" :: f :: r => parseOpts { o with html := some f } r
  | "--from" :: f :: r => parseOpts { o with from_ := some f } r
  | a :: r =>
    if a.startsWith "-" then .error s!"unknown option {a}"
    else parseOpts { o with targets := o.targets.push a } r

def say (o : Opts) (s : String) : IO Unit := unless o.quiet do IO.eprintln s!"leanprof build: {s}"

def mean (xs : Array Float) : Float := if xs.isEmpty then 0 else xs.foldl (· + ·) 0 / xs.size.toFloat

/-- A module's source in the worktree `dir`: its path relative to the project, else the default layout. -/
def sourceIn (projAbs : String) (dir : FilePath) (j : Job) : FilePath :=
  if !j.source.isEmpty && j.source.startsWith (projAbs ++ "/") then dir / (j.source.drop (projAbs.length + 1)).toString
  else dir / ((j.name.replace "." "/") ++ ".lean")

/-- How the rebuilt modules of a build differ from the predicted ones. -/
def setDifference (pred actual : Array String) : String :=
  let missing := actual.filter (!pred.contains ·)
  let extra := pred.filter (!actual.contains ·)
  let show_ (xs : Array String) := ", ".intercalate (xs.extract 0 3).toList ++ (if xs.size > 3 then s!" and {xs.size - 3} more" else "")
  (if missing.isEmpty then "" else s!"rebuilt but not predicted: {show_ missing}") ++
  (if !missing.isEmpty && !extra.isEmpty then "; " else "") ++
  (if extra.isEmpty then "" else s!"predicted but not rebuilt: {show_ extra}")

/-- Touch `file` (a new definition at its end), build, put it back, build
again: the two builds' runs. -/
def touchAndBuild (o : Opts) (work exp : FilePath) (file : FilePath) (k : Nat) : IO (Run × Run) := do
  let orig ← IO.FS.readFile file
  IO.FS.writeFile file (touched orig k)
  let r1 ← try runLake work exp o.targets false catch e => do IO.FS.writeFile file orig; throw e
  IO.FS.writeFile file orig
  let r2 ← runLake work exp o.targets false
  return (r1, r2)

/-- `--validate K`: K modules, from the costliest rebuild estimate to the
cheapest, each touched and rebuilt in the worktree. -/
def validate (o : Opts) (a : Analysis) (noop : Float) (projAbs : String) (work exp : FilePath) (mods : Array String) : IO Json := do
  let est := (mods.map fun m => (m, rebuildEstimate a noop m)).qsort fun x y => x.2.2.2 > y.2.2.2
  let k := min o.validate est.size
  let picks := if k <= 1 then est.extract 0 k else
    ((List.range k).toArray.map fun i => est[(i * (est.size - 1) + (k - 1) / 2) / (k - 1)]!)
  let loadBefore ← loadNow
  let mut samples := #[]
  let mut errs : Array Float := #[]
  let mut errsReplay : Array Float := #[]
  for (m, (_, _, e)) in picks do
    -- the same jobs with their wall times as measured in this build (what the model would be without times alone)
    let ids := rebuildSet a.jobs m
    let replay := noop + simulate (simOf a.jobs ids) a.workers a.latency
    let some j := a.jobs.find? fun j => j.kind == "lean" && j.name == m | continue
    let file := sourceIn projAbs work j
    say o s!"validate: touching {m} (estimated {fmtS e})"
    let pred := ((rebuildSet a.jobs m).filterMap fun i =>
      let x := a.jobs[i]!; if x.kind == "lean" then some x.name else none)
    try
      let (r1, r2) ← touchAndBuild o work exp file (samples.size + 1)
      let ms := #[r1.elapsed, r2.elapsed]
      let ep := ms.map fun x => (e - x) / x * 100
      let epr := ms.map fun x => (replay - x) / x * 100
      if r1.exitCode == 0 && r2.exitCode == 0 then
        errs := errs ++ ep.map Float.abs
        errsReplay := errsReplay ++ epr.map Float.abs
      let actual := r1.built
      let same := pred.all actual.contains && actual.all pred.contains
      samples := samples.push <| Json.mkObj [("module", Json.str m), ("estimate_s", toJson (r3 e)),
        ("measured_s", toJson (ms.map r3)), ("error_pct", toJson (ep.map fun x => (x * 10).round / 10)),
        ("replay_estimate_s", toJson (r3 replay)), ("replay_error_pct", toJson (epr.map fun x => (x * 10).round / 10)),
        -- the same jobs' wall and CPU time, summed, in the measured build and in the first rebuild
        ("clean_wall_s", toJson (r3 (ids.foldl (fun s i => s + a.jobs[i]!.dur) 0))),
        ("clean_cpu_s", toJson (r3 (ids.foldl (fun s i => s + a.jobs[i]!.user + a.jobs[i]!.sys) 0))),
        ("rebuild_wall_s", toJson (r3 (r1.jobs.foldl (fun s j => s + j.dur) 0))),
        ("rebuild_cpu_s", toJson (r3 (r1.jobs.foldl (fun s j => s + j.user + j.sys) 0))),
        ("predicted_modules", toJson pred.size), ("rebuilt_modules", toJson actual.size),
        ("same_modules", Json.bool same), ("module_difference", Json.str (setDifference pred actual)),
        ("exit_codes", toJson #[r1.exitCode.toNat, r2.exitCode.toNat]),
        ("error", Json.str (if r1.exitCode != 0 || r2.exitCode != 0 then s!"a build failed: {tailOf ("\n".intercalate (r1.lines ++ r2.lines).toList) 3}" else ""))]
    catch ex =>
      samples := samples.push <| Json.mkObj [("module", Json.str m), ("estimate_s", toJson (r3 e)), ("error", Json.str (toString ex))]
  let maxE := errs.foldl max 0
  return Json.mkObj [("samples", Json.arr samples), ("mean_abs_error_pct", toJson ((mean errs * 10).round / 10)),
    ("max_abs_error_pct", toJson ((maxE * 10).round / 10)),
    ("replay_mean_abs_error_pct", toJson ((mean errsReplay * 10).round / 10)),
    ("replay_max_abs_error_pct", toJson ((errsReplay.foldl max 0 * 10).round / 10)),
    ("load", Json.mkObj [("before", toJson loadBefore), ("after", toJson (← loadNow))])]

/-! ## Imports -/

structure Cand where
  m : String
  imp : String
  /-- The imports put in its place (none: removed). -/
  extra : Array String := #[]
  cpGain : Float
  rebuildGain : Float
  freed : Nat
  cleanGain : Float := 0

/-- The jobs as they would be if module `m` imported `direct'` (its direct
imports, changed) instead: the measured modules each module imports,
recomputed for `m` and the modules importing it; dependencies follow. -/
def withImports (a : Analysis) (direct : Std.HashMap String (Array String)) (m : String) (direct' : Array String) :
    Array Job := Id.run do
  let leanId : Std.HashMap String Nat := a.jobs.foldl (init := {}) fun h j => if j.kind == "lean" then h.insert j.name j.id else h
  let affected := (#[leanId.get? m].filterMap id) ++ dependentsOf a.jobs m
  let affectedSet : Std.HashSet Nat := affected.foldl (·.insert ·) {}
  let mut closure : Std.HashMap String (Array String) := {}
  -- in start order: a module's imports were rebuilt before it
  for i in affected.qsort (· < ·) do
    let j := a.jobs[i]!
    let some ds := if j.name == m then some direct' else direct.get? j.name
      | closure := closure.insert j.name j.imports   -- header unknown: as measured
        continue
    let mut acc : Std.HashSet String := {}
    for d in ds do
      if let some di := leanId.get? d then
        acc := acc.insert d
        let sub := if affectedSet.contains di then (closure.get? d).getD #[] else
          a.jobs[di]!.imports.filter leanId.contains
        for x in sub do acc := acc.insert x
    closure := closure.insert j.name acc.toArray
  let jobs := a.jobs.map fun j =>
    if j.kind == "lean" && affectedSet.contains j.id then
      let imps := (closure.get? j.name).getD #[]
      { j with imports := imps, deps := imps.filterMap leanId.get? }
    else j
  return jobs

/-- What a module's `.ilean` says it uses: the modules of the declarations
its source names, and how many declarations it defines. (Instances,
notations and macros it relies on without naming them are not there.) -/
def readIlean (p : FilePath) : IO (Option (Array String × Nat)) := do
  unless ← p.pathExists do return none
  let some j := (Json.parse (← IO.FS.readFile p)).toOption | return none
  let decls := match j.getObjVal? "decls" with
    | .ok (.obj kvs) => kvs.toList.length
    | _ => 0
  let mut used : Array String := #[]
  if let .ok (.obj refs) := j.getObjVal? "references" then
    for (k, v) in refs.toList do
      if (jarr v "usages").isEmpty then continue
      let some kj := (Json.parse k).toOption | continue
      let m := jstr (kj.getObjValD "c") "m"
      unless m.isEmpty || used.contains m do used := used.push m
  return some (used, decls)

/-- Why imports were not candidates, counted. -/
structure Skipped where
  needed : Nat := 0
  redundant : Nat := 0
  reexport : Nat := 0
  noIlean : Nat := 0
  importers : Nat := 0
  kept : Nat := 0

/-- The imports whose removal changes the measured graph, each with what
the module would import instead: the modules of the declarations it names
that it would no longer reach (from its `.ilean`). An import whose own
declarations the module names is needed and left out; so are the imports of
modules that define nothing (they exist to re-export). Ranked by the
estimated gain on the clean build's critical path plus on the rebuild after
touching the import. -/
def candidates (a : Analysis) (noop : Float) (direct : Std.HashMap String (Array String)) (roots : Array String)
    (uses : Std.HashMap String (Array String × Nat)) (kept : Std.HashMap String (Array String) := {}) :
    Nat × Skipped × Array Cand := Id.run do
  let leanJob : Std.HashMap String Job := a.jobs.foldl (init := {}) fun h j => if j.kind == "lean" then h.insert j.name j else h
  let mut out := #[]
  let mut considered := 0
  let mut sk : Skipped := {}
  for m in roots do
    let ds := (direct.get? m).getD #[]
    let some jm0 := leanJob.get? m | continue
    for imp in ds do
      unless leanJob.contains imp do continue
      considered := considered + 1
      if ((kept.get? m).getD #[]).contains imp then sk := { sk with kept := sk.kept + 1 }; continue
      let some (used, decls) := uses.get? m | sk := { sk with noIlean := sk.noIlean + 1 }; continue
      if decls == 0 then sk := { sk with reexport := sk.reexport + 1 }; continue
      if used.contains imp then sk := { sk with needed := sk.needed + 1 }; continue
      -- what `m` reaches without `imp`; the modules it names among the rest come in its place
      let rest := ds.filter (· != imp)
      let mut reach : Std.HashSet String := {}
      for d in rest do
        reach := reach.insert d
        if let some jd := leanJob.get? d then
          for x in jd.allImports do reach := reach.insert x
      let lost := used.filter fun u => u != m && jm0.allImports.contains u && !reach.contains u
      -- modules of this build by name; modules of other packages (cached, not rebuilt)
      -- through what the import itself imports from them, which keeps the header short
      let extra := lost.filter leanJob.contains
      let extra := if lost.all leanJob.contains then extra else
        extra ++ ((direct.get? imp).getD #[]).filter fun d => !leanJob.contains d && !reach.contains d && !rest.contains d
      let jobs' := withImports a direct m (rest ++ extra)
      let some jm := jobs'.find? fun j => j.kind == "lean" && j.name == m | continue
      -- still imported through another import: nothing changes
      if jm.imports.contains imp then sk := { sk with redundant := sk.redundant + 1 }; continue
      -- a module importing `m` names a declaration it would no longer reach: it would break
      let breaks := jobs'.any fun j => j.kind == "lean" && j.id != jm.id &&
        let gone := a.jobs[j.id]!.imports.filter (!j.imports.contains ·)
        !gone.isEmpty && ((uses.get? j.name).map (·.1.any gone.contains)).getD false
      if breaks then sk := { sk with importers := sk.importers + 1 }; continue
      let freed := (jobs'.filter fun j => j.kind == "lean" && a.jobs[j.id]!.imports.contains imp && !j.imports.contains imp).size
      let (_, cp') := cpm jobs'
      let a' : Analysis := { a with jobs := jobs' }
      let (_, _, before) := rebuildEstimate a noop imp
      let (_, _, after) := rebuildEstimate a' noop imp
      out := out.push { m, imp, extra, cpGain := a.cpmLen - cp', rebuildGain := before - after, freed }
  return (considered, sk, out.qsort fun x y => x.cpGain + x.rebuildGain > y.cpGain + y.rebuildGain)

def candJson (c : Cand) : Json :=
  Json.mkObj [("module", Json.str c.m), ("import", Json.str c.imp), ("replace_with", toJson c.extra),
    ("modules_freed", toJson c.freed),
    ("critical_path_gain_s", toJson (r3 c.cpGain)), ("clean_gain_s", toJson (r3 c.cleanGain)),
    ("rebuild_gain_s", toJson (r3 c.rebuildGain))]

/-- Try one candidate in the worktree: rebuild after touching the import
before; the import removed (else replaced by what it imports); the build
must pass with no more `sorry` warnings; rebuild after touching the import
again; then the module put back. -/
def tryCand (o : Opts) (projAbs : String) (work exp : FilePath) (a : Analysis) (direct : Std.HashMap String (Array String))
    (c : Cand) (baseSorries : Nat) (k : Nat) : IO Json := do
  let some jm := a.jobs.find? fun j => j.kind == "lean" && j.name == c.m | return Json.null
  let some ji := a.jobs.find? fun j => j.kind == "lean" && j.name == c.imp | return Json.null
  let fileM := sourceIn projAbs work jm
  let fileI := sourceIn projAbs work ji
  let orig ← IO.FS.readFile fileM
  let base := Json.mkObj [("module", Json.str c.m), ("import", Json.str c.imp)]
  let fields (xs : List (String × Json)) : Json := xs.foldl (fun j (k, v) => j.setObjVal! k v) base
  say o s!"imports: {c.m} without `import {c.imp}`: rebuild after touching {c.imp}, as it is"
  let (b1, b2) ← touchAndBuild o work exp fileI (1000 + 2 * k)
  -- the modules it names in place of the import; if that fails (an instance
  -- or a notation it uses without naming it), what the import itself imports
  let below := ((direct.get? c.imp).getD #[]).filter fun d => !((direct.get? c.m).getD #[]).contains d
  let attempts : Array (Array String) :=
    #[c.extra] ++ (if below.isEmpty || below == c.extra then #[] else #[below])
  let mut result : Json := fields [("verdict", Json.str "does not build"), ("replaced_by", toJson (#[] : Array String))]
  for extra in attempts do
    let some edited := withoutImport orig c.imp extra | return fields [("verdict", Json.str "import not found in the header")]
    IO.FS.writeFile fileM edited
    say o s!"imports: building {c.m} without `import {c.imp}`{if extra.isEmpty then "" else s!", importing {", ".intercalate extra.toList} instead"}"
    let r ← try runLake work exp o.targets false catch e => do IO.FS.writeFile fileM orig; throw e
    if r.exitCode != 0 then
      let errLine := (r.lines.find? fun l => l.startsWith "error:").getD (tailOf ("\n".intercalate r.lines.toList) 2)
      result := fields [("verdict", Json.str "does not build"), ("replaced_by", toJson extra), ("reason", Json.str (trim errLine))]
      continue
    if r.sorries > baseSorries then
      result := fields [("verdict", Json.str "builds with more sorry"), ("replaced_by", toJson extra),
        ("reason", Json.str s!"{r.sorries} `declaration uses 'sorry'` warnings, {baseSorries} before")]
      break
    say o s!"imports: it builds; rebuild after touching {c.imp}, without the import"
    let (a1, a2) ← try touchAndBuild o work exp fileI (1001 + 2 * k) catch e => do IO.FS.writeFile fileM orig; throw e
    let before := mean #[b1.elapsed, b2.elapsed]
    let after := mean #[a1.elapsed, a2.elapsed]
    result := fields [("verdict", Json.str "builds"), ("replaced_by", toJson extra), ("samples", toJson 2),
      ("before_s", toJson (r3 before)), ("after_s", toJson (r3 after)), ("rebuild_gain_s", toJson (r3 (before - after))),
      ("before_modules", toJson b1.built.size), ("after_modules", toJson a1.built.size),
      ("clean_gain_s", toJson (r3 c.cleanGain)), ("clean_gain_is", Json.str "estimated (simulated with the measured durations)")]
    break
  -- put the module back and rebuild, so the next try starts from the same build
  IO.FS.writeFile fileM orig
  discard <| runLake work exp o.targets false
  return result

/-! ## The command -/

def modulesJson (a : Analysis) (run : Run) (noop : Float) (graph : Array (String × Array String)) (projAbs : String) :
    Array Json × Json := Id.run do
  let leanJob : Std.HashMap String Job := a.jobs.foldl (init := {}) fun h j => if j.kind == "lean" then h.insert j.name j else h
  let mut out := #[]
  let mut seen : Std.HashSet String := {}
  for (m, imps) in graph do
    let verb := run.states.get? m
    let job := leanJob.get? m
    if verb.isNone && job.isNone then continue   -- not part of what was built
    seen := seen.insert m
    let state := if job.isSome then "built" else stateOf (verb.getD "")
    let mut fields : List (String × Json) := [("name", Json.str m), ("state", Json.str state),
      ("imports", toJson imps)]
    if let some j := job then
      let (n, task, e) := rebuildEstimate a noop m
      fields := fields ++ [("job", toJson j.id), ("duration_s", toJson (r3 j.dur)), ("max_rss_bytes", toJson j.rss),
        ("source", Json.str (if j.source.startsWith (projAbs ++ "/") then (j.source.drop (projAbs.length + 1)).toString else j.source)),
        ("rebuild", Json.mkObj [("jobs", toJson n), ("task_s", toJson (r3 task)), ("estimate_s", toJson (r3 e))])]
    out := out.push (Json.mkObj fields)
  -- modules of other packages, by state
  let mut other : Std.HashMap String Nat := {}
  for (m, v) in run.states.toList do
    unless seen.contains m || leanJob.contains m do
      other := other.insert (stateOf v) ((other.get? (stateOf v)).getD 0 + 1)
  for (m, _) in leanJob.toList do
    unless seen.contains m do other := other.insert "built" ((other.get? "built").getD 0 + 1)
  return (out, Json.mkObj (other.toList.map fun (k, v) => (k, toJson v)))

def buildCmd (usage : String) (argv : List String) : IO UInt32 := do
  let o ← match parseOpts {} argv with
    | .ok o => pure o
    | .error e => throw <| IO.userError s!"{e}\n\n{usage}"
  let dir : FilePath := ".lake" / "leanprof"
  let jsonPath : FilePath := o.json.getD (dir / "build.json").toString
  let writeHtml (r : Json) : IO Unit := do
    if let some h := o.html then
      IO.FS.writeFile h (htmlPage r)
      IO.println s!"HTML: {h}"
  if let some f := o.from_ then
    let r ← match Json.parse (← IO.FS.readFile f) with
      | .ok j => pure j
      | .error e => throw <| IO.userError s!"{f}: not JSON ({e})"
    unless jstr r "leanprof" == "build" do throw <| IO.userError s!"{f} is not a `leanprof build` report"
    IO.println (render r o.top)
    writeHtml r
    return 0
  unless (← ("lakefile.lean" : FilePath).pathExists) || (← ("lakefile.toml" : FilePath).pathExists) do
    throw <| IO.userError "run it in a Lake project (no lakefile.lean or lakefile.toml here)"
  let proj ← IO.currentDir
  let projAbs := (← IO.FS.realPath proj).toString
  -- absolute: Lake runs the shim's scripts in the worktree too
  let work := proj / dir / "build"
  IO.FS.createDirAll work
  let workers ← match o.workers with
    | some n => pure n
    | none => hardwareThreads
  let hw ← hardwareThreads
  let lean ← leanVersion proj
  -- the shim is copied before `--clean` can remove it with the build
  discard <| shimCommand work
  if o.clean then
    say o "--clean: removing .lake/build (the packages' builds stay)"
    if ← (".lake" / "build" : FilePath).pathExists then IO.FS.removeDirAll (".lake" / "build")
  let loadBefore ← loadNow
  let cmd := "lake build" ++ (if o.targets.isEmpty then "" else " " ++ " ".intercalate o.targets.toList)
  say o s!"running `{cmd}` with every toolchain program recorded"
  let run ← runLake proj work o.targets (!o.quiet)
  let loadAfter ← loadNow
  let a := analyze run.jobs workers hw
  -- a build with nothing to do: Lake's own time around any rebuild
  -- (three times, the fastest: the first after a clean build can take several
  -- times longer, with the dependencies' files not yet in the page cache)
  let noops ← if run.exitCode == 0 then do
      say o "timing a build with nothing to do (three times)"
      let mut rs : Array Run := #[]
      for _ in [0:3] do rs := rs.push (← runLake proj work o.targets false)
      pure rs
    else pure #[]
  let noop : Option Run := noops.foldl (fun b r => match b with
    | some x => if r.elapsed < x.elapsed then some r else some x
    | none => some r) none
  let noopS := match noop with
    | some r => r.elapsed
    | none => a.first + (run.elapsed - a.last)
  let graph ← Experiment.importGraph proj
  let (mods, other) := modulesJson a run noopS graph projAbs
  let mut direct : Std.HashMap String (Array String) := graph.foldl (init := {}) fun h (m, is) => h.insert m is
  -- modules outside the default layout (an executable's `srcDir`, another package): their headers
  for j in a.jobs do
    if j.kind == "lean" && !direct.contains j.name && !j.source.isEmpty then
      if let some src ← (try some <$> IO.FS.readFile j.source catch _ => pure none) then
        direct := direct.insert j.name (directImports src)
  let critical : Std.HashSet Nat := a.path.foldl (fun s (i, _) => s.insert i) {}
  let prof := a.prof
  let span := a.last - a.first
  let busy := a.jobs.foldl (fun s j => s + j.dur) 0
  let serMin := max 1.0 (0.02 * run.elapsed)
  let ser := (serialized prof a.first a.last serMin).map fun (s, e) =>
    let names := (a.jobs.filter fun j => j.start < e && j.stop > s).map fun j => s!"{j.kind} {j.name}"
    Json.mkObj [("start_s", toJson (r3 s)), ("end_s", toJson (r3 e)), ("running", toJson names)]
  let at_ := timeAt prof run.elapsed
  let prov ← Leanprof.Contract.provenance (← Leanprof.Contract.workload "lake build" o.targets)
    (Json.mkObj [("mode", Json.str "build"), ("clean", Json.bool o.clean), ("targets", toJson o.targets)])
  let mut report : List (String × Json) := [
    ("schema", Leanprof.Contract.schema "build"), ("version", toJson (1 : Nat)), ("leanprof", Json.str "build"),
    ("provenance", prov), ("command", Json.str cmd),
    ("targets", toJson o.targets), ("lean", Json.str lean), ("clean", Json.bool o.clean),
    ("exit_code", toJson run.exitCode.toNat), ("elapsed_s", toJson (r3 run.elapsed)),
    ("hardware_threads", toJson hw), ("workers", toJson workers),
    ("load", Json.mkObj [("before", toJson loadBefore), ("after", toJson loadAfter)]),
    ("measurement", Json.str ("lake build -v with LAKE_OVERRIDE_LEAN=true and LEAN_SYSROOT set to a copy of the toolchain " ++
      "whose programs run through leanprof-build-shim: each process's start, end, peak resident memory and CPU time; " ++
      "module states from Lake's -v job lines; dependencies from Lake's module setup files")),
    ("jobs", Json.arr (a.jobs.map fun j => jobJson j (critical.contains j.id))),
    ("modules", Json.arr mods), ("other_modules", other),
    ("critical_path", Json.mkObj [
      ("steps", Json.arr (a.path.map fun (i, w) => Json.mkObj [("job", toJson i), ("wait_s", toJson (r3 w))])),
      ("startup_s", toJson (r3 a.first)), ("tail_s", toJson (r3 (run.elapsed - a.last))),
      ("unlimited_workers_s", toJson (r3 a.cpmLen))]),
    ("parallelism", Json.mkObj [
      ("average", toJson (if span > 0 then (busy / span * 100).round / 100 else 0)),
      ("peak", toJson (prof.foldl (fun m p => max m p.2) 0)),
      ("time_at", Json.arr (at_.mapIdx fun i s => Json.mkObj [("running", toJson i), ("seconds", toJson (r3 s))])),
      ("serialized_min_s", toJson (r3 serMin)), ("serialized", Json.arr ser),
      ("profile", Json.arr (prof.map fun (t, n) => Json.arr #[toJson (r3 t), toJson n]))]),
    ("model", Json.mkObj [("workers", toJson workers), ("latency_s", toJson (r3 a.latency)),
      ("simulated_span_s", toJson (r3 a.simulated)), ("measured_span_s", toJson (r3 span)),
      ("cores", toJson a.cores), ("latency_free_s", toJson (r3 a.latencyFree)),
      ("simulated_alone_span_s", toJson (r3 a.simulatedShared)),
      ("noop_s", toJson (r3 noopS)), ("noop_runs_s", toJson (noops.map (r3 ·.elapsed))), ("noop_measured", Json.bool noop.isSome),
      ("noop_jobs", toJson ((noop.map (·.jobs.size)).getD 0))])]
  -- experiments in a worktree
  if (o.validate > 0 || o.imports > 0) && run.exitCode == 0 then
    let wt := work / "work"
    let exp := work / "exp"
    say o "experiments: making a git worktree of the working tree with a copy of the build"
    let wdir ← makeWork proj wt
    try
      let settle ← runLake wdir exp o.targets false
      if settle.exitCode != 0 then throw <| IO.userError s!"the worktree does not build:\n{tailOf ("\n".intercalate settle.lines.toList)}"
      unless settle.jobs.isEmpty do
        say o s!"the worktree rebuilt {settle.jobs.size} jobs from the copied build (rebuilt once, before measuring)"
      let roots := (mods.filter fun m => !(m.getObjVal? "job").toOption.isNone).map (jstr · "name")
      if o.validate > 0 then
        report := report ++ [("validation", ← validate o a noopS projAbs wdir exp roots)]
      if o.imports > 0 then
        let mut uses : Std.HashMap String (Array String × Nat) := {}
        for j in a.jobs do
          if j.kind == "lean" && j.output.endsWith ".olean" then
            if let some u ← readIlean ((j.output.dropEnd 6).toString ++ ".ilean") then uses := uses.insert j.name u
        let mut kept : Std.HashMap String (Array String) := {}
        for j in a.jobs do
          if j.kind == "lean" && !j.source.isEmpty then
            if let some src ← (try some <$> IO.FS.readFile j.source catch _ => pure none) then
              let k := keptImports src
              unless k.isEmpty do kept := kept.insert j.name k
        let (considered, sk, cands) := candidates a noopS direct roots uses kept
        -- the clean build's estimate, simulated with the workers, for those that may be tried
        let cands := (cands.extract 0 (3 * o.imports)).map fun c =>
          let ds := ((direct.get? c.m).getD #[]).filter (· != c.imp)
          let jobs' := withImports a direct c.m (ds ++ c.extra)
          { c with cleanGain := a.simulated - simulate (simOf jobs' ((List.range jobs'.size).toArray)) a.workers a.latency }
        let tried ← (cands.extract 0 o.imports |>.filter (fun c => c.cpGain + c.rebuildGain > 0)).mapIdxM fun i c =>
          tryCand o projAbs wdir exp a direct c settle.sorries i
        report := report ++ [("imports", Json.mkObj [("considered", toJson considered),
          ("needed", toJson sk.needed), ("redundant", toJson sk.redundant), ("reexport", toJson sk.reexport),
          ("no_ilean", toJson sk.noIlean), ("importers_use_it", toJson sk.importers), ("marked_keep", toJson sk.kept),
          ("candidates", Json.arr (cands.map candJson)), ("tried", Json.arr tried)])]
    finally
      unless o.keep do Experiment.removeWorktree wt
  let r := Json.mkObj report
  if let some p := (jsonPath : FilePath).parent then
    unless p.toString.isEmpty do IO.FS.createDirAll p
  IO.FS.writeFile jsonPath (r.pretty ++ "\n")
  IO.println (render r o.top)
  IO.println s!"\nJSON: {jsonPath}"
  writeHtml r
  if run.exitCode != 0 then
    let errs := run.lines.filter fun l => !l.startsWith "trace:" && (parseLakeLine l |>.map (·.1) |>.all (fun v => v != "Ran" && v != "Replayed"))
    IO.eprintln s!"leanprof build: `{cmd}` failed (exit code {run.exitCode}):\n{tailOf ("\n".intercalate errs.toList) 20}"
    return 1
  return 0

end Leanprof.Build
