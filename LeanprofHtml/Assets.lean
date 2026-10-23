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

/-- The page for `data` (compressed JSON). `<` is escaped, so nothing in the
data can close its script element. -/
def page (title data : String) : String :=
  "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n" ++
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" ++
  "<meta name=\"generator\" content=\"leanprof html\">\n" ++
  s!"<title>{escapeHtml title}</title>\n<style>\n{css}</style>\n</head>\n<body>\n" ++
  "<div id=\"app\"><noscript>This report needs JavaScript.</noscript></div>\n" ++
  s!"<script id=\"leanprof-data\" type=\"application/json\">{data.replace "<" "\\u003c"}</script>\n" ++
  s!"<script>\n{js}</script>\n</body>\n</html>\n"

end LeanprofHtml
