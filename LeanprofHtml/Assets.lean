/-!
# The page `leanprof html` writes

`report.css` and `report.js` (next to this file) are compiled into the
command, so the page and the command need nothing else at run time (the
lakefile's `needs` rebuilds this module when they change).
-/

namespace LeanprofHtml

def css : String := include_str "report.css"
def js : String := include_str "report.js"

/-- `s` safe as HTML text. -/
def escapeHtml (s : String) : String :=
  ((s.replace "&" "&amp;").replace "<" "&lt;").replace ">" "&gt;"

/-- `s` with every `<` written `\u003c`, a byte at a time (`String.replace` is
several times slower on a report of megabytes). -/
def escapeLt (s : String) : String := Id.run do
  let rep := "\\u003c".toUTF8
  let mut out := ByteArray.emptyWithCapacity (s.utf8ByteSize + 64)
  for x in s.toUTF8 do
    out := if x == 60 then out ++ rep else out.push x
  return String.fromUTF8! out

/-- The page for `data` (compressed JSON). `<` is escaped, so nothing in the
data can close its script element. -/
def page (title data : String) : String :=
  "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n" ++
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" ++
  "<meta name=\"generator\" content=\"leanprof html\">\n" ++
  s!"<title>{escapeHtml title}</title>\n<style>\n{css}</style>\n</head>\n<body>\n" ++
  "<div id=\"app\"><noscript>This report needs JavaScript.</noscript></div>\n" ++
  s!"<script id=\"leanprof-data\" type=\"application/json\">{escapeLt data}</script>\n" ++
  s!"<script>\n{js}</script>\n</body>\n</html>\n"

end LeanprofHtml
