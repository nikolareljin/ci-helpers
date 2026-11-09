#!/usr/bin/env bash
# scan-new-findings.yml's `tools` job, run as the workflow would: the step
# decides which scanners run and refuses a value it cannot read, before any
# checkout or download.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/scan-new-findings.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$WORKFLOW" > "$work/step.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
job = doc["jobs"]["tools"]
assert not any("uses" in s for s in job["steps"]), "the tools job must check nothing out"
print(next(s["run"] for s in job["steps"] if s.get("id") == "pick"))
PY

fail=0
# expect <tools> <exit> <gitleaks> <foxguard>
expect() {
  local tools="$1" want="$2" gl="$3" fg="$4" rc=0 out
  : > "$work/out"
  out="$(TOOLS="$tools" GITHUB_OUTPUT="$work/out" bash "$work/step.sh" 2>&1)" || rc=$?
  if (( rc != want )); then echo "FAIL: tools='$tools' exited $rc, expected $want: $out"; fail=1; return; fi
  if (( want != 0 )); then
    if [[ -s "$work/out" ]]; then echo "FAIL: tools='$tools' was refused but still set outputs: $(cat "$work/out")"; fail=1; fi
    grep -q '^::error::' <<<"$out" || { echo "FAIL: tools='$tools' refused without an error line: $out"; fail=1; }
    return
  fi
  [[ "$(cat "$work/out")" == "gitleaks=$gl"$'\n'"foxguard=$fg" ]] \
    || { echo "FAIL: tools='$tools' outputs: $(tr '\n' ' ' < "$work/out"), expected gitleaks=$gl foxguard=$fg"; fail=1; }
}

default="$(python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print((d.get(True) or d.get("on"))["workflow_call"]["inputs"]["tools"]["default"])' "$WORKFLOW")"
[[ "$default" == "gitleaks,foxguard" ]] || { echo "FAIL: tools defaults to '$default'"; fail=1; }

expect "gitleaks,foxguard" 0 true true
expect "foxguard,gitleaks" 0 true true
expect " gitleaks , foxguard " 0 true true
expect "gitleaks" 0 true false
expect "foxguard" 0 false true
expect "" 1 - -
expect "   " 1 - -
expect "," 1 - -
expect "gitleaks," 1 - -
expect "nope" 1 - -
expect "gitleaks,nope" 1 - -
expect "Gitleaks" 1 - -
expect "gitleaks,gitleaks" 1 - -
expect "gitleaks;foxguard" 1 - -

# The two scan jobs wait on `tools` alone and run only when it names them,
# with no continue-on-error anywhere: one failing never hides the other.
python3 - "$WORKFLOW" <<'PY' || fail=1
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc["jobs"]
bad = []
for name in ("gitleaks", "foxguard"):
    job = jobs[name]
    if job.get("needs") != "tools":
        bad.append(f"{name} needs {job.get('needs')!r}, expected 'tools'")
    if job.get("if") != "${{ needs.tools.outputs.%s == 'true' }}" % name:
        bad.append(f"{name} has if {job.get('if')!r}")
    if "continue-on-error" in job or any("continue-on-error" in s for s in job["steps"]):
        bad.append(f"{name} has continue-on-error")
    action = [s for s in job["steps"] if str(s.get("uses", "")).endswith("/.github/actions/%s-diff" % name)]
    if len(action) != 1:
        bad.append(f"{name} does not run the {name}-diff action exactly once")
    other = "foxguard" if name == "gitleaks" else "gitleaks"
    if any(other in str(s.get("uses", "")) for s in job["steps"]):
        bad.append(f"{name} runs {other}")
for line in bad:
    print("FAIL:", line)
sys.exit(1 if bad else 0)
PY

(( fail == 0 )) && echo "scan_tools: tools input picks the scanners and refuses what it cannot read"
exit "$fail"
