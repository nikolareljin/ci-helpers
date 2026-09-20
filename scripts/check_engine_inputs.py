#!/usr/bin/env python3
"""Assert that every workflow reaching the CI engine forwards its pass-through inputs.

    python3 scripts/check_engine_inputs.py              # check this repository
    python3 scripts/check_engine_inputs.py --root DIR   # check a tree elsewhere

An input added to `ci.yml` is useless to a caller that goes through a preset
unless every hop on the way declares it and passes it on. Nothing caught that
before this script: `check_workflow_yaml.py` proves a file parses, and
actionlint rejects a preset that forwards an input the engine does *not*
declare -- but neither notices the reverse, a preset that silently stops
forwarding one. That is how `timeout_minutes` came to be declared by the engine
and honoured by only two of the thirteen presets that call it, for months,
while every gate stayed green.

Scope is an explicit PASS_THROUGH set, not "every engine input". Presets differ
from the engine on purpose: `docker.yml` deliberately forwards a small subset,
`node.yml` overrides the empty `lint_command` default with a real command, and
the database inputs exist on `php.yml` alone. A check demanding every input
everywhere could not pass against this tree and would be deleted within a week.
What the set holds instead is the inputs whose whole purpose is to reach the
engine unchanged -- a caller sets them, and no preset has any business
interpreting them.

The graph is followed transitively, so `laravel.yml -> php.yml -> ci.yml` is
checked at both hops. A file that reaches the engine by any path is in scope;
one that does not is ignored.

EXIT_CODES:
  0  every reachable caller declares and forwards the set
  1  at least one hop drops an input, or a default disagrees with the engine
  2  the tree could not be read
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("pyyaml is required: pip install pyyaml")

# The engines. A workflow is in scope when it reaches one of these.
ENGINES = ("ci.yml", "pr-gate.yml")

# Inputs a caller sets and every hop must hand on untouched. Adding one here is
# what makes the gate demand it everywhere -- which is the point: the set is the
# single definition, and the 14 forwards are checked against it rather than
# against each other.
PASS_THROUGH = (
    "runner",
    "working_directory",
    "concurrency_key",
    "fetch_depth",
    "submodules",
    "cache",
    "timeout_minutes",
)

# Deliberate exemptions, as (workflow, input) -> why. An exemption is a named
# entry so that removing one is a visible diff rather than a silent widening.
EXEMPT: dict[tuple[str, str], str] = {}

CALL_PREFIX = "./.github/workflows/"


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def workflow_call_inputs(doc: dict) -> dict:
    # `on:` is YAML 1.1's boolean True under a safe loader, so a plain
    # doc["on"] finds nothing and every check would pass vacuously.
    on = doc.get("on", doc.get(True)) or {}
    if not isinstance(on, dict):
        return {}
    call = on.get("workflow_call") or {}
    if not isinstance(call, dict):
        return {}
    return call.get("inputs") or {}


def local_calls(doc: dict) -> list[tuple[str, str, dict]]:
    """Every (job_id, called_file, with_mapping) for local reusable-workflow calls."""
    out = []
    for job_id, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        uses = job.get("uses")
        if isinstance(uses, str) and uses.startswith(CALL_PREFIX):
            out.append((job_id, uses[len(CALL_PREFIX):], job.get("with") or {}))
    return out


def engine_section(text: str, engine: str) -> str | None:
    """The whole `## <engine>` section, not just its bullet list.

    `concurrency_key` is documented in prose below the bullets, so a check that
    read only the contiguous list would report it missing and be "fixed" by
    duplicating the entry.
    """
    heading = f"## {engine}\n"
    start = text.find(heading)
    if start < 0:
        return None
    rest = text.find("\n## ", start + len(heading))
    return text[start:rest if rest > 0 else len(text)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent),
                    help="repository root to check (default: this repository)")
    args = ap.parse_args()

    wf_dir = Path(args.root) / ".github" / "workflows"
    if not wf_dir.is_dir():
        print(f"[ERROR] no .github/workflows under {args.root}", file=sys.stderr)
        return 2

    docs: dict[str, dict] = {}
    for path in sorted(wf_dir.glob("*.yml")):
        try:
            docs[path.name] = load(path)
        except yaml.YAMLError as exc:
            print(f"[ERROR] {path.name}: {exc}", file=sys.stderr)
            return 2
    if not docs:
        print(f"[ERROR] no workflow files under {wf_dir}", file=sys.stderr)
        return 2

    missing_engines = [e for e in ENGINES if e not in docs]
    if missing_engines:
        # Without an engine there is nothing to reach, and every caller would
        # pass by default -- a check that cannot see its own subject.
        print(f"[ERROR] engine workflow(s) missing: {', '.join(missing_engines)}",
              file=sys.stderr)
        return 2

    engine_defaults: dict[str, object] = {}
    for engine in ENGINES:
        for name, spec in workflow_call_inputs(docs[engine]).items():
            if name in PASS_THROUGH and isinstance(spec, dict):
                engine_defaults.setdefault(name, spec.get("default"))

    undeclared = [n for n in PASS_THROUGH if n not in engine_defaults]
    if undeclared:
        print(f"[ERROR] not declared by any engine: {', '.join(undeclared)}",
              file=sys.stderr)
        return 2

    # Which files reach an engine, and by which jobs. Iterated to a fixed point
    # so a chain of any depth is followed (laravel.yml -> php.yml -> ci.yml).
    reaching = set(ENGINES)
    changed = True
    while changed:
        changed = False
        for name, doc in docs.items():
            if name in reaching:
                continue
            if any(target in reaching for _, target, _ in local_calls(doc)):
                reaching.add(name)
                changed = True

    problems: list[str] = []
    checked = 0
    for name in sorted(reaching - set(ENGINES)):
        doc = docs[name]
        declared = workflow_call_inputs(doc)
        # Only a *reusable* workflow is a hop. A repo-local one -- self-test.yml,
        # docs-site.yml -- is the end consumer: it calls a preset with the fixed
        # values it wants and has no caller to pass anything on from. Demanding
        # it declare inputs nobody can set would make the gate unpassable, and a
        # gate that cannot pass gets deleted rather than obeyed.
        if not declared and "workflow_call" not in str(doc.get("on", doc.get(True, ""))):
            continue
        hops = [(job_id, target, with_) for job_id, target, with_ in local_calls(doc)
                if target in reaching]
        if not hops:
            continue
        checked += 1
        for input_name in PASS_THROUGH:
            if (name, input_name) in EXEMPT:
                continue
            spec = declared.get(input_name)
            if not isinstance(spec, dict):
                problems.append(f"{name}: does not declare `{input_name}`")
                continue
            want = engine_defaults[input_name]
            got = spec.get("default")
            if got != want:
                problems.append(
                    f"{name}: `{input_name}` defaults to {got!r}, engine says {want!r}")
            expected = "${{ inputs.%s }}" % input_name
            for job_id, target, with_ in hops:
                actual = with_.get(input_name)
                if actual is None:
                    problems.append(
                        f"{name}: job `{job_id}` calls {target} without `{input_name}`")
                elif str(actual).strip() != expected:
                    problems.append(
                        f"{name}: job `{job_id}` passes `{input_name}` as "
                        f"{str(actual).strip()!r}, expected {expected!r}")

    # The documented list is the other copy of this fact, and it drifts the same
    # way the forwards do -- silently, because nothing reads it. Checking it here
    # keeps one definition: the engine's own `workflow_call` block.
    docs_path = Path(args.root) / "docs" / "workflows.md"
    if docs_path.is_file():
        text = docs_path.read_text(encoding="utf-8")
        for engine in ENGINES:
            section = engine_section(text, engine)
            if section is None:
                problems.append(f"docs/workflows.md: no `## {engine}` section")
                continue
            if "All CI inputs" in section:
                # pr-gate.yml documents its shared inputs by reference to ci.yml
                # rather than repeating them. One list, not two.
                continue
            for name in workflow_call_inputs(docs[engine]):
                if f"`{name}`" not in section:
                    problems.append(
                        f"docs/workflows.md: `## {engine}` does not mention `{name}`")
    else:
        problems.append("docs/workflows.md is missing")

    if problems:
        print("[ERROR] engine inputs are not threaded through every caller:",
              file=sys.stderr)
        for line in problems:
            print(f"      {line}", file=sys.stderr)
        print(f"[ERROR] {len(problems)} problem(s) across {checked} caller(s).",
              file=sys.stderr)
        print("[ERROR] Every workflow reaching the engine must declare each "
              "pass-through input", file=sys.stderr)
        print("[ERROR] with the engine's default and forward it verbatim.",
              file=sys.stderr)
        return 1

    print(f"[INFO] {len(PASS_THROUGH)} pass-through input(s) threaded through "
          f"{checked} caller(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
