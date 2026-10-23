/-! Declarations whose names need escapes when mangled. -/

namespace Odd

@[noinline] def «weird name» (n : Nat) : Nat := n + 1
@[noinline] def «1st» (n : Nat) : Nat := n * 2
@[noinline] def αβγ (n : Nat) : Nat := n + 3
@[noinline] def ℕsum (xs : List Nat) : Nat := xs.foldl (· + ·) 0
@[noinline] def x₁ (n : Nat) : Nat := n + 4
@[noinline] def «emoji🎉» (n : Nat) : Nat := n + 5
@[noinline] def foo_bar (n : Nat) : Nat := n + 6
@[noinline] def foo_ (n : Nat) : Nat := n + 7
@[noinline] def foo_.bar (n : Nat) : Nat := n + 8
@[noinline] def «_x41» (n : Nat) : Nat := n + 9
@[noinline] def «a.b» (n : Nat) : Nat := n + 10
@[noinline] def get! (xs : Array Nat) : Nat := xs[0]!
@[noinline] def find? (xs : List Nat) : Option Nat := xs.find? (· > 2)
@[noinline] def prime' (n : Nat) : Nat := n + 12
@[noinline] def «x2d» (n : Nat) : Nat := n + 13
@[noinline] def «__» (n : Nat) : Nat := n + 14
@[noinline] def a__b (n : Nat) : Nat := n + 15
@[noinline] def «-» (n : Nat) : Nat := n + 16
@[noinline] def «spec_0» (n : Nat) : Nat := n + 17
@[noinline] def «00» (n : Nat) : Nat := n + 19
@[noinline] def «_under» (n : Nat) : Nat := n + 20

@[noinline] private def secret (n : Nat) : Nat := n + 21

@[noinline] private def secretSum (n : Nat) : Nat := Id.run do
  let mut s := 0
  for i in [0:n] do
    s := s + i * 2
  return s

/-- `helper` gets a hygienic name (`helper._@.OddNames.Basic._hyg.N`). -/
macro "mk_helper" : command => `(
  @[noinline] def helper (n : Nat) : Nat := n + 30
  @[noinline] def $(Lean.mkIdent `useHelper) (n : Nat) : Nat := helper n)

mk_helper

structure Point where
  x : Nat
  y : Nat
deriving Repr, BEq, Hashable

instance : Add Point := ⟨fun a b => ⟨a.x + b.x, a.y + b.y⟩⟩

@[noinline] def sumTo (n : Nat) : Nat := go n 0
where
  go : Nat → Nat → Nat
    | 0, acc => acc
    | k + 1, acc => go k (acc + k)

@[noinline] partial def collatz (n : Nat) (steps : Nat := 0) : Nat :=
  if n ≤ 1 then steps else collatz (if n % 2 == 0 then n / 2 else 3 * n + 1) (steps + 1)

@[noinline] def pushAll (n : Nat) : Array Nat := Id.run do
  let mut acc := #[]
  for i in [0:n] do
    acc := acc.push i
  return acc

@[noinline] def mapPlus (k : Nat) (xs : List Nat) : List Nat := xs.map (· + k)

@[noinline] def callAll (n : Nat) : Nat :=
  «weird name» n + «1st» n + αβγ n + ℕsum [n, 1] + x₁ n + «emoji🎉» n + foo_bar n + foo_ n +
    foo_.bar n + «_x41» n + «a.b» n + get! #[n] + (find? [n, 5]).getD 0 + prime' n +
    «x2d» n + «__» n + a__b n + «-» n + «spec_0» n + «00» n + «_under» n + secret n + secretSum n + useHelper n +
    (toString (repr ({ x := n, y := 2 } : Point))).length + (hash ({ x := n, y := 3 } : Point)).toNat +
    (({ x := n, y := 1 } : Point) + ⟨1, 2⟩).x + sumTo n + collatz (n + 7) + (pushAll n).size +
    (mapPlus n [1, 2]).length

end Odd

@[noinline] def «top level» (n : Nat) : Nat := n + 22
@[noinline] def «ελ» (n : Nat) : Nat := n + 23
