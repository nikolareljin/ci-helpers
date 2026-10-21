#!/usr/bin/env bash
# SCRIPT: windows_sign_mode_test.sh
# DESCRIPTION: windows-sign and tauri-release accept tauri_updater, pfx and
#              azure (plus "none" in tauri-release), windows-sign refuses pfx
#              when the certificate or password is empty, both refuse unknown
#              modes, and tauri-release signs in a sign-windows job that gets
#              the signing secrets and checks out and runs no app code.
#              The pfx script is run against a throwaway PFX made with openssl:
#              a good PFX passes, a wrong password, bad base64, a non-code-
#              signing certificate and a bad timestamp URL are refused, and the
#              password never reaches the output unmasked. Signing itself needs
#              signtool and runs in the self-test workflow on Windows.
# USAGE: bash tests/windows_sign_mode_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root/.github/actions/windows-sign/action.yml" "$root/.github/workflows/tauri-release.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
rd = yaml.safe_load(open(sys.argv[2]))
fail = []
first = d["runs"]["steps"][0]
if first.get("name") != "Check sign mode" or "if" in first:
    fail.append("first step is not an unconditional 'Check sign mode'")
pfx = [s for s in d["runs"]["steps"] if s.get("if") == "${{ inputs.sign_mode == 'pfx' }}"]
if len(pfx) != 1 or "sign_pfx.ps1" not in pfx[0].get("run", ""):
    fail.append("windows-sign has no pfx step running sign_pfx.ps1")
for name in ("certificate_base64", "certificate_password", "timestamp_server", "files_folder", "verify_trust"):
    if name not in d["inputs"]:
        fail.append(f"windows-sign has no input {name}")
jobs = rd["jobs"]
build, sign = jobs["build-windows"], jobs.get("sign-windows")
# The build job runs the app's code, so no Authenticode secret may reach it.
btext = yaml.safe_dump(build)
for name in ("WINDOWS_CERTIFICATE", "AZURE_"):
    if name in btext:
        fail.append(f"build-windows references {name}*: signing secrets must stay out of the build job")
if not sign:
    fail.append("tauri-release has no sign-windows job")
else:
    if sign.get("needs") != "build-windows":
        fail.append("sign-windows does not need build-windows")
    for st in sign["steps"]:
        uses = st.get("uses", "")
        if uses.startswith("actions/checkout@"):
            w = st.get("with", {})
            if w.get("repository") != "${{ job.workflow_repository }}" or w.get("ref") != "${{ job.workflow_sha }}" \
               or w.get("sparse-checkout") != ".github/actions":
                fail.append("sign-windows checks out something other than the ci-helpers actions")
        run = st.get("run", "")
        for tool in ("cargo", "npm", "pnpm", "yarn", "node ", "bash -c", "INSTALL_CMD", "BUILD_CMD"):
            if tool in run:
                fail.append(f"sign-windows runs {tool.strip()}: it must run no app or build code")
        if "working-directory" in st:
            fail.append("sign-windows has a step with working-directory: it has no app tree")
    stext = yaml.safe_dump(sign)
    if "tauri-windows-unsigned" not in stext or "tauri-windows-artifacts" not in stext:
        fail.append("sign-windows does not download tauri-windows-unsigned and upload tauri-windows-artifacts")
    calls = [st for st in sign["steps"] if st.get("uses", "").endswith("/windows-sign")]
    if len(calls) != 1 or not calls[0].get("with", {}).get("files_folder"):
        fail.append("sign-windows does not run windows-sign with files_folder")
    elif "secrets.WINDOWS_CERTIFICATE " not in calls[0]["with"].get("certificate_base64", "") + " ":
        fail.append("sign-windows does not pass WINDOWS_CERTIFICATE to windows-sign")
if "sign-windows" not in jobs["release"].get("needs", []):
    fail.append("release does not wait for sign-windows")
first_win = rd["jobs"]["build-windows"]["steps"][0]
if first_win.get("name") != "Check Windows sign mode" or "if" in first_win:
    fail.append("build-windows does not start with an unconditional 'Check Windows sign mode'")
if fail:
    sys.exit("FAIL: " + "; ".join(fail))
print("ok: pfx is wired in; tauri-release signs in sign-windows, away from the build")
PY

if ! command -v pwsh >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then echo "FAIL: pwsh not found"; exit 1; fi
  echo "SKIP: pwsh not found, the pwsh checks were not run"
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
need_secrets="sign_mode pfx needs certificate_base64 and certificate_password"
check() { # want_rc mode cert password want_text
  local rc=0 out
  out="$(SIGN_MODE="$2" CERT_B64="$3" CERT_PW="$4" pwsh -NoProfile -File "$script" 2>&1)" || rc=$?
  if [ "$rc" != "$1" ] || [[ "$out" != *"$5"* ]]; then
    echo "FAIL: $(basename "$script") sign_mode='$2' cert='$3' pw='$4': rc $rc, want $1 and '$5'; output: $out"
    fail=1
  fi
}
for script in "$tmp/check.ps1" "$tmp/release.ps1"; do
  check 0 tauri_updater "" "" ""
  check 0 Azure "" "" ""
  check 0 pfx "QUJD" "pw" ""
  check 0 PFX "QUJD" "pw" ""
  check 1 bogus "" "" "must be"
  check 1 "" "" "" "must be"
done
# Only the action sees the secrets; tauri-release's first step has none.
script="$tmp/check.ps1"
check 1 pfx "" "pw" "$need_secrets"
check 1 pfx "QUJD" "" "$need_secrets"
check 1 pfx " " "pw" "$need_secrets"
script="$tmp/check.ps1"
check 1 none "" "" "must be tauri_updater, pfx or azure"
script="$tmp/release.ps1"
check 0 none "" "" ""
check 0 None "" "" ""
check 1 bogus "" "" "must be none, tauri_updater, pfx or azure"
[ "$fail" = 0 ] || exit 1
echo "ok: both checks accept pfx, the action refuses it without secrets, both refuse unknown modes"

# sign_pfx.ps1 itself, up to the point where signtool would run.
pw='T3st-only pw!'
mk() { # name eku
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/$1.key" -out "$tmp/$1.crt" -days 2 \
    -subj "/CN=windows-sign test $1" -addext "extendedKeyUsage=$2" >/dev/null 2>&1
  openssl pkcs12 -export -inkey "$tmp/$1.key" -in "$tmp/$1.crt" -out "$tmp/$1.pfx" \
    -passout "pass:$pw" -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256
  base64 -w0 "$tmp/$1.pfx"
}
good="$(mk good codeSigning)"
tls="$(mk tls serverAuth)"
sign() { # want_rc b64 pw ts_url files_dir want_text
  local rc=0 out
  out="$(CERT_B64="$2" CERT_PW="$3" TS_URL="$4" FILES_DIR="$5" pwsh -NoProfile -File "$root/.github/actions/windows-sign/sign_pfx.ps1" 2>&1)" || rc=$?
  if [ "$rc" != "$1" ] || [[ "$out" != *"$6"* ]]; then
    echo "FAIL: sign_pfx ts='$4' dir='$5' want rc $1 and '$6'; got rc $rc: $out"
    fail=1
  fi
  # The password may appear only in the ::add-mask:: line.
  if [ -n "$3" ] && grep -v "^::add-mask::" <<<"$out" | grep -qF -- "$3"; then
    echo "FAIL: sign_pfx printed the password (ts='$4'): $out"
    fail=1
  fi
}
sign 0 "$good" "$pw" "" "" "PFX ok: CN=windows-sign test good"
sign 0 "$good" "$pw" "https://timestamp.example/x" "" "PFX ok"
sign 1 "$good" "wrong-password" "" "" "does not open with certificate_password"
sign 1 "not base64!!" "$pw" "" "" "not valid base64"
sign 1 "$tls" "$pw" "" "" "not for code signing"
sign 1 "$good" "$pw" "ftp://ts.example" "" "timestamp_server must be an http(s) URL"
sign 1 "$good" "$pw" "http://ts.example/a b" "" "timestamp_server must be an http(s) URL"
sign 1 "" "$pw" "" "" "$need_secrets"
sign 1 "$good" "" "" "" "$need_secrets"
sign 1 "$good" "$pw" "" "$tmp" "needs a Windows runner"
[ "$fail" = 0 ] || exit 1
echo "ok: sign_pfx.ps1 opens a good PFX and refuses bad ones with a reason"
