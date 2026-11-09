#!/usr/bin/env python3
"""Write a test summary from JUnit XML to the job summary.

    python3 scripts/junit_summary.py --title "Tests" --glob "test-results/**/*.xml"

Replaces dorny/test-reporter, which needed `checks: write` and received every
test name, file path and assertion message. This reads the same JUnit XML,
with the standard library only, and appends a Markdown table of totals and a
list of failures to $GITHUB_STEP_SUMMARY (stdout when it is unset). It never
fails the job: no file, an unreadable file or a malformed one is reported in
the summary and the exit code is 0, as the reporter's `fail-on-error: false`
was. A DOCTYPE is refused (entity expansion), and a file over --max-bytes is
skipped.

EXIT_CODES:
  0  always, once the summary is written
  2  bad arguments
"""
from __future__ import annotations

import argparse
import glob
import html
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

MAX_FAILURES = 50
MESSAGE_CHARS = 300


def parse(path: Path, max_bytes: int) -> ET.Element:
    if path.stat().st_size > max_bytes:
        raise ValueError(f"over {max_bytes} bytes")
    data = path.read_bytes()
    # A test report declares no entities. The C parser exposes no doctype
    # handler, so the declaration is refused before anything is parsed.
    if b"<!doctype" in data.lower():
        raise ValueError("DOCTYPE refused")
    return ET.fromstring(data)


def cell(text: str) -> str:
    """One Markdown table cell: escaped, one line, bounded."""
    text = " ".join((text or "").split())
    if len(text) > MESSAGE_CHARS:
        text = text[: MESSAGE_CHARS - 3] + "..."
    return html.escape(text, quote=False).replace("|", "\\|")


def collect(root: ET.Element, source: str, totals: dict, failures: list) -> None:
    for case in root.iter("testcase"):
        totals["tests"] += 1
        try:
            totals["time"] += float(case.get("time") or 0)
        except ValueError:
            pass
        name = " / ".join(p for p in (case.get("classname"), case.get("name")) if p)
        if case.find("skipped") is not None:
            totals["skipped"] += 1
            continue
        kind = next((k for k in ("failure", "error") if case.find(k) is not None), None)
        if kind is None:
            totals["passed"] += 1
            continue
        totals[kind + "s"] += 1
        node = case.find(kind)
        message = node.get("message") or (node.text or "").strip().splitlines()[:1]
        if isinstance(message, list):
            message = message[0] if message else ""
        failures.append((kind, name or "(unnamed)", message, source))


def summary(title: str, files: list[Path], max_bytes: int) -> str:
    totals = {"tests": 0, "passed": 0, "failures": 0, "errors": 0, "skipped": 0, "time": 0.0}
    failures: list = []
    problems: list[str] = []
    for path in files:
        try:
            collect(parse(path, max_bytes), path.name, totals, failures)
        except (OSError, ET.ParseError, ValueError) as exc:
            problems.append(f"{path.name}: {exc}")
    out = [f"## {cell(title)}", ""]
    if not files:
        out.append("No JUnit XML found.")
        return "\n".join(out) + "\n"
    out += [
        "| Tests | Passed | Failed | Errors | Skipped | Time |",
        "|---:|---:|---:|---:|---:|---:|",
        f"| {totals['tests']} | {totals['passed']} | {totals['failures']} | {totals['errors']} "
        f"| {totals['skipped']} | {totals['time']:.1f}s |",
        "",
        f"{len(files)} file(s) read.",
    ]
    if failures:
        out += ["", "| Result | Test | Message | File |", "|---|---|---|---|"]
        for kind, name, message, source in failures[:MAX_FAILURES]:
            out.append(f"| {kind} | {cell(name)} | {cell(message)} | {cell(source)} |")
        if len(failures) > MAX_FAILURES:
            out.append(f"\n{len(failures) - MAX_FAILURES} more not shown.")
    if problems:
        out += ["", "Not read:"] + [f"- {cell(p)}" for p in problems]
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--title", default="Tests")
    ap.add_argument("--glob", required=True, help="glob of JUnit XML files; ** recurses")
    ap.add_argument("--max-bytes", type=int, default=20 * 1024 * 1024)
    args = ap.parse_args()
    files = sorted(Path(p) for p in glob.glob(args.glob, recursive=True) if Path(p).is_file())
    text = summary(args.title, files, args.max_bytes)
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
