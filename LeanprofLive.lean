import Lean.Data.Json
import Leanprof.Contract

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

/-- A process id as `kill` must receive it: digits only, not 0. Anything else
(`-1`, `0`, a path) would signal every process or a process group, or name a
file outside the temporary directory. -/
def checkPid (pid : String) : IO Unit := do
  unless !pid.isEmpty && pid.all Char.isDigit && pid.any (· != '0') do
    throw <| IO.userError s!"not a process id: {pid}"

/-- The snapshot file of a program started with `LEANPROF_LIVE=1`. -/
def livePathFor (pid : String) : IO FilePath := do
  checkPid pid
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

/-- "N sites that copied only empty or tiny values, M copies". -/
def tinySummary (tiny : Array Json) : String :=
  let copies := tiny.foldl (fun a c => a + num c "copies") 0
  s!"{tiny.size} site{if tiny.size == 1 then "" else "s"} copying only empty or tiny values, {fmtCount copies} copies"

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
  let rssRate : Float := match prev? with
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
    let all := sortedRows r sec cur
    -- copies of empty or tiny values (`tiny`), summarized in one line as
    -- `run` and the MCP tools do: listed, they push out the copies worth fixing
    let tiny := all.filter (bool · "tiny")
    let rows := all.filter (!bool · "tiny")
    out := out.push ""
    out := out.push s!"{sec.title}{if rows.size > per then s!" ({per} of {rows.size})" else ""}"
    if rows.isEmpty then
      out := out.push s!"({tinySummary tiny}; LEANPROF_ALL_COPIES=1 lists them)"
      continue
    out := out.push sec.header
    for row in rows[0:min per rows.size] do
      out := out.push (sec.line r row)
    unless tiny.isEmpty do out := out.push s!"(and {tinySummary tiny}, not listed)"
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
    let label := if o.attach.isSome then p else s!"pid {p}"
    let (last, drawn) ← watch o label path finished
      (pure #[s!"leanprof top: waiting for {path} (start the program with LEANPROF_LIVE=1 or LEANPROF_LIVE={path})"])
    match last with
    | some s =>
      -- a program that had exited (or exits now): its last snapshot, drawn once
      if num s "seq" != drawn then
        let (h, w) ← termSize
        draw ansi (render label none s w (h - 1) o.rows)
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
  checkPid pid
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

/-- A time of a report row, or "< probe cost" / "< 1 clock tick" when the row
lists it in `too_small` (too small to measure; never shown as 0). -/
def rowTime (r : Json) (k : String) (tick := false) : String :=
  if ((r.getObjVal? "too_small" >>= Json.getArr?).toOption.getD #[]).any (·.getStr?.toOption == some k) then
    (if tick then "< 1 clock tick" else "< probe cost")
  else fmtTime (num r k)

/-- A row's share of the run (`pct_run`), as ", 1.2% of the run", or "". -/
def runShare (r : Json) : String :=
  if (r.getObjVal? "pct_run").isOk then s!", {fixed (num r "pct_run") 2}% of the run" else ""

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
    xs.map fun s => s!"{rowTime s "total_ns"} total, {rowTime s "self_ns"} self, {fmtCount (num s "calls")} calls, p99 {rowTime s "p99_ns"}: {str s "name"}{w s}"
  | "copies" =>
    let n (c : Json) := if live then num c "copies" else num c "shared" + num c "multi_threaded"
    -- copies of empty or tiny values (`tiny`: a first push, `prefix ++ s`), as `run`
    -- summarizes them: listed, they pushed the copies worth fixing out of the top rows
    let copied := (arr j "copies").filter (n · > 0)
    let tiny := copied.filter (bool · "tiny")
    let xs := take (((copied.filter (!bool · "tiny"))).qsort fun a b =>
      if num a "copy_ns" != num b "copy_ns" then num a "copy_ns" > num b "copy_ns" else num a "bytes" > num b "bytes")
    xs.map (fun c => s!"{fmtCount (n c)} copies, {fmtBytes (num c "bytes")}, {rowTime c "copy_ns" (tick := true)}{runShare c} [{str c "kind"}] in scope {str c "scope"}: {str c "function"}{str c (if live then "name" else "")}{w c}") ++
      (if tiny.isEmpty then #[] else
        #[s!"(and {tiny.size} sites that copied only empty or tiny values, {fmtCount (tiny.foldl (· + n ·) 0)} copies, not listed)"])
  | "allocations" =>
    -- costliest first: estimated time is the count times one allocation's cost
    let xs := take ((arr j "allocations").qsort fun a b =>
      if num a "allocs" != num b "allocs" then num a "allocs" > num b "allocs" else num a "bytes" > num b "bytes")
    let est (a : Json) := if num a "est_ns" > 0 then s!", est. {fmtTime (num a "est_ns")}{runShare a}" else ""
    xs.map fun a => s!"{fmtCount (num a "allocs")} allocations, {fmtBytes (num a "bytes")}{est a} in scope {str a "scope"}: {str a "function"}{str a (if live then "name" else "")}{w a}"
  | "tasks" =>
    let run := if live then "run_ns" else "run_sum_ns"
    let xs := take ((arr j "tasks").qsort fun a b => num a run > num b run)
    xs.map fun t => s!"{fmtCount (num t "tasks")} tasks, {fmtTime (num t run)} run, wait mean {fmtTime (num t "wait_ns" / max 1 (num t "tasks"))}: spawned by {str t (if live then "name" else "spawned_by")}"
  | "waits" =>
    let xs := take ((arr j "waits").qsort fun a b => num a "blocked_ns" > num b "blocked_ns")
    xs.map fun x => s!"{fmtCount (num x "waits")} waits, {fmtTime (num x "blocked_ns")} blocked in scope {str x "scope"}: {str x "function"}{str x (if live then "name" else "")}{w x}"
  | _ => #[s!"unknown kind {kind}: use scopes, copies, allocations, tasks or waits"]

/-- The rows of one section of a report or a live snapshot, hottest first
(as `hotLines` orders them; copies of tiny values left out). -/
def hotRows (j : Json) (kind : String) : Array Json :=
  let live := num j "leanprof_live" > 0
  match kind with
  | "scopes" => (arr j "scopes").qsort fun a b => num a "total_ns" > num b "total_ns"
  | "copies" =>
    let n (c : Json) := if live then num c "copies" else num c "shared" + num c "multi_threaded"
    ((arr j "copies").filter fun c => n c > 0 && !bool c "tiny").qsort fun a b =>
      if num a "copy_ns" != num b "copy_ns" then num a "copy_ns" > num b "copy_ns" else num a "bytes" > num b "bytes"
  | "allocations" => (arr j "allocations").qsort fun a b =>
      if num a "allocs" != num b "allocs" then num a "allocs" > num b "allocs" else num a "bytes" > num b "bytes"
  | "tasks" => let run := if live then "run_ns" else "run_sum_ns"
    (arr j "tasks").qsort fun a b => num a run > num b run
  | "waits" => (arr j "waits").qsort fun a b => num a "blocked_ns" > num b "blocked_ns"
  | _ => #[]

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
def explain (j : Json) (filter : String) (limit : Nat := 5) (copyLines : Option (Array String) := none) :
    String := Id.run do
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
  -- copies: in a report, `leanprof explain`'s diagnosis from the IR
  -- (`copyLines`); in a live snapshot, which has no symbols, the usual causes
  let nc (c : Json) := if live then num c "copies" else num c "shared" + num c "multi_threaded"
  -- costliest first; copies of empty or tiny values (`tiny`) are not worth explaining
  let copies := ((arr j "copies").filter fun c => nc c > 0 && has c && !bool c "tiny").qsort fun a b =>
    num a "copy_ns" > num b "copy_ns"
  if let some ls := copyLines then out := out ++ ls
  for c in (if copyLines.isSome then #[] else copies[0:min limit copies.size].toArray) do
    let n := nc c
    let share := scopeTotal (str c "scope")
    let pct := if share > 0 then s!", {fixed (num c "copy_ns" / share * 100)}% of scope {str c "scope"}" else ""
    out := out.push s!"COPY  {fmtCount n} copies of a shared {str c "kind"} in {fnOf c}{pos c}, inside scope {str c "scope"}: {fmtBytes (num c "bytes")} copied ({fmtBytes (num c "bytes" / max n 1)} each), {rowTime c "copy_ns" (tick := true)}{runShare c}{pct}."
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
    out := out.push s!"SCOPE {str s "name"}{pos s}: {rowTime s "total_ns"}{pct} in {fmtCount calls} calls, mean {if total > 0 then fmtTime (total / max calls 1) else rowTime s "total_ns"}, self {rowTime s "self_ns"}."
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

/-- The findings of `leanprof explain --json` as text for the MCP `explain`
tool: per copy site its cause, why, fix (with the program's names), lines and
confidence. `filter` keeps findings whose function contains it. -/
def explainFindings (ej : Json) (filter : String) (limit : Nat) : Array String := Id.run do
  let fs := (arr ej "findings").filter fun f => filter.isEmpty || ((str f "function").splitOn filter).length > 1
  let mut out : Array String := #[]
  let mut sites : Array String := #[]
  for f in fs do
    let site := s!"{str f "function"}|{str f "where"}"
    if !sites.contains site then
      if sites.size ≥ limit then break
      sites := sites.push site
      out := out.push s!"COPY  {fmtCount (num f "copies")} copies of a shared {str f "kind"} in {str f "function"} ({str f "where"}): {fmtBytes (num f "bytes")}, {fmtTime (num f "copy_ns")} copying."
    out := out.push s!"  cause ({str f "cause"}): {str f "why"}"
    unless (str f "fix").isEmpty do out := out.push s!"  fix: {str f "fix"}"
    for c in arr f "fix_code" do
      for l in (c.getStr?.toOption.getD "").splitOn "\n" do out := out.push s!"      {l}"
    let lines := (arr f "lines").filterMap (·.getNat?.toOption)
    unless lines.isEmpty do out := out.push s!"  where: {str f "file"} lines {", ".intercalate (lines.toList.map toString)}"
    out := out.push s!"  confidence: {str f "confidence"}"
  return out

/-! ## `leanprof mcp` -/

def sProp (d : String) : Json := Json.mkObj [("type", Json.str "string"), ("description", Json.str d)]
def bProp (d : String) : Json := Json.mkObj [("type", Json.str "boolean"), ("description", Json.str d)]
def nProp (d : String) : Json := Json.mkObj [("type", Json.str "integer"), ("description", Json.str d)]
def fProp (d : String) : Json := Json.mkObj [("type", Json.str "number"), ("description", Json.str d)]
def oProp (d : String) : Json := Json.mkObj [("type", Json.str "object"), ("description", Json.str d)]
def aProp (d : String) : Json :=
  Json.mkObj [("type", Json.str "array"), ("items", Json.mkObj [("type", Json.str "string")]), ("description", Json.str d)]
def aoProp (d : String) : Json :=
  Json.mkObj [("type", Json.str "array"), ("items", Json.mkObj [("type", Json.str "object")]), ("description", Json.str d)]
def enumProp (d : String) (xs : List String) : Json :=
  Json.mkObj [("enum", toJson xs), ("description", Json.str d)]

/-- The error of a structured result (`schemas/common.schema.json#/$defs/error`). -/
def errorSchema : Json :=
  Json.mkObj [("type", Json.str "object"),
    ("properties", Json.mkObj [
      ("code", enumProp "the kind of failure" (Leanprof.Contract.errorKinds.map (·.1))),
      ("message", sProp "what went wrong"),
      ("retryable", bProp "whether calling again unchanged may succeed"),
      ("hint", sProp "what to do about it")]),
    ("required", toJson ["code", "message", "retryable", "hint"])]

/-- A tool's output schema: `ok`, `tool`, `error` (when not ok), `warnings`
(problems that did not stop the call, such as an overloaded machine), and the
tool's own fields. -/
def outSchema (props : List (String × Json)) : Json :=
  Json.mkObj [("type", Json.str "object"),
    ("properties", Json.mkObj ([("ok", bProp "false when the call failed; then `error` says why"),
      ("tool", sProp "the tool called"), ("error", errorSchema),
      ("warnings", Json.mkObj [("type", Json.str "array"), ("items", errorSchema),
        ("description", Json.str "problems that did not stop the call, in the error format")])] ++ props)),
    ("required", toJson ["ok", "tool"])]

def exeProps : List (String × Json) :=
  [("executable", sProp "a lean_exe target of the Lake project"),
   ("args", aProp "arguments for the program")]

def tool (name desc : String) (props : List (String × Json)) (required : List String)
    (out : List (String × Json) := []) : Json :=
  Json.mkObj [("name", Json.str name), ("description", Json.str desc),
    ("inputSchema", Json.mkObj [("type", Json.str "object"),
      ("properties", Json.mkObj (props ++ [("cwd", sProp "project directory (default: the server's)")])),
      ("required", toJson required)]),
    ("outputSchema", outSchema out)]

/-- The fields of a verdict (`judge --json`, experiment evidence). -/
def verdictOut : List (String × Json) :=
  [("verdict", enumProp "the verdict" ["KEEP", "DISCARD", "INCONCLUSIVE", "ERROR"]),
   ("outcome", enumProp "what the verdict means (docs/guide/reference.md#verdict-outcomes)"
     ["improved", "regression", "no_improvement", "insufficient_evidence", "correctness_failure", "incompatible",
      "measurement_failed"]),
   ("measurement_valid", bProp "false when the measurement failed or compared incompatible things"),
   ("retryable", bProp "whether measuring again may change the outcome")]

def runOut : List (String × Json) :=
  [("exit_code", nProp "the command's exit code"), ("report", sProp "the report written (schemas/run.schema.json)")]

def tools : Array Json := #[
  tool "run" ("Build a Lake executable with leanprof's probes, run it and summarize the report: time per " ++
    "profile! scope or function, copies of shared arrays/strings with file:line, allocations, tasks, " ++
    "blocking waits, peak memory. The full JSON report is saved (default .lake/leanprof/report.json).")
    (exeProps ++ [("auto", bProp "time every function of the package (no profile! needed)"),
      ("allocs", bProp "count allocations per site"), ("counters", bProp "failed reuse and closure counters"),
      ("frees", bProp "time freeing cascades"), ("core", bProp "also probe Lean's own libraries"),
      ("json", sProp "where to save the report"), ("top", nProp "rows per section (default 8)")]) ["executable"]
    (runOut ++ [("wall_ns", fProp "wall time of the run"), ("copies", nProp "copies of shared or multi-threaded values")]),
  tool "sample" "Sample a Lake executable with samply (no probes): CPU time per Lean declaration with file:line."
    (exeProps ++ [("top", nProp "declarations shown (default 15)")]) ["executable"] runOut,
  tool "stat" "One-screen summary of a run: wall/CPU time, peak memory, allocations, copies, frees, tasks, top scopes."
    exeProps ["executable"] runOut,
  tool "elab" "Compile cost per line and declaration of Lean files (elaboration, kernel, compiler), optionally in exact heartbeats."
    [("files", aProp "Lean files"), ("heartbeats", bProp "count heartbeats (deterministic) instead of time"),
     ("top", nProp "lines shown")] ["files"]
    [("exit_code", nProp "the command's exit code"), ("report", sProp "the report written (schemas/elab.schema.json)")],
  tool "measure" "Run an executable several times with probes into one summary, for judge."
    (exeProps ++ [("runs", nProp "runs (default 5)"), ("out", sProp "summary file (default .lake/leanprof/measure.json)"),
      ("core", bProp "also count copies and allocations inside Lean's own libraries")])
    ["executable"]
    [("summary", sProp "the summary written (schemas/measure.schema.json)"), ("exit_code", nProp "the program's exit code"),
     ("time_ns", oProp "median, min, max, mean, stddev and runs"), ("copies_total", nProp "copies, exact"),
     ("allocs_total", nProp "allocations, exact (null when not counted)"), ("overloaded", bProp "the machine was overloaded")],
  tool "report" "Summarize a leanprof report (run, sample or elab JSON) or a live snapshot: the hottest rows of each section."
    [("path", sProp "report file (default .lake/leanprof/report.json)"), ("top", nProp "rows per section (default 5)")] []
    [("path", sProp "the report read"), ("kind", enumProp "the report's kind" ["run", "sampled", "elab", "live"])],
  tool "hot" "List the hottest scopes, copy sites, allocation sites, tasks or waits of a report or live snapshot, with file:line."
    [("kind", sProp "scopes, copies, allocations, tasks or waits"),
     ("path", sProp "report or live snapshot (default .lake/leanprof/report.json)"), ("limit", nProp "rows (default 10)")]
    ["kind"]
    [("kind", sProp "the section"), ("rows", aoProp "its rows as the report has them, hottest first"),
     ("total", nProp "rows in the section"), ("truncated", bProp "rows were left out (limit)")],
  tool "explain" ("Explain the costliest findings of a run report or live snapshot: why each copy of a shared value " ++
    "happens and how to fix it (for a report, `leanprof explain`'s diagnosis from the compiler's IR, with the fix " ++
    "in the program's own names), where a scope's time goes (own or nested), tail latency, allocations per call, " ++
    "task granularity, failed reuse and closure calls. Not for sampled reports (they count no copies or calls).")
    [("path", sProp "report or live snapshot (default .lake/leanprof/report.json)"),
     ("name", sProp "only findings whose function, scope or name contains this"), ("limit", nProp "findings per kind (default 5)")] []
    [("path", sProp "the report read"), ("findings", aoProp "explain's copy findings (schemas/explain.schema.json)")],
  tool "compare" "Compare two run reports: exact for copies and call counts, thresholded for time. Says whether anything regressed."
    [("base", sProp "baseline report"), ("new", sProp "new report"), ("threshold", nProp "time threshold in percent (default 10)")]
    ["base", "new"]
    [("regressed", bProp "anything regressed"), ("regressions", nProp "how many rows regressed"),
     ("comparison", oProp "compare --json (schemas/compare.schema.json)")],
  tool "measure_pair" ("Run two binaries in alternating AB/BA order (no probes) into one paired session for " ++
    "judge, stopping once the time verdict is settled: every timing, exit code and output hash. Give base and " ++
    "candidate (prebuilt), or base_rev and exe (the base built at that git revision, cached; the candidate built here).")
    [("base", sProp "baseline binary"), ("candidate", sProp "candidate binary"),
     ("base_rev", sProp "git revision to build the baseline at (cached by commit), with exe"),
     ("exe", sProp "Lake executable to build at base_rev and in candidate_cwd"),
     ("args", aProp "arguments for both binaries"), ("base_cwd", sProp "working directory of the baseline"),
     ("candidate_cwd", sProp "working directory of the candidate"), ("runs", nProp "most pairs, 6 to 1000 (default 30); stops early once the time verdict is settled"),
     ("fixed", bProp "measure exactly runs pairs, no early stop"),
     ("min_change", sProp "smallest time change in percent that counts (default 1)"),
     ("scope", sProp "time only the region the program wraps in Leanprof.bench with this name"),
     ("warmup", nProp "warmup pairs (default 1)"), ("check_output", sProp "output file compared instead of stdout"),
     ("out", sProp "session file (default .lake/leanprof/paired.json)")] []
    ([("session", sProp "the session written (schemas/measure-pair.schema.json)"),
      ("judge", oProp "judge --json of the session (schemas/judge.schema.json)")] ++ verdictOut),
  tool "judge" ("KEEP or DISCARD a change: from two measure summaries (output, copies, allocations, heartbeats, " ++
    "time), or from one measure_pair session (output and a paired 95% median interval on time).")
    [("base", sProp "baseline measure summary"), ("new", sProp "new measure summary"),
     ("pair", sProp "measure_pair session, instead of base and new"),
     ("min_change", sProp "smallest time change in percent that counts (default 1)"),
     ("allow_overloaded", bProp "judge a paired session's time even though the machine was overloaded")] []
    ([("judge", oProp "judge --json (schemas/judge.schema.json)")] ++ verdictOut),
  tool "experiment_start" ("Start an experiment: record the base (HEAD) in a git worktree: build, tests (the " ++
    "Lake test driver), behaviour on every case (stdout, stderr, exit code, output files; the workload args, plus " ++
    "one case per file of inputs) and exact counts. Without executable, the measure is compile heartbeats.")
    (exeProps ++ [("inputs", sProp "directory of input files, each a case: args with {} replaced by the file, or the file appended"),
      ("cases", sProp "file with one argument list per line, each a case"),
      ("heldout", sProp "directory of held-out inputs, run only by experiment_finish"),
      ("check_output", aProp "output files compared after every run (relative to the project)"),
      ("ignore_lines", aProp "lines of stdout and stderr containing any of these are not compared (the program's own timings)"),
      ("protect", aProp "more path globs no candidate may change (tests/, Tests/, expected/ always are)"),
      ("no_test", bProp "run no tests even if the project has a Lake test driver"),
      ("runs", nProp "measure runs (default 3)"), ("pairs", nProp "most measure-pair pairs (default 30)"),
      ("min_change", sProp "smallest time change in percent that counts (default 1)"),
      ("base", sProp "the base revision (default HEAD)"), ("id", sProp "experiment id (default: the time)")]) []
    [("experiment", sProp "the experiment's id"), ("state", oProp "experiment status --json (schemas/experiment-status.schema.json)")],
  tool "experiment_try" ("Try one candidate in its own git worktree: build, proof-preservation guard (sorry, axioms, " ++
    "implemented_by, extern, changed theorem statements, tests or expected outputs), tests, identical behaviour on every " ++
    "case, then exact counts and paired timing (or compile heartbeats). Returns KEEP, DISCARD, INCONCLUSIVE or ERROR " ++
    "with the evidence JSON. A KEEP becomes the base; from the working tree it is committed with the evidence.")
    [("rev", sProp "commit to try (default HEAD)"), ("working_tree", bProp "try the working tree instead of a commit"),
     ("time", bProp "time it even when the generated code is the base's"),
     ("no_commit", bProp "do not commit a kept working tree"), ("message", sProp "subject of that commit"),
     ("allow_overloaded", bProp "judge time on an overloaded machine"), ("id", sProp "experiment id (default: the current one)")] []
    ([("evidence", oProp "the try's evidence (schemas/experiment-try.schema.json)")] ++ verdictOut),
  tool "experiment_finish" "Finish an experiment: run the held-out inputs on the final base, compare with the baseline, remove the worktrees."
    [("keep_worktrees", bProp "keep the base and candidate worktrees"), ("id", sProp "experiment id (default: the current one)")] []
    [("result", oProp "experiment finish --json (schemas/experiment-finish.schema.json)")],
  tool "experiment_status" "The experiment's configuration, base and tries so far (JSON)."
    [("id", sProp "experiment id (default: the current one)")] []
    [("state", oProp "experiment status --json (schemas/experiment-status.schema.json)")],
  tool "live" ("What a running program is doing now: its latest live snapshot (it must run with LEANPROF_LIVE), " ++
    "with rates over a short interval and the scopes each thread is inside.")
    [("pid", sProp "process id (snapshot in $TMPDIR/leanprof-PID.live.json, from LEANPROF_LIVE=1)"),
     ("path", sProp "snapshot file (LEANPROF_LIVE=path)"), ("seconds", nProp "interval for rates (default 1, at most 60)")] []
    [("path", sProp "the snapshot read"), ("pid", nProp "the program's process id"), ("exited", bProp "the program has exited"),
     ("seq", nProp "the snapshot's number"), ("scopes", aoProp "the hottest scopes, by total time")],
  tool "doctor" ("Discover the setup before anything else: the Lean version and whether leanprof supports it, the " ++
    "project's executables, libraries and test driver, which modes work here (run, stat, measure, sample, elab and " ++
    "whether its driver is built, --auto, --core), samply and perf, and each setup failure with its error code and fix. " ++
    "Builds and runs nothing of the project (a few seconds).")
    [] []
    [("doctor", oProp "leanprof doctor --json (schemas/doctor.schema.json)"),
     ("ready", bProp "no required check failed"),
     ("modes", oProp "per mode: available, and why not"),
     ("setup_failures", aoProp "the required checks that failed, as errors (code, message, retryable, hint)")],
  tool "dump" "Write a running program's flight recorder (LEANPROF_FLIGHT) to a Perfetto trace of its last seconds; returns the path."
    [("pid", sProp "process id")] ["pid"]
    [("path", sProp "the Perfetto trace written")]]

/-- A tool's result: the text for people (cut at 30,000 characters, and said
so), and `structuredContent` for agents (`ok`, `tool`, its own fields), which
follows the tool's `outputSchema`. -/
def toolResult (name text : String) (fields : List (String × Json)) (isError : Bool := false)
    (warnings : Array Json := #[]) : Json :=
  let text := if text.length > 30000 then String.ofList (text.toList.take 30000) ++ "\n… (truncated)" else text
  let structured := Json.mkObj ([("ok", Json.bool !isError), ("tool", Json.str name)] ++
    (if warnings.isEmpty then [] else [("warnings", Json.arr warnings)]) ++ fields)
  Json.mkObj [("content", Json.arr #[Json.mkObj [("type", Json.str "text"), ("text", Json.str text)]]),
    ("structuredContent", structured), ("isError", Json.bool isError)]

/-- A failed call: the error (`code`, `message`, `retryable`, `hint`) in
`structuredContent`, and as text. -/
def errorResult (name : String) (err : Json) (text : String := "") (fields : List (String × Json) := []) : Json :=
  let msg := (err.getObjValAs? String "message").toOption.getD ""
  let hint := (err.getObjValAs? String "hint").toOption.getD ""
  let text := if text.isEmpty then s!"leanprof: {msg}" else text
  toolResult name (if hint.isEmpty then text else s!"{text}\nhint: {hint}") ([("error", err)] ++ fields) (isError := true)

/-- An error a tool raises itself, with its kind (`Contract.errorKinds`). -/
def toolFail {α} (code msg : String) : IO α := throw <| IO.userError s!"leanprof-error:{code}:{msg}"

/-- The kind and message of an error a tool raised. -/
def decodeError (e : IO.Error) : String × String :=
  let s := toString e
  match s.splitOn ":" with
  | "leanprof-error" :: code :: rest => (code, ":".intercalate rest)
  | _ => (Leanprof.Contract.classifyError s, s)

def argStr (a : Json) (k : String) : Option String := (a.getObjVal? k >>= Json.getStr?).toOption
def argBool (a : Json) (k : String) : Bool := (a.getObjVal? k >>= Json.getBool?).toOption.getD false
def argNat (a : Json) (k : String) : Option Nat := (a.getObjVal? k >>= Json.getNat?).toOption
def argStrs (a : Json) (k : String) : Array String :=
  ((a.getObjVal? k >>= Json.getArr?).toOption.getD #[]).filterMap (·.getStr?.toOption)

def tailText (s : String) (n : Nat) : String :=
  let ls := (s.splitOn "\n").filter (!·.isEmpty)
  "\n".intercalate (ls.drop (ls.length - n))

/-- `j` without its field `k`. -/
def dropKey (j : Json) (k : String) : Json :=
  match j with
  | .obj kvs => .obj (kvs.erase k)
  | x => x

/-- What one of this executable's own subcommands did: its exit code, output,
and the error it recorded (`LEANPROF_ERROR_JSON`), if any. -/
structure Ran where
  rc : UInt32
  out : String
  err : String
  error? : Option Json := none

/-- Run one of this executable's own subcommands. -/
def runSelf (args : Array String) (cwd : Option String) (env : Array (String × Option String) := #[]) : IO Ran := do
  let errFile : FilePath := s!"{← tmpDir}/leanprof-mcp-{← IO.monoNanosNow}.error.json"
  let env := env.push ("LEANPROF_ERROR_JSON", some errFile.toString)
  let out ← IO.Process.output { cmd := ← selfExe, args, cwd := cwd.map (⟨·⟩), env, stdin := .null }
  let error? ← readJson? errFile
  try IO.FS.removeFile errFile catch _ => pure ()
  return { rc := out.exitCode, out := out.stdout, err := out.stderr, error? := error? }

/-- The error of a subcommand that failed: the one it recorded, else one made
from its output (`code` when the output does not say). -/
def Ran.errorJson (r : Ran) (code : String := "failed") : Json :=
  match r.error? with
  | some e => dropKey e "schema"
  | none =>
    let tail := tailText (r.out ++ r.err) 6
    let c := if code == "failed" then Leanprof.Contract.classifyError tail else code
    Leanprof.Contract.errorJson c s!"exit code {r.rc}: {tail}"

def inDir (cwd : Option String) (p : String) : FilePath :=
  match cwd with
  | some d => if p.startsWith "/" then p else (d : FilePath) / p
  | none => p

/-- A file the server writes or deletes for its client, in the directory
`cwd` (none: the server's own): relative, without `..`, and inside `cwd`
with symbolic links resolved, so a tool call cannot overwrite or remove
files elsewhere, also through a link (`external/x.json` with `external`
pointing out of the project, or `x.json` itself a link). -/
def projectPath (cwd : Option String) (what p : String) : IO String := do
  let fp : FilePath := p
  let refuse {α} : IO α :=
    toolFail "bad_argument" s!"{what} must be a path inside the project (relative, without .., not through a symbolic link): {p}"
  if fp.isAbsolute || fp.components.contains ".." || p.isEmpty then refuse
  let root ← IO.FS.realPath (cwd.getD ".")
  let inside (r : FilePath) := r == root || r.toString.startsWith (root.toString ++ "/")
  let isLink (q : FilePath) : IO Bool := do
    try return (← q.symlinkMetadata).type == .symlink catch _ => return false
  let full := inDir cwd p
  -- the file itself: writing follows a link, removing it would not, but
  -- neither should be possible
  if ← isLink full then refuse
  -- the nearest directory above it that exists, links resolved
  let mut d := full.parent.getD "."
  for _ in [0:fp.components.length + 1] do
    if ← d.pathExists then break
    if ← isLink d then refuse
    d := d.parent.getD "."
  unless inside (← IO.FS.realPath d) do refuse
  return p

/-- A file name the server passes on as a command's argument: the command
must not read it as an option (`leanprof elab`'s `--out F` among its files). -/
def notOption (f : String) : IO Unit := do
  if f.startsWith "-" then toolFail "bad_argument" s!"not a file name: {f} (an option cannot be passed as a file)"

def isLakeProject (dir : FilePath) : IO Bool := do
  return (← (dir / "lakefile.lean").pathExists) || (← (dir / "lakefile.toml").pathExists)

/-- `cmd` is an executable file in a directory of `PATH`. -/
def onPath (cmd : String) : IO Bool := do
  let path := (← IO.getEnv "PATH").getD ""
  for d in path.splitOn ":" do
    if !d.isEmpty && (← ((d : FilePath) / cmd).pathExists) then return true
  return false

/-- Before a tool builds or runs anything: the directory is a Lake project
and Lake is on `PATH`. -/
def requireProject (cwd : Option String) : IO Unit := do
  let d := cwd.getD "."
  unless ← (d : FilePath).isDir do toolFail "bad_argument" s!"cwd is not a directory: {d}"
  unless ← isLakeProject d do
    toolFail "not_lake_project" s!"not a Lake project (no lakefile.lean or lakefile.toml): {← IO.FS.realPath d}"
  unless ← onPath "lake" do
    toolFail "lean_not_found" "`lake` is not on the PATH the MCP server runs with"

/-- The overloaded-machine warning, when a summary or session says so. -/
def overloadWarnings (j : Json) : Array Json :=
  let m := obj j "machine"
  if bool m "overloaded" || bool j "overloaded" then
    #[Leanprof.Contract.errorJson "overloaded"
      s!"the machine was overloaded while measuring (load average {fixed (num m "load_avg_1m") 1} on {(num m "cpus").toUInt64} CPUs)"]
  else #[]

/-- The verdict fields of a `judge --json` result or an experiment's evidence. -/
def verdictFields (j : Json) : List (String × Json) :=
  ["verdict", "outcome", "measurement_valid", "retryable"].filterMap fun k =>
    (j.getObjVal? k).toOption.map (k, ·)

def callTool (name : String) (a : Json) : IO Json := do
  let cwd := argStr a "cwd"
  let exeArgs : IO (Array String) := do
    let some exe := argStr a "executable" | toolFail "bad_argument" "missing argument: executable"
    if exe.startsWith "-" then toolFail "bad_argument" s!"not an executable name: {exe}"
    return #[exe, "--"] ++ argStrs a "args"
  let res (text : String) (fields : List (String × Json)) := toolResult name text fields
  match name with
  | "run" =>
    let json ← projectPath cwd "json" (argStr a "json" |>.getD ".lake/leanprof/report.json")
    let flags := [("auto", "--auto"), ("allocs", "--allocs"), ("counters", "--counters"), ("frees", "--frees"),
      ("core", "--core")].filterMap fun (k, f) => if argBool a k then some f else none
    let args ← exeArgs
    requireProject cwd
    let r ← runSelf (#["run", "--json", json] ++ flags.toArray ++ args) cwd #[("LEANPROF_QUIET", some "1")]
    let report ← readJson? (inDir cwd json)
    match report with
    | none =>
      return errorResult name (r.errorJson "build_failed")
        s!"exit code {r.rc}; no report was written\n\nlast output:\n{tailText (r.out ++ r.err) 15}"
        [("exit_code", toJson r.rc.toNat)]
    | some j =>
      let copies := (arr j "copies").foldl (fun s c => s + num c "shared" + num c "multi_threaded") 0
      return res s!"exit code {r.rc}; report {json}\n\n{summarize j ((argNat a "top").getD 8)}\n\nlast output:\n{tailText (r.out ++ r.err) 15}"
        [("exit_code", toJson r.rc.toNat), ("report", Json.str json), ("wall_ns", toJson (num j "wall_ns")),
         ("copies", toJson copies.toUInt64.toNat)]
  | "sample" | "stat" =>
    let args ← exeArgs
    requireProject cwd
    let r ← runSelf ((if name == "sample" then #["sample", "--top", toString ((argNat a "top").getD 15)] else #["stat"]) ++
      args) cwd
    if r.rc != 0 && r.out.isEmpty then
      return errorResult name (r.errorJson (if name == "sample" then "failed" else "build_failed"))
        s!"{r.out}\n{tailText r.err 10}" [("exit_code", toJson r.rc.toNat)]
    return res s!"{r.out}\n{tailText r.err 10}" [("exit_code", toJson r.rc.toNat), ("report", Json.str ".lake/leanprof/report.json")]
  | "elab" =>
    let files := argStrs a "files"
    if files.isEmpty then toolFail "bad_argument" "missing argument: files"
    -- `leanprof elab` reads options anywhere among its files (`--out F`)
    for f in files do notOption f
    requireProject cwd
    let r ← runSelf (#["elab"] ++ (if argBool a "heartbeats" then #["--heartbeats"] else #[]) ++
      #["--top", toString ((argNat a "top").getD 15)] ++ files) cwd
    if r.rc != 0 then
      return errorResult name (r.errorJson) s!"{r.out}\n{tailText r.err 10}" [("exit_code", toJson r.rc.toNat)]
    return res s!"{r.out}\n{tailText r.err 10}" [("exit_code", toJson r.rc.toNat), ("report", Json.str ".lake/leanprof/elab.json")]
  | "measure" =>
    let outFile ← projectPath cwd "out" (argStr a "out" |>.getD ".lake/leanprof/measure.json")
    let args ← exeArgs
    requireProject cwd
    let r ← runSelf (#["measure", "--runs", toString ((argNat a "runs").getD 5), "--out", outFile] ++
      (if argBool a "core" then #["--core"] else #[]) ++ args) cwd
    let text := s!"summary {outFile}\n{r.out}\n{tailText r.err 10}"
    if r.rc != 0 then return errorResult name (r.errorJson "build_failed") text
    let some j ← readJson? (inDir cwd outFile)
      | return errorResult name (Leanprof.Contract.errorJson "failed" s!"no summary at {outFile}") text
    return toolResult name text (warnings := overloadWarnings j) [("summary", Json.str outFile), ("exit_code", j.getObjValD "exit_code"),
      ("time_ns", dropKey (obj j "time_ns") "runs"), ("copies_total", j.getObjValD "copies_total"),
      ("allocs_total", j.getObjValD "allocs_total"), ("overloaded", Json.bool (bool (obj j "machine") "overloaded"))]

  | "report" =>
    let path := argStr a "path" |>.getD ".lake/leanprof/report.json"
    match ← readJson? (inDir cwd path) with
    | some j =>
      let kind := if bool j "elab" then "elab" else if num j "leanprof_live" > 0 then "live"
        else if bool j "sampled" then "sampled" else "run"
      return res s!"{path}\n{summarize j ((argNat a "top").getD 5)}" [("path", Json.str path), ("kind", Json.str kind)]
    | none =>
      return errorResult name (Leanprof.Contract.errorJson "not_found" s!"cannot read a report at {path}")
        s!"cannot read a report at {path} (run the `run` tool first)"
  | "hot" =>
    let path := argStr a "path" |>.getD ".lake/leanprof/report.json"
    let kind := argStr a "kind" |>.getD "scopes"
    unless ["scopes", "copies", "allocations", "tasks", "waits"].contains kind do
      toolFail "bad_argument" s!"unknown kind {kind}: use scopes, copies, allocations, tasks or waits"
    match ← readJson? (inDir cwd path) with
    | some j =>
      let limit := (argNat a "limit").getD 10
      let ls := hotLines j kind limit
      let rows := hotRows j kind
      return res (if ls.isEmpty then s!"no {kind} in {path}" else "\n".intercalate ls.toList)
        [("kind", Json.str kind), ("rows", Json.arr (rows.extract 0 limit)), ("total", toJson rows.size),
         ("truncated", Json.bool (rows.size > limit))]
    | none => return errorResult name (Leanprof.Contract.errorJson "not_found" s!"cannot read a report at {path}")
  | "explain" =>
    let path := argStr a "path" |>.getD ".lake/leanprof/report.json"
    let filter := (argStr a "name").getD ""
    let limit := (argNat a "limit").getD 5
    match ← readJson? (inDir cwd path) with
    | some j =>
      -- as `leanprof explain`: a sampled report has no copies and no call counts
      if bool j "sampled" then
        return errorResult name (Leanprof.Contract.errorJson "bad_argument"
          s!"{path} is from `leanprof sample`, which counts no copies or calls: use the `run` tool, then explain its report")
      if num j "leanprof_live" > 0 then return res (explain j filter limit) [("path", Json.str path), ("findings", Json.arr #[])]
      -- copies: the command's own diagnosis, from the IR next to the report
      let r ← runSelf #["explain", "--json", "--top", "1000", "--report", path] cwd
      let (copyLines, findings) ← match r.rc, Json.parse r.out with
        | 0, .ok ej => pure (explainFindings ej filter limit,
            (arr ej "findings").filter fun f => filter.isEmpty || ((str f "function").splitOn filter).length > 1)
        | _, _ => pure (#[s!"COPY  (leanprof explain failed: {tailText (r.out ++ r.err) 3})"], #[])
      return res (explain j filter limit (some copyLines)) [("path", Json.str path), ("findings", Json.arr findings)]
    | none => return errorResult name (Leanprof.Contract.errorJson "not_found" s!"cannot read a report at {path}")
  | "compare" =>
    let (some b, some n) := (argStr a "base", argStr a "new") | toolFail "bad_argument" "missing argument: base or new"
    let thr := (argNat a "threshold").map (#["--threshold", toString ·]) |>.getD #[]
    for f in [b, n] do notOption f
    let r ← runSelf (#["compare"] ++ thr ++ #[b, n]) cwd
    let verdict := if r.rc == 0 then "no regressions" else if r.rc == 1 then "REGRESSION" else "error"
    let text := s!"{verdict}\n{r.out}{r.err}"
    if r.rc > 1 then return errorResult name (r.errorJson) text
    let cj := match ← runSelf (#["compare", "--json"] ++ thr ++ #[b, n]) cwd with
      | x => (Json.parse x.out).toOption.getD Json.null
    return res text [("regressed", Json.bool (r.rc == 1)), ("regressions", cj.getObjValD "regressions"), ("comparison", cj)]
  | "measure_pair" =>
    let (bins, sides) ← match argStr a "base", argStr a "candidate", argStr a "base_rev", argStr a "exe" with
      | some b, some c, none, none => pure ([b, c], #["--base", b, "--candidate", c])
      | none, none, some r, some e => pure ([], #["--base-rev", r, "--exe", e])
      | _, _, _, _ => toolFail "bad_argument" "give base and candidate, or base_rev and exe"
    let outFile ← projectPath cwd "out" (argStr a "out" |>.getD ".lake/leanprof/paired.json")
    -- Only what a Lake project built, run in a Lake project: the tool must not
    -- become a way to run any program, or to delete files (measure-pair
    -- removes the checked output file before each run).
    for bin in bins do
      let real ← try IO.FS.realPath (inDir cwd bin) catch _ => toolFail "not_found" s!"no such binary: {bin}"
      unless (real.toString.splitOn "/.lake/build/bin/").length > 1 do
        toolFail "bad_argument" s!"{bin} is not a binary built by Lake (.lake/build/bin/)"
    -- the directories it really runs in: `base_cwd` and `candidate_cwd`
    -- default to `cwd` (itself the server's directory when not given),
    -- where the session is written too
    let top := cwd.getD "."
    let dirs := [("cwd", top)] ++ ["base_cwd", "candidate_cwd"].map fun k =>
      (k, ((argStr a k).map fun d => (inDir cwd d).toString).getD top)
    for (k, d) in dirs do
      unless ← isLakeProject d do toolFail "not_lake_project" s!"{k} is not a Lake project: {d}"
    if let some f := argStr a "check_output" then
      for (_, d) in dirs.drop 1 do discard <| projectPath (some d) "check_output" f
    let opt (k flag : String) := (argStr a k).map (#[flag, ·]) |>.getD #[]
    let num (k flag : String) := (argNat a k).map (#[flag, toString ·]) |>.getD #[]
    if argStr a "base_rev" |>.isSome then
      unless ← isLakeProject (inDir cwd ((argStr a "candidate_cwd").getD ".")) do
        toolFail "not_lake_project" "base_rev needs candidate_cwd (default the project) to be a Lake project"
    let r ← runSelf (#["measure-pair"] ++ sides ++ #["--out", outFile] ++
      opt "base_cwd" "--base-cwd" ++ opt "candidate_cwd" "--candidate-cwd" ++ opt "check_output" "--check-output" ++
      opt "min_change" "--min-change" ++ opt "scope" "--scope" ++ (if argBool a "fixed" then #["--fixed"] else #[]) ++
      num "runs" "--runs" ++ num "warmup" "--warmup" ++ #["--"] ++ argStrs a "args") cwd
    let text := s!"session {outFile}\n{r.out}\n{tailText r.err 10}"
    if r.rc != 0 then return errorResult name (r.errorJson) text
    let jr ← runSelf (#["judge", "--json"] ++ opt "min_change" "--min-change" ++ #[outFile]) cwd
    let jj := (Json.parse jr.out).toOption.getD Json.null
    let session := (← readJson? (inDir cwd outFile)).getD Json.null
    return toolResult name text (warnings := overloadWarnings session)
      ([("session", Json.str outFile), ("judge", jj)] ++ verdictFields jj)
  | "judge" =>
    let files ← match argStr a "pair", argStr a "base", argStr a "new" with
      | some p, none, none => pure #[p]
      | none, some b, some n => pure #[b, n]
      | _, _, _ => toolFail "bad_argument" "give pair, or base and new"
    for f in files do notOption f
    let minChange := (argStr a "min_change").map (#["--min-change", ·]) |>.getD #[]
    let allow := if argBool a "allow_overloaded" then #["--allow-overloaded"] else #[]
    let r ← runSelf (#["judge"] ++ minChange ++ allow ++ files) cwd
    if r.rc > 1 then return errorResult name (r.errorJson) s!"{r.out}{r.err}"
    let jj := (Json.parse (← runSelf (#["judge", "--json"] ++ minChange ++ allow ++ files) cwd).out).toOption.getD Json.null
    return toolResult name s!"{r.out}{r.err}" (warnings := overloadWarnings jj) ([("judge", jj)] ++ verdictFields jj)
  | "experiment_start" | "experiment_try" | "experiment_finish" | "experiment_status" =>
    -- paths inside the project only (check_output files are deleted before
    -- each run); no shell command for tests: the project's Lake test driver
    let inside (k : String) : IO (Option String) := do
      match argStr a k with
      | some p => return some (← projectPath cwd k p)
      | none => return none
    let flag (k f : String) := if argBool a k then #[f] else #[]
    let opt (k f : String) : IO (Array String) := do
      match argStr a k with
      | some v =>
        if v.startsWith "-" then toolFail "bad_argument" s!"{k} cannot start with -: {v}"
        return #[f, v]
      | none => return #[]
    let num (k f : String) := (argNat a k).map (#[f, toString ·]) |>.getD #[]
    let args ← match name with
      | "experiment_start" => do
        let mut xs := #["start"]
        if let some exe := argStr a "executable" then
          if exe.startsWith "-" then toolFail "bad_argument" s!"not an executable name: {exe}"
          xs := xs ++ #["--exe", exe]
        for k in ["inputs", "cases", "heldout"] do
          if let some p ← inside k then xs := xs ++ #[s!"--{k}", p]
        for f in argStrs a "check_output" do xs := xs ++ #["--check-output", ← projectPath cwd "check_output" f]
        for g in argStrs a "protect" do xs := xs ++ #["--protect", g]
        for t in argStrs a "ignore_lines" do xs := xs ++ #["--ignore-lines", t]
        xs := xs ++ flag "no_test" "--no-test" ++ num "runs" "--runs" ++ num "pairs" "--pairs" ++
          (← opt "min_change" "--min-change") ++ (← opt "base" "--base") ++ (← opt "id" "--id")
        pure (xs ++ #["--"] ++ argStrs a "args")
      | "experiment_try" => do
        let rev ← match argStr a "rev" with
          | some r => do
            if r.startsWith "-" then toolFail "bad_argument" s!"not a revision: {r}"
            pure #[r]
          | none => pure #[]
        pure (#["try", "--json"] ++ rev ++ flag "working_tree" "--working-tree" ++ flag "time" "--time" ++
          flag "no_commit" "--no-commit" ++ flag "allow_overloaded" "--allow-overloaded" ++
          (match argStr a "message" with | some m => #["--message", m] | none => #[]) ++ (← opt "id" "--id"))
      | "experiment_finish" => pure (#["finish", "--json"] ++ flag "keep_worktrees" "--keep-worktrees" ++ (← opt "id" "--id"))
      | _ => pure (#["status", "--json"] ++ (← opt "id" "--id"))
    requireProject cwd
    let r ← runSelf (#["experiment"] ++ args) cwd
    let verdict := match name, r.rc with
      | "experiment_try", 0 => "KEEP\n" | "experiment_try", 1 => "DISCARD\n"
      | "experiment_try", 3 => "INCONCLUSIVE\n" | "experiment_try", _ => "ERROR\n"
      | _, _ => ""
    let text := s!"{verdict}{r.out}\n{tailText r.err 10}"
    let parsed := (Json.parse r.out).toOption
    match name with
    | "experiment_try" =>
      match parsed with
      | some ev => return toolResult name text ([("evidence", ev)] ++ verdictFields ev) (r.rc == 2)
      | none => return errorResult name (r.errorJson) text
    | "experiment_finish" =>
      match parsed with
      | some j => return res text [("result", j)]
      | none => return errorResult name (r.errorJson) text
    | "experiment_status" =>
      match parsed with
      | some j => return res text [("state", j)]
      | none => return errorResult name (r.errorJson) text
    | _ =>
      if r.rc != 0 then return errorResult name (r.errorJson) text
      let st := (Json.parse (← runSelf (#["experiment", "status", "--json"] ++ (← opt "id" "--id")) cwd).out).toOption.getD Json.null
      return res text [("experiment", st.getObjValD "id"), ("state", st)]
  | "live" =>
    let path ← match argStr a "path", argStr a "pid" with
      | some p, _ => pure (inDir cwd p)
      | none, some pid =>
        try livePathFor pid catch e => toolFail "bad_argument" (toString e)
      | none, none => toolFail "bad_argument" "give pid or path"
    let some first ← readJson? path
      | return errorResult name (Leanprof.Contract.errorJson "not_found" s!"no live snapshot at {path}"
          "start the program with LEANPROF_LIVE=1 (or LEANPROF_LIVE=path)")
    if !bool first "exited" then IO.sleep ((min ((argNat a "seconds").getD 1) 60) * 1000).toUInt32
    let cur := (← readJson? path).getD first
    let prev := if num cur "seq" != num first "seq" then some first else none
    let scopes := ((arr cur "scopes").qsort fun x y => num x "total_ns" > num y "total_ns").extract 0 10
    return res ("\n".intercalate (render path.toString prev cur 220 60 (some 10)).toList)
      [("path", Json.str path.toString), ("pid", cur.getObjValD "pid"), ("exited", Json.bool (bool cur "exited")),
       ("seq", cur.getObjValD "seq"), ("scopes", Json.arr scopes)]
  | "doctor" =>
    let d := cwd.getD "."
    unless ← (d : FilePath).isDir do toolFail "bad_argument" s!"cwd is not a directory: {d}"
    let r ← runSelf #["doctor", "--json"] cwd
    let some doc := (Json.parse r.out).toOption | return errorResult name (r.errorJson) s!"{r.out}{r.err}"
    let lines := (arr doc "checks").map fun c =>
      s!"  {if bool c "ok" then "ok " else "!! "} {str c "message"}" ++
        (if bool c "ok" || (str c "fix").isEmpty then "" else s!"\n       {str c "fix"}")
    let n := num doc "problems"
    let text := "\n".intercalate (#["leanprof doctor"] ++ lines ++
      #[s!"  elab driver: {str (obj doc "elab_driver") "status"}",
        if n == 0 then "everything leanprof needs is here" else s!"{n.toUInt64} problem(s)"]).toList
    return res text [("doctor", doc), ("ready", Json.bool (bool doc "ok")), ("modes", doc.getObjValD "modes"),
      ("setup_failures", doc.getObjValD "setup_failures")]
  | "dump" =>
    let some pid := argStr a "pid" | toolFail "bad_argument" "missing argument: pid"
    try checkPid pid catch e => toolFail "bad_argument" (toString e)
    let p ← dumpPid pid
    return res s!"wrote {p} (Chrome trace format: open in https://ui.perfetto.dev)" [("path", Json.str p)]
  | _ => toolFail "bad_argument" s!"unknown tool {name}"

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
      ("serverInfo", Json.mkObj [("name", Json.str "leanprof"), ("version", Json.str Leanprof.Contract.leanprofVersion)]),
      ("instructions", Json.str ("leanprof profiles compiled Lean 4 programs. Run tools from the Lake project " ++
        "directory (or pass cwd). `run` builds with probes and summarizes; `hot` and `report` read the saved " ++
        "report; `compare` and `judge` decide whether a change regressed; `live` and `dump` look at a running " ++
        "program started with LEANPROF_LIVE / LEANPROF_FLIGHT. Every result has structuredContent (each tool's " ++
        "outputSchema): `ok`, and on failure `error` with a `code`, whether it is `retryable` and a `hint`; " ++
        "verdicts carry an `outcome` that tells a valid DISCARD from a failed measurement."))]
  | "ping" => return some (rpcResult id (Json.mkObj []))
  | "tools/list" => return some (rpcResult id (Json.mkObj [("tools", Json.arr tools)]))
  | "tools/call" =>
    let name := str params "name"
    unless tools.any (str · "name" == name) do
      return some (rpcError id (-32602) s!"unknown tool: {name}")
    let r ← try callTool name (obj params "arguments") catch e =>
      let (code, msg) := decodeError e
      pure (errorResult name (Leanprof.Contract.errorJson code msg))
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
