#!/usr/bin/env bash
# SCRIPT: production_library_copy_test.sh
# DESCRIPTION: auto-tag.yml and update-production.yml move production with the
#              library's own create_production.sh, from the scripts-only copy
#              lib_isolate.sh makes, and never run the caller's
#              scripts/create_production.sh. The guard probes pass against
#              that copy with no script-helpers beside it.
# USAGE: bash tests/production_library_copy_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
fail=0

# The copy the workflows run from: scripts/ alone, read-only.
mkdir -p "$work/lib"
cp -RP "$root/scripts" "$work/lib/scripts"
chmod -R a-w "$work/lib"
if env -u SCRIPT_HELPERS_DIR CREATE_PRODUCTION_SCRIPT="$work/lib/scripts/create_production.sh" \
    bash "$root/tests/create_production_guard_test.sh" > "$work/log" 2>&1; then
  echo "ok   the guard probes pass against the scripts-only copy"
else
  echo "FAIL the guard probes fail against the scripts-only copy"; sed 's/^/     /' "$work/log"; fail=1
fi
if env -u SCRIPT_HELPERS_DIR bash "$work/lib/scripts/create_production.sh" -h 2>&1 | grep -q -- '--allow-rollback'; then
  echo "ok   -h prints the usage without script-helpers"
else
  echo "FAIL -h prints no usage without script-helpers"; fail=1
fi

# The workflows: every run of create_production.sh is the library copy's.
python3 - "$root" <<'PY' || fail=1
import sys, yaml
root = sys.argv[1]
bad = 0
for wf, job in (("auto-tag.yml", "production"), ("update-production.yml", "move")):
    d = yaml.safe_load(open(f"{root}/.github/workflows/{wf}"))
    for jname, j in d["jobs"].items():
        for s in j.get("steps") or []:
            run = "\n".join(l for l in str(s.get("run") or "").splitlines() if not l.lstrip().startswith("#"))
            if "create_production.sh" in run.replace('"$run_lib/scripts/create_production.sh"', ""):
                print(f"FAIL {wf}:{jname} step {s.get('name')!r} runs a create_production.sh that is not the library copy")
                bad = 1
    runs = [s for s in d["jobs"][job]["steps"] if '"$run_lib/scripts/create_production.sh"' in str(s.get("run") or "")]
    if not runs:
        print(f"FAIL {wf}:{job} does not run the library copy"); bad = 1
    for s in runs:
        if "lib_path.sh\" secret" not in s["run"]:
            print(f"FAIL {wf}:{job} step {s.get('name')!r} holds the token without lib_path.sh secret"); bad = 1
if not bad:
    print("ok   the production jobs run only the library copy")
sys.exit(bad)
PY

exit "$fail"
