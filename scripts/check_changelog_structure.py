#!/usr/bin/env python3
"""Assert the CHANGELOG has one Unreleased section, at the top, and no repeated version.

    python3 scripts/check_changelog_structure.py              # check this repository
    python3 scripts/check_changelog_structure.py --file PATH  # check a file elsewhere

Release notes are cut from a single section. On 2026-09-21 a second
`## Unreleased` was added above the existing one, and the entries under the
lower heading -- a feature merged that morning -- would have been dropped from
the next release while the file still appeared to contain them. Nothing here
noticed: `check_changelog_section.sh` asks whether a section for the version
being released exists and has entries, which was true of the top one.

Scope is deliberately narrow, because this file's history holds four heading
shapes and a check that cannot pass gets deleted rather than obeyed:

    ## Unreleased
    ## 2026-09-21 - v0.31.0     (5 of them)
    ## 2026-09-17 - 0.27.0      (49)
    ## 2026-04-11               (20, date only)

So this does not police the shape of a released heading. It asserts the three
things that are unambiguous and that break something when violated:

  1. At most one `## Unreleased`.
  2. If there is one, no released section precedes it -- notes are read from the
     top, and an Unreleased buried mid-file is invisible to a reader and to the
     release tooling alike.
  3. No version appears in two headings. Two sections for one version make
     "the section for X.Y.Z" ambiguous, and whichever is found first wins
     silently.

EXIT_CODES:
  0  the structure is sound
  1  at least one of the three rules is broken
  2  the file could not be read
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

UNRELEASED = "## Unreleased"
# Any heading that names a SemVer, with or without the `v` the file adopted
# late. Date-only headings carry no version and simply have nothing to clash.
VERSION_IN_HEADING = re.compile(r"^##\s+.*?\bv?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\s*$")


def check(text: str) -> list[str]:
    problems: list[str] = []
    headings = [
        (n, line.rstrip())
        for n, line in enumerate(text.splitlines(), 1)
        if line.startswith("## ")
    ]

    unreleased = [n for n, line in headings if line == UNRELEASED]
    if len(unreleased) > 1:
        where = ", ".join(f"line {n}" for n in unreleased)
        problems.append(
            f"{len(unreleased)} `{UNRELEASED}` sections ({where}); "
            "release notes are cut from one section, so the rest are dropped silently"
        )

    if unreleased:
        first_heading_line = headings[0][0]
        if unreleased[0] != first_heading_line:
            problems.append(
                f"`{UNRELEASED}` is at line {unreleased[0]}, below the section at "
                f"line {first_heading_line}; it must be the first section"
            )

    seen: dict[str, int] = {}
    for n, line in headings:
        m = VERSION_IN_HEADING.match(line)
        if not m:
            continue
        version = m.group(1)
        if version in seen:
            problems.append(
                f"version {version} appears twice, at lines {seen[version]} and {n}; "
                "the section for a version must be unique"
            )
        else:
            seen[version] = n

    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--file",
        default=str(Path(__file__).resolve().parent.parent / "CHANGELOG.md"),
        help="CHANGELOG to check (default: this repository's)",
    )
    args = ap.parse_args()

    path = Path(args.file)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"[ERROR] cannot read {path}: {exc}", file=sys.stderr)
        return 2

    problems = check(text)
    if problems:
        print(f"[ERROR] {path.name} structure:", file=sys.stderr)
        for line in problems:
            print(f"      {line}", file=sys.stderr)
        return 1

    print(f"[INFO] {path.name}: one Unreleased section at the top, no repeated version")
    return 0


if __name__ == "__main__":
    sys.exit(main())
