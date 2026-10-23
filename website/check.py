#!/usr/bin/env python3
"""Check the built site's links: every internal link and image resolves to a
file, every #anchor to an id on its page, and every link to a file of this
repository on GitHub (blob/main, tree/main) to a file or directory that
exists. External sites are not fetched.

    python3 website/check.py [_site]
"""

import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
PREFIX = "/leanprof/"  # where GitHub Pages serves the site
REPO = "https://github.com/unbalancedparentheses/leanprof/"


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.refs = set(), []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            self.ids.add(a["id"])
        if tag == "a" and "name" in a:
            self.ids.add(a["name"])
        for key in ("href", "src"):
            if key in a and a[key] is not None and not (tag == "link" and a.get("rel") == "preconnect"):
                self.refs.append((tag, a[key], self.getpos()[0]))


def main():
    site = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "_site").resolve()
    pages = {}
    for f in sorted(site.rglob("*.html")):
        p = Page()
        p.feed(f.read_text())
        pages[f] = p
    errors, n = [], 0
    for f, p in pages.items():
        rel = f.relative_to(site)
        for tag, ref, line in p.refs:
            n += 1
            where = f"{rel}:{line}"
            u = urlsplit(ref)
            if u.scheme in ("http", "https"):
                if ref.startswith(REPO + "blob/main/") or ref.startswith(REPO + "tree/main/"):
                    path = unquote(u.path.split("/main/", 1)[1])
                    if not (ROOT / path).exists():
                        errors.append(f"{where}: {ref}: no {path} in the repository")
                continue
            if u.scheme or ref.startswith("//"):
                continue
            if u.path.startswith(PREFIX):
                target = site / u.path[len(PREFIX):]
            elif u.path.startswith("/"):
                errors.append(f"{where}: {ref}: absolute path outside {PREFIX}")
                continue
            elif u.path:
                target = (f.parent / unquote(u.path)).resolve()
            else:
                target = f
            if target.is_dir():
                target = target / "index.html"
            if not target.exists():
                errors.append(f"{where}: {ref}: {target.relative_to(site) if target.is_relative_to(site) else target} does not exist")
                continue
            if u.fragment:
                if target.suffix != ".html":
                    errors.append(f"{where}: {ref}: anchor on a non-page")
                elif unquote(u.fragment) not in pages[target].ids:
                    errors.append(f"{where}: {ref}: no id {u.fragment!r} in {target.relative_to(site)}")
    for e in errors:
        print(e)
    print(f"{len(pages)} pages, {n} links and images checked, {len(errors)} broken")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
