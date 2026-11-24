#!/usr/bin/env bash
# SCRIPT: setup_java_problem_matcher_test.sh
# DESCRIPTION: setup-java 6.3.0 registers its javac problem matcher only with
#              `problem-matcher: true`. ci.yml and pr-gate.yml build the
#              caller's code on pull requests, so their Setup Java step must set
#              it, or compiler errors stop showing as annotations on the diff.
# USAGE: bash tests/setup_java_problem_matcher_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root/.github/workflows/ci.yml" "$root/.github/workflows/pr-gate.yml" <<'PY'
import os, sys, yaml
bad = 0
for path in sys.argv[1:]:
    name = os.path.basename(path)
    steps = [s for j in yaml.safe_load(open(path))["jobs"].values()
             for s in j.get("steps", [])
             if str(s.get("uses", "")).startswith("actions/setup-java@")]
    if not steps:
        print(f"FAIL {name}: no actions/setup-java step"); bad = 1
    for s in steps:
        if (s.get("with") or {}).get("problem-matcher") is not True:
            print(f"FAIL {name}: '{s.get('name')}' does not set problem-matcher: true"); bad = 1
    if not bad:
        print(f"ok   {name}: setup-java keeps the javac problem matcher")
sys.exit(bad)
PY
