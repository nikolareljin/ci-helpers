#!/usr/bin/env bash
# SCRIPT: sign_export_env_default_test.sh
# DESCRIPTION: macos-sign and windows-sign keep their secrets out of
#              GITHUB_ENV unless export_env is exactly "true": the input
#              defaults to "false", and every export branch is gated on an
#              exact "true", so a typo such as "False" or "no" exports nothing.
# USAGE: bash tests/sign_export_env_default_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import re, sys, yaml
root = sys.argv[1]
fail = []
gates = {
    "macos-sign": (r'if \[ "\$\{EXPORT_ENV\}" != "true" \]; then', 1),
    "windows-sign": (r'if \(\$env:EXPORT_ENV -cne "true"\) \{', 2),
}
for action, (gate, count) in gates.items():
    path = f"{root}/.github/actions/{action}/action.yml"
    d = yaml.safe_load(open(path))
    default = d["inputs"]["export_env"].get("default")
    if default != "false":
        fail.append(f"{action}: export_env default is {default!r}, not 'false'")
    runs = [s.get("run", "") for s in d["runs"]["steps"] if "EXPORT_ENV" in str(s.get("env", {}))]
    gated = sum(len(re.findall(gate, r)) for r in runs)
    if gated != count or len(runs) != count:
        fail.append(f"{action}: {gated} of {len(runs)} export steps gated on an exact \"true\", expected {count}")
for f in fail:
    print(f"FAIL {f}")
sys.exit(1 if fail else 0)
PY
echo "ok: sign actions export secrets only on an exact \"true\""
