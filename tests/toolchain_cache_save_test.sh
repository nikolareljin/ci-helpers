#!/usr/bin/env bash
# SCRIPT: toolchain_cache_save_test.sh
# DESCRIPTION: The Godot and Flutter archive caches are written only by a
#              `actions/cache/save` step that directly follows the setup
#              step which verified the archive, before any step runs the
#              caller's code (`inputs.<name>_command`), never by a post-job
#              `actions/cache` save; the restore step precedes the setup
#              step; and the workflows that hold secrets or publish
#              (`flutter-release.yml`, `release-build.yml`) restore and
#              never save. The same check runs on fixtures with the save
#              moved after the caller's install step, replaced by a post-job
#              `actions/cache`, and added to the release workflow, and must
#              fail on each.
# USAGE: bash tests/toolchain_cache_save_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

cat > "$work/check.py" <<'PY'
import re, sys
import yaml

TOOLS = {"Flutter": "flutter", "Godot": "godot"}
CALLER = re.compile(r"\$\{\{\s*inputs\.[a-z_]*command\s*\}\}")
problems = []

def steps_of(path):
    doc = yaml.safe_load(open(path))
    for job, body in (doc.get("jobs") or {}).items():
        if isinstance(body, dict) and body.get("steps"):
            yield job, body["steps"]

def mentions(step, tool):
    text = yaml.safe_dump(step, width=10**9).lower()
    return tool in text

def check_engine(path):
    for job, steps in steps_of(path):
        for tool, word in TOOLS.items():
            setup = [i for i, s in enumerate(steps) if (s.get("name") or "") == f"Setup {tool}"]
            if not setup:
                continue
            at = setup[0]
            if ("uses" in steps[at]) or f"setup_{word}.sh" not in (steps[at].get("run") or ""):
                problems.append(f"{path} job {job}: 'Setup {tool}' is not scripts/setup_{word}.sh from the library checkout")
            for i, s in enumerate(steps):
                uses = s.get("uses") or ""
                if uses.startswith("actions/cache@") and mentions(s, word):
                    problems.append(f"{path} job {job} step {i} '{s.get('name')}': a post-job actions/cache save for the {tool} archive; use actions/cache/restore before and actions/cache/save right after 'Setup {tool}'")
            restores = [i for i, s in enumerate(steps) if (s.get("uses") or "").startswith("actions/cache/restore@") and mentions(s, word)]
            saves = [i for i, s in enumerate(steps) if (s.get("uses") or "").startswith("actions/cache/save@") and mentions(s, word)]
            if not restores:
                problems.append(f"{path} job {job}: no actions/cache/restore for the {tool} archive")
            for i in restores:
                if i > at:
                    problems.append(f"{path} job {job} step {i}: the {tool} archive restore runs after 'Setup {tool}'")
            if len(saves) != 1:
                problems.append(f"{path} job {job}: {len(saves)} actions/cache/save steps for the {tool} archive, expected 1")
            for i in saves:
                if i != at + 1:
                    problems.append(f"{path} job {job} step {i} '{steps[i].get('name')}': the {tool} archive save does not directly follow 'Setup {tool}' (step {at})")
                if "cache-hit != 'true'" not in (steps[i].get("if") or ""):
                    problems.append(f"{path} job {job} step {i}: the {tool} archive save does not skip a restored entry")
                first_caller = next((j for j, s in enumerate(steps) if CALLER.search(s.get("run") or "")), None)
                if first_caller is not None and first_caller < i:
                    problems.append(f"{path} job {job} step {i}: the {tool} archive save runs after the caller's step {first_caller} '{steps[first_caller].get('name')}'")

def check_release(path):
    for job, steps in steps_of(path):
        for i, s in enumerate(steps):
            uses = s.get("uses") or ""
            for tool, word in TOOLS.items():
                if (uses.startswith("actions/cache/save@") or uses.startswith("actions/cache@")) and mentions(s, word):
                    problems.append(f"{path} job {job} step {i} '{s.get('name')}': saves the {tool} archive cache from a job that holds secrets or publishes; restore only")

mode, path = sys.argv[1], sys.argv[2]
(check_engine if mode == "engine" else check_release)(path)
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY

name="this tree"
for f in ci.yml pr-gate.yml; do
  if ! python3 "$work/check.py" engine "$root/.github/workflows/$f" > "$work/out" 2>&1; then
    echo "FAIL $name ($f):"; cat "$work/out"; fail=1
  fi
done
for f in flutter-release.yml release-build.yml; do
  if ! python3 "$work/check.py" release "$root/.github/workflows/$f" > "$work/out" 2>&1; then
    echo "FAIL $name ($f):"; cat "$work/out"; fail=1
  fi
done

# refuse <name> <mode> <fixture> <pattern>
refuse() {
  local name="$1" mode="$2" fixture="$3" pattern="$4" rc=0
  python3 "$work/check.py" "$mode" "$fixture" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != 1 ] || ! grep -qF -- "$pattern" "$work/out"; then
    echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1
  fi
}

# The save moved after the caller's Install step.
python3 - "$root/.github/workflows/ci.yml" "$work/late.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["ci"]["steps"]
save = next(s for s in steps if s.get("name") == "Save Flutter archive")
steps.remove(save)
at = next(i for i, s in enumerate(steps) if s.get("name") == "Install") + 1
steps.insert(at, save)
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
refuse "a save after the caller's install step" engine "$work/late.yml" "the Flutter archive save runs after the caller's step"

# A post-job actions/cache in place of restore + save.
python3 - "$root/.github/workflows/ci.yml" "$work/postjob.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["ci"]["steps"]
for s in steps:
    if s.get("name") == "Restore Godot archive":
        s["uses"] = s["uses"].replace("actions/cache/restore@", "actions/cache@")
doc["jobs"]["ci"]["steps"] = [s for s in steps if s.get("name") != "Save Godot archive"]
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
refuse "a post-job cache save" engine "$work/postjob.yml" "a post-job actions/cache save for the Godot archive"

# A save that does not skip a restored entry.
python3 - "$root/.github/workflows/pr-gate.yml" "$work/always.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for s in doc["jobs"]["pr-gate"]["steps"]:
    if s.get("name") == "Save Godot archive":
        s["if"] = "${{ inputs.godot_version != '' }}"
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
refuse "a save that overwrites a restored entry" engine "$work/always.yml" "does not skip a restored entry"

# A restore after the setup step.
python3 - "$root/.github/workflows/ci.yml" "$work/laterestore.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["ci"]["steps"]
restore = next(s for s in steps if s.get("name") == "Restore Flutter archive")
steps.remove(restore)
at = next(i for i, s in enumerate(steps) if s.get("name") == "Setup Flutter") + 1
steps.insert(at, restore)
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
refuse "a restore after the setup step" engine "$work/laterestore.yml" "the Flutter archive restore runs after 'Setup Flutter'"

# A save added to the release workflow.
python3 - "$root/.github/workflows/flutter-release.yml" "$work/releasesave.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["build"]["steps"]
at = next(i for i, s in enumerate(steps) if s.get("name") == "Setup Flutter") + 1
steps.insert(at, {"name": "Save Flutter archive", "uses": "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
                  "with": {"path": "${{ steps.flutter_resolve.outputs.cache_path }}", "key": "${{ steps.flutter_resolve.outputs.cache_key }}"}})
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
refuse "a save in the release workflow" release "$work/releasesave.yml" "saves the Flutter archive cache from a job that holds secrets or publishes"

[[ "$fail" = 0 ]] && echo "ok: the Godot and Flutter archive caches are restored before and saved right after the verified download, before any caller step, and never from a release job"
exit "$fail"
