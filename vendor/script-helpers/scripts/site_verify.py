#!/usr/bin/env python3
"""Verify a built static site the way a visitor reaches it: over HTTP.

    python3 scripts/site_verify.py <site dir>             # crawl from /
    python3 scripts/site_verify.py --fences <docs dir>    # fence balance in Markdown

Crawl: serves <site dir> on 127.0.0.1 at a port the OS picks (so it never
meets a taken port), fetches / and every page linked from it, and every
internal link, image, script and stylesheet those pages name. Reports each
target that does not answer 200, and each #fragment the target page has no
id for, with the page that links to it. External links are not fetched: a
check that needs the network fails for reasons that are not the site's.

Fences: a code fence left open swallows the rest of the page into one code
block. `mkdocs build --strict` does not see it (it checks links, and a
swallowed section has none), so this does.

Exit: 0 clean, 1 problems found (listed), 2 usage.
Standard library only, Python 3.8+.
"""
from __future__ import annotations

import argparse
import functools
import http.server
import re
import socketserver
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path


class _Links(HTMLParser):
    """Collects link targets and element ids from one page."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.targets: list[str] = []
        self.ids: set[str] = set()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        for key in ("href", "src"):
            if a.get(key):
                self.targets.append(a[key])


class _Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):  # noqa: D401 - silence the access log
        pass


def _serve(root: Path):
    handler = functools.partial(_Quiet, directory=str(root))
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def _fetch(url: str):
    try:
        with urllib.request.urlopen(url, timeout=15) as r:  # noqa: S310 - loopback only
            return r.status, r.headers.get_content_type(), r.read(), r.geturl()
    except urllib.error.HTTPError as e:
        return e.code, "", b"", url
    except (urllib.error.URLError, OSError) as e:
        return 0, str(e), b"", url


def crawl(root: Path) -> list[str]:
    if not (root / "index.html").is_file():
        return [f"no index.html at the site root ({root}): the site would serve 404"]
    server = _serve(root)
    base = f"http://127.0.0.1:{server.server_address[1]}/"
    problems: list[str] = []
    pages: dict[str, set[str]] = {}       # page path -> ids
    status: dict[str, int] = {}
    wanted: list[tuple[str, str, str]] = []  # (target path, fragment, from page)
    queue = ["/"]
    seen = set(queue)
    try:
        while queue:
            path = queue.pop()
            code, ctype, body, final = _fetch(urllib.parse.urljoin(base, path))
            status[path] = code
            if code != 200 or ctype != "text/html":
                continue
            parser = _Links()
            parser.feed(body.decode("utf-8", "replace"))
            pages[path] = parser.ids
            # A link to "guide" is redirected to "guide/"; that page's own
            # relative links resolve against where it was served, as a
            # browser resolves them.
            path = urllib.parse.urlsplit(final).path or path
            for raw in parser.targets:
                parts = urllib.parse.urlsplit(raw)
                if parts.scheme or parts.netloc or raw.startswith(("mailto:", "tel:", "javascript:", "data:")):
                    continue
                target = urllib.parse.urljoin(path, parts.path) if parts.path else path
                target = urllib.parse.urlsplit(target).path or "/"
                wanted.append((target, urllib.parse.unquote(parts.fragment), path))
                if target not in seen:
                    seen.add(target)
                    queue.append(target)
        for target, fragment, page in wanted:
            code = status.get(target)
            if code != 200:
                problems.append(f"{page}: links to {target}, which answers {code or 'nothing'}")
            elif fragment and target in pages and fragment not in pages[target]:
                problems.append(f"{page}: links to {target}#{fragment}, and that page has no such id")
    finally:
        server.shutdown()
        server.server_close()
    # One message per broken target and page, however often it is linked.
    return sorted(set(problems))


FENCE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")


def fences(docs: Path) -> list[str]:
    problems = []
    for md in sorted(docs.rglob("*.md")):
        open_at = None
        marker = ""
        for n, line in enumerate(md.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            m = FENCE.match(line)
            if not m:
                continue
            run, rest = m.group(1), m.group(2)
            if open_at is None:
                open_at, marker = n, run
            elif run[0] == marker[0] and len(run) >= len(marker) and not rest.strip():
                open_at = None
        if open_at is not None:
            problems.append(f"{md}:{open_at}: code fence {marker} is never closed; the rest of the page renders as code")
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dir", type=Path)
    ap.add_argument("--fences", action="store_true", help="check Markdown sources for unclosed fences")
    args = ap.parse_args(argv)
    if not args.dir.is_dir():
        print(f"site_verify: not a directory: {args.dir}", file=sys.stderr)
        return 2
    problems = fences(args.dir) if args.fences else crawl(args.dir.resolve())
    for p in problems:
        print(p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
