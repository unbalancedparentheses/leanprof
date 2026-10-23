import Lean.Data.Json

/-!
# Live commands: `leanprof top`, `leanprof dump`, `leanprof mcp`

* `top`: a terminal view of a running program, refreshed like `top`, from
  the snapshots the runtime writes with `LEANPROF_LIVE` (see `c/live.inc.c`):
  hottest scopes, copy sites, allocation sites, tasks and waits, with rates
  since the previous frame. Plain ANSI escapes, no curses.
* `dump`: ask a program running with the flight recorder for a Perfetto
  trace of its last seconds (SIGUSR1).
* `mcp`: a Model Context Protocol server on stdio (newline-delimited
  JSON-RPC 2.0), so AI agents can run, sample and compare programs and read
  reports and live snapshots.

The commands that build or run programs call this executable's own `run`,
`sample`, ... subcommands, so this module does not depend on `LeanprofCli`.
-/

open Lean System

namespace LeanprofLive

/-! ## JSON and formatting -/

def num (j : Json) (k : String) : Float :=
  match j.getObjVal? k with
  | .ok (.num n) => n.toFloat
  | _ => 0

def str (j : Json) (k : String) : String := (j.getObjVal? k >>= Json.getStr?).toOption.getD ""
def arr (j : Json) (k : String) : Array Json := (j.getObjVal? k >>= Json.getArr?).toOption.getD #[]
def obj (j : Json) (k : String) : Json := (j.getObjVal? k).toOption.getD Json.null
def bool (j : Json) (k : String) : Bool := (j.getObjVal? k >>= Json.getBool?).toOption.getD false

/-- `x` with `d` decimals. -/
def fixed (x : Float) (d : Nat := 1) : String :=
  let p := 10 ^ d
  let v := (x.abs * p.toFloat).round.toUInt64.toNat
  let frac := toString (v % p)
  let fracS := if d == 0 then "" else "." ++ "".pushn '0' (d - frac.length) ++ frac
  s!"{if x < 0 && v > 0 then "-" else ""}{v / p}{fracS}"

def groupDigits (n : Nat) : String :=
  let s := (toString n).toList.reverse
  let rec go : List Char → Nat → List Char
    | [], _ => []
    | c :: cs, i => (if i > 0 && i % 3 == 0 then [',', c] else [c]) ++ go cs (i + 1)
  String.ofList (go s 0).reverse

def fmtCount (x : Float) : String :=
  if x > 0 && x < 10 && x != x.round then fixed x 1 else groupDigits x.abs.round.toUInt64.toNat

def fmtTime (ns : Float) : String :=
  if ns < 1e3 then s!"{fixed ns 0} ns"
  else if ns < 1e6 then s!"{fixed (ns / 1e3)} µs"
  else if ns < 1e9 then s!"{fixed (ns / 1e6)} ms"
  else s!"{fixed (ns / 1e9) 2} s"

def fmtBytes (b : Float) : String :=
  if b.abs < 1024 then s!"{fixed b 0} B"
  else if b.abs < 1048576 then s!"{fixed (b / 1024)} KiB"
  else if b.abs < 1073741824 then s!"{fixed (b / 1048576)} MiB"
  else s!"{fixed (b / 1073741824) 2} GiB"

/-- Time per second of wall time, as a share of one core. -/
def fmtShare (nsPerS : Float) : String := s!"{fixed (nsPerS / 1e7)}%"

def rpad (s : String) (n : Nat) : String := if s.length ≥ n then s else "".pushn ' ' (n - s.length) ++ s
def lpad (s : String) (n : Nat) : String := if s.length ≥ n then s else s.pushn ' ' (n - s.length)
def clip (s : String) (n : Nat) : String :=
  if s.length ≤ n then s else String.ofList (s.toList.take (n - 1)) ++ "…"

def trimWs (s : String) : String :=
  let ws (c : Char) := c == ' ' || c == '\n' || c == '\r' || c == '\t'
  String.ofList ((s.toList.dropWhile ws).reverse.dropWhile ws).reverse

def selfExe : IO String := return (← IO.appPath).toString

def tmpDir : IO String := do
  let d := (← IO.getEnv "TMPDIR").getD "/tmp"
  let d := if d.isEmpty then "/tmp" else d
  return String.ofList ((d.toList.reverse.dropWhile (· == '/')).reverse)

def readJson? (path : FilePath) : IO (Option Json) := do
  try
    match Json.parse (← IO.FS.readFile path) with
    | .ok j => return some j
    | .error _ => return none
  catch _ => return none

def pidAlive (pid : String) : IO Bool := do
  try
    let out ← IO.Process.output { cmd := "kill", args := #["-0", pid], stdin := .null }
    return out.exitCode == 0
  catch _ => return false

/-- The snapshot file of a program started with `LEANPROF_LIVE=1`. -/
def livePathFor (pid : String) : IO FilePath := do
  let p : FilePath := s!"{← tmpDir}/leanprof-{pid}.live.json"
  if ← p.pathExists then return p
  let q : FilePath := s!"/tmp/leanprof-{pid}.live.json"
  if ← q.pathExists then return q
  return p

/-! ## Rendering a snapshot -/

def rowKey (sec : String) (r : Json) : String :=
  s!"{sec}|{str r "name"}|{str r "where"}|{str r "scope"}|{str r "kind"}"

/-- Per-second rates of a row's counters since the previous snapshot (or the
program's start, with no previous one). -/
structure Rates where
  prev : Std.HashMap String Json := {}
  dt : Float     -- seconds between the snapshots
  hasPrev : Bool

def Rates.of (prev? : Option Json) (cur : Json) : Rates :=
  match prev? with
  | some p =>
    let dt := (num cur "ts_ns" - num p "ts_ns") / 1e9
    let m := ["scopes", "tasks", "copies", "allocations", "waits"].foldl (init := {}) fun m sec =>
      (arr p sec).foldl (fun m r => m.insert (rowKey sec r) r) m
    if dt > 0 then { prev := m, dt, hasPrev := true } else { dt := num cur "ts_ns" / 1e9, hasPrev := false }
  | none => { dt := num cur "ts_ns" / 1e9, hasPrev := false }

def Rates.rate (r : Rates) (sec : String) (row : Json) (k : String) : Float :=
  if r.dt <= 0 then 0 else
  let before := if r.hasPrev then (r.prev.get? (rowKey sec row)).map (num · k) |>.getD 0 else 0
  max 0 ((num row k - before) / r.dt)

/-- `name  (where)`. -/
def named (r : Json) : String :=
  let w := str r "where"
  if w.isEmpty then str r "name" else s!"{str r "name"}  ({w})"

structure Section where
  key : String
  title : String
  header : String
  sortBy : String          -- the counter rows are ordered by (its rate, then its total)
  line : Rates → Json → String

def sections : List Section := [
  { key := "scopes", title := "scopes (p50/p99 of the last 1-2 s, max and total of the whole run)", sortBy := "total_ns",
    header := s!"{rpad "calls/s" 10} {rpad "time/s" 8} {rpad "self/s" 8} {rpad "p50" 9} {rpad "p99" 9} {rpad "max" 9} {rpad "calls" 12} {rpad "total" 10}  scope  (where)",
    line := fun r s =>
      let rec_ := obj s "recent"
      let pct (k : String) := if num rec_ "calls" > 0 then fmtTime (num rec_ k) else "-"
      s!"{rpad (fmtCount (r.rate "scopes" s "calls")) 10} {rpad (fmtShare (r.rate "scopes" s "total_ns")) 8} {rpad (fmtShare (r.rate "scopes" s "self_ns")) 8} {rpad (pct "p50_ns") 9} {rpad (pct "p99_ns") 9} {rpad (fmtTime (num s "max_ns")) 9} {rpad (fmtCount (num s "calls")) 12} {rpad (fmtTime (num s "total_ns")) 10}  {named s}" },
  { key := "copies", title := "copies of shared values", sortBy := "copy_ns",
    header := s!"{rpad "copies/s" 10} {rpad "bytes/s" 11} {rpad "time/s" 8} {rpad "copies" 12} {rpad "bytes" 11}  {lpad "kind" 11} {lpad "in scope" 18} function  (where)",
    line := fun r c =>
      s!"{rpad (fmtCount (r.rate "copies" c "copies")) 10} {rpad (fmtBytes (r.rate "copies" c "bytes")) 11} {rpad (fmtShare (r.rate "copies" c "copy_ns")) 8} {rpad (fmtCount (num c "copies")) 12} {rpad (fmtBytes (num c "bytes")) 11}  {lpad (str c "kind") 11} {lpad (str c "scope") 18} {named c}" },
  { key := "allocations", title := "allocations", sortBy := "bytes",
    header := s!"{rpad "allocs/s" 10} {rpad "bytes/s" 11} {rpad "allocs" 12} {rpad "bytes" 11}  {lpad "in scope" 18} function  (where)",
    line := fun r a =>
      s!"{rpad (fmtCount (r.rate "allocations" a "allocs")) 10} {rpad (fmtBytes (r.rate "allocations" a "bytes")) 11} {rpad (fmtCount (num a "allocs")) 12} {rpad (fmtBytes (num a "bytes")) 11}  {lpad (str a "scope") 18} {named a}" },
  { key := "tasks", title := "tasks", sortBy := "run_ns",
    header := s!"{rpad "tasks/s" 10} {rpad "run/s" 8} {rpad "tasks" 12} {rpad "run" 10} {rpad "wait mean" 10}  spawned by",
    line := fun r t =>
      let n := num t "tasks"
      s!"{rpad (fmtCount (r.rate "tasks" t "tasks")) 10} {rpad (fmtShare (r.rate "tasks" t "run_ns")) 8} {rpad (fmtCount n) 12} {rpad (fmtTime (num t "run_ns")) 10} {rpad (fmtTime (num t "wait_ns" / (if n > 0 then n else 1))) 10}  {str t "name"}" },
  { key := "waits", title := "blocking waits", sortBy := "blocked_ns",
    header := s!"{rpad "waits/s" 10} {rpad "blocked/s" 9} {rpad "waits" 12} {rpad "blocked" 10}  {lpad "in scope" 18} function  (where)",
    line := fun r w =>
      s!"{rpad (fmtCount (r.rate "waits" w "waits")) 10} {rpad (fmtShare (r.rate "waits" w "blocked_ns")) 9} {rpad (fmtCount (num w "waits")) 12} {rpad (fmtTime (num w "blocked_ns")) 10}  {lpad (str w "scope") 18} {named w}" }]

/-- Rows of a section, busiest now first. -/
def sortedRows (r : Rates) (sec : Section) (cur : Json) : Array Json :=
  (arr cur sec.key).qsort fun a b =>
    let ra := r.rate sec.key a sec.sortBy
    let rb := r.rate sec.key b sec.sortBy
    if ra != rb then ra > rb else num a sec.sortBy > num b sec.sortBy

/-- One frame: a header, what each thread is inside now, and each non-empty
section, within `width` columns and about `height` lines. -/
def render (label : String) (prev? : Option Json) (cur : Json) (width height : Nat)
    (rowsPer : Option Nat := none) : Array String := Id.run do
  let r := Rates.of prev? cur
  let mut out : Array String := #[]
  let up := num cur "ts_ns"
  let state := if bool cur "exited" then "  (exited)" else ""
  out := out.push s!"leanprof top  {label}  pid {(num cur "pid").toUInt64}  up {fmtTime up}  threads {(num cur "threads").toUInt64}{state}"
  let mem := obj cur "memory"
  let cpu := obj cur "cpu"
  let cpuNs (j : Json) := num (obj j "cpu") "user_ns" + num (obj j "cpu") "sys_ns"
  let cores := match prev? with
    | some p => if r.hasPrev then (cpuNs cur - cpuNs p) / (r.dt * 1e9) else (cpuNs cur) / (up + 1)
    | none => (num cpu "user_ns" + num cpu "sys_ns") / (up + 1)
  let rssRate := match prev? with
    | some p => if r.hasPrev then (num mem "rss" - num (obj p "memory") "rss") / r.dt else 0
    | none => 0
  let sign := if rssRate >= 0 then "+" else "-"
  out := out.push s!"cpu {fixed cores 2} cores   memory {fmtBytes (num mem "rss")} resident ({sign}{fmtBytes rssRate.abs}/s), {fmtBytes (num mem "commit")} committed, peak {fmtBytes (num mem "peak_rss")}"
  match cur.getObjVal? "flight" with
  | .ok f@(.obj _) =>
    let slow := num f "slow_ms"
    let last := str f "last"
    out := out.push s!"flight recorder: last {fixed (num f "secs") 0} s kept{if slow > 0 then s!", dump on scopes over {fixed slow 0} ms" else ""}; {(num f "dumps").toUInt64} dumps{if last.isEmpty then s!" (to {str f "dir"})" else s!", last {last}"}"
  | _ => pure ()
  let stacks := arr cur "stacks"
  for s in stacks[0:min 4 stacks.size] do
    let frames := (arr s "frames").toList.map fun f => s!"{str f "name"} {fmtTime (num f "elapsed_ns")}"
    out := out.push s!"now  thread {(num s "thread").toUInt64}: {" > ".intercalate frames}"
  if stacks.size > 4 then out := out.push s!"     ({stacks.size - 4} more threads inside scopes)"
  let present := sections.filter fun sec => !(arr cur sec.key).isEmpty
  if present.isEmpty then
    out := out.push ""
    out := out.push "nothing recorded yet (mark code with profile!, or run with --auto)"
  -- share the remaining lines between the sections shown
  let free := if height > out.size + 3 * present.length then height - out.size - 3 * present.length else 3 * present.length
  let per := rowsPer.getD (max 3 (free / max 1 present.length))
  for sec in present do
    let rows := sortedRows r sec cur
    out := out.push ""
    out := out.push s!"{sec.title}{if rows.size > per then s!" ({per} of {rows.size})" else ""}"
    out := out.push sec.header
    for row in rows[0:min per rows.size] do
      out := out.push (sec.line r row)
  return out.map (clip · width)

/-! ## `leanprof top` -/

structure TopOpts where
  attach : Option String := none
  pid : Option String := none
  interval : Nat := 1000
  frames : Option Nat := none
  rows : Option Nat := none
  plain : Bool := false
  runFlags : Array String := #[]
  flight : Option String := none
  slowMs : Option String := none
  exe : Option String := none
  args : Array String := #[]

def topUsage : String :=
  "usage: leanprof top [--interval MS] [--rows N] [--frames N] [--plain] [--flight DIR] [--slow-ms MS]\n" ++
  "                    [--auto | --auto-all] [--allocs] [--counters] [--frees] [--core] [--no-deps] EXE [-- ARGS...]\n" ++
  "       leanprof top [OPTIONS] --attach FILE | --pid PID"

partial def parseTop (o : TopOpts) : List String → Except String TopOpts
  | [] => .ok o
  | "--attach" :: f :: rest => parseTop { o with attach := some f } rest
  | "--pid" :: p :: rest => parseTop { o with pid := some p } rest
  | "--interval" :: v :: rest => parseTop { o with interval := max 50 (v.toNat?.getD 1000) } rest
  | "--frames" :: v :: rest => parseTop { o with frames := v.toNat? } rest
  | "--rows" :: v :: rest => parseTop { o with rows := v.toNat? } rest
  | "--plain" :: rest => parseTop { o with plain := true } rest
  | "--flight" :: d :: rest => parseTop { o with flight := some d } rest
  | "--slow-ms" :: v :: rest => parseTop { o with slowMs := some v } rest
  | "--" :: rest => .ok { o with args := o.args ++ rest.toArray }
  | a :: rest =>
    if ["--auto", "--auto-all", "--allocs", "--counters", "--frees", "--core", "--no-deps"].contains a then
      parseTop { o with runFlags := o.runFlags.push a } rest
    else if a.startsWith "--" then .error s!"unknown option {a}\n{topUsage}"
    else if o.exe.isNone then parseTop { o with exe := some a } rest
    else parseTop { o with args := o.args.push a } rest

/-- Terminal size: `stty size` on the controlling terminal, else `$LINES`/`$COLUMNS`. -/
def termSize : IO (Nat × Nat) := do
  let fallback := do
    let h := ((← IO.getEnv "LINES").bind String.toNat?).getD 40
    let w := ((← IO.getEnv "COLUMNS").bind String.toNat?).getD 160
    return (h, w)
  try
    let out ← IO.Process.output { cmd := "sh", args := #["-c", "stty size < /dev/tty 2>/dev/null"], stdin := .null }
    match (trimWs out.stdout).splitOn " " with
    | [h, w] => match h.toNat?, w.toNat? with
      | some h, some w => if h > 0 && w > 0 then return (h, w) else fallback
      | _, _ => fallback
    | _ => fallback
  catch _ => fallback

def draw (ansi : Bool) (lines : Array String) : IO Unit := do
  let stdout ← IO.getStdout
  if ansi then
    stdout.putStr ("\x1b[H" ++ String.join (lines.toList.map (· ++ "\x1b[K\n")) ++ "\x1b[J")
  else
    stdout.putStr (String.join (lines.toList.map (· ++ "\n")) ++ "\n")
  stdout.flush

/-- The last `n` lines of a file. -/
def tailLines (path : FilePath) (n : Nat) : IO (List String) := do
  try
    let lines := ((← IO.FS.readFile path).splitOn "\n").filter (!·.isEmpty)
    return lines.drop (lines.length - n)
  catch _ => return []

/-- Redraw from `path` until `finished` says the program is gone; returns the
last snapshot. -/
def watch (o : TopOpts) (label : String) (path : FilePath) (finished : IO Bool)
    (waiting : IO (Array String)) : IO (Option Json × Float) := do
  let ansi := !o.plain && (← (← IO.getStdout).isTty)
  if ansi then (← IO.getStdout).putStr "\x1b[2J"
  let mut prev : Option Json := none   -- the snapshot the shown rates are relative to
  let mut last : Option Json := none
  let mut shown := 0
  let mut drawn : Float := -1          -- seq of the last snapshot drawn
  let mut waited := false
  repeat
    let done ← finished
    let snap ← readJson? path
    if let some s := snap then
      -- rates over the last frame: keep the previous snapshot unless it is the same one
      let fresh := match last with
        | some l => num l "seq" != num s "seq"
        | none => true
      if fresh then
        prev := last
        last := some s
      if o.frames.all (shown < ·) && !done then
        let (h, w) ← termSize
        draw ansi (render label prev s w (h - 1) o.rows)
        shown := shown + 1
        drawn := num s "seq"
        if o.attach.isSome || o.pid.isSome then
          if o.frames.any (shown ≥ ·) then return (last, drawn)
      if bool s "exited" then return (last, drawn)
    else if !waited || ansi then
      draw ansi (← waiting)
      waited := true
    if done then return (last, drawn)
    IO.sleep o.interval.toUInt32
  return (last, drawn)

def topCmd (argv : List String) : IO UInt32 := do
  let o ← IO.ofExcept (parseTop {} argv)
  let ansi := !o.plain && (← (← IO.getStdout).isTty)
  if let some p := o.attach.orElse fun _ => o.pid then
    let path ← if o.attach.isSome then pure (p : FilePath) else livePathFor p
    let pidOf : IO (Option String) := do
      if let some pid := o.pid then return some pid
      return (← readJson? path).map fun j => toString (num j "pid").toUInt64
    let finished : IO Bool := do
      match ← pidOf with
      | some pid => return !(← pidAlive pid)
      | none => return false
    let (last, _) ← watch o (if o.attach.isSome then p else s!"pid {p}") path finished
      (pure #[s!"leanprof top: waiting for {path} (start the program with LEANPROF_LIVE=1 or LEANPROF_LIVE={path})"])
    match last with
    | some s =>
      if !bool s "exited" && (← finished) then
        IO.eprintln s!"leanprof top: the program is gone; its last snapshot is shown"
      return 0
    | none =>
      IO.eprintln s!"leanprof top: no snapshot at {path}"
      return 1
  let some exe := o.exe | throw <| IO.userError topUsage
  let dir : FilePath := (← IO.currentDir) / ".lake" / "leanprof"
  IO.FS.createDirAll dir
  let live := dir / "live.json"
  let log := dir / "top.log"
  if ← live.pathExists then IO.FS.removeFile live
  let env := #[("LEANPROF_LIVE", some live.toString),
    ("LEANPROF_LIVE_MS", some (toString (min 250 o.interval))),
    ("LEANPROF_LIVE_SKIP_CHILD_OF", some (toString (← IO.Process.getPID))),
    ("LEANPROF_QUIET", some "1"), ("LEANPROF_TOP_LOG", some log.toString)] ++
    (if o.flight.isSome || o.slowMs.isSome then #[("LEANPROF_FLIGHT", some (o.flight.getD "1"))] else #[]) ++
    (if let some ms := o.slowMs then #[("LEANPROF_SLOW_MS", some ms)] else #[])
  let runArgs := #["run"] ++ o.runFlags ++ #[exe, "--"] ++ o.args
  -- `leanprof run` builds with probes, runs, and puts the normal build back;
  -- its output (and the program's) goes to the log, away from the view
  let self ← selfExe
  let shArgs := #["-c", "exec \"$0\" \"$@\" >\"$LEANPROF_TOP_LOG\" 2>&1", self] ++ runArgs
  let child ← IO.Process.spawn { cmd := "sh", args := shArgs, env }
  let code ← IO.mkRef (none : Option UInt32)
  let finished : IO Bool := do
    if (← code.get).isSome then return true
    let c ← child.tryWait
    code.set c
    return c.isSome
  let waiting : IO (Array String) := do
    let tail ← tailLines log 1
    return #[s!"leanprof top: building and starting {exe} (log: {log})", tail.headD ""]
  let (last, drawn) ← watch o exe live finished waiting
  -- the final snapshot, written at exit
  let rc ← match ← code.get with
    | some c => pure c
    | none => child.wait
  let final ← readJson? live
  let prev := if (final.map (num · "seq")) != (last.map (num · "seq")) then last else none
  if let some s := final then
    if num s "seq" != drawn then
      if ansi then (← IO.getStdout).putStr "\x1b[2J"
      let (h, w) ← termSize
      draw ansi (render exe prev s w (h - 8) o.rows)
  let out ← tailLines log 5
  unless out.isEmpty do
    IO.println s!"last lines of {log}:"
    for l in out do IO.println s!"  {l}"
  IO.println s!"exit code {rc}; report: .lake/leanprof/report.json"
  return rc

/-! ## `leanprof dump` -/

/-- `key value` lines of a program's flight marker. -/
def readMarker (path : FilePath) : IO (Std.HashMap String String) := do
  let text ← IO.FS.readFile path
  return text.splitOn "\n" |>.foldl (init := {}) fun m l =>
    match l.splitOn " " with
    | k :: v => m.insert k (" ".intercalate v)
    | [] => m

def markerPath (pid : String) : IO (Option FilePath) := do
  for d in [← tmpDir, "/tmp"] do
    let p : FilePath := s!"{d}/leanprof-{pid}.flight"
    if ← p.pathExists then return some p
  return none

/-- Signal `pid` to dump its flight recorder and wait for the trace; returns its path. -/
def dumpPid (pid : String) (timeoutMs : Nat := 10000) : IO String := do
  let some marker ← markerPath pid | throw <| IO.userError <|
    s!"process {pid} is not running with leanprof's flight recorder (no {← tmpDir}/leanprof-{pid}.flight): " ++
    "start it with LEANPROF_FLIGHT=1 (or LEANPROF_FLIGHT=DIR, LEANPROF_SLOW_MS=MS)"
  unless ← pidAlive pid do
    throw <| IO.userError s!"process {pid} is not running (stale {marker})"
  let before := ((← readMarker marker).get? "dumps" >>= String.toNat?).getD 0
  let out ← IO.Process.output { cmd := "kill", args := #["-USR1", pid], stdin := .null }
  if out.exitCode != 0 then throw <| IO.userError s!"kill -USR1 {pid} failed: {out.stderr}"
  let mut waited := 0
  while waited < timeoutMs do
    IO.sleep 50
    waited := waited + 50
    if ← marker.pathExists then
      let m ← readMarker marker
      if (m.get? "dumps" >>= String.toNat?).getD 0 > before then
        return m.getD "last" ""
  throw <| IO.userError s!"process {pid} wrote no trace within {timeoutMs / 1000} s"

def dumpCmd (argv : List String) : IO UInt32 := do
  let rec parse (timeout : Nat) : List String → Except String (Nat × Option String)
    | "--timeout" :: s :: rest => parse ((s.toNat?.getD 10) * 1000) rest
    | [pid] => .ok (timeout, some pid)
    | _ => .ok (timeout, none)
  let (timeout, some pid) ← IO.ofExcept (parse 10000 argv)
    | throw <| IO.userError "usage: leanprof dump [--timeout S] PID"
  let path ← dumpPid pid timeout
  IO.println s!"{path}\nopen it in https://ui.perfetto.dev"
  return 0

/-! ## Report summaries (for the MCP tools) -/

/-- The hottest rows of one section of a report or a live snapshot, with file:line. -/
def hotLines (j : Json) (kind : String) (limit : Nat) : Array String := Id.run do
  let live := num j "leanprof_live" > 0
  let w (r : Json) := let p := if live then str r "where" else
      (if (str r "pos").isEmpty then str r "where" else str r "pos")
    if p.isEmpty then "" else s!"  ({p})"
  let take (xs : Array Json) := xs[0:min limit xs.size].toArray
  match kind with
  | "scopes" =>
    let xs := take ((arr j "scopes").qsort fun a b => num a "total_ns" > num b "total_ns")
    xs.map fun s => s!"{fmtTime (num s "total_ns")} total, {fmtTime (num s "self_ns")} self, {fmtCount (num s "calls")} calls, p99 {fmtTime (num s "p99_ns")}: {str s "name"}{w s}"
  | "copies" =>
    let n (c : Json) := if live then num c "copies" else num c "shared" + num c "multi_threaded"
    let xs := take (((arr j "copies").filter (n · > 0)).qsort fun a b =>
      if num a "copy_ns" != num b "copy_ns" then num a "copy_ns" > num b "copy_ns" else num a "bytes" > num b "bytes")
    xs.map fun c => s!"{fmtCount (n c)} copies, {fmtBytes (num c "bytes")}, {fmtTime (num c "copy_ns")} [{str c "kind"}] in scope {str c "scope"}: {str c "function"}{str c (if live then "name" else "")}{w c}"
  | "allocations" =>
    let xs := take ((arr j "allocations").qsort fun a b => num a "bytes" > num b "bytes")
    xs.map fun a => s!"{fmtCount (num a "allocs")} allocations, {fmtBytes (num a "bytes")} in scope {str a "scope"}: {str a "function"}{str a (if live then "name" else "")}{w a}"
  | "tasks" =>
    let run := if live then "run_ns" else "run_sum_ns"
    let xs := take ((arr j "tasks").qsort fun a b => num a run > num b run)
    xs.map fun t => s!"{fmtCount (num t "tasks")} tasks, {fmtTime (num t run)} run, wait mean {fmtTime (num t "wait_ns" / max 1 (num t "tasks"))}: spawned by {str t (if live then "name" else "spawned_by")}"
  | "waits" =>
    let xs := take ((arr j "waits").qsort fun a b => num a "blocked_ns" > num b "blocked_ns")
    xs.map fun x => s!"{fmtCount (num x "waits")} waits, {fmtTime (num x "blocked_ns")} blocked in scope {str x "scope"}: {str x "function"}{str x (if live then "name" else "")}{w x}"
  | _ => #[s!"unknown kind {kind}: use scopes, copies, allocations, tasks or waits"]

def summarize (j : Json) (limit : Nat := 5) : String := Id.run do
  let mut out : Array String := #[]
  if bool j "elab" then
    out := out.push "compile-time report (leanprof elab): costliest lines"
    let xs := (arr j "scopes").qsort fun a b => num a "total_ns" > num b "total_ns"
    let unit := str j "unit"
    for s in xs[0:min (limit * 2) xs.size] do
      let v := num s "total_ns"
      out := out.push s!"  {if unit == "heartbeats" then s!"{fmtCount v} heartbeats" else fmtTime v}: {str s "name"}  ({str s "pos"})"
    return "\n".intercalate out.toList
  let live := num j "leanprof_live" > 0
  if live then
    out := out.push s!"live snapshot of pid {(num j "pid").toUInt64} at {fmtTime (num j "ts_ns")}{if bool j "exited" then " (exited)" else ""}"
  else
    out := out.push s!"wall {fmtTime (num j "wall_ns")}, leanprof overhead {fixed (num j "overhead_ns")} ns per scope (subtracted){if bool j "sampled" then ", sampled" else ""}"
  let mem := obj j "memory"
  if num mem "peak_rss" > 0 then
    out := out.push s!"peak memory {fmtBytes (num mem "peak_rss")} resident, {fmtBytes (num mem "peak_commit")} committed"
  for k in ["scopes", "copies", "allocations", "tasks", "waits"] do
    let ls := hotLines j k limit
    unless ls.isEmpty do
      out := out.push s!"{k}:"
      out := out ++ ls.map ("  " ++ ·)
  return "\n".intercalate out.toList


/-- Why each of the costliest findings of a report happens and what usually
fixes it, for an agent (or a person) deciding what to change. `filter`
keeps only rows whose name, function or scope contains it. -/
def explain (j : Json) (filter : String) (limit : Nat := 5) : String := Id.run do
  let live := num j "leanprof_live" > 0
  let has (r : Json) := filter.isEmpty || ["name", "function", "scope", "spawned_by"].any fun k =>
    ((str r k).splitOn filter).length > 1
  let pos (r : Json) := let p := if (str r "pos").isEmpty then str r "where" else str r "pos"
    if p.isEmpty then "" else s!" ({p})"
  let fnOf (r : Json) := if (str r "function").isEmpty then str r "name" else str r "function"
  let mut out : Array String := #[]
  let scopes := (arr j "scopes").qsort fun a b => num a "total_ns" > num b "total_ns"
  let scopeTotal (name : String) : Float :=
    (scopes.find? (str · "name" == name)).map (num · "total_ns") |>.getD 0
  -- copies
  let nc (c : Json) := if live then num c "copies" else num c "shared" + num c "multi_threaded"
  let copies := ((arr j "copies").filter fun c => nc c > 0 && has c).qsort fun a b => num a "copy_ns" > num b "copy_ns"
  for c in copies[0:min limit copies.size] do
    let n := nc c
    let share := scopeTotal (str c "scope")
    let pct := if share > 0 then s!", {fixed (num c "copy_ns" / share * 100)}% of scope {str c "scope"}" else ""
    out := out.push s!"COPY  {fmtCount n} copies of a shared {str c "kind"} in {fnOf c}{pos c}, inside scope {str c "scope"}: {fmtBytes (num c "bytes")} copied ({fmtBytes (num c "bytes" / max n 1)} each), {fmtTime (num c "copy_ns")}{pct}."
    if num c "multi_threaded" > 0 then
      out := out.push "  why: the value is marked multi-threaded (it was reachable from a Task, IO.asTask or a shared IO.Ref), so it is never updated in place. Fix: build it on one thread and share it only when finished, or give each task its own copy up front."
    if num c "shared" > 0 || live then
      out := out.push s!"  why: another reference to the {str c "kind"} was alive at the update (Lean updates in place only when the reference count is 1). Typical causes: an old version kept (history := history.push acc; acc := acc.push x), the value used again after the update, a field of a structure that is still referenced, or a let-bound copy. Fix: drop the extra reference before updating (swap it out with Array.empty / modify via a single owner), or keep indices instead of snapshots."
    if num c "bytes" / max n 1 > 4096 then
      out := out.push "  cost grows with the size: copying a large value on every update makes the loop quadratic."
  -- scopes
  let hot := scopes.filter has
  for s in hot[0:min limit hot.size] do
    let calls := num s "calls"
    let total := num s "total_ns"
    let self := num s "self_ns"
    let p50 := num s "p50_ns"
    let p99 := num s "p99_ns"
    let wall := num j "wall_ns"
    let pct := if wall > 0 then s!" ({fixed (total / wall * 100)}% of the run)" else ""
    out := out.push s!"SCOPE {str s "name"}{pos s}: {fmtTime total}{pct} in {fmtCount calls} calls, mean {fmtTime (total / max calls 1)}, self {fmtTime self}."
    if total > 0 && self / total < 0.2 then
      out := out.push s!"  most of its time ({fixed ((total - self) / total * 100)}%) is in nested scopes: look at its children."
    else if total > 0 && self / total > 0.8 then
      out := out.push "  its time is its own (not in nested scopes): mark its parts with profile! or use `leanprof run --auto` / `leanprof sample` to see inside."
    if p50 > 0 && p99 > 10 * p50 && calls >= 100 then
      out := out.push s!"  tail: p99 {fmtTime p99} is {fixed (p99 / p50) 0}x the median {fmtTime p50}: a few calls are much slower (an occasional slow path, a copy, a collection of frees); a flight-recorder dump (LEANPROF_SLOW_MS) shows one."
    let al := num s "allocs"
    if al > 0 && calls > 0 then
      out := out.push s!"  allocates {fixed (al / calls)} objects ({fmtBytes (num s "alloc_bytes" / calls)}) per call, including nested scopes."
  -- tasks
  let tasks := (arr j "tasks").filter has
  for t in tasks[0:min limit tasks.size] do
    let n := max (num t "tasks") 1
    let run := num t (if live then "run_ns" else "run_sum_ns") / n
    let wait := num t "wait_ns" / n
    let who := str t (if live then "name" else "spawned_by")
    out := out.push s!"TASKS {fmtCount n} spawned by {who}: run {fmtTime run} each, waited {fmtTime wait} to start."
    if wait > 2 * run && run > 0 then
      out := out.push "  they wait longer to start than they run: too fine-grained for the thread pool, or the pool is busy. Batch work into fewer, larger tasks."
    if run < 1e4 then
      out := out.push "  each runs for microseconds: if the spawning scope is slow, the work probably ran before the spawn (pure work in a do block is computed early: use IO.lazyPure)."
  -- failed reuse and closures (with --counters)
  let reuse := ((arr j "reuse").filter fun r => num r "failures" > 0 && has r).qsort fun a b => num a "failures" > num b "failures"
  for r in reuse[0:min limit reuse.size] do
    out := out.push s!"REUSE {str r "function"}{pos r}: {fmtCount (num r "failures")} of {fmtCount (num r "checks")} in-place constructor updates failed (the cell was shared), each allocating a new cell instead. Same causes and fixes as shared copies."
  let clo := ((arr j "closures").filter has).qsort fun a b => num a "applications" > num b "applications"
  for c in clo[0:min limit clo.size] do
    out := out.push s!"CLOSURE {fmtCount (num c "applications")} calls of {str c "target"} through a closure in {str c "function"}{pos c} ({fmtCount (num c "partial")} partial, {fmtCount (num c "over")} over-applied). A non-specialized higher-order call: @[specialize] or @[inline] on the higher-order function usually removes it."
  if out.isEmpty then
    out := out.push (if filter.isEmpty then "nothing notable in this report" else s!"nothing in this report matches {filter}")
  return "\n".intercalate out.toList

/-! ## `leanprof mcp` -/

def sProp (d : String) : Json := Json.mkObj [("type", Json.str "string"), ("description", Json.str d)]
def bProp (d : String) : Json := Json.mkObj [("type", Json.str "boolean"), ("description", Json.str d)]
def nProp (d : String) : Json := Json.mkObj [("type", Json.str "integer"), ("description", Json.str d)]
def aProp (d : String) : Json :=
  Json.mkObj [("type", Json.str "array"), ("items", Json.mkObj [("type", Json.str "string")]), ("description", Json.str d)]

def tool (name desc : String) (props : List (String × Json)) (required : List String) : Json :=
  Json.mkObj [("name", Json.str name), ("description", Json.str desc),
    ("inputSchema", Json.mkObj [("type", Json.str "object"),
      ("properties", Json.mkObj (props ++ [("cwd", sProp "project directory (default: the server's)")])),
      ("required", toJson required)])]

def exeProps : List (String × Json) :=
  [("executable", sProp "a lean_exe target of the Lake project"),
   ("args", aProp "arguments for the program")]

def tools : Array Json := #[
  tool "run" ("Build a Lake executable with leanprof's probes, run it and summarize the report: time per " ++
    "profile! scope or function, copies of shared arrays/strings with file:line, allocations, tasks, " ++
    "blocking waits, peak memory. The full JSON report is saved (default .lake/leanprof/report.json).")
    (exeProps ++ [("auto", bProp "time every function of the package (no profile! needed)"),
      ("allocs", bProp "count allocations per site"), ("counters", bProp "failed reuse and closure counters"),
      ("frees", bProp "time freeing cascades"), ("core", bProp "also probe Lean's own libraries"),
      ("json", sProp "where to save the report"), ("top", nProp "rows per section (default 8)")]) ["executable"],
  tool "sample" "Sample a Lake executable with samply (no probes): CPU time per Lean declaration with file:line."
    (exeProps ++ [("top", nProp "declarations shown (default 15)")]) ["executable"],
  tool "stat" "One-screen summary of a run: wall/CPU time, peak memory, allocations, copies, frees, tasks, top scopes."
    exeProps ["executable"],
  tool "elab" "Compile cost per line and declaration of Lean files (elaboration, kernel, compiler), optionally in exact heartbeats."
    [("files", aProp "Lean files"), ("heartbeats", bProp "count heartbeats (deterministic) instead of time"),
     ("top", nProp "lines shown")] ["files"],
  tool "measure" "Run an executable several times with probes into one summary, for judge."
    (exeProps ++ [("runs", nProp "runs (default 5)"), ("out", sProp "summary file (default .lake/leanprof/measure.json)")])
    ["executable"],
  tool "report" "Summarize a leanprof report (run, sample or elab JSON) or a live snapshot: the hottest rows of each section."
    [("path", sProp "report file (default .lake/leanprof/report.json)"), ("top", nProp "rows per section (default 5)")] [],
  tool "hot" "List the hottest scopes, copy sites, allocation sites, tasks or waits of a report or live snapshot, with file:line."
    [("kind", sProp "scopes, copies, allocations, tasks or waits"),
     ("path", sProp "report or live snapshot (default .lake/leanprof/report.json)"), ("limit", nProp "rows (default 10)")]
    ["kind"],
  tool "explain" ("Explain the costliest findings of a report or live snapshot: why each copy of a shared value " ++
    "happens and how to fix it, where a scope's time goes (own or nested), tail latency, allocations per call, " ++
    "task granularity, failed reuse and closure calls.")
    [("path", sProp "report or live snapshot (default .lake/leanprof/report.json)"),
     ("name", sProp "only findings whose function, scope or name contains this"), ("limit", nProp "findings per kind (default 5)")] [],
  tool "compare" "Compare two run reports: exact for copies and call counts, thresholded for time. Says whether anything regressed."
    [("base", sProp "baseline report"), ("new", sProp "new report"), ("threshold", nProp "time threshold in percent (default 10)")]
    ["base", "new"],
  tool "judge" "KEEP or DISCARD a change from two measure summaries (output, copies, heartbeats, time)."
    [("base", sProp "baseline measure summary"), ("new", sProp "new measure summary")] ["base", "new"],
  tool "live" ("What a running program is doing now: its latest live snapshot (it must run with LEANPROF_LIVE), " ++
    "with rates over a short interval and the scopes each thread is inside.")
    [("pid", sProp "process id (snapshot in $TMPDIR/leanprof-PID.live.json, from LEANPROF_LIVE=1)"),
     ("path", sProp "snapshot file (LEANPROF_LIVE=path)"), ("seconds", nProp "interval for rates (default 1)")] [],
  tool "dump" "Write a running program's flight recorder (LEANPROF_FLIGHT) to a Perfetto trace of its last seconds; returns the path."
    [("pid", sProp "process id")] ["pid"]]

def textResult (text : String) (isError : Bool := false) : Json :=
  let text := if text.length > 30000 then String.ofList (text.toList.take 30000) ++ "\n… (truncated)" else text
  Json.mkObj [("content", Json.arr #[Json.mkObj [("type", Json.str "text"), ("text", Json.str text)]]),
    ("isError", Json.bool isError)]

def argStr (a : Json) (k : String) : Option String := (a.getObjVal? k >>= Json.getStr?).toOption
def argBool (a : Json) (k : String) : Bool := (a.getObjVal? k >>= Json.getBool?).toOption.getD false
def argNat (a : Json) (k : String) : Option Nat := (a.getObjVal? k >>= Json.getNat?).toOption
def argStrs (a : Json) (k : String) : Array String :=
  ((a.getObjVal? k >>= Json.getArr?).toOption.getD #[]).filterMap (·.getStr?.toOption)

def tailText (s : String) (n : Nat) : String :=
  let ls := (s.splitOn "\n").filter (!·.isEmpty)
  "\n".intercalate (ls.drop (ls.length - n))

/-- Run one of this executable's own subcommands. -/
def runSelf (args : Array String) (cwd : Option String) (env : Array (String × Option String) := #[]) :
    IO (UInt32 × String × String) := do
  let out ← IO.Process.output { cmd := ← selfExe, args, cwd := cwd.map (⟨·⟩), env, stdin := .null }
  return (out.exitCode, out.stdout, out.stderr)

def inDir (cwd : Option String) (p : String) : FilePath :=
  match cwd with
  | some d => if p.startsWith "/" then p else (d : FilePath) / p
  | none => p

def callTool (name : String) (a : Json) : IO Json := do
  let cwd := argStr a "cwd"
  let exeArgs : IO (Array String) := do
    let some exe := argStr a "executable" | throw <| IO.userError "missing argument: executable"
    return #[exe, "--"] ++ argStrs a "args"
  match name with
  | "run" =>
    let json := argStr a "json" |>.getD ".lake/leanprof/report.json"
    let flags := [("auto", "--auto"), ("allocs", "--allocs"), ("counters", "--counters"), ("frees", "--frees"),
      ("core", "--core")].filterMap fun (k, f) => if argBool a k then some f else none
    let (rc, out, err) ← runSelf (#["run", "--json", json] ++ flags.toArray ++ (← exeArgs)) cwd
      #[("LEANPROF_QUIET", some "1")]
    let report ← readJson? (inDir cwd json)
    let body := match report with
      | some j => summarize j ((argNat a "top").getD 8)
      | none => "no report was written"
    return textResult s!"exit code {rc}; report {json}\n\n{body}\n\nlast output:\n{tailText (out ++ err) 15}" (report.isNone)
  | "sample" =>
    let (rc, out, err) ← runSelf (#["sample", "--top", toString ((argNat a "top").getD 15)] ++ (← exeArgs)) cwd
    return textResult s!"{out}\n{tailText err 10}" (rc != 0 && out.isEmpty)
  | "stat" =>
    let (rc, out, err) ← runSelf (#["stat"] ++ (← exeArgs)) cwd
    return textResult s!"{out}\n{tailText err 10}" (rc != 0 && out.isEmpty)
  | "elab" =>
    let files := argStrs a "files"
    if files.isEmpty then throw <| IO.userError "missing argument: files"
    let (rc, out, err) ← runSelf (#["elab"] ++ (if argBool a "heartbeats" then #["--heartbeats"] else #[]) ++
      #["--top", toString ((argNat a "top").getD 15)] ++ files) cwd
    return textResult s!"{out}\n{tailText err 10}" (rc != 0)
  | "measure" =>
    let outFile := argStr a "out" |>.getD ".lake/leanprof/measure.json"
    let (rc, out, err) ← runSelf (#["measure", "--runs", toString ((argNat a "runs").getD 5), "--out", outFile] ++
      (← exeArgs)) cwd
    return textResult s!"summary {outFile}\n{out}\n{tailText err 10}" (rc != 0)
  | "report" =>
    let path := argStr a "path" |>.getD ".lake/leanprof/report.json"
    match ← readJson? (inDir cwd path) with
    | some j => return textResult s!"{path}\n{summarize j ((argNat a "top").getD 5)}"
    | none => return textResult s!"cannot read a report at {path} (run the `run` tool first)" true
  | "hot" =>
    let path := argStr a "path" |>.getD ".lake/leanprof/report.json"
    let kind := argStr a "kind" |>.getD "scopes"
    match ← readJson? (inDir cwd path) with
    | some j =>
      let ls := hotLines j kind ((argNat a "limit").getD 10)
      return textResult (if ls.isEmpty then s!"no {kind} in {path}" else "\n".intercalate ls.toList)
    | none => return textResult s!"cannot read a report at {path}" true
  | "explain" =>
    let path := argStr a "path" |>.getD ".lake/leanprof/report.json"
    match ← readJson? (inDir cwd path) with
    | some j => return textResult (explain j ((argStr a "name").getD "") ((argNat a "limit").getD 5))
    | none => return textResult s!"cannot read a report at {path}" true
  | "compare" =>
    let (some b, some n) := (argStr a "base", argStr a "new") | throw <| IO.userError "missing argument: base or new"
    let thr := (argNat a "threshold").map (#["--threshold", toString ·]) |>.getD #[]
    let (rc, out, err) ← runSelf (#["compare"] ++ thr ++ #[b, n]) cwd
    let verdict := if rc == 0 then "no regressions" else if rc == 1 then "REGRESSION" else "error"
    return textResult s!"{verdict}\n{out}{err}" (rc > 1)
  | "judge" =>
    let (some b, some n) := (argStr a "base", argStr a "new") | throw <| IO.userError "missing argument: base or new"
    let (rc, out, err) ← runSelf #["judge", b, n] cwd
    return textResult s!"{out}{err}" (rc > 1)
  | "live" =>
    let path ← match argStr a "path", argStr a "pid" with
      | some p, _ => pure (inDir cwd p)
      | none, some pid => livePathFor pid
      | none, none => throw <| IO.userError "give pid or path"
    let some first ← readJson? path
      | return textResult s!"no live snapshot at {path} (start the program with LEANPROF_LIVE=1)" true
    if !bool first "exited" then IO.sleep ((argNat a "seconds").getD 1 * 1000).toUInt32
    let cur := (← readJson? path).getD first
    let prev := if num cur "seq" != num first "seq" then some first else none
    return textResult ("\n".intercalate (render path.toString prev cur 220 60 (some 10)).toList)
  | "dump" =>
    let some pid := argStr a "pid" | throw <| IO.userError "missing argument: pid"
    let p ← dumpPid pid
    return textResult s!"wrote {p} (Chrome trace format: open in https://ui.perfetto.dev)"
  | _ => throw <| IO.userError s!"unknown tool {name}"

def protocolVersions : List String := ["2025-06-18", "2025-03-26", "2024-11-05"]

def rpcError (id : Json) (code : Int) (msg : String) : Json :=
  Json.mkObj [("jsonrpc", Json.str "2.0"), ("id", id),
    ("error", Json.mkObj [("code", toJson code), ("message", Json.str msg)])]

def rpcResult (id : Json) (r : Json) : Json := Json.mkObj [("jsonrpc", Json.str "2.0"), ("id", id), ("result", r)]

/-- The answer to one message, or none for a notification. -/
def handle (msg : Json) : IO (Option Json) := do
  let id? := (msg.getObjVal? "id").toOption
  let method := str msg "method"
  let params := obj msg "params"
  let some id := id? | return none    -- notifications (initialized, cancelled) need no answer
  match method with
  | "initialize" =>
    let asked := str params "protocolVersion"
    let v := if protocolVersions.contains asked then asked else protocolVersions.head!
    return some <| rpcResult id <| Json.mkObj [("protocolVersion", Json.str v),
      ("capabilities", Json.mkObj [("tools", Json.mkObj [])]),
      ("serverInfo", Json.mkObj [("name", Json.str "leanprof"), ("version", Json.str "0.1.0")]),
      ("instructions", Json.str ("leanprof profiles compiled Lean 4 programs. Run tools from the Lake project " ++
        "directory (or pass cwd). `run` builds with probes and summarizes; `hot` and `report` read the saved " ++
        "report; `compare` and `judge` decide whether a change regressed; `live` and `dump` look at a running " ++
        "program started with LEANPROF_LIVE / LEANPROF_FLIGHT."))]
  | "ping" => return some (rpcResult id (Json.mkObj []))
  | "tools/list" => return some (rpcResult id (Json.mkObj [("tools", Json.arr tools)]))
  | "tools/call" =>
    let name := str params "name"
    unless tools.any (str · "name" == name) do
      return some (rpcError id (-32602) s!"unknown tool: {name}")
    let r ← try callTool name (obj params "arguments") catch e => pure (textResult s!"leanprof: {e}" true)
    return some (rpcResult id r)
  | _ => return some (rpcError id (-32601) s!"method not found: {method}")

partial def mcpCmd (_argv : List String) : IO UInt32 := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  let rec loop : IO Unit := do
    let line ← stdin.getLine
    if line.isEmpty then return   -- end of input
    let line := trimWs line
    unless line.isEmpty do
      let reply ← match Json.parse line with
        | .error e => pure (some (rpcError Json.null (-32700) s!"parse error: {e}"))
        | .ok msg => handle msg
      if let some r := reply then
        stdout.putStrLn r.compress
        stdout.flush
    loop
  loop
  return 0

end LeanprofLive
