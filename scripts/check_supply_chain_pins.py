#!/usr/bin/env python3
"""Reject unpinned images, unverified downloads and unchecked SSH host keys.

    python3 scripts/check_supply_chain_pins.py              # check this repository
    python3 scripts/check_supply_chain_pins.py --root DIR   # check a tree elsewhere

Scans .github/workflows/*.yml and .github/actions/*/action.yml for:

  image     a container image the library chooses (input default, `with:`
            value, `services:`/`container:` image, or a literal in a run
            block) that is not referenced by `name:tag@sha256:<digest>`.
            A tag alone is re-resolved on every run. Images composed from a
            caller's input (`${...}`) are the caller's choice and are skipped.
  download  a run block that saves a curl/wget download to a file (-o/-O,
            curl redirected with `>`, or wget with no -O) but never checks a
            sha256; or a `*_url` input with a default whose matching
            `*_sha256` input defaults to empty.
  hostkey   `StrictHostKeyChecking` set to `no`, `off` or `accept-new`, or
            `ssh-keyscan` output written to a known_hosts file (`>>` or
            `tee`): each trusts an unknown key on first use.

Comment lines are ignored, so a comment may name what it guards against.

EXIT_CODES:
  0  nothing found
  1  at least one finding
  2  the tree could not be read
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

DIGEST = "@sha256:"
# name/name:tag (a slash keeps host:port and uid:gid pairs out).
SLASH_IMAGE = re.compile(r"(?<![\w./:-])([a-z0-9][a-z0-9._-]*/[a-z0-9._/-]+:[A-Za-z0-9._-]+)(?!@|[\w.-])")
LINE_IMAGE = re.compile(r"""^\s*(?:-\s*)?image:\s*["']?([^"'\s#]+)""")
ASSIGN_IMAGE = re.compile(r"""\bimage=["']?([^"'\s;]+)""")
# `accept-new` and `off` trust an unknown key on first use, same as `no`.
STRICT_NO = re.compile(r"StrictHostKeyChecking\s*[= ]\s*[\"']?(no|off|accept-new)\b", re.I)
KEYSCAN_TOFU = re.compile(r"ssh-keyscan\b[^\n]*(>>?|\btee\b[^\n]*)\s*\S*known_hosts")
DOWNLOAD = re.compile(
    r"\b(curl|wget)\b[^\n]*(\s-[A-Za-z]*[oO]\b|--output\b|--output-document\b)"
    # curl's stdout redirected to a file (not 2>, &>, or past a pipe).
    r"|\bcurl\b[^|\n]*(?<![0-9&])>>?\s*(?!/dev/null)[^\s&|]"
    # wget fetching a URL with no -O saves into the current directory.
    r"|\bwget\b(?![^\n]*(\s-[A-Za-z]*O|--output-document|--spider))[^\n]*\s[\"']?(https?|ftp)://")
DEV_NULL = re.compile(r"(-[A-Za-z]*[oO]|--output(-document)?)[ =]+/dev/null")


def code_lines(text: str):
    """Yield (offset, line) for non-comment lines of a run block."""
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield i, line


def image_ok(ref: str) -> bool:
    return DIGEST in ref or "$" in ref


def walk(node, path=()):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, path + (i,))
    else:
        yield path, node


def check_file(path: Path, rel: str) -> list[str]:
    out: list[str] = []
    try:
        doc = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as exc:
        print(f"{rel}: cannot read: {exc}", file=sys.stderr)
        raise SystemExit(2)
    if not isinstance(doc, dict):
        return out

    # Input defaults: `on.workflow_call.inputs` (PyYAML reads `on` as True)
    # and composite action `inputs`.
    trigger = doc.get(True) or doc.get("on") or {}
    inputs = {}
    if isinstance(trigger, dict) and isinstance(trigger.get("workflow_call"), dict):
        inputs = trigger["workflow_call"].get("inputs") or {}
    if isinstance(doc.get("inputs"), dict):
        inputs = doc["inputs"]
    for name, spec in inputs.items():
        if not isinstance(spec, dict):
            continue
        default = spec.get("default")
        if not isinstance(default, str) or not default:
            continue
        if (name.endswith("_image") or name == "image") and not image_ok(default):
            out.append(f"{rel}: image: input '{name}' default '{default}' is not pinned by digest")
        if name.endswith("_url"):
            sha = inputs.get(name[: -len("_url")] + "_sha256")
            if isinstance(sha, dict) and not sha.get("default"):
                out.append(f"{rel}: download: input '{name}' has a default but "
                           f"'{name[:-4]}_sha256' defaults to empty")

    for keys, value in walk(doc):
        if not isinstance(value, str) or not keys:
            continue
        last = keys[-1]
        # `with:` values passed to another workflow, services, container.
        if (len(keys) >= 2 and keys[-2] == "with" and isinstance(last, str)
                and last.endswith("_image") and value and not image_ok(value)):
            out.append(f"{rel}: image: with.{last} '{value}' is not pinned by digest")
        if (last == "image" and len(keys) >= 2 and keys[-2] != "with"
                and value and not image_ok(value)):
            out.append(f"{rel}: image: {'.'.join(map(str, keys))} '{value}' is not pinned by digest")
        if last != "run":
            continue
        has_sha = "sha256" in value.lower()
        for n, line in code_lines(value):
            where = f"{rel}: {'.'.join(map(str, keys))} line {n}"
            m = STRICT_NO.search(line)
            if m:
                out.append(f"{where}: hostkey: StrictHostKeyChecking={m.group(1)}")
            if KEYSCAN_TOFU.search(line):
                out.append(f"{where}: hostkey: ssh-keyscan written to known_hosts (trust on first use)")
            if DOWNLOAD.search(line) and not DEV_NULL.search(line) and not has_sha:
                out.append(f"{where}: download: saved to a file with no sha256 check in the step")
            for rx in (LINE_IMAGE, ASSIGN_IMAGE, SLASH_IMAGE):
                for m in rx.finditer(line):
                    ref = m.group(1)
                    if ":" in ref and not image_ok(ref):
                        out.append(f"{where}: image: '{ref}' is not pinned by digest")
    # A job-level `container: name:tag` string.
    for job_name, job in (doc.get("jobs") or {}).items():
        if isinstance(job, dict) and isinstance(job.get("container"), str):
            if not image_ok(job["container"]):
                out.append(f"{rel}: image: jobs.{job_name}.container '{job['container']}' is not pinned by digest")
    return sorted(set(out))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    args = ap.parse_args()
    root = Path(args.root)
    files = sorted((root / ".github/workflows").glob("*.yml"))
    files += sorted((root / ".github/actions").glob("*/action.yml"))
    if not files:
        print(f"no workflow or action files under {root}", file=sys.stderr)
        return 2
    findings: list[str] = []
    for f in files:
        findings += check_file(f, str(f.relative_to(root)))
    for line in findings:
        print(line)
    if findings:
        print(f"{len(findings)} finding(s): pin images by digest, verify every "
              "download with sha256, check SSH host keys", file=sys.stderr)
        return 1
    print(f"ok: {len(files)} files, images pinned, downloads verified, host keys checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
