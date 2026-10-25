import Lean.Data.Json
import Leanprof.Core
import LeanprofHtml.Assets

/-!
# `leanprof html`: one self-contained page

Reads reports (`report.json` from `run` or `sample`, `elab.json` from `elab`,
`measure.json` from `measure`) and writes one HTML file that needs no network:
summary, flame graph, sortable tables, the source lines each report mentions
with the editor's hints, and a base-against-new comparison when given two
reports of a kind.

The page is data plus a fixed script (`LeanprofHtml/Assets.lean`). This file
gathers the data: the reports as they are, a call tree for the flame graph
(from samply's profile next to a sampled report, or from a `--trace`
timeline), and the source lines around every `file:line` in the reports, read
from the project now.
-/

open Lean System

namespace LeanprofHtml

def str (j : Json) (k : String) : String := (j.getObjVal? k >>= Json.getStr?).toOption.getD ""
def arr (j : Json) (k : String) : Array Json := (j.getObjVal? k >>= Json.getArr?).toOption.getD #[]
def natAt (a : Array Json) (i : Nat) : Option Nat := a[i]? >>= fun x => x.getNat?.toOption
def numOf : Json → Option Float
  | .num n => some n.toFloat
  | _ => none
def flag (j : Json) (k : String) : Bool := (j.getObjVal? k >>= Json.getBool?).toOption.getD false

/-! ## Call trees -/

/-- A node of a call tree; `self` is what was spent in it and in nothing below. -/
structure Node where
  name : String
  self : Float := 0
  kids : Std.HashMap String Nat := {}
  deriving Inhabited

structure Tree where
  nodes : Array Node := #[{ name := "all" }]

/-- The child `name` of node `p`, created if new. -/
def Tree.child (t : Tree) (p : Nat) (name : String) : Tree × Nat :=
  match t.nodes[p]!.kids.get? name with
  | some i => (t, i)
  | none =>
    let i := t.nodes.size
    let nodes := t.nodes.push { name }
    ({ nodes := nodes.modify p fun n => { n with kids := n.kids.insert name i } }, i)

def Tree.addSelf (t : Tree) (i : Nat) (w : Float) : Tree :=
  { nodes := t.nodes.modify i fun n => { n with self := n.self + w } }

/-- Inclusive value of every node (children have larger indices than parents). -/
def Tree.totals (t : Tree) : Array Float := Id.run do
  let mut v := t.nodes.map (·.self)
  for i' in [0:t.nodes.size] do
    let i := t.nodes.size - 1 - i'
    for (_, k) in t.nodes[i]!.kids.toList do
      v := v.set! i (v[i]! + v[k]!)
  return v

/-- The tree as `{n, v, p?, c?}` (name, inclusive value, `file:line`,
children by value), without nodes below `minFrac` of the whole. -/
partial def Tree.toJson (t : Tree) (pos : String → Option String) (minFrac : Float := 0.0005) : Json :=
  let v := t.totals
  let minV := v[0]! * minFrac
  let rec go (i : Nat) (depth : Nat) : Json :=
    let n := t.nodes[i]!
    let kids := (n.kids.toArray.filter fun (_, k) => v[k]! ≥ minV && v[k]! > 0).qsort (fun a b => v[a.2]! > v[b.2]!)
    let fields := [("n", Json.str n.name), ("v", Lean.toJson v[i]!)] ++
      (match pos n.name with | some p => [("p", Json.str p)] | none => []) ++
      (if kids.isEmpty || depth > 256 then [] else [("c", Json.arr (kids.map (go ·.2 (depth + 1))))])
    Json.mkObj fields
  go 0 0

/-! ## samply's profile (as `leanprof sample` reads it) -/

/-- Symbols defined in `bin`, as `nm` lists them (Mach-O's leading `_` removed). -/
def binarySymbols (bin : FilePath) : IO (Array String) := do
  let out ← IO.Process.output { cmd := "nm", args := #[bin.toString] }
  let mut syms := #[]
  for line in out.stdout.splitOn "\n" do
    match (line.splitOn " ").filter (· != "") with
    | [_, _, name] | [_, name] =>
      syms := syms.push (if System.Platform.isOSX && name.startsWith "_" then (name.drop 1).toString else name)
    | _ => pure ()
  return syms

def libSymbols (lib : Json) (strings : Array String) : Array (Nat × Nat × String) := Id.run do
  let mut v := #[]
  for e in arr lib "symbol_table" do
    let get (k : String) := (e.getObjVal? k >>= Json.getNat?).toOption.getD 0
    v := v.push (get "rva", get "rva" + get "size", strings[get "symbol"]?.getD "?")
  return v.qsort (·.1 < ·.1)

def lookupSym (tbl : Array (Nat × Nat × String)) (addr : Nat) : Option String := Id.run do
  let mut lo := 0
  let mut hi := tbl.size
  while lo < hi do
    let mid := (lo + hi) / 2
    if tbl[mid]!.1 ≤ addr then lo := mid + 1 else hi := mid
  if lo == 0 then return none
  let (s, e, n) := tbl[lo - 1]!
  if s ≤ addr && addr < e then some n else none

/-- A C name of compiled Lean code, not yet turned into a Lean name. -/
def mangled (raw : String) : Bool :=
  let r := if raw.startsWith "_" then (raw.drop 1).toString else raw
  r.startsWith "l_" || r.startsWith "lp_"

/-- The sampled call tree of samply's profile `prof` (with its `.syms.json`),
in nanoseconds of CPU, for the binary `exe`. Names are those `leanprof sample`
shows; it rewrites the symbol file to Lean names, and raw names are
demangled here. -/
def sampledTree (prof : FilePath) (exe : String) : IO Tree := do
  let profile ← IO.ofExcept (Json.parse (← IO.FS.readFile prof))
  let syms ← IO.ofExcept (Json.parse (← IO.FS.readFile (prof.withExtension "syms.json")))
  let strings := (arr syms "string_table").map fun j => j.getStr?.toOption.getD "?"
  let libsMeta := arr profile "libs"
  let symData := arr syms "data"
  let mut tables : Array (Array (Nat × Nat × String)) := #[]
  let mut isMain : Array Bool := #[]
  for l in libsMeta do
    let dn := str l "debugName"
    tables := tables.push ((symData.find? (str · "debug_name" == dn)).map (libSymbols · strings) |>.getD #[])
    isMain := isMain.push (dn == exe)
  let threads := arr profile "threads"
  let weighty := threads.filter fun t => !(arr ((t.getObjVal? "samples").toOption.getD Json.null) "stack").isEmpty
  let mut tree : Tree := { nodes := #[{ name := "all samples" }] }
  for t in threads do
    let some samples := (t.getObjVal? "samples").toOption | continue
    let stacks := arr samples "stack"
    if stacks.isEmpty then continue
    let deltas := arr samples "threadCPUDelta"
    let get (k : String) := (t.getObjVal? k).toOption.getD Json.null
    let (st, ft, fu, rt) := (get "stackTable", get "frameTable", get "funcTable", get "resourceTable")
    let (parents, frameOf, addrs, funcOf, resOf, libOf) :=
      (arr st "prefix", arr st "frame", arr ft "address", arr ft "func", arr fu "resource", arr rt "lib")
    let frameName : Array String := (List.range addrs.size).toArray.map fun i =>
      let addr := (natAt addrs i).getD 0
      let lib := (natAt funcOf i >>= natAt resOf >>= natAt libOf).getD 0
      let raw := (tables[lib]? >>= (lookupSym · addr)).getD s!"0x{String.ofList (Nat.toDigits 16 addr)}"
      if isMain[lib]?.getD false then (if mangled raw then Leanprof.demangle raw else raw)
      else if raw.startsWith "[" then raw
      else s!"[{str (libsMeta[lib]?.getD Json.null) "name"}] {raw}"
    -- one top-level node per thread when there are several
    let (tree', top) := if weighty.size > 1 then tree.child 0 (str t "name") else (tree, 0)
    tree := tree'
    let mut nodeOf : Array Nat := #[]
    for i in [0:parents.size] do
      let p := (natAt parents i >>= (nodeOf[·]?)).getD top
      let (tree', n) := tree.child p (frameName[(natAt frameOf i).getD 0]?.getD "?")
      tree := tree'
      nodeOf := nodeOf.push n
    for i in [0:stacks.size] do
      let some s := natAt stacks i | continue
      let w := (deltas[i]? >>= numOf).getD 1000
      if w == 0 then continue
      tree := tree.addSelf (nodeOf[s]?.getD top) (w * 1000)
  return tree

/-- The newest samply profile (`EXE.json` with `EXE.syms.json`) in `dir`. -/
def findProfile (dir : FilePath) : IO (Option FilePath) := do
  unless ← dir.isDir do return none
  let mut best : Option (FilePath × IO.FS.SystemTime) := none
  for e in ← dir.readDir do
    unless e.fileName.endsWith ".syms.json" do continue
    let p := dir / ((e.fileName.dropEnd ".syms.json".length).toString ++ ".json")
    unless ← p.pathExists do continue
    let m := (← p.metadata).modified
    if best.all (fun (_, t) => t < m) then best := some (p, m)
  return best.map (·.1)

/-- The scope tree of a Perfetto timeline written by `--trace` / `LEANPROF_TRACE`. -/
def traceTree (path : FilePath) : IO Tree := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  let mut tree : Tree := { nodes := #[{ name := "all scopes" }] }
  -- per thread: open (node, start, time in children)
  let mut open_ : Std.HashMap Nat (Array (Nat × Float × Float)) := {}
  let mut threadNode : Std.HashMap Nat Nat := {}
  let events := arr j "traceEvents"
  let tids := (events.filterMap fun e => if str e "ph" == "B" then (e.getObjVal? "tid" >>= Json.getNat?).toOption else none)
  let several := (tids.foldl (fun (s : Std.HashSet Nat) t => s.insert t) {}).size > 1
  for e in events do
    let ph := str e "ph"
    unless ph == "B" || ph == "E" do continue
    let tid := (e.getObjVal? "tid" >>= Json.getNat?).toOption.getD 0
    let ts := ((e.getObjVal? "ts").toOption >>= numOf).getD 0 * 1000
    let stack := open_.getD tid #[]
    if ph == "B" then
      let root ← match threadNode.get? tid with
        | some n => pure n
        | none => do
          let (t, n) := if several then tree.child 0 s!"thread {tid}" else (tree, 0)
          tree := t
          threadNode := threadNode.insert tid n
          pure n
      let parent := (stack.back?.map (·.1)).getD root
      let (t, n) := tree.child parent (str e "name")
      tree := t
      open_ := open_.insert tid (stack.push (n, ts, 0))
    else
      let some (n, t0, inKids) := stack.back? | continue
      let dur := max 0 (ts - t0)
      tree := tree.addSelf n (max 0 (dur - inKids))
      let stack := stack.pop
      open_ := open_.insert tid (match stack.back? with
        | some (p, pt, pk) => stack.pop.push (p, pt, pk + dur)
        | none => stack)
  return tree

/-! ## Source lines -/

def posKeys : List String := ["pos", "where", "target_where", "first_at"]

/-- `File.lean:12` as (file, line). -/
def parsePos (s : String) : Option (String × Nat) :=
  match s.splitOn ":" with
  | [f, l] => if f.endsWith ".lean" then l.toNat?.map (f, ·) else none
  | _ => none

partial def collectPos (j : Json) (acc : Array String) : Array String :=
  match j with
  | .obj kvs => kvs.toList.foldl (init := acc) fun acc (k, v) =>
      match v with
      | .str s => if posKeys.contains k && (parsePos s).isSome then acc.push s else acc
      | _ => collectPos v acc
  | .arr a => a.foldl (fun acc x => collectPos x acc) acc
  | _ => acc

/-- The lines within `context` of each position, per file: `{file: {line: text}}`,
for files found under the current directory. Reports list the costliest
first; past `limit` positions the rest have no source, so the page stays small. -/
def sources (positions : Array String) (context : Nat) (limit : Nat := 1500) : IO Json := do
  let mut want : Std.HashMap String (Std.HashSet Nat) := {}
  let mut seen : Std.HashSet String := {}
  for p in positions do
    if seen.size ≥ limit then break
    if seen.contains p then continue
    if let some (f, l) := parsePos p then
      seen := seen.insert p
      want := want.insert f ((want.getD f {}).insert l)
  let mut files : Array (String × Json) := #[]
  for (f, ls) in want.toArray.qsort (·.1 < ·.1) do
    unless ← (f : FilePath).pathExists do continue
    let text ← try IO.FS.readFile f catch _ => continue
    let lines := (text.splitOn "\n").toArray
    let mut keep : Std.HashSet Nat := {}
    for l in ls.toList do
      for k in [l - min l context:l + context + 1] do
        if k ≥ 1 && k ≤ lines.size then keep := keep.insert k
    let out := (keep.toArray.qsort (· < ·)).map fun k =>
      let t := lines[k - 1]!
      (toString k, Json.str (if t.length > 400 then String.ofList (t.toList.take 400) ++ "…" else t))
    files := files.push (f, Json.mkObj out.toList)
  return Json.mkObj files.toList

/-- `j` without the field `k` in any object inside it. -/
partial def dropField (k : String) : Json → Json
  | .obj kvs => Json.mkObj ((kvs.erase k).toList.map fun (k', v) => (k', dropField k v))
  | .arr a => .arr (a.map (dropField k))
  | x => x

/-! ## The command -/

structure Opts where
  out : String := ".lake/leanprof/report.html"
  trace : Option String := none
  profile : Option String := none
  threshold : Float := 10
  minMs : Float := 1
  context : Nat := 3
  title : Option String := none
  /-- How many of an elab report's term and tactic ranges the page keeps (the costliest). -/
  ranges : Nat := 2000
  files : Array String := #[]

partial def parse (o : Opts) : List String → Except String Opts
  | [] => .ok o
  | "-o" :: f :: rest | "--out" :: f :: rest => parse { o with out := f } rest
  | "--trace" :: f :: rest => parse { o with trace := some f } rest
  | "--profile" :: f :: rest => parse { o with profile := some f } rest
  | "--threshold" :: v :: rest => parse { o with threshold := v.toNat!.toFloat } rest
  | "--min-ms" :: v :: rest => parse { o with minMs := v.toNat!.toFloat } rest
  | "--context" :: v :: rest => parse { o with context := v.toNat! } rest
  | "--title" :: v :: rest => parse { o with title := some v } rest
  | "--ranges" :: v :: rest => parse { o with ranges := v.toNat! } rest
  | a :: rest =>
    if a.startsWith "-" then .error s!"unknown option {a}" else parse { o with files := o.files.push a } rest

/-- `run` (also `sample`), `elab` or `measure`. -/
def kindOf (j : Json) : String :=
  if str j "leanprof" == "measure" then "measure"
  else if flag j "elab" then "elab"
  else if flag j "sampled" then "sample"
  else "run"

def kindClass (k : String) : String := if k == "sample" then "run" else k

/-- Write the page for `argv`'s reports; `usage` is this command's help. -/
def htmlCmd (usage : String) (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parse {} argv)
  let dir : FilePath := ".lake" / "leanprof"
  let files ← if !o.files.isEmpty then pure o.files else
    (#["report.json", "elab.json", "measure.json"] : Array String).filterMapM fun (f : String) => do
      return if ← (dir / f).pathExists then some (dir / f).toString else none
  if files.isEmpty then
    throw <| IO.userError s!"no reports in {dir}: run `leanprof run`, `sample` or `elab` first, or name them\n\n{usage}"
  -- base and new: the first and second report of a kind
  let mut loaded : Array (String × String × Json) := #[]
  for f in files do
    let j ← match Json.parse (← IO.FS.readFile f) with
      | .ok j => pure j
      | .error e => throw <| IO.userError s!"{f}: not JSON ({e})"
    loaded := loaded.push (f, kindOf j, j)
  let mut reports : Array Json := #[]
  let mut positions : Array String := #[]
  for i in [0:loaded.size] do
    let (f, kind, j) := loaded[i]!
    let same := loaded.filter (kindClass ·.2.1 == kindClass kind)
    if same.size > 2 then
      throw <| IO.userError s!"{same.size} {kindClass kind} reports given: at most two of a kind (base and new)"
    let role := if same.size == 1 then "only" else if same[0]!.1 == f then "base" else "new"
    positions := collectPos j positions
    -- a base is only compared: without the operations behind each line, it is smaller
    let j := if role == "base" && kind == "elab" then
        j.setObjVal! "scopes" (Json.arr <| (arr j "scopes").map fun
          | .obj kvs => .obj (kvs.erase "top")
          | x => x)
      else j
    -- what the page does not show: where each definition's file is on this machine (for the
    -- editor), and tactics by line when the report has them by exact range
    let j := if kind == "elab" then
        let j := dropField "path" j
        if flag j "exact_ranges" then j.setObjVal! "tactics" (Json.arr #[]) else j
      else j
    -- the costliest source ranges (an elab report lists up to 20,000)
    let rangesTotal := (arr j "ranges").size
    let j := if kind == "elab" && rangesTotal > o.ranges then
        j.setObjVal! "ranges" (Json.arr ((arr j "ranges").extract 0 o.ranges)) else j
    let mut entry : List (String × Json) := [("path", Json.str f), ("kind", Json.str kind),
      ("role", Json.str role), ("data", j)] ++ (if kind == "elab" then [("ranges_total", toJson rangesTotal)] else [])
    -- a call tree for the flame graph, for the report shown (not a base)
    if role != "base" then
      let pos : Std.HashMap String String := (arr j "scopes").foldl (init := {}) fun m s =>
        if (str s "pos").isEmpty || kind == "elab" then m else m.insert (str s "name") (str s "pos")
      if kind == "sample" then
        let prof ← match o.profile with
          | some p => pure (some (p : FilePath))
          | none => findProfile (((f : FilePath).parent).getD ".")
        if let some prof := prof then
          try
            let exe := (prof.fileStem).getD ""
            let bin := (".lake" : FilePath) / "build" / "bin" / exe
            let haveBin ← bin.pathExists
            if haveBin then Leanprof.setSymbols (← binarySymbols bin)
            let tree ← sampledTree prof exe
            let mut posOf := pos
            if haveBin then
              for n in tree.nodes do
                if !posOf.contains n.name && !n.name.startsWith "[" then
                  let w ← Leanprof.whereIs n.name
                  if !w.isEmpty then posOf := posOf.insert n.name w
            let t := tree.toJson posOf.get?
            positions := collectPos t positions
            entry := entry ++ [("flame", t), ("flame_from", Json.str prof.toString)]
          catch e => IO.eprintln s!"leanprof: cannot read samply's profile {prof}: {e}"
      else if kind == "run" then
        if let some tr := o.trace then
          let t := (← traceTree tr).toJson pos.get?
          entry := entry ++ [("flame", t), ("flame_from", Json.str tr)]
    reports := reports.push (Json.mkObj entry)
  let project := ((← IO.currentDir).fileName).getD "project"
  let data := Json.mkObj [("project", Json.str project), ("title", Json.str (o.title.getD s!"leanprof · {project}")),
    ("threshold", toJson o.threshold), ("min_ms", toJson o.minMs),
    ("reports", Json.arr reports), ("sources", ← sources positions o.context)]
  let page := LeanprofHtml.page (o.title.getD s!"leanprof: {project}") data.compress
  if let some d := (o.out : FilePath).parent then
    if !d.toString.isEmpty then IO.FS.createDirAll d
  IO.FS.writeFile o.out page
  IO.println s!"leanprof: wrote {o.out} ({page.utf8ByteSize / 1024} KiB, {files.size} report{if files.size == 1 then "" else "s"}: {", ".intercalate files.toList})"
  return 0

end LeanprofHtml
