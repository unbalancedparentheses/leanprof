#!/usr/bin/env python3
"""An interrupted `leanprof run` or `measure` must not leave instrumented
objects, or the program, behind.

    python3 scripts/interrupt-check.py [LEANPROF]

In a fresh project that does not depend on leanprof (Tests/Smoke's setup, a
program that waits), `leanprof run` is stopped while the program runs:

- by SIGTERM, SIGHUP and SIGINT: leanprof passes the signal on, puts the
  normal build back itself and exits with 128 + the signal; so does
  `leanprof measure` (and `measure-pair`, which builds nothing, passes the
  signal on too);
- by SIGKILL (nothing can be caught): a plain `lake build` afterwards must
  compile normal objects (leanprof forgot Lake's records of the instrumented
  ones), and `leanprof doctor` puts the stashed normal build back;
- by a failure while preparing the instrumented build (compiling leanprof's
  runtime): the executable and objects are as they were.

"Normal" is checked by running the program with LEANPROF_JSON set: an
instrumented build writes a report, a normal one does not.
"""
import os, shutil, signal, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LP = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, ".lake", "build", "bin", "leanprof")
MAIN = '''def main (args : List String) : IO Unit := do
  let mut xs : Array Nat := #[]
  for i in [0:100] do xs := xs.push i
  IO.println s!"{xs.size}"
  if let some f := args.head? then
    IO.FS.writeFile f "started"
    IO.sleep 60000
'''
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"\n     {detail}"))
    failures += 0 if ok else 1


def normal(work):
    """The program as built now writes no report: it is not instrumented."""
    report = os.path.join(work, "plain.json")
    if os.path.exists(report):
        os.remove(report)
    subprocess.run([os.path.join(work, ".lake", "build", "bin", "smoke")], cwd=work, check=True,
                   env=dict(os.environ, LEANPROF_JSON=report, LEANPROF_QUIET="1"), stdout=subprocess.DEVNULL)
    return not os.path.exists(report)


def running(started):
    """The program started with this argument is still running."""
    return subprocess.run(["pgrep", "-f", started], stdout=subprocess.DEVNULL).returncode == 0


def interrupted_run(work, sig, cmd=("run",)):
    """`leanprof CMD` stopped by `sig` once the program has started; its exit
    code, its stderr, and whether the program was still running afterwards."""
    started = os.path.join(work, "started")
    if os.path.exists(started):
        os.remove(started)
    if cmd[0] == "measure-pair":
        bin = os.path.join(work, ".lake", "build", "bin", "smoke")
        args = [LP, "measure-pair", "--base", bin, "--candidate", bin, "--warmup", "0", "--", started]
    else:
        args = [LP, *cmd, "smoke", "--", started]
    p = subprocess.Popen(args, cwd=work, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, text=True, env=dict(os.environ, LEANPROF_QUIET="1"))
    deadline = time.time() + 600
    while not os.path.exists(started) and p.poll() is None and time.time() < deadline:
        time.sleep(0.1)
    p.send_signal(sig)
    try:
        _, err = p.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        p.kill()
        _, err = p.communicate()
    left = running(started)
    # with SIGKILL the program outlives leanprof
    subprocess.run(["pkill", "-KILL", "-f", started])
    return p.returncode, err, left


work = tempfile.mkdtemp(prefix="leanprof-interrupt-")
try:
    for f in ("lakefile.toml", "lake-manifest.json", "lean-toolchain"):
        shutil.copy(os.path.join(ROOT, "Tests", "Smoke", f), work)
    with open(os.path.join(work, "Main.lean"), "w") as f:
        f.write(MAIN)
    subprocess.run(["lake", "build", "smoke"], cwd=work, check=True, stdout=subprocess.DEVNULL)
    check("the plain build is normal", normal(work))
    stash = os.path.join(work, ".lake", "leanprof", "normal-objects")
    for cmd in (("run",), ("measure", "--runs", "1", "--warmup", "0"), ("measure-pair",)):
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            what = f"{cmd[0]}, {sig.name}"
            rc, err, left = interrupted_run(work, sig, cmd)
            check(f"{what}: leanprof exits with 128 + {int(sig)}", rc == 128 + int(sig), f"rc={rc} {err[-500:]}")
            check(f"{what}: the program is not left running", not left)
            check(f"{what}: the normal build is back", not os.path.exists(stash) and normal(work), err[-500:])
    rc, err, _ = interrupted_run(work, signal.SIGKILL)
    check("SIGKILL: the normal objects are still set aside", os.path.exists(stash), f"rc={rc}")
    subprocess.run(["lake", "build", "smoke"], cwd=work, check=True, stdout=subprocess.DEVNULL)
    check("SIGKILL: a plain lake build afterwards is normal", normal(work))
    d = subprocess.run([LP, "doctor"], cwd=work, capture_output=True, text=True)
    check("SIGKILL: doctor puts the normal build back", "the normal build is back" in d.stdout
          and not os.path.exists(stash) and normal(work), d.stdout[-1500:])
    d = subprocess.run([LP, "doctor"], cwd=work, capture_output=True, text=True)
    check("doctor afterwards: nothing left", "no instrumented build left" in d.stdout, d.stdout[-1500:])
    # a failure while preparing the instrumented build (here compiling
    # leanprof's runtime, with a `cc` that fails) leaves the normal build as it was
    fake = os.path.join(work, "fake-cc")
    os.makedirs(fake)
    with open(os.path.join(fake, "cc"), "w") as f:
        f.write("#!/bin/sh\necho 'cc: refusing' >&2\nexit 1\n")
    os.chmod(os.path.join(fake, "cc"), 0o755)
    p = subprocess.run([LP, "run", "smoke"], cwd=work, capture_output=True, text=True,
                       env=dict(os.environ, PATH=fake + os.pathsep + os.environ["PATH"], LEANPROF_QUIET="1"))
    exe = os.path.join(work, ".lake", "build", "bin", "smoke")
    check("a failed runtime compile is reported", p.returncode != 0 and "runtime" in p.stderr, p.stderr[-500:])
    check("a failed runtime compile leaves the executable and objects in place",
          os.path.exists(exe) and not os.path.exists(stash) and normal(work), p.stderr[-500:])
finally:
    shutil.rmtree(work, ignore_errors=True)

print("all interrupt checks passed" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
