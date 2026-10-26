/-!
# What `leanprof` with no arguments profiles

The targets a Lake project declares, read from its `lakefile.lean` or
`lakefile.toml` as text (loading the configuration would need the project's
Lean and its dependencies), and the workload chosen from them: the one
executable, else the test driver when it is an executable, else compile time
of the libraries. Several executables are never chosen between: the caller
lists them.
-/

namespace Leanprof.Workload

structure Targets where
  exes : Array String := #[]
  libs : Array String := #[]
  /-- `testDriver` (or the older `testRunner`), or the target marked `@[test_driver]` -/
  testDriver : Option String := none
  deriving Repr, BEq, Inhabited

/-- The text of a `lakefile.lean` without comments (`--` to the end of the
line, nested `/- -/` blocks); string literals are kept, and a `--` inside one
is not a comment. -/
def stripLeanComments (s : String) : String := Id.run do
  let cs := s.toList.toArray
  let mut out : Array Char := #[]
  let mut i := 0
  let mut depth := 0
  let mut inStr := false
  while i < cs.size do
    let c := cs[i]!
    let n := cs[i + 1]?.getD ' '
    if depth > 0 then
      if c == '/' && n == '-' then depth := depth + 1; i := i + 2
      else if c == '-' && n == '/' then depth := depth - 1; i := i + 2; out := out.push ' '
      else
        if c == '\n' then out := out.push c
        i := i + 1
    else if inStr then
      out := out.push c
      if c == '\\' then
        out := out.push n
        i := i + 2
      else
        if c == '"' then inStr := false
        i := i + 1
    else if c == '"' then inStr := true; out := out.push c; i := i + 1
    else if c == '-' && n == '-' then
      while i < cs.size && cs[i]! != '\n' do i := i + 1
    else if c == '/' && n == '-' then depth := 1; i := i + 2
    else out := out.push c; i := i + 1
  return String.ofList out.toList

/-- Words of a `lakefile.lean`: identifiers (`«…»` unquoted), string literals
(with their quotes), `@[` and single punctuation characters. -/
def leanTokens (s : String) : Array String := Id.run do
  let cs := (stripLeanComments s).toList.toArray
  let mut toks : Array String := #[]
  let mut i := 0
  let isId (c : Char) := c.isAlphanum || c == '_' || c == '.' || c == '\'' || c == '!' || c == '?'
  while i < cs.size do
    let c := cs[i]!
    if c.isWhitespace then i := i + 1
    else if c == '«' then
      let mut j := i + 1
      while j < cs.size && cs[j]! != '»' do j := j + 1
      toks := toks.push (String.ofList (cs.extract (i + 1) j).toList)
      i := j + 1
    else if c == '"' then
      let mut j := i + 1
      while j < cs.size && cs[j]! != '"' do
        j := j + (if cs[j]! == '\\' then 2 else 1)
      toks := toks.push (String.ofList (cs.extract i (min (j + 1) cs.size)).toList)
      i := j + 1
    else if c == '@' && cs[i + 1]? == some '[' then
      toks := toks.push "@["
      i := i + 2
    else if isId c then
      let mut j := i
      while j < cs.size && isId cs[j]! do j := j + 1
      toks := toks.push (String.ofList (cs.extract i j).toList)
      i := j
    else if c == ':' && cs[i + 1]? == some '=' then
      toks := toks.push ":="
      i := i + 2
    else
      toks := toks.push c.toString
      i := i + 1
  return toks

def unquote (t : String) : String :=
  if t.length ≥ 2 && t.startsWith "\"" && t.endsWith "\"" then ((t.drop 1).dropEnd 1).toString else t

/-- The targets declared by a `lakefile.lean`. -/
def parseLean (s : String) : Targets := Id.run do
  let toks := leanTokens s
  let mut t : Targets := {}
  let mut attrs : Array String := #[]
  let mut i := 0
  while i < toks.size do
    let tok := toks[i]!
    if tok == "@[" then
      let mut j := i + 1
      while j < toks.size && toks[j]! != "]" do
        attrs := attrs.push toks[j]!
        j := j + 1
      i := j + 1
      continue
    if (tok == "lean_exe" || tok == "lean_lib") && i + 1 < toks.size then
      let name := unquote toks[i + 1]!
      if tok == "lean_exe" then t := { t with exes := t.exes.push name }
      else t := { t with libs := t.libs.push name }
      if attrs.contains "test_driver" || attrs.contains "test_runner" then
        t := { t with testDriver := some name }
      attrs := #[]
      i := i + 2
      continue
    if (tok == "testDriver" || tok == "testRunner") && toks[i + 1]? == some ":=" then
      if let some v := toks[i + 2]? then
        if v.startsWith "\"" then t := { t with testDriver := some (unquote v) }
      i := i + 3
      continue
    -- attributes belong to the declaration right after them
    if !attrs.isEmpty && tok != "]" then attrs := #[]
    i := i + 1
  return t

/-- The value of `key = "value"` on a TOML line, if the line sets `key`. -/
def tomlString (line key : String) : Option String := do
  let l := line.trimAscii.toString
  guard (l.startsWith key)
  let rest := (l.drop key.length).trimAscii.toString
  guard (rest.startsWith "=")
  let v := (rest.drop 1).trimAscii.toString
  guard (v.startsWith "\"")
  let body := (v.drop 1).toString
  return (body.splitOn "\"").head!

/-- The targets declared by a `lakefile.toml`. -/
def parseToml (s : String) : Targets := Id.run do
  let mut t : Targets := {}
  let mut sect := ""
  for raw in s.splitOn "\n" do
    let line := raw.trimAscii.toString
    if line.isEmpty || line.startsWith "#" then continue
    if line.startsWith "[" then
      sect := line
      continue
    if sect == "" then
      if let some v := tomlString line "testDriver" <|> tomlString line "testRunner" then
        t := { t with testDriver := some v }
    else if let some v := tomlString line "name" then
      if sect == "[[lean_exe]]" then t := { t with exes := t.exes.push v }
      else if sect == "[[lean_lib]]" then t := { t with libs := t.libs.push v }
  return t

/-- What `leanprof` with no arguments profiles. -/
inductive Choice where
  /-- an executable of the project, and why it was chosen -/
  | exe (name : String) (why : String)
  /-- several executables (and the test driver, if it is one): the user picks -/
  | ambiguous (exes : Array String) (testDriver : Option String)
  /-- no executable: compile time of the libraries -/
  | elab
  | nothing
  deriving Repr, BEq, Inhabited

def choose (t : Targets) : Choice :=
  let test := t.testDriver.filter (t.exes.contains ·)
  let programs := t.exes.filter (some · != test)
  if h : programs.size = 1 then .exe programs[0] "the project's only executable"
  else if programs.size > 1 then .ambiguous programs test
  else if let some d := test then .exe d "the test driver; the project has no other executable"
  else if !t.libs.isEmpty then .elab
  else .nothing

end Leanprof.Workload
