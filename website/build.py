#!/usr/bin/env python3
"""Build the leanprof website from the repository's Markdown.

    python3 website/build.py [--out _site]

The docs pages are rendered from docs/guide, docs/case-studies and bench at
build time, and the landing page takes its message ("Where leanprof wins", the
comparison table, the opening paragraph) from README.md, so the site cannot
drift from the repository. The numbers the landing page states in its own
words are listed in FACTS below and the build fails unless each one appears
verbatim both in the document it cites and on the page.
"""

import argparse
import html
import os
import re
import shutil
import sys
from pathlib import Path

from markdown_it import MarkdownIt
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from pygments.util import ClassNotFound

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "website"
REPO = "https://github.com/unbalancedparentheses/leanprof"
BLOB = REPO + "/blob/main/"
TREE = REPO + "/tree/main/"

# Navigation, in reading order. Paths are repository paths; each page is
# written at the same path with .html.
NAV = [
    ("Guide", [
        "docs/guide/getting-started.md",
        "docs/guide/run-time.md",
        "docs/guide/copies-and-allocations.md",
        "docs/guide/static-copies.md",
        "docs/guide/fix.md",
        "docs/guide/experiment.md",
        "docs/guide/proof-audit.md",
        "docs/guide/memory.md",
        "docs/guide/compile-time.md",
        "docs/guide/build-time.md",
        "docs/guide/editor.md",
        "docs/guide/vscode.md",
        "docs/guide/html-report.md",
        "docs/guide/ci-and-regressions.md",
        "docs/guide/live.md",
        "docs/guide/lean-api.md",
        "docs/guide/reference.md",
        "docs/guide/how-it-works.md",
    ]),
    ("Case studies", [
        "docs/case-studies/lean-compiler-backend.md",
        "docs/case-studies/doc-gen4.md",
        "docs/case-studies/verso.md",
        "docs/case-studies/lean-regex.md",
        "docs/case-studies/concrete.md",
        "docs/case-studies/batteries.md",
        "docs/case-studies/mathlib.md",
        "docs/case-studies/build-time.md",
        "docs/case-studies/compile-time-vs-lean-source-profiler.md",
        "docs/case-studies/leanbench.md",
        "docs/profiles/README.md",
    ]),
    ("Benchmarks", [
        "bench/README.md",
        "bench/RESULTS.md",
    ]),
]
NAV_TITLES = {  # shorter names for the sidebar where the H1 is long
    "docs/case-studies/compile-time-vs-lean-source-profiler.md": "vs lean-source-profiler",
    "bench/README.md": "Benchmarks and LeanProfiler",
    "docs/profiles/README.md": "Published profiles",
    "bench/RESULTS.md": "Accuracy results",
}
RENDERED = {p for _, pages in NAV for p in pages}
README_TARGET = "index.html"

# Numbers the landing page states in its own words: (source, [facts]).
# Each fact must appear in the source (ignoring ` and * and line breaks) and
# in the landing page's text.
FACTS = [
    ("docs/case-studies/lean-compiler-backend.md", [
        "4,066,775", "11,946,202", "8,572,024", "−28%", "4864dd2",
        "byte-identical", "30 times slower", "91,020", "6.84 GiB", "121,054",
    ]),
    ("docs/case-studies/doc-gen4.md", [
        "two thirds of its CPU time is one SQL query", "getContainedNames",
        "12.7% of the CPU time is threads waiting for SQLite's global memory mutex",
        "SQLITE_DEFAULT_MEMSTATUS=0", "29,026", "69.9 MiB",
    ]),
    ("bench/README.md", [
        "4.6 µs", "20.1 µs", "88.5 µs", "15.9–17.8, 8.9–17.0 and 10.0–11.6 ns", "12003", "123.0 MiB",
        "every span copies every event recorded so far",
    ]),
    ("docs/case-studies/batteries.md", [
        "195", "13.3 s", "17.0 s", "216.5 M", "14.4%", "decreasing_tactic",
        "24,369",
    ]),
    ("docs/case-studies/compile-time-vs-lean-source-profiler.md", [
        "16.8 s", "102.9 s", "152.3 s",
    ]),
]


# --- Markdown ---------------------------------------------------------------

def slugify(text, seen):
    s = text.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    s = s.replace(" ", "-")
    base, n = s, seen.get(s, 0)
    if n:
        s = f"{base}-{n}"
    seen[base] = n + 1
    return s


CMD = re.compile(
    r"^\s*(\$ )?(leanprof|lake|git|sh|cd|python3|brew|cargo|curl|export|samply|elan|"
    r"lean|kill|cat|ls|rm|mkdir|cp|LEANPROF_\w+=|LEAN_\w+=|\./|\.lake/|#)(?=[\s/=]|$)")
OUTPUT_LIKE = re.compile(r"^\s*\S+( \S+)?:\s")


def hl(code, lexer):
    return highlight(code, lexer, HtmlFormatter(nowrap=True))


def highlight_block(code, lang):
    lang = (lang or "").strip().split()[0] if lang else ""
    if lang in ("lean", "lean4"):
        return hl(code, get_lexer_by_name("lean4"))
    if lang in ("sh", "bash", "shell", "console"):
        lang = ""
    if lang:
        try:
            return hl(code, get_lexer_by_name(lang))
        except ClassNotFound:
            return html.escape(code)
    # Unlabelled blocks mix commands and their output: highlight lines that
    # are shell commands, leave output as it is.
    bash = get_lexer_by_name("bash")
    out = []
    for line in code.split("\n"):
        if line.strip() and CMD.match(line) and not OUTPUT_LIKE.match(line) \
                and not line.lstrip().startswith("#leanprof"):
            prompt = ""
            if line.startswith("$ "):
                prompt, line = '<span class="gp">$ </span>', line[2:]
            out.append(prompt + hl(line, bash).rstrip("\n"))
        else:
            out.append(html.escape(line))
    return "\n".join(out)


def make_md():
    md = MarkdownIt("commonmark", {"html": False, "typographer": False,
                                   "highlight": lambda c, lang, attrs: highlight_block(c, lang)})
    md.enable(["table", "strikethrough"])
    return md


def site_rel(from_out, to_out):
    """Relative URL from one output file to another."""
    return os.path.relpath(to_out, os.path.dirname(from_out) or ".").replace(os.sep, "/")


def out_path(src):
    if src == "README.md":
        return README_TARGET
    return src[:-3] + ".html"


def rewrite_link(href, src, out):
    """Map a link written in repository file `src` to the site page `out`."""
    if re.match(r"^[a-z][a-z0-9+.-]*:", href, re.I) or href.startswith("#") or not href:
        return href
    path, _, frag = href.partition("#")
    target = os.path.normpath(os.path.join(os.path.dirname(src), path)).replace(os.sep, "/")
    frag = "#" + frag if frag else ""
    if target in RENDERED or target == "README.md":
        return site_rel(out, out_path(target)) + frag
    if target.startswith("docs/images/") or target.startswith("docs/profiles/"):
        return site_rel(out, target)
    if target.startswith(".."):
        return href
    kind = TREE if (ROOT / target).is_dir() else BLOB
    return kind + target + frag


def render(md_text, src, out, drop_h1=False):
    md = make_md()
    tokens = md.parse(md_text)
    seen = {}
    title = None
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t.type == "heading_open":
            inline = tokens[i + 1]
            text = "".join(c.content for c in inline.children if c.type in ("text", "code_inline"))
            if t.tag == "h1" and title is None:
                title = text
                if drop_h1:
                    del tokens[i:i + 3]
                    continue
            hid = slugify(text, seen)
            t.attrSet("id", hid)
        if t.type == "inline" and t.children:
            for c in t.children:
                if c.type == "link_open":
                    c.attrSet("href", rewrite_link(c.attrGet("href"), src, out))
                    if c.attrGet("href").startswith("http"):
                        c.attrSet("rel", "noopener")
                elif c.type == "image":
                    c.attrSet("src", rewrite_link(c.attrGet("src"), src, out))
                    c.attrSet("loading", "lazy")
        i += 1
    body = md.renderer.render(tokens, md.options, {})
    # Wide tables scroll inside their own box on narrow screens.
    body = body.replace("<table>", '<div class="table"><table>').replace("</table>", "</table></div>")
    # A self link on each section heading.
    body = re.sub(r'<(h[23]) id="([^"]+)">(.*?)</\1>',
                  r'<\1 id="\2"><a class="self" href="#\2">\3</a></\1>', body)
    return title, body


def plain(s):
    """Text of a fact as checked: no Markdown emphasis or code marks, one space per run."""
    return re.sub(r"\s+", " ", s.replace("`", "").replace("*", "")).strip()


# --- Page shell -------------------------------------------------------------

def page(out, title, description, body, active=None, body_class=""):
    shell = (WEB / "templates" / "page.html").read_text()
    up = site_rel(out, "index.html")[: -len("index.html")]  # "" or "../../"
    nav = []
    for section, first in (("Docs", "docs/guide/getting-started.html"),
                           ("Case studies", "docs/case-studies/lean-compiler-backend.html"),
                           ("Benchmarks", "bench/README.html")):
        cur = ' aria-current="true"' if active == section else ""
        nav.append(f'<a href="{up}{first}"{cur}>{section}</a>')
    return (shell.replace("{{title}}", html.escape(title))
            .replace("{{description}}", html.escape(description, quote=True))
            .replace("{{up}}", up)
            .replace("{{nav}}", "\n      ".join(nav))
            .replace("{{body_class}}", body_class)
            .replace("{{body}}", body))


def sidebar(out, current):
    parts = []
    for section, pages in NAV:
        items = []
        for p in pages:
            name = NAV_TITLES.get(p) or nav_title(p)
            cur = ' aria-current="page"' if p == current else ""
            items.append(f'<li><a href="{site_rel(out, out_path(p))}"{cur}>{html.escape(name)}</a></li>')
        parts.append(f"<h2>{section}</h2>\n<ul>\n" + "\n".join(items) + "\n</ul>")
    return "\n".join(parts)


_titles = {}


def nav_title(p):
    if p not in _titles:
        first = (ROOT / p).read_text().split("\n", 1)[0]
        t = first.lstrip("# ").replace("`", "")
        t = re.sub(r"^Case study: (compile time of )?", "", t)
        _titles[p] = t
    return _titles[p]


def first_paragraph(md_text):
    for block in md_text.split("\n\n")[1:]:
        b = block.strip()
        if b and not b.startswith(("#", "```", "|", "-", ">")):
            return re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", re.sub(r"\s+", " ", b)).replace("`", "")
    return ""


def section_of(p):
    return {"docs/guide": "Docs", "docs/case-studies": "Case studies", "docs/profiles": "Case studies", "bench": "Benchmarks"}[
        os.path.dirname(p)]


def build_doc(src, outdir):
    out = out_path(src)
    text = (ROOT / src).read_text()
    title, body = render(text, src, out)
    flat = [p for _, pages in NAV for p in pages]
    i = flat.index(src)
    pager = []
    if i > 0:
        pager.append(f'<a rel="prev" href="{site_rel(out, out_path(flat[i-1]))}">'
                     f'<span>Previous</span>{html.escape(NAV_TITLES.get(flat[i-1]) or nav_title(flat[i-1]))}</a>')
    if i + 1 < len(flat):
        pager.append(f'<a rel="next" href="{site_rel(out, out_path(flat[i+1]))}">'
                     f'<span>Next</span>{html.escape(NAV_TITLES.get(flat[i+1]) or nav_title(flat[i+1]))}</a>')
    content = f"""<div class="docs">
  <aside class="sidebar">
    <nav aria-label="Documentation">
{sidebar(out, src)}
    </nav>
  </aside>
  <details class="docnav">
    <summary>All pages</summary>
    <nav aria-label="Documentation (menu)">
{sidebar(out, src)}
    </nav>
  </details>
  <article class="prose">
{body}
    <footer class="docfoot">
      <nav class="pager">{''.join(pager)}</nav>
      <p><a href="{BLOB}{src}">{src}</a> on GitHub. This page is generated from that file.</p>
    </footer>
  </article>
</div>"""
    title_plain = title.replace("`", "") if title else src
    write(outdir, out, page(out, f"{title_plain} · leanprof", first_paragraph(text), content,
                            active=section_of(src), body_class="doc"))


def write(outdir, rel, text):
    p = outdir / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


# --- Landing page -----------------------------------------------------------

def readme_section(readme, heading):
    m = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", readme, re.S | re.M)
    if not m:
        sys.exit(f"README.md has no '## {heading}' section")
    return m.group(1).strip()


def readme_opening(readme):
    m = re.search(r"((?:^> .*\n?)+)", readme, re.M)
    if not m:
        sys.exit("README.md does not open with a quoted paragraph")
    return "\n".join(line[2:] for line in m.group(1).strip().split("\n"))


def inline_md(text, out):
    _, body = render(text, "README.md", out)
    return body.strip()


def source_listing(path, first, last, marks):
    """Lines first..last of a Lean file, highlighted, with line numbers."""
    lines = (ROOT / path).read_text().split("\n")
    code = "\n".join(lines[first - 1:last])
    hl_lines = hl(code, get_lexer_by_name("lean4")).rstrip("\n").split("\n")
    rows = []
    for n, h in zip(range(first, last + 1), hl_lines):
        cls = ' class="marked"' if n in marks else ""
        rows.append(f'<span{cls}><span class="ln">{n}</span>{h}</span>')
    return "".join(rows)


def terminal(path, mark=None, labels=()):
    text = (WEB / path).read_text().rstrip("\n")
    lines = []
    for line in text.split("\n"):
        e = html.escape(line)
        if mark and mark(line):
            e = f'<span class="hit">{e}</span>'
        for lab in labels:
            if line.startswith(f"  {lab}:"):
                e = e.replace(f"{lab}:", f'<b class="lab">{lab}:</b>', 1)
        lines.append(e)
    return "\n".join(lines)


def editor_hint():
    """The first hint line of docs/guide/editor.md, split into code and hints."""
    text = (ROOT / "docs/guide/editor.md").read_text()
    m = re.search(r"Every line the reports mention.*?```\n(.*?)\n", text, re.S)
    line = m.group(1)
    code, *hints = re.split(r"\s{3,}", line)
    code_html = hl(code, get_lexer_by_name("lean4")).rstrip("\n")
    hints_html = "".join(f'<span class="hint{" copy" if h.startswith("⚠") else ""}">'
                         f'{html.escape(h)}</span>' for h in hints)
    return code_html, hints_html


def docs_index(out):
    cols = []
    for section, pages in NAV:
        items = "".join(f'<li><a href="{site_rel(out, out_path(p))}">'
                        f'{html.escape(NAV_TITLES.get(p) or nav_title(p))}</a></li>' for p in pages)
        cols.append(f"<div><h3>{section}</h3><ul>{items}</ul></div>")
    return '<div class="cols">' + "".join(cols) + "</div>"


def build_landing(outdir):
    out = README_TARGET
    readme = (ROOT / "README.md").read_text()
    tpl = (WEB / "templates" / "index.html").read_text()
    code_html, hints_html = editor_hint()
    subs = {
        "opening": inline_md(readme_opening(readme), out),
        "why_intro": inline_md(readme_section(readme, "Where leanprof wins, and where it does not").split("\n\n", 1)[0], out),
        "why": inline_md(readme_section(readme, "Where leanprof wins, and where it does not").split("\n\n", 1)[1], out),
        "compare": inline_md(readme_section(readme, "How it compares").split("\n### ", 1)[0], out),
        "source": source_listing("Examples/CopyBug.lean", 17, 23, {21, 22}),
        "run": terminal("output/run.txt", mark=lambda l: "15.3 MiB" in l),
        "explain": terminal("output/explain.txt", labels=("why", "fix")),
        "hint_code": code_html,
        "hint_hints": hints_html,
        "docs_index": docs_index(out),
    }
    for k, v in subs.items():
        tpl = tpl.replace("{{" + k + "}}", v)
    left = re.findall(r"{{\w+}}", tpl)
    if left:
        sys.exit(f"landing template: unfilled {left}")
    # Every stated number is in its source document and on the page.
    page_text = plain(html.unescape(re.sub(r"<[^>]+>", " ", tpl)))
    page_text = re.sub(r"\s+", " ", page_text)
    bad = []
    for src, facts in FACTS:
        doc = plain((ROOT / src).read_text())
        for f in facts:
            if plain(f) not in doc:
                bad.append(f"{f!r} is not in {src}")
            if plain(f) not in page_text:
                bad.append(f"{f!r} (from {src}) is not on the landing page")
    if bad:
        sys.exit("landing page facts:\n  " + "\n  ".join(bad))
    write(outdir, out, page(out, "leanprof: a profiler for Lean 4",
                            plain(readme_opening(readme)), tpl, body_class="home"))


def build(outdir):
    if outdir.exists():
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True)
    for _, pages in NAV:
        for p in pages:
            build_doc(p, outdir)
    build_landing(outdir)
    shutil.copytree(ROOT / "docs" / "images", outdir / "docs" / "images")
    # the published profiles: pages made by `leanprof html` and their reports, served as they are
    shutil.copytree(ROOT / "docs" / "profiles", outdir / "docs" / "profiles",
                    ignore=lambda d, names: [n for n in names if n.endswith(".md")], dirs_exist_ok=True)
    shutil.copy(WEB / "style.css", outdir / "style.css")
    shutil.copy(WEB / "favicon.svg", outdir / "favicon.svg")
    (outdir / ".nojekyll").write_text("")
    # 404 page for GitHub Pages: absolute links, since it is served at any path.
    notfound = page("404.html", "Not found · leanprof", "Page not found",
                    '<article class="prose narrow"><h1>Not found</h1><p>There is no page at this '
                    'address. Start from the <a href="/leanprof/">home page</a> or the '
                    '<a href="/leanprof/docs/guide/getting-started.html">getting started guide</a>.'
                    '</p></article>')
    write(outdir, "404.html", notfound.replace('href="style.css"', 'href="/leanprof/style.css"')
          .replace('href="favicon.svg"', 'href="/leanprof/favicon.svg"')
          .replace('href="docs/', 'href="/leanprof/docs/').replace('href="bench/', 'href="/leanprof/bench/')
          .replace('href="index.html"', 'href="/leanprof/"'))
    n = sum(1 for _ in outdir.rglob("*.html"))
    print(f"built {n} pages into {outdir}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "_site"))
    build(Path(ap.parse_args().out))
