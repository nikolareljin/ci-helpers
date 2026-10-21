#!/usr/bin/env bash
# SCRIPT: windows_sign_no_pfx_test.sh
# DESCRIPTION: pfx signing is gone: windows-sign has no PFX import and its
#              first step, run here with pwsh, fails sign_mode "pfx" and any
#              unknown mode (Tauri v2 never used the sign command, so pfx
#              builds came out unsigned); tauri-release passes no certificate
#              to the action, has no certificate cleanup, and its Windows job
#              runs the same check (plus "none") as its first step.
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
first_win = rd["jobs"]["build-windows"]["steps"][0]
if first_win.get("name") != "Check Windows sign mode" or "if" in first_win:
    fail.append("build-windows does not start with an unconditional 'Check Windows sign mode'")
if re.search(r"WINDOWS_CERT_THUMBPRINT|WINDOWS_PFX_PATH", release):
    fail.append("tauri-release still cleans up a pfx certificate")
if fail:
    sys.exit("FAIL: " + "; ".join(fail))
print("ok: pfx signing removed")
PY

# Run the 'Check sign mode' step itself. GitHub expressions compare strings
# without case, so "Azure" runs the azure step and must pass here too.
if ! command -v pwsh >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then echo "FAIL: pwsh not found"; exit 1; fi
  echo "SKIP: pwsh not found, 'Check sign mode' not run"
  exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 - "$root/.github/actions/windows-sign/action.yml" "$tmp/check.ps1" \
  "$root/.github/workflows/tauri-release.yml" "$tmp/release.ps1" <<'PY'
import sys, yaml
open(sys.argv[2], "w").write(yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]["run"])
job = yaml.safe_load(open(sys.argv[3]))["jobs"]["build-windows"]
open(sys.argv[4], "w").write(job["steps"][0]["run"])
PY
fail=0
script="$tmp/check.ps1"
check() { # want_rc mode timestamp_server want_text
  local rc=0 out
  out="$(SIGN_MODE="$2" TS_URL="$3" CERT_B64="" CERT_PW="" pwsh -NoProfile -File "$script" 2>&1)" || rc=$?
  if [ "$rc" != "$1" ] || [[ "$out" != *"$4"* ]]; then
    echo "FAIL: sign_mode='$2' timestamp_server='$3': rc $rc, want $1 and '$4'; output: $out"
    fail=1
  fi
}
check 0 tauri_updater "" ""
check 0 azure "" ""
check 0 Azure "" ""
check 1 pfx "" "sign_mode pfx was removed"
check 1 PFX "" "sign_mode pfx was removed"
check 1 "" "" "must be tauri_updater or azure"
check 1 none "" "must be tauri_updater or azure"
check 0 azure "https://timestamp.example" "::warning::"
[ "$fail" = 0 ] || exit 1
echo "ok: 'Check sign mode' rejects pfx and unknown modes, accepts the rest"

# tauri-release's early check: same rule, and "none" skips signing.
script="$tmp/release.ps1"
check 0 none "" ""
check 0 None "" ""
check 0 tauri_updater "" ""
check 0 Azure "" ""
check 1 pfx "" "sign_mode pfx was removed"
check 1 PFX "" "sign_mode pfx was removed"
check 1 "" "" "must be none, tauri_updater or azure"
check 1 bogus "" "must be none, tauri_updater or azure"
[ "$fail" = 0 ] || exit 1
echo "ok: tauri-release refuses pfx and unknown modes before the build"
