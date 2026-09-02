#!/usr/bin/env python3
"""Check that every GitHub configuration file in this repository parses.

    python3 scripts/check_workflow_yaml.py

Everything under .github/workflows and .github/actions is consumed by other
repositories, so a file that does not parse is a broken release for everyone
pinned to it -- and until this existed, nothing checked. .github/dependabot.yml
is covered for a different reason: a malformed one does not fail anything,
GitHub just stops opening update pull requests, which looks the same as having
nothing to update.

That is not hypothetical. `.github/actions/wp-plugin-check/action.yml` shipped
invalid: its heredoc bodies were written at column 0 inside an indented
`run: |` block, and a block scalar ends as soon as indentation drops below its
own. Both PyYAML and Ruby's Psych refused the file, while the repository's own
PR gate -- a release-tag check and a secret scan -- had nothing to say about it.

Reports every file that fails, not just the first, so one run names all of
them. A file that cannot be read or decoded counts as a failure too -- it is
just as broken for a consumer as one that will not parse. Exits non-zero if
any failed.
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
    # Included because a malformed dependabot.yml does not fail anything --
    # GitHub simply stops opening update pull requests, which looks identical
    # to having nothing to update.
    ".github/dependabot.yml",
    ".github/dependabot.yaml",
)


def main() -> int:
    paths = sorted(
        {p for pattern in PATTERNS for p in glob.glob(str(ROOT / pattern))}
    )
    if not paths:
        print("no GitHub configuration files found", file=sys.stderr)
        return 1

    failed = []
    for path in paths:
        try:
            yaml.safe_load(Path(path).read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            failed.append((path, "is not valid YAML", exc))
        except (OSError, UnicodeDecodeError) as exc:
            # A file that cannot be read or decoded is just as broken for a
            # consumer as one that will not parse. Catching only YAMLError
            # would end the run in a traceback and report nothing, which is
            # the opposite of naming every bad file in one pass.
            failed.append((path, "could not be read", exc))

    for path, problem, exc in failed:
        rel = Path(path).relative_to(ROOT)
        # Workflow commands are line-based, and PyYAML's messages are usually
        # several lines. An unescaped newline truncates the annotation and
        # spills the remainder into the log as loose text, so collapse it.
        detail = " ".join(str(exc).split())
        # ::error:: so the failure is annotated on the file in the PR diff.
        print(f"::error file={rel}::{rel} {problem}: {detail}", file=sys.stderr)

    if failed:
        print(f"\n{len(failed)} of {len(paths)} file(s) failed to parse.", file=sys.stderr)
        return 1

    print(f"{len(paths)} GitHub configuration files parse.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
