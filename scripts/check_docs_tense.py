#!/usr/bin/env python3
"""Published pages describe what the product does now, not how it got there.

History belongs in CHANGELOG.md. A page that says "the previous default was"
or "new in 0.24.0" is out of date the day it is published, and it buries the
current behaviour under an account of an older one.

Checks README.md and every docs/*.md outside fenced code for the clearest
history phrases. A line that must keep one (a product's own former name, say)
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
    r"\bnew in v?\d",
    r"\b(since|until|before|in) v?0\.\d+(\.\d+)?\b",
    r"\bwas hardcoded\b",
    r"\bbefore this\b",
    r"\ban older note\b",
    r"\bthis fleet\b",
    r"\bhad it backwards\b",
    r"\bnothing (checked|caught|noticed)\b",
    r"\b(was|were) (added|removed|renamed|introduced)\b",
    r"\bit now\b",
    r"\bis now\b",
    r"\bnow (runs|does|uses|fails|refuses|takes)\b",
    r"(?<![\w/])\(#\d+\)",
    r"\bPR #?\d+\b",
]
PHRASE_RE = re.compile("|".join(PHRASES), re.I)

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
        fence = False
        for number, line in enumerate(page.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("```"):
                fence = not fence
                continue
            if fence:
                continue
            match = PHRASE_RE.search(line)
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
