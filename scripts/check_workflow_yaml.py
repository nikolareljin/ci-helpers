#!/usr/bin/env python3
"""Check that every workflow and composite action in this repository parses.

    python3 scripts/check_workflow_yaml.py

Everything under .github/workflows and .github/actions is consumed by other
repositories, so a file that does not parse is a broken release for everyone
pinned to it -- and until this existed, nothing checked.

That is not hypothetical. `.github/actions/wp-plugin-check/action.yml` shipped
invalid: its heredoc bodies were written at column 0 inside an indented
`run: |` block, and a block scalar ends as soon as indentation drops below its
own. Both PyYAML and Ruby's Psych refused the file, while the repository's own
PR gate -- a release-tag check and a secret scan -- had nothing to say about it.

Exits non-zero on the first file that fails, naming it.
"""
from __future__ import annotations

import glob
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("pyyaml is required: pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent

PATTERNS = (
    ".github/workflows/*.yml",
    ".github/workflows/*.yaml",
    ".github/actions/*/action.yml",
    ".github/actions/*/action.yaml",
)


def main() -> int:
    paths = sorted(
        {p for pattern in PATTERNS for p in glob.glob(str(ROOT / pattern))}
    )
    if not paths:
        print("no workflow or action files found", file=sys.stderr)
        return 1

    failed = []
    for path in paths:
        try:
            yaml.safe_load(Path(path).read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            failed.append((path, exc))

    for path, exc in failed:
        rel = Path(path).relative_to(ROOT)
        # ::error:: so the failure is annotated on the file in the PR diff.
        print(f"::error file={rel}::{rel} is not valid YAML: {exc}", file=sys.stderr)

    if failed:
        print(f"\n{len(failed)} of {len(paths)} file(s) failed to parse.", file=sys.stderr)
        return 1

    print(f"{len(paths)} workflow and action files parse.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
