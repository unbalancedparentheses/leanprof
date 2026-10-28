import Leanprof.ProjectFix

/-! Tests of the project-wide compile-time hypotheses and their edits
(`fix --elab --project`, `Leanprof/ProjectFix.lean`). Pure: run by `Tests/Main.lean`. -/

open Lean Leanprof

namespace Tests.ProjectFix

/-- A project report: a definition unfolded in three files, one unfolded in one file
only, a simp lemma tried often and never used, an instance tried often and rarely
used, a definition named by failed instance searches in two files, a repeated
instance problem, and a toolchain constant (not the project's). -/
def report : Json :=
  let const (name kind wh : String) (amount : Float) (count files sites : Nat) (extra : List (String × Json)) :=
    Json.mkObj ([("name", Json.str name), ("kind", Json.str kind), ("where", Json.str wh), ("amount", toJson amount),
      ("count", toJson count), ("files", toJson files), ("sites", toJson sites),
      ("site_keys", toJson #["B.lean:3", "C.lean:5"]),
      ("site_files", Json.arr #[Json.mkObj [("file", "B.lean"), ("sites", toJson (1 : Nat))],
        Json.mkObj [("file", "C.lean"), ("sites", toJson (1 : Nat))]])] ++ extra)
  Json.mkObj [("unit", "heartbeats"), ("project", Json.bool true), ("counts", Json.bool true),
    ("scopes", Json.arr #[
      Json.mkObj [("pos", "B.lean:3"), ("key", "B.lean usesDouble"), ("name", "theorem usesDouble"),
        ("instances_failed", Json.arr #[Json.mkObj [("problem", "Inhabited (Wrapper Nat)"), ("count", toJson (2 : Nat))]])],
      Json.mkObj [("pos", "C.lean:5"), ("key", "C.lean other"), ("name", "theorem other"),
        ("instances_failed", Json.arr #[Json.mkObj [("problem", "Inhabited (Wrapper Int)"), ("count", toJson (1 : Nat))]])]]),
    ("constants", Json.arr #[
      const "double" "unfold" "A.lean:1" 5000000 40 3 12 [("unfolds", toJson (300 : Nat)), ("kernel", toJson (20 : Nat))],
      const "single" "unfold" "A.lean:9" 9000000 40 1 4 [("unfolds", toJson (500 : Nat))],
      const "foo_never" "" "A.lean:4" 0 0 2 6 [("simp_tried", toJson (60 : Nat)), ("simp_failed", toJson (60 : Nat))],
      const "foo_used" "simp" "A.lean:6" 0 0 2 6 [("simp_tried", toJson (60 : Nat)), ("simp_used", toJson (30 : Nat))],
      const "instSlow" "instance" "A.lean:12" 100000 50 2 9 [("instances", toJson (3 : Nat))],
      const "Wrapper" "unfold" "A.lean:14" 0 0 2 2 [("unfolds", toJson (30 : Nat))],
      const "Nat.add" "unfold" "Init/Prelude.lean:1" 9000000 900 20 90 [("unfolds", toJson (9000 : Nat))],
      const "A._proof_1" "unfold" "A.lean:20" 100 90 3 3 [("unfolds", toJson (90 : Nat))]]),
    ("repeated", Json.arr #[Json.mkObj [("class", "Meta.synthInstance"), ("op", "Add Nat"), ("count", toJson (30 : Nat)),
      ("files", toJson (4 : Nat)), ("total", toJson (200000 : Float)), ("first_at", "B.lean:3"),
      ("by_file", Json.arr #[Json.mkObj [("file", "B.lean"), ("count", toJson (10 : Nat))]])]])]

def inProject (f : String) : Bool := !f.startsWith "Init/"

def cases : List (String × Bool × String) :=
  let hs := ProjectFix.hypotheses report inProject
  let kinds := hs.map fun c => (c.kind, c.target)
  let src := "/-- doc\n  def in a comment -/\n@[simp, grind] theorem foo : 1 = 1 := rfl\n\n@[simp]\ntheorem bar : 2 = 2 := rfl\n" ++
    "@[instance] def notInst := 1\n@[simp ←] theorem baz : 3 = 3 := rfl\n"
  let ls := (src.splitOn "\n").toArray
  let inst := "/-- an instance -/\nprotected instance foo : Inhabited Nat := ⟨0⟩\ninstance (priority := high) bar : Inhabited Int := ⟨0⟩\n"
  let ils := (inst.splitOn "\n").toArray
  [("project fix: a definition unfolded across files is an irreducible candidate", kinds.contains ("irreducible", "double"), s!"{kinds}"),
   ("project fix: one file only is no cross-file candidate", !(kinds.any (·.2 == "single")), s!"{kinds}"),
   ("project fix: the toolchain's constants and generated names are not candidates",
     !(kinds.any fun (_, t) => t == "Nat.add" || t == "A._proof_1"), s!"{kinds}"),
   ("project fix: a simp lemma never used is a simp-attr candidate", kinds.contains ("simp-attr", "foo_never"), s!"{kinds}"),
   ("project fix: a simp lemma used half the time is not", !(kinds.contains ("simp-attr", "foo_used")), s!"{kinds}"),
   ("project fix: an instance tried often, used rarely: a lower priority", kinds.contains ("instance-priority", "instSlow"), s!"{kinds}"),
   ("project fix: a definition failed instance searches name: reducible", kinds.contains ("reducible", "Wrapper"), s!"{kinds}"),
   ("project fix: a repeated instance problem is a shortcut hypothesis, not mechanical",
     (hs.find? (·.kind == "shortcut-instance")).any (!·.mechanical), s!"{kinds}"),
   ("project fix: ranked by files, then the exact count, not by attributed heartbeats",
     (hs[0]?.map (·.target)) == some "Add Nat" && (hs.findIdx? (·.target == "double")).getD 99 < (hs.findIdx? (·.target == "instSlow")).getD 0,
     s!"{kinds}"),
   ("project fix: the attributed heartbeats are stated as overlapping",
     (hs.find? (·.target == "double")).any fun c => c.observed.any fun o => (o.splitOn "overlapping").length > 1, ""),
   ("project fix: the declarations where it was seen", (hs.find? (·.target == "double")).any (·.decls == #["B.lean:3 usesDouble", "C.lean:5 other"]),
     s!"{(hs.find? (·.target == "double")).map (·.decls)}"),
   ("project fix: mentions is by whole names", ProjectFix.mentions "Inhabited (Wrapper Nat)" "Wrapper" &&
     !ProjectFix.mentions "Inhabited (Wrappers Nat)" "Wrapper" && !ProjectFix.mentions "Foo.Wrapper" "Wrapper", ""),
   ("project fix: the declaration keyword past a doc comment and attributes",
     ProjectFix.declKeyword ls 1 == some ("theorem", 3) && ProjectFix.declKeyword ls 7 == some ("def", 7),
     s!"{ProjectFix.declKeyword ls 1} {ProjectFix.declKeyword ls 7}"),
   ("project fix: simp taken out of an attribute list",
     ProjectFix.dropSimpAttr ls 1 == some (ls.set! 2 "@[grind] theorem foo : 1 = 1 := rfl"), s!"{ProjectFix.dropSimpAttr ls 1}"),
   ("project fix: an attribute line with simp alone goes",
     (ProjectFix.dropSimpAttr ls 5).map (·.size) == some (ls.size - 1) &&
       (ProjectFix.dropSimpAttr ls 5).any (·[4]! == "theorem bar : 2 = 2 := rfl"), s!"{ProjectFix.dropSimpAttr ls 5}"),
   ("project fix: simp ← is not simp", ProjectFix.dropSimpAttr ls 8 == none, ""),
   ("project fix: an instance at low priority",
     ProjectFix.addPriority ils 1 == some (ils.set! 1 "protected instance (priority := low) foo : Inhabited Nat := ⟨0⟩"),
     s!"{ProjectFix.addPriority ils 1}"),
   ("project fix: an instance with a priority is left alone", ProjectFix.addPriority ils 3 == none, ""),
   ("project fix: the declaration there declares the name",
     ProjectFix.declares ls 1 "foo" && ProjectFix.declares ls 1 "Ns.foo" && !ProjectFix.declares ls 1 "run" &&
       !ProjectFix.declares ls 1 "xfoo" && ProjectFix.declares ils 1 "Inst.foo" &&
       ProjectFix.declares #["instance : Inhabited Nat := ⟨0⟩"] 1 "instInhabitedNat", ""),
   ("project fix: a name located by its end is edited by the name it was found as",
     (ProjectFix.hypotheses (report.setObjVal! "constants" (Json.arr #[Json.mkObj [("name", "double"), ("kind", "unfold"),
       ("where", "A.lean:1"), ("files", toJson (3 : Nat)), ("unfolds", toJson (300 : Nat)), ("located_by_suffix", Json.bool true),
       ("declared_as", "Ns.double")]])) inProject).any fun c => c.target == "Ns.double" && c.kind == "irreducible", ""),
   ("project fix: a protected declaration is not what a one-part name names",
     !ProjectFix.declares #["protected theorem pure : True := trivial"] 1 "pure" &&
       ProjectFix.declares #["protected theorem pure : True := trivial"] 1 "SatisfiesM.pure", ""),
   ("project fix: no declaration starts on a `public section` line",
     ProjectFix.declKeyword #["public section", "", "namespace Foo", "def drop := 1"] 1 == none, ""),
   ("project fix: the time the lock wrapper measured", ProjectFix.lockedElapsed "x\nleanprof-elapsed 12.500000\n" == some 12.5 &&
     ProjectFix.lockedElapsed "no time" == none, ""),
   ("project fix: `variable (x) in` is part of the declaration",
     ProjectFix.declKeyword #["variable (W') in", "/-- doc -/", "abbrev CoordinateRing : Type := Nat"] 1 == some ("abbrev", 3), ""),
   ("project fix: a line appended", ProjectFix.appendLine "a\nb" "c" == "a\nb\nc\n" && ProjectFix.appendLine "a\n" "c" == "a\nc\n", ""),
   ("project fix: build times: worse only when every candidate run is slower",
     ProjectFix.buildTimeVerdict #[10, 10.2, 10.1] #[11, 11.2, 11.1] == "worse" &&
     ProjectFix.buildTimeVerdict #[10, 12, 10.1] #[11, 11.2, 11.1] == "within noise" &&
     ProjectFix.buildTimeVerdict #[10, 10.2, 10.3] #[9, 9.1, 9.2] == "better" &&
     ProjectFix.buildTimeVerdict #[10] #[12] == "too few runs to judge", "")]

end Tests.ProjectFix
