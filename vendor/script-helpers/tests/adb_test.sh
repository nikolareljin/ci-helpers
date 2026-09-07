#!/usr/bin/env bash
# SCRIPT: adb_test.sh
# DESCRIPTION: Tests for lib/adb.sh install-user pinning and post-install verification.
# USAGE: ./tests/adb_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/adb_test.sh
# ----------------------------------------------------
#
# `adb` is stubbed as a shell function, so these run with no device attached and
# assert the behaviour that matters: that an install into an unreadable profile
# is reported rather than passing silently. That is the failure this code exists
# to prevent, so it is the one worth testing without hardware.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[adb_test] $*"; }
error() { echo "[adb_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import adb

# 1) functions defined after import
for fn in adb_install adb_installed_for_user adb_install_verified; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'fake apk' > "$tmp/app.apk"

# --- the stub --------------------------------------------------------------
#
# Drives every branch from two globals:
#   STUB_INSTALL_RC   what `adb install` returns
#   STUB_PM_MODE      ok | missing | security
# and records the install argv in STUB_LAST_INSTALL.

adb_available() { return 0; }
adb() {
  local -a argv=("$@")
  local i
  for ((i = 0; i < ${#argv[@]}; i++)); do
    case "${argv[i]}" in
      install)
        STUB_LAST_INSTALL="${argv[*]}"
        return "${STUB_INSTALL_RC:-0}"
        ;;
      shell)
        case "${argv[i+1]:-}" in
          pm)
            if [[ "${argv[i+2]:-}" == "list" && "${argv[i+3]:-}" == "packages" ]]; then
              case "${STUB_PM_MODE:-ok}" in
                ok)       printf 'package:com.example.app\npackage:com.android.settings\n'; return 0 ;;
                missing)  printf 'package:com.android.settings\n'; return 0 ;;
                # Exit 0 deliberately. This is what a real device does: observed
                # on a Galaxy S21 FE (Android 16), `pm list packages --user 150`
                # prints the SecurityException and still exits 0. A stub that
                # returned non-zero here would let a status-only check pass.
                security) echo "Error: java.lang.SecurityException: Shell does not have permission to access user 150" >&2; return 0 ;;
                # Some Android versions phrase it differently and do exit non-zero.
                security_rc) echo "Error: java.lang.SecurityException: Shell does not have permission to access user 150" >&2; return 255 ;;
                baduser)  echo "Bad user number: 999" >&2; return 0 ;;
              esac
            fi
            if [[ "${argv[i+2]:-}" == "list" && "${argv[i+3]:-}" == "users" ]]; then
              printf 'Users:\n\tUserInfo{0:Owner:c13} running\n\tUserInfo{150:Secure Folder:1010} running\n'
              return 0
            fi
            ;;
        esac
        return 0
        ;;
    esac
  done
  return 0
}

# 2) --user defaults to 0 and is passed through
STUB_INSTALL_RC=0 STUB_PM_MODE=ok STUB_LAST_INSTALL=""
adb_install "SERIAL1" "$tmp/app.apk" >/dev/null 2>&1
if [[ "$STUB_LAST_INSTALL" == *"--user 0"* ]]; then
  note "adb_install passes --user 0 by default"
else
  error "adb_install did not pass --user 0 (argv: $STUB_LAST_INSTALL)"
fi

# 3) an explicit --user is honoured, and does not end up as a stray argument
STUB_LAST_INSTALL=""
adb_install "SERIAL1" "$tmp/app.apk" --user 150 >/dev/null 2>&1
if [[ "$STUB_LAST_INSTALL" == *"--user 150"* ]]; then
  note "adb_install honours an explicit --user"
else
  error "adb_install ignored --user 150 (argv: $STUB_LAST_INSTALL)"
fi
if [[ "$STUB_LAST_INSTALL" == *"--user 150"*"--user"* ]]; then
  error "adb_install emitted --user twice (argv: $STUB_LAST_INSTALL)"
fi

# 4) extra adb flags still reach adb alongside --user
STUB_LAST_INSTALL=""
adb_install "SERIAL1" "$tmp/app.apk" --user 0 -g >/dev/null 2>&1
[[ "$STUB_LAST_INSTALL" == *"-g"* ]] || error "extra adb flags were dropped (argv: $STUB_LAST_INSTALL)"

# 5) a non-numeric --user is an argument error, not a pass-through
set +e
adb_install "SERIAL1" "$tmp/app.apk" --user notanumber >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "a non-numeric --user returned $status (expected 2)"
note "argument validation on --user"

# 6) the visibility predicate
STUB_PM_MODE=ok
adb_installed_for_user "SERIAL1" "com.example.app" 0 >/dev/null 2>&1 \
  || error "adb_installed_for_user said no for a package that is listed"

STUB_PM_MODE=missing
set +e
adb_installed_for_user "SERIAL1" "com.example.app" 0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "adb_installed_for_user returned $status for an absent package (expected 1)"

# The case this whole change exists for: the shell cannot read the profile.
# Both shapes matter — the real device prints the error and exits 0, so a
# status-only check would classify it as "package absent".
for mode in security security_rc baduser; do
  STUB_PM_MODE="$mode"
  set +e
  adb_installed_for_user "SERIAL1" "com.example.app" 150 >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || error "pm mode '$mode' returned $status (expected 3)"
done
note "an unreadable profile is reported as 3 whether or not adb exits non-zero"

# 7) install_verified: success only when the package is actually visible
STUB_INSTALL_RC=0 STUB_PM_MODE=ok
set +e
adb_install_verified "SERIAL1" "$tmp/app.apk" "com.example.app" --user 0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 0 ]] || error "install_verified returned $status on a genuine success (expected 0)"

# The silent failure: adb says Success, the package is not there.
STUB_INSTALL_RC=0 STUB_PM_MODE=missing
set +e
adb_install_verified "SERIAL1" "$tmp/app.apk" "com.example.app" --user 0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 4 ]] || error "install_verified returned $status when adb succeeded but the package was absent (expected 4)"
note "an install that adb reports as Success but did not land fails with 4"

# The work-profile shape.
STUB_INSTALL_RC=0 STUB_PM_MODE=security
set +e
adb_install_verified "SERIAL1" "$tmp/app.apk" "com.example.app" --user 150 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 3 ]] || error "install_verified returned $status for an unreadable profile (expected 3)"

# A real install failure is passed through, not masked by the check.
STUB_INSTALL_RC=1 STUB_PM_MODE=ok
set +e
adb_install_verified "SERIAL1" "$tmp/app.apk" "com.example.app" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || error "install_verified returned 0 when the install itself failed"

# 8) bad args return exactly 2
set +e
adb_install_verified >/dev/null 2>&1;               [[ $? -eq 2 ]] || error "install_verified with no args did not return 2"
adb_installed_for_user "SERIAL1" >/dev/null 2>&1;   [[ $? -eq 2 ]] || error "installed_for_user with no package did not return 2"
adb_installed_for_user "S" "p" abc >/dev/null 2>&1; [[ $? -eq 2 ]] || error "installed_for_user with a non-numeric user did not return 2"
set -e
note "bad arguments return 2"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
