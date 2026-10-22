#!/usr/bin/env python3
"""Every reusable workflow and composite action is documented, and correctly.

`check_workflow_coverage.py` asks whether a workflow is exercised. It never
asked whether one is documented, so `wp-build.yml`, `laravel.yml` and
`django.yml` shipped with no section at all, and `release-notes` stayed
documented after the action was removed.

A workflow's section is a `## <name>.yml` heading, or any `##` section of
docs/workflows.md or docs/presets.md with a `Workflow: .github/workflows/<name>.yml`
line. Fails when:

  * a reusable workflow has no section
  * an input, secret or output of a workflow is not named, in backticks, in
    its section (preset sections may rely on the shared inputs listed under
    `## Shared inputs` in docs/presets.md)
  * a presets section lists `- `name`: `X`` and X is not the declared default
  * a section documents a workflow input as `- `name` (type, default `X`)` and
    the type or X is not what the workflow declares, or the input does not exist
  * a composite action has no `## <name>` section in docs/actions.md, or such
    a section names an action that does not exist
  * an action input is not named in its section
  * README.md does not name a reusable workflow or an action
  * a YAML example in README.md or docs/*.md calls a workflow or action of
    this repository with a `with:` or `secrets:` key it does not declare, or
    names one that does not exist, or the example is not valid YAML
  * the counts in README.md and docs/assets/hero.svg ("N reusable workflows,
    N stack presets, N composite actions") are not the counts in the tree; a
    preset is a reusable workflow whose `name:` starts with `preset-`

Usage: check_docs_coverage.py [--root <dir>] [--quiet]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

import yaml

WORKFLOW_DOCS = ("docs/workflows.md", "docs/presets.md")
SHARED_HEADING = "## Shared inputs"
# A `Workflow:` or `Workflows:` paragraph, which may wrap onto further lines.
OWN_PARA_RE = re.compile(r"^Workflows?: (?:.+\n?)+", re.M)
PATH_RE = re.compile(r"`\.github/workflows/([a-z0-9-]+\.yml)`")
HEAD_RE = re.compile(r"^## ([a-z0-9-]+\.yml)\b")
# The presets page lists defaults as "- `name`: `value`".
DEFAULT_LINE_RE = re.compile(r"^- `([a-z0-9_]+)`: `([^`]*)`", re.M)
INPUT_LINE_RE = re.compile(
    r"^- `([a-z0-9_]+)` \((string|number|boolean)(?:, (required|default `([^`]*)`))?\)",
    re.M,
)


def sections(text: str) -> list[tuple[str, str]]:
    """(heading, body) for each `## ` section; fenced code is not a heading."""
    out: list[tuple[str, list[str]]] = []
    fence = False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fence = not fence
        if not fence and line.startswith("## "):
            out.append((line, []))
        elif out:
            out[-1][1].append(line)
    return [(h, "\n".join(b)) for h, b in out]


def triggers(parsed: dict) -> dict:
    # `on:` parses as the boolean True in YAML 1.1.
    t = parsed.get(True) or parsed.get("on") or {}
    return t if isinstance(t, dict) else {}


def render_default(value: object) -> str:
    if value is None or value == "":
        return '""'
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def unquote(value: str) -> str:
    """`"."` and `.` are the same default written two ways."""
    if len(value) > 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


COUNTS_RE = re.compile(
    r"(\d+) reusable workflows, (\d+) stack presets, (\d+) composite actions"
)
COUNTED_FILES = ("README.md", "docs/assets/hero.svg")


def check_readme(
    root: pathlib.Path, workflows: list[str], presets: int, actions: list[str], problems: list[str]
) -> None:
    readme = root / "README.md"
    text = readme.read_text(encoding="utf-8") if readme.is_file() else ""
    for name in workflows:
        # Whole names: `go.yml` must not be satisfied by `cargo.yml`.
        if not re.search(r"(?<![\w-])" + re.escape(name), text):
            problems.append(f"README.md does not name {name}")
    for name in actions:
        if f".github/actions/{name}" not in text:
            problems.append(f"README.md does not name .github/actions/{name}")
    actual = (len(workflows), presets, len(actions))
    for rel in COUNTED_FILES:
        path = root / rel
        if not path.is_file():
            continue
        for match in COUNTS_RE.finditer(path.read_text(encoding="utf-8")):
            stated = tuple(int(g) for g in match.groups())
            if stated != actual:
                problems.append(
                    f"{rel} says {match.group(0)}; the tree has "
                    f"{actual[0]} reusable workflows, {actual[1]} stack presets, "
                    f"{actual[2]} composite actions"
                )


def check_workflows(root: pathlib.Path, problems: list[str]) -> tuple[list[str], int]:
    owned: dict[str, list[tuple[str, str]]] = {}
    shared = ""
    for rel in WORKFLOW_DOCS:
        path = root / rel
        if not path.is_file():
            problems.append(f"{rel} does not exist")
            continue
        for heading, body in sections(path.read_text(encoding="utf-8")):
            if rel.endswith("presets.md") and heading.strip() == SHARED_HEADING:
                shared = body
            names = {
                n for para in OWN_PARA_RE.findall(body) for n in PATH_RE.findall(para)
            }
            match = HEAD_RE.match(heading)
            if match:
                names.add(match.group(1))
            for name in names:
                owned.setdefault(name, []).append((rel, body))

    reusable: list[str] = []
    presets = 0
    for path in sorted((root / ".github" / "workflows").glob("*.yml")):
        try:
            parsed = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError:
            continue  # the YAML gate reports it
        trig = triggers(parsed)
        if "workflow_call" not in trig:
            continue
        reusable.append(path.name)
        if str(parsed.get("name", "")).startswith("preset-"):
            presets += 1
        call = trig["workflow_call"] or {}
        inputs = call.get("inputs") or {}
        names = (
            [("input", n) for n in inputs]
            + [("secret", n) for n in (call.get("secrets") or {})]
            + [("output", n) for n in (call.get("outputs") or {})]
        )
        docs = owned.get(path.name)
        if not docs:
            problems.append(f"{path.name}: no section in {' or '.join(WORKFLOW_DOCS)}")
            continue
        body = "\n".join(b for _, b in docs)
        in_presets = any(rel.endswith("presets.md") for rel, _ in docs)
        for kind, name in names:
            token = f"`{name}`"
            if token in body or (in_presets and kind == "input" and token in shared):
                continue
            problems.append(f"{path.name}: {kind} `{name}` is not documented")
        for name, default in DEFAULT_LINE_RE.findall(body):
            if name not in inputs:
                continue  # a sibling workflow's input, or an output
            actual = render_default((inputs[name] or {}).get("default"))
            # An image pinned by digest is written by its tag.
            if unquote(default) not in (unquote(actual), actual.split("@sha256:")[0]):
                problems.append(
                    f"{path.name}: `{name}` listed with default `{default}`, declared `{actual}`"
                )
        for name, _type, required, default in INPUT_LINE_RE.findall(body):
            if name not in inputs:
                # A secret or output listed in the same style is fine.
                if name in (call.get("secrets") or {}) or name in (call.get("outputs") or {}):
                    continue
                problems.append(f"{path.name}: documents input `{name}`, which it does not have")
                continue
            spec = inputs[name] or {}
            declared_type = spec.get("type", "string")
            if _type != declared_type:
                problems.append(
                    f"{path.name}: `{name}` documented as {_type}, declared {declared_type}"
                )
            if required == "required":
                if not spec.get("required"):
                    problems.append(f"{path.name}: `{name}` documented as required, but is not")
                continue
            if not required:
                continue
            actual = render_default(spec.get("default"))
            if unquote(default) != unquote(actual):
                problems.append(
                    f"{path.name}: `{name}` documented default `{default}`, declared `{actual}`"
                )
    return reusable, presets


def check_actions(root: pathlib.Path, problems: list[str]) -> list[str]:
    doc = root / "docs" / "actions.md"
    secs = {}
    if doc.is_file():
        for heading, body in sections(doc.read_text(encoding="utf-8")):
            secs[heading[3:].strip()] = body
    actions_dir = root / ".github" / "actions"
    present = {p.name for p in actions_dir.iterdir() if (p / "action.yml").is_file()} if actions_dir.is_dir() else set()
    for name in sorted(present):
        if name not in secs:
            problems.append(f"action {name}: no `## {name}` section in docs/actions.md")
            continue
        spec = yaml.safe_load((actions_dir / name / "action.yml").read_text(encoding="utf-8")) or {}
        for inp in spec.get("inputs") or {}:
            if f"`{inp}`" not in secs[name]:
                problems.append(f"action {name}: input `{inp}` is not documented")
    for name in sorted(set(secs) - present):
        if re.fullmatch(r"[a-z0-9-]+", name):
            problems.append(f"docs/actions.md documents `{name}`, which is not an action here")
    return sorted(present)


FENCE_RE = re.compile(r"^```ya?ml[^\n]*\n(.*?)^```", re.M | re.S)
USES_RE = re.compile(r"nikolareljin/ci-helpers/\.github/(workflows|actions)/([A-Za-z0-9_.-]+?)(?:\.yml)?@")


def _calls(node):
    """Every mapping with a `uses:` naming this repository, anywhere in a tree."""
    if isinstance(node, dict):
        uses = node.get("uses")
        if isinstance(uses, str):
            match = USES_RE.search(uses)
            if match:
                yield match.group(1), match.group(2), node
        for value in node.values():
            yield from _calls(value)
    elif isinstance(node, list):
        for value in node:
            yield from _calls(value)


def check_examples(root: pathlib.Path, problems: list[str]) -> None:
    specs: dict[tuple[str, str], tuple[set, set] | None] = {}

    def spec(kind: str, name: str):
        key = (kind, name)
        if key not in specs:
            if kind == "workflows":
                path = root / ".github" / "workflows" / f"{name}.yml"
                if not path.is_file():
                    specs[key] = None
                else:
                    call = triggers(yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get(
                        "workflow_call"
                    )
                    call = call or {}
                    specs[key] = (set(call.get("inputs") or {}), set(call.get("secrets") or {}))
            else:
                path = root / ".github" / "actions" / name / "action.yml"
                if not path.is_file():
                    specs[key] = None
                else:
                    parsed = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
                    specs[key] = (set(parsed.get("inputs") or {}), set())
        return specs[key]

    docs = [root / "README.md", *sorted((root / "docs").glob("*.md"))]
    for doc in docs:
        if not doc.is_file():
            continue
        rel = doc.relative_to(root)
        for block in FENCE_RE.findall(doc.read_text(encoding="utf-8")):
            try:
                parsed = yaml.safe_load(block)
            except yaml.YAMLError as exc:
                # A caller pasting this gets the same parse error from GitHub.
                if USES_RE.search(block):
                    mark = getattr(exc, "problem_mark", None)
                    where = f" (block line {mark.line + 1})" if mark else ""
                    problems.append(f"{rel}: example calling this repository is not valid YAML{where}")
                continue
            for kind, name, node in _calls(parsed):
                declared = spec(kind, name)
                if declared is None:
                    problems.append(f"{rel}: example calls {kind}/{name}, which does not exist")
                    continue
                inputs, secrets = declared
                for key in node.get("with") or {}:
                    if key not in inputs:
                        problems.append(f"{rel}: example passes `{key}` to {name}, which has no such input")
                passed = node.get("secrets")
                if isinstance(passed, dict):
                    for key in passed:
                        if key not in secrets:
                            problems.append(f"{rel}: example passes secret `{key}` to {name}, which declares no such secret")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root to check")
    parser.add_argument("--quiet", action="store_true", help="only report problems")
    args = parser.parse_args()
    root = pathlib.Path(args.root)

    problems: list[str] = []
    workflows, presets = check_workflows(root, problems)
    actions = check_actions(root, problems)
    check_readme(root, workflows, presets, actions, problems)
    check_examples(root, problems)
    if problems:
        print("[ERROR] docs coverage:", file=sys.stderr)
        for line in problems:
            print(f"      {line}", file=sys.stderr)
        return 1
    if not args.quiet:
        print(
            f"[INFO] {len(workflows)} reusable workflow(s) ({presets} preset(s)) "
            f"and {len(actions)} action(s) documented"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
