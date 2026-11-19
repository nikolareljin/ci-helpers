#!/usr/bin/env python3
"""Reject an action repository pinned at more than one commit.

    python3 scripts/check_action_pin_consistency.py              # this repository
    python3 scripts/check_action_pin_consistency.py --root DIR   # a tree elsewhere

Reads every `.yml`/`.yaml` under `.github`. Each `uses: owner/repo[/path]@<sha>`
is grouped by `owner/repo` (case-insensitive), so `github/codeql-action/init`
and `github/codeql-action/upload-sarif` must name the same commit. Dependabot
opens one PR per file and sub-action; merging some of them leaves the rest on
the old commit, and nothing else notices.

Files are parsed with PyYAML and every mapping key `uses` with a string value
is read, at any depth (`jobs.*.uses`, `jobs.*.steps[*].uses`, composite
`runs.steps[*].uses`, flow style included). Comments and block-scalar text such
as `run: |` fixtures are never read as pins. Refs that are not a 40-hex sha
are not compared.

EXIT_CODES:
  0  every action repository is pinned at one commit
  1  at least one repository is pinned at two or more commits
  2  the tree could not be read or a file is not valid YAML
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required", file=sys.stderr)
    sys.exit(2)

USES = re.compile(r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/[^@\s]*)?@([0-9a-fA-F]{40})")


def uses_nodes(node):
    """Yield every scalar value node whose mapping key is `uses`."""
    stack, seen = [node], set()
    while stack:
        n = stack.pop()
        if id(n) in seen:  # an alias can point back at its own anchor
            continue
        seen.add(id(n))
        if isinstance(n, yaml.MappingNode):
            for k, v in n.value:
                if isinstance(k, yaml.ScalarNode) and k.value == "uses" and isinstance(v, yaml.ScalarNode):
                    yield v
                stack.append(v)
        elif isinstance(n, yaml.SequenceNode):
            stack.extend(n.value)


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
            docs = list(yaml.compose_all(path.read_text(encoding="utf-8"), Loader=yaml.SafeLoader))
        except (OSError, UnicodeDecodeError, yaml.YAMLError) as exc:
            print(f"error: {path}: {exc}", file=sys.stderr)
            return 2
        for doc in docs:
            if doc is None:
                continue
            for v in uses_nodes(doc):
                m = USES.fullmatch(v.value.strip())
                if not m:
                    continue
                repo, sha = m.group(1).lower(), m.group(2).lower()
                where = f"{path.relative_to(args.root)}:{v.start_mark.line + 1}"
                pins.setdefault(repo, {}).setdefault(sha, []).append(where)
    bad = 0
    for repo in sorted(pins):
        if len(pins[repo]) < 2:
            continue
        bad = 1
        print(f"{repo} is pinned at {len(pins[repo])} commits:")
        for sha, places in sorted(pins[repo].items()):
            print(f"  {sha}: {', '.join(places)}")
    if bad:
        print("fix: pin every use of each repository above to the same commit")
    return bad


if __name__ == "__main__":
    sys.exit(main())
