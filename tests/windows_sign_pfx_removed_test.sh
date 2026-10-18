#!/usr/bin/env bash
# SCRIPT: windows_sign_pfx_removed_test.sh
# DESCRIPTION: windows-sign (pfx) removes the decoded PFX file in a finally
#              block wrapped around Import-PfxCertificate, so the file is gone
#              before the caller's build runs, even when the import fails.
# USAGE: bash tests/windows_sign_pfx_removed_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root/.github/actions/windows-sign/action.yml" <<'PY'
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in d["runs"]["steps"] if s.get("name", "").startswith("Import PFX")]
assert len(steps) == 1, "no Import PFX step"
run = steps[0]["run"]
m = re.search(r"try\s*\{(.*?)\}\s*finally\s*\{(.*?)\}", run, re.S)
if not m or "Import-PfxCertificate" not in m.group(1):
    sys.exit("FAIL: Import-PfxCertificate is not inside try { } finally { }")
if not re.search(r"Remove-Item\s+\$pfxPath\b", m.group(2)):
    sys.exit("FAIL: the finally block does not remove $pfxPath")
print("ok: PFX file removed in a finally right after the import")
PY
