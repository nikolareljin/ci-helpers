#!/usr/bin/env bash
# SCRIPT: packaging_no_vendor_dir_test.sh
# DESCRIPTION: The packaging workflows use script-helpers where the caller
#              keeps it and never create vendor/ in the caller's tree: in a Go
#              module that directory switches go build to vendor mode, which
#              fails with "inconsistent vendoring".
# USAGE: bash tests/packaging_no_vendor_dir_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import re, sys, yaml
root = sys.argv[1]
files = ["deb-build.yml", "rpm-build.yml", "homebrew-package.yml"]
creates = re.compile(r"mkdir\s+(-p\s+)?\S*vendor\b|ln\s+-\S*\s+\S+\s+\S*vendor/")
bad = []
for f in files:
    d = yaml.safe_load(open(f"{root}/.github/workflows/{f}"))
    for job, j in d["jobs"].items():
        for s in j.get("steps", []):
            run = s.get("run", "")
            if creates.search(run):
                bad.append(f"{f}: {job}: {s.get('name', '?')}: creates vendor/")
            if "vendor/script-helpers/scripts" in run:
                bad.append(f"{f}: {job}: {s.get('name', '?')}: hard-codes vendor/script-helpers")
for b in bad:
    print(f"FAIL {b}")
sys.exit(1 if bad else 0)
PY
echo "ok: packaging workflows create no vendor/ directory"
