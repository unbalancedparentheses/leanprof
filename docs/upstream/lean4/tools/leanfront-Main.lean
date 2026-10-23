import Lean

/-!
`lean`'s command line (`lean FILE`, `lean --server`, `lean --worker`) as a Lake
executable, so that leanprof can build it with probes (`run --core`) and sample
it with Lean names. It does what `lean_main` in `src/util/shell.cpp` does, but
with Lean's libraries linked statically.
-/

/-- `Lean.ShellOptions` (private to `Lean.Shell`), passed through untouched. -/
opaque ShellOptsPointed : NonemptyType
def ShellOpts : Type := ShellOptsPointed.type
instance : Nonempty ShellOpts := ShellOptsPointed.property

@[extern "lean_shell_options_mk"] opaque mkShellOpts : Unit → ShellOpts
@[extern "lean_shell_options_process"]
opaque processOpt (opts : ShellOpts) (opt : Char) (arg : Option String) : EIO UInt32 ShellOpts
@[extern "lean_shell_main"] opaque shellMain (args : List String) (opts : ShellOpts) : IO UInt32

/-- getopt's view of the options leanfront needs: long names to `lean`'s option
characters, and whether they take an argument. -/
def longOpts : List (String × Char × Bool) :=
  [("server", 'S', false), ("worker", 'W', false), ("threads", 'j', true), ("tstack", 's', true),
   ("root", 'R', true), ("memory", 'M', true), ("trust", 't', true), ("profile", 'P', false),
   ("stats", 'a', false), ("json", 'J', false), ("setup", 'u', true), ("o", 'o', true),
   ("i", 'i', true), ("c", 'c', true), ("timeout", 'T', true), ("deps", 'd', false),
   ("plugin", 'p', true), ("load-dynlib", 'l', true), ("error", 'E', true)]

/-- Short options that take an argument (`-Dname=value`, `-j4`). -/
def shortWithArg : List Char := ['D', 'o', 'i', 'b', 'c', 'C', 't', 'j', 'R', 'M', 'T', 'p', 'E', 'Y', 'Z', 'H', 's']

partial def parse (opts : ShellOpts) (files : Array String) : List String → EIO UInt32 (ShellOpts × Array String)
  | [] => return (opts, files)
  | a :: rest => do
    if a.startsWith "--" && a.length > 2 then
      let body := (a.drop 2).toString
      let (name, inline?) := match body.splitOn "=" with
        | [n] => (n, none)
        | n :: vs => (n, some ("=".intercalate vs))
        | [] => (body, none)
      match longOpts.find? (·.1 == name) with
      | some (_, c, true) =>
        match inline?, rest with
        | some v, _ => parse (← processOpt opts c (some v)) files rest
        | none, v :: rest' => parse (← processOpt opts c (some v)) files rest'
        | none, [] => throw 1
      | some (_, c, false) => parse (← processOpt opts c none) files rest
      | none => throw 1
    else if a.startsWith "-" && a.length > 1 then
      let c := a.toList[1]!
      if shortWithArg.contains c then
        if a.length > 2 then parse (← processOpt opts c (some (a.drop 2).toString)) files rest
        else match rest with
          | v :: rest' => parse (← processOpt opts c (some v)) files rest'
          | [] => throw 1
      else parse (← processOpt opts c none) files rest
    else
      parse opts (files.push a) rest

def main (args : List String) : IO UInt32 := do
  Lean.initSearchPath (← Lean.findSysroot)
  unsafe Lean.enableInitializersExecution
  match ← (parse (mkShellOpts ()) #[] args).toBaseIO with
  | .ok (opts, files) => shellMain files.toList opts
  | .error rc => return rc
