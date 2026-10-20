#!/usr/bin/env bash
# SCRIPT: windows_sign_no_pfx_test.sh
# DESCRIPTION: pfx signing is gone: windows-sign has no PFX import and its
#              first step fails sign_mode "pfx" (Tauri v2 never used the sign
#              command, so pfx builds came out unsigned); tauri-release passes
#              no certificate to the action and has no certificate cleanup.
# USAGE: bash tests/windows_sign_no_pfx_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root/.github/actions/windows-sign/action.yml" "$root/.github/workflows/tauri-release.yml" <<'PY'
import re, sys, yaml
action, release = (open(p).read() for p in sys.argv[1:3])
d = yaml.safe_load(action)
fail = []
if re.search(r"Import-PfxCertificate|signtool sign|TAURI_WINDOWS_SIGN_COMMAND=", action):
    fail.append("windows-sign still imports a PFX or sets a signtool command")
first = d["runs"]["steps"][0]
if first.get("name") != "Check sign mode" or "if" in first:
    fail.append("first step is not an unconditional 'Check sign mode'")
elif not re.search(r'\$env:SIGN_MODE -ceq "pfx"\)\s*\{[^}]*exit 1', first["run"]):
    fail.append("'Check sign mode' does not exit 1 on pfx")
for name in ("certificate_base64", "certificate_password", "timestamp_server"):
    if d["inputs"].get(name, {}).get("default") != "":
        fail.append(f"input {name} must stay, deprecated, with default ''")
rd = yaml.safe_load(release)
for job in rd["jobs"].values():
    for st in job.get("steps", []):
        if st.get("uses", "").endswith("/windows-sign"):
            passed = set(st.get("with", {})) & {"certificate_base64", "certificate_password", "timestamp_server"}
            if passed:
                fail.append(f"tauri-release passes {sorted(passed)} to windows-sign")
if re.search(r"WINDOWS_CERT_THUMBPRINT|WINDOWS_PFX_PATH", release):
    fail.append("tauri-release still cleans up a pfx certificate")
if fail:
    sys.exit("FAIL: " + "; ".join(fail))
print("ok: pfx signing removed and sign_mode pfx rejected")
PY
