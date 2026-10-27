/-!
# The build shim of `leanprof build`

`leanprof build` runs `lake build` against a copy of the toolchain's
directory whose `bin/` programs are small scripts calling this shim:
`leanprof-build-shim REAL LOGDIR ARGS...`. The shim runs `REAL ARGS...`
with the same standard streams, waits for it, and writes one record to
`LOGDIR`: the program, its arguments, when it started and ended (the
monotonic clock, which all processes share), its exit code, and the peak
resident memory and CPU time of the process (`getrusage(RUSAGE_CHILDREN)`
after the wait: the shim has no other child). It exits with the program's
exit code, so Lake sees what it would have seen.

It imports only `Init`, so it starts in a few milliseconds.
-/

namespace Leanprof.BuildShim

/-- Peak resident memory in bytes, user and system CPU time in microseconds
of the children waited for, as "RSS USER SYS" (`c/cli.c`). -/
@[extern "leanprof_cli_child_rusage"] opaque childRusage : IO String

/-- `s` as a JSON string. -/
def jsonStr (s : String) : String := Id.run do
  let mut out := "\""
  for c in s.toList do
    if c == '"' then out := out ++ "\\\""
    else if c == '\\' then out := out ++ "\\\\"
    else if c == '\n' then out := out ++ "\\n"
    else if c.toNat < 0x20 then
      let h := Nat.toDigits 16 c.toNat
      out := out ++ "\\u" ++ String.ofList (List.replicate (4 - h.length) '0' ++ h)
    else out := out.push c
  return out ++ "\""

/-- Run the program, record it, exit with its exit code. -/
def shimMain (argv : List String) : IO UInt32 := do
  match argv with
  | real :: logDir :: args =>
    let t0 ← IO.monoNanosNow
    let child ← IO.Process.spawn { cmd := real, args := args.toArray }
    let code ← child.wait
    let t1 ← IO.monoNanosNow
    try
      let ru := ((← childRusage).splitOn " ").map String.toNat?
      let num (i : Nat) : Nat := (ru[i]?.getD none).getD 0
      let cwd ← IO.currentDir
      let rec_ := "{" ++ s!"\"program\": {jsonStr real}, \"args\": [" ++
        ", ".intercalate (args.map jsonStr) ++ s!"], \"cwd\": {jsonStr cwd.toString}, " ++
        s!"\"start_ns\": {t0}, \"end_ns\": {t1}, \"exit_code\": {code}, " ++
        s!"\"max_rss_bytes\": {num 0}, \"user_us\": {num 1}, \"sys_us\": {num 2}" ++ "}\n"
      -- one file per process: no two processes write the same file
      IO.FS.writeFile (System.FilePath.mk logDir / s!"{t0}-{← IO.Process.getPID}.json") rec_
    catch _ => pure ()
    return code
  | _ =>
    IO.eprintln "usage: leanprof-build-shim PROGRAM LOGDIR [ARGS...] (run by `leanprof build`)"
    return 2

end Leanprof.BuildShim
