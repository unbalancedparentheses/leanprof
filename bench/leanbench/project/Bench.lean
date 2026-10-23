import LeanBench
import Work
-- LeanBench's view: the same action, timed in process, one sample per call.
bench "work" do
  Work.action

def main (args : List String) : IO UInt32 := do
  Work.setup
  LeanBench.runMain args

