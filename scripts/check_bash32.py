#!/usr/bin/env python3
"""Shell code here runs under bash 3.2: no bash 4 or 5 feature.

    python3 scripts/check_bash32.py              # this repository
    python3 scripts/check_bash32.py --root DIR   # a tree elsewhere

macOS runners start /bin/bash, which is bash 3.2. A bash 4 feature there
fails at run time, after every Linux leg passed: `shopt -s globstar` in
scripts/artifact_parts.sh stopped every macOS build with "invalid shell
option name".

Read: every *.sh under scripts/ and .github/, and the run: of every step in
the workflows and composite actions under .github (a Linux-only job today
can gain a macOS runner input tomorrow, so all of them). Lines that start
with `#` are skipped. A finding names the file, the line and the feature.

Exit 0 with nothing found, 1 with a finding, 2 on a usage or parse error.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("::error::PyYAML is required (pip install pyyaml)")
    sys.exit(2)

NAME = r"[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]*\])?"
FEATURES = (
    ("globstar (bash 4.0); use find", re.compile(r"\bglobstar\b")),
    ("mapfile/readarray (bash 4.0); use a read loop", re.compile(r"(?:^|[\s;&|(])(?:mapfile|readarray)\b")),
    ("associative array (bash 4.0)", re.compile(r"(?:^|[\s;&|(])(?:declare|local|typeset)\s+-[A-Za-z]*A")),
    ("nameref (bash 4.3)", re.compile(r"(?:^|[\s;&|(])(?:declare|local|typeset)\s+-[A-Za-z]*n\b")),
    ("case modification ${x,,} / ${x^^} (bash 4.0); use tr", re.compile(r"\$\{" + NAME + r"(?:\^\^?|,,?)[^}]*\}")),
    ("${x@Q} transformation (bash 4.4)", re.compile(r"\$\{" + NAME + r"@[QEPAaKkUuL]\}")),
    ("negative subscript (bash 4.3)", re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]+\]\}")),
    ("[[ -v ]] (bash 4.2)", re.compile(r"\[\[\s+(?:!\s+)?-v\s")),
    (";;& or ;& in case (bash 4.0)", re.compile(r";;&|[^;];&\s*$")),
    ("coproc (bash 4.0)", re.compile(r"(?:^|[\s;&|(])coproc\s")),
    ("wait -n (bash 4.3)", re.compile(r"(?:^|[\s;&|(])wait\s+-n\b")),
    ("shopt lastpipe (bash 4.2)", re.compile(r"\blastpipe\b")),
    ("BASHPID (bash 4.0)", re.compile(r"\bBASHPID\b")),
    ("EPOCHSECONDS/EPOCHREALTIME (bash 5.0)", re.compile(r"\bEPOCH(?:SECONDS|REALTIME)\b")),
    ("|& (bash 4.0); use 2>&1 |", re.compile(r"\|&")),
    ("&>> (bash 4.0); use >> f 2>&1", re.compile(r"&>>")),
    ("printf %(...)T (bash 4.2); use date", re.compile(r"%\([^)]*\)T")),
)


def scan(text: str) -> list[tuple[int, str]]:
    """(line number, feature) for every bash 4 or 5 feature in text."""
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for what, rx in FEATURES:
            if rx.search(line):
                out.append((n, what))
    return out


def run_blocks(doc: object):
    """Yield (label, run text) for every step with a run: in a workflow or action."""
    if not isinstance(doc, dict):
        return
    jobs = doc.get("jobs")
    if isinstance(jobs, dict):
        for jid, job in jobs.items():
            if isinstance(job, dict):
                for i, st in enumerate(job.get("steps") or []):
                    if isinstance(st, dict) and isinstance(st.get("run"), str):
                        yield f"job {jid} step {i + 1} ({st.get('name') or 'run'})", st["run"]
    runs = doc.get("runs")
    if isinstance(runs, dict):
        for i, st in enumerate(runs.get("steps") or []):
            if isinstance(st, dict) and isinstance(st.get("run"), str):
                yield f"composite step {i + 1} ({st.get('name') or 'run'})", st["run"]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=".", help="repository root (default: .)")
    args = ap.parse_args(argv)
    root = Path(args.root)
    if not (root / "scripts").is_dir() and not (root / ".github").is_dir():
        print(f"::error::no scripts/ or .github/ under {args.root}")
        return 2
    errors: list[str] = []
    count = 0
    for top in ("scripts", ".github"):
        base = root / top
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*")):
            if not p.is_file() or p.is_symlink():
                continue
            rel = p.relative_to(root).as_posix()
            if p.suffix == ".sh":
                count += 1
                errors += [f"{rel}:{n}: {what}" for n, what in scan(p.read_text(encoding="utf-8", errors="replace"))]
            elif p.suffix in (".yml", ".yaml") and top == ".github":
                try:
                    doc = yaml.safe_load(p.read_text(encoding="utf-8"))
                except yaml.YAMLError as e:
                    print(f"::error::{rel}: cannot parse: {e}")
                    return 2
                count += 1
                for label, text in run_blocks(doc):
                    errors += [f"{rel}: {label}, run: line {n}: {what}" for n, what in scan(text)]
    for e in errors:
        print(f"::error::{e}")
    if errors:
        print(f"{len(errors)} finding(s): macOS runs /bin/bash 3.2; use a bash 3.2 form.")
        return 1
    print(f"ok: {count} files, no bash 4 or 5 feature")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
