/-! `buildWithHistory` keeps every intermediate array, so each `push` copies:
`leanprof run` must count n - 1 copies of a shared Array here, and
`strings` n/2 - 1 copies of a shared String. -/

def fib : Nat → Nat
  | 0 => 0
  | 1 => 1
  | n + 2 => fib n + fib (n + 1)

def buildWithHistory (n : Nat) : Array Nat × Array (Array Nat) := Id.run do
  let mut acc : Array Nat := Array.mkEmpty 0
  let mut history : Array (Array Nat) := #[]
  for i in [0:n] do
    history := history.push acc
    acc := acc.push i
  return (acc, history)

/-- The same with a `String`: `n - 1` copies of a shared String. -/
def strings (n : Nat) : String × Array String := Id.run do
  let mut s := ""
  let mut seen : Array String := #[]
  for _ in [0:n] do
    seen := seen.push s
    s := s.push 'a'
  return (s, seen)

theorem sum_small : (List.range 30).foldl (· + ·) 0 = 435 := by decide

def main (args : List String) : IO Unit := do
  let n := (args.head? >>= String.toNat?).getD 1000
  let (acc, history) := buildWithHistory n
  let (s, seen) := strings (n / 2)
  IO.println s!"{acc.size} {history.size} {s.length} {seen.size} {fib 25}"
