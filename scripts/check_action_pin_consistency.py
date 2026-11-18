#!/usr/bin/env python3
"""Reject an action repository pinned at more than one commit.

    python3 scripts/check_action_pin_consistency.py              # this repository
    python3 scripts/check_action_pin_consistency.py --root DIR   # a tree elsewhere

Reads every `.yml`/`.yaml` under `.github`. Each `uses: owner/repo[/path]@<sha>`
is grouped by `owner/repo` (case-insensitive), so `github/codeql-action/init`
and `github/codeql-action/upload-sarif` must name the same commit. Dependabot
opens one PR per file and sub-action; merging some of them leaves the rest on
the old commit, and nothing else notices.

Comment lines are ignored. Refs that are not a 40-hex sha are not compared.

EXIT_CODES:
  0  every action repository is pinned at one commit
  1  at least one repository is pinned at two or more commits
  2  the tree could not be read
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

USES = re.compile(
    r"^\s*(?:-\s+)?uses:\s*['\"]?([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/[^@\s'\"]*)?@([0-9a-fA-F]{40})\b"
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=Path(__file__).resolve().parent.parent, type=Path)
    args = parser.parse_args()
    gh = args.root / ".github"
    if not gh.is_dir():
        print(f"error: {gh} is not a directory", file=sys.stderr)
        return 2
    pins: dict[str, dict[str, list[str]]] = {}
    files = sorted(p for p in gh.rglob("*") if p.suffix in (".yml", ".yaml") and p.is_file())
    for path in files:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError) as exc:
            print(f"error: {path}: {exc}", file=sys.stderr)
            return 2
        for n, line in enumerate(lines, 1):
            m = USES.match(line)
            if not m:
                continue
            repo, sha = m.group(1).lower(), m.group(2).lower()
            where = f"{path.relative_to(args.root)}:{n}"
            pins.setdefault(repo, {}).setdefault(sha, []).append(where)
    bad = 0
    for repo in sorted(pins):
        if len(pins[repo]) < 2:
            continue
        bad = 1
        print(f"{repo} is pinned at {len(pins[repo])} commits:")
        for sha, places in sorted(pins[repo].items()):
            print(f"  {sha}: {', '.join(places)}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
