#!/usr/bin/env python3
"""Check a page written by `leanprof html`.

    check-html.py PAGE.html [--expect TEXT]... [--max-kib N]

Fails unless the page is well-formed HTML (one doctype, every element
closed, nothing loaded from elsewhere), its embedded data is JSON with at
least one report, its script parses (`node --check`, when node is
installed), it is at most --max-kib KiB (default 300), and each --expect
text occurs in the embedded data.
"""
import argparse
import html.parser
import json
import os
import shutil
import subprocess
import sys
import tempfile

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


class Checker(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.errors, self.doctypes = [], [], 0
        self.scripts = []  # (attrs, text)
        self._script = None

    def handle_decl(self, decl):
        if decl.lower() == "doctype html":
            self.doctypes += 1

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        for k in ("src", "href"):
            v = a.get(k) or ""
            if "//" in v:
                self.errors.append(f"<{tag} {k}={v!r}> loads something from elsewhere")
        if tag == "link":
            self.errors.append("<link> element: the page must be self-contained")
        if tag == "script":
            self._script = (a, [])
        if tag not in VOID:
            self.stack.append((tag, self.getpos()))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.stack.pop()

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack or self.stack[-1][0] != tag:
            self.errors.append(f"</{tag}> at line {self.getpos()[0]} does not close {self.stack[-1] if self.stack else 'anything'}")
            return
        self.stack.pop()
        if tag == "script" and self._script:
            self.scripts.append((self._script[0], "".join(self._script[1])))
            self._script = None

    def handle_data(self, data):
        if self._script:
            self._script[1].append(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("page")
    ap.add_argument("--expect", action="append", default=[])
    ap.add_argument("--max-kib", type=int, default=300)
    o = ap.parse_args()
    text = open(o.page, encoding="utf-8").read()
    errors = []
    size = os.path.getsize(o.page)
    if size > o.max_kib * 1024:
        errors.append(f"{size // 1024} KiB, more than {o.max_kib} KiB")
    if not text.lower().startswith("<!doctype html>"):
        errors.append("does not start with <!doctype html>")
    p = Checker()
    p.feed(text)
    p.close()
    errors += p.errors
    if p.doctypes != 1:
        errors.append(f"{p.doctypes} doctypes")
    if p.stack:
        errors.append(f"unclosed elements: {p.stack}")
    data = [t for a, t in p.scripts if a.get("id") == "leanprof-data"]
    code = [t for a, t in p.scripts if "id" not in a and "src" not in a]
    reports = []
    if len(data) != 1:
        errors.append(f"{len(data)} data scripts")
    else:
        try:
            reports = json.loads(data[0]).get("reports", [])
        except ValueError as e:
            errors.append(f"data is not JSON: {e}")
        if not reports:
            errors.append("no reports in the data")
        for e in o.expect:
            if e not in data[0]:
                errors.append(f"{e!r} not in the page's data")
    if len(code) != 1:
        errors.append(f"{len(code)} inline scripts")
    elif shutil.which("node"):
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
            f.write(code[0])
        r = subprocess.run(["node", "--check", f.name], capture_output=True, text=True)
        os.unlink(f.name)
        if r.returncode:
            errors.append("script does not parse:\n" + r.stderr)
    kinds = ", ".join(f"{r.get('role')} {r.get('kind')}" + (" with flame graph" if "flame" in r else "") for r in reports)
    print(f"{o.page}: {size // 1024} KiB, reports: {kinds}")
    for e in errors:
        print("error:", e)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
