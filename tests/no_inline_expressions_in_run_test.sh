#!/usr/bin/env bash
# SCRIPT: no_inline_expressions_in_run_test.sh
# DESCRIPTION: The run scripts of the signing workflows take inputs through
#              env, never as ${{ }} spliced into the script, where an input
#              such as `x; curl ...` would run as code next to the keys.
# USAGE: bash tests/no_inline_expressions_in_run_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import sys, yaml
root = sys.argv[1]
files = [".github/workflows/ppa-deb.yml"]
bad = []
for f in files:
    d = yaml.safe_load(open(f"{root}/{f}"))
    for job, j in d["jobs"].items():
        for s in j.get("steps", []):
            if "${{" in s.get("run", ""):
                bad.append(f"{f}: {job}: {s.get('name', '?')}")
for b in bad:
    print(f"FAIL inline expression in run: {b}")
sys.exit(1 if bad else 0)
PY
echo "ok: no inline expressions in run scripts"
