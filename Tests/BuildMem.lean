import Leanprof.BuildMem

/-! Tests of `leanprof build-memory`'s reading and arithmetic (Leanprof/BuildMem.lean);
`scripts/build-memory-check.sh` runs the command on a real build. -/

open Leanprof.BuildMem

namespace Tests.BuildMem

def gib : Nat := 1024 * 1024 * 1024

/-- A module that ran from `a` to `b` (µs) with peak `rss`. -/
def mod (name : String) (a b rss : Nat) (priv : Option Nat := none) : Module :=
  { name, file := name ++ ".lean", setup := none,
    proc := { startUs := a, stopUs := b, userUs := 0, sysUs := 0, maxrss := rss, priv, privSampled := false,
              exit := 0, signal := 0, cwd := "", leanPath := "", args := #[] } }

def wrapperLine : String :=
  "{\"pid\":7,\"start_us\":1000,\"end_us\":5000,\"user_us\":2000,\"sys_us\":500,\"maxrss\":414318592," ++
  "\"private_peak\":90233624,\"private_sampled\":false,\"exit\":0,\"signal\":0,\"cwd\":\"/p\"," ++
  "\"lean_path\":\"/p/.lake/build/lib/lean\",\"args\":[\"/p/P/A.lean\",\"-o\",\"/p/.lake/build/lib/lean/P/A.olean\"," ++
  "\"--setup\",\"/p/.lake/build/ir/P/A.setup.json\",\"--json\"]}"

def driverLines : List String := [
  "{\"imports\":true,\"rss_after\":300,\"private_after\":80,\"peak_after\":310,\"private_peak_after\":85}",
  "{\"command\":0,\"line\":2,\"end_line\":2,\"name\":\"a\",\"text\":\"def a := 1\",\"heartbeats_before\":10," ++
    "\"heartbeats_after\":30,\"rss_before\":300,\"rss_after\":320,\"peak_before\":310,\"peak_after\":330," ++
    "\"private_before\":80,\"private_after\":90,\"private_peak_before\":85,\"private_peak_after\":95}",
  "{\"command\":1,\"line\":3,\"end_line\":5,\"name\":\"b\",\"text\":\"theorem b\",\"heartbeats_before\":30," ++
    "\"heartbeats_after\":90,\"rss_before\":320,\"rss_after\":315,\"peak_before\":330,\"peak_after\":400," ++
    "\"private_before\":90,\"private_after\":91,\"private_peak_before\":95,\"private_peak_after\":150}",
  "{\"command\":2,\"line\":6,\"end_line\":6,\"name\":\"c\",\"text\":\"def c\",\"heartbeats_before\":90," ++
    "\"heartbeats_after\":95,\"rss_before\":315,\"rss_after\":316,\"peak_before\":400,\"peak_after\":400," ++
    "\"private_before\":91,\"private_after\":91,\"private_peak_before\":150,\"private_peak_after\":150}",
  -- the end of the input: no command
  "{\"command\":3,\"line\":7,\"end_line\":7,\"name\":\"\",\"text\":\"\",\"heartbeats_before\":95," ++
    "\"heartbeats_after\":95,\"rss_before\":316,\"rss_after\":316,\"peak_before\":400,\"peak_after\":400}"]

def run (check : String → Bool → String → StateT Nat IO Unit) : StateT Nat IO Unit := do
  -- sizes
  check "build-memory: sizes in binary units"
    (parseSize "8G" == some (8 * gib) && parseSize "512M" == some (512 * 1024 * 1024) &&
     parseSize "1.5GiB" == some (3 * gib / 2) && parseSize "100" == some 100 && parseSize "2 kb" == some 2048)
    s!"{parseSize "8G"} {parseSize "1.5GiB"}"
  check "build-memory: a size with an unknown unit is refused" (parseSize "8X" == none && parseSize "G" == none) ""
  check "build-memory: sizes printed" (fmtBytes (3 * gib / 2) == "1.50 GiB" && fmtBytes (5 * 1024 * 1024) == "5 MiB")
    (fmtBytes (3 * gib / 2))
  -- the header alone
  let src := "/- Copyright -/\nmodule\n\npublic import Foo.Bar -- a comment\nimport all Baz\n" ++
    "/- a /- nested -/ comment -/ meta import «A b».C\n\n/-! # Docs -/\n\ndef x := 1\n"
  let h := headerText src
  check "build-memory: the header ends after the last import" (h.endsWith "meta import «A b».C" && !h.contains '!') h
  check "build-memory: a file without imports has an empty header" (headerText "def x := 1\nimport Foo" == "") ""
  check "build-memory: prelude and imports, then a command"
    (headerText "prelude\nimport Init.Core\nset_option x true\n" == "prelude\nimport Init.Core") (headerText "prelude\nimport Init.Core\nset_option x true\n")
  -- the wrapper's records
  let p? := (Lean.Json.parse wrapperLine).toOption.bind Proc.ofJson?
  check "build-memory: a wrapper record is read"
    (match p? with
     | some p => p.maxrss == 414318592 && p.priv == some 90233624 && p.stopUs - p.startUs == 4000 &&
        sourceOf p.args == some "/p/P/A.lean" && argAfter p.args "--setup" == some "/p/.lake/build/ir/P/A.setup.json"
     | none => false) wrapperLine
  check "build-memory: a module named from its path" (moduleOfPath "/p" "/p/P/Data/A.lean" == "P.Data.A") ""
  -- jobs under a limit
  check "build-memory: the largest peaks that fit a limit" (safeJobs #[3, 5, 1, 2] 8 18 == (2, 8)) s!"{safeJobs #[3, 5, 1, 2] 8 18}"
  check "build-memory: jobs counted with a shared part" (safeJobs #[3, 5, 1, 2] 8 18 (base := 1) == (1, 6)) ""
  check "build-memory: no job fits when the heaviest is above the limit" (safeJobs #[9, 1] 8 18 == (0, 0)) ""
  check "build-memory: jobs at most the CPUs" (safeJobs #[1, 1, 1, 1] 100 2 == (2, 2)) ""
  -- modules running together
  let ms := #[mod "A" 0 10 100, mod "B" 5 15 50, mod "C" 12 20 30, mod "D" 15 16 10]
  let (peak, set, most) := concurrentPeak ms
  check "build-memory: the peaks of modules running together" (peak == 150 && set == #[0, 1] && most == 2)
    s!"{peak} {set} {most}"
  -- memory per command
  let s := Serial.ofLines "P.A" "P/A.lean" driverLines
  check "build-memory: commands of a serial run, without the end of input"
    (s.commands.size == 3 && s.importRss == 300 && s.peak == 400 && s.privPeak == 150) s!"{s.commands.size} {s.peak}"
  check "build-memory: the command during which the peak was reached"
    ((s.peakCommand?.map (·.name)) == some "b" && s.commands[1]!.peakRise == 70 && s.commands[1]!.heartbeats == 60 &&
     s.commands[1]!.growth == -5) ""

end Tests.BuildMem
