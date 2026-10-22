#!/usr/bin/env python3
"""Published pages describe what the product does now, not how it got there.

History belongs in CHANGELOG.md. A page that says "the previous default was"
or "new in 0.24.0" is out of date the day it is published, and it buries the
current behaviour under an account of an older one.

Checks README.md and every docs/*.md outside fenced and inline code for the
clearest history phrases. A line that must keep one (a product's own former name, say)
is listed in ALLOW as (file, text on that line).

Usage: check_docs_tense.py [--root <dir>] [--quiet]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

PHRASES = [
    r"there was none",
    r"\bpreviously\b",
    r"\bthe previous (default|version|behaviou?r|note)\b",
    r"\bused to be\b",
    r"\bno longer\b",
    r"\bnew in (v?\d|this (release|version))",
    r"\b(since|until|before|in) v?0\.\d+(\.\d+)?\b",
    r"\bwas hardcoded\b",
    r"\bbefore this\b",
    r"\ban older note\b",
    r"\bthis fleet\b",
    r"\bhad it backwards\b",
    r"\bnothing (checked|caught|noticed)\b",
    r"\b(was|were|has been|have been) (added|removed|renamed|introduced|replaced|dropped)\b",
    r"\bchanged from\b",
    r"\b(is|are) now\b",
    # "now <verb>s": "it now runs", "the preset now supports". Plain "now", as
    # in "run it now", is not history.
    r"\bnow (?!(?:is|has|this|was|as|its|us|yes)\b)[a-z]+s\b",
    r"\bnow (has|have)\b",
    r"(?<![\w/])\(#\d+\)",
    r"\bPR #?\d+\b",
]
PHRASE_RE = re.compile("|".join(PHRASES), re.I)
# A fence opens with three or more backticks or tildes and closes with a run of
# the same character at least as long, with nothing after it.
FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})")
# Inline code quotes a literal; history words inside one are not prose.
INLINE_CODE_RE = re.compile(r"(`+)(?:(?!\1).)+?\1")

# (file relative to the root, text that appears on the allowed line)
ALLOW: list[tuple[str, str]] = [
    ("docs/windows-signing.md", "Azure Artifact Signing (formerly Trusted Signing)"),
]


def pages(root: pathlib.Path) -> list[pathlib.Path]:
    found = [root / "README.md", *sorted((root / "docs").glob("*.md"))]
    return [p for p in found if p.is_file()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root to check")
    parser.add_argument("--quiet", action="store_true", help="only report problems")
    args = parser.parse_args()
    root = pathlib.Path(args.root)

    problems = []
    for page in pages(root):
        rel = page.relative_to(root).as_posix()
        fence = ""  # the opening marker while inside a fence
        for number, line in enumerate(page.read_text(encoding="utf-8").splitlines(), 1):
            marker = FENCE_RE.match(line)
            if marker:
                run = marker.group(1)
                if not fence:
                    fence = run
                elif run[0] == fence[0] and len(run) >= len(fence) and not line.strip()[len(run):]:
                    fence = ""
                continue
            if fence:
                continue
            match = PHRASE_RE.search(INLINE_CODE_RE.sub("``", line))
            if not match:
                continue
            if any(rel == f and text in line for f, text in ALLOW):
                continue
            problems.append(f"{rel}:{number}: \"{match.group(0)}\" tells history: {line.strip()[:120]}")

    if problems:
        print("[ERROR] published pages must describe current behaviour; history goes in CHANGELOG.md:", file=sys.stderr)
        for line in problems:
            print(f"      {line}", file=sys.stderr)
        return 1
    if not args.quiet:
        print(f"[INFO] {len(pages(root))} page(s) describe current behaviour")
    return 0


if __name__ == "__main__":
    sys.exit(main())
