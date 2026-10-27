import Leanprof.BuildShim

/-- `leanprof-build-shim PROGRAM LOGDIR ARGS...` (Leanprof/BuildShim.lean). -/
def main (argv : List String) : IO UInt32 := Leanprof.BuildShim.shimMain argv
