#!/usr/bin/env bash
# SCRIPT: adb_wireless_test.sh
# DESCRIPTION: Tests for lib/adb.sh wireless helpers and scripts/check_no_private_ips.sh.
# USAGE: ./tests/adb_wireless_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/adb_wireless_test.sh
# ----------------------------------------------------
#
# `adb` is stubbed as a shell function, so these run with no device attached.
#
# The behaviours worth pinning without hardware are the ones where the obvious
# implementation is wrong: `adb connect` reporting success on a bare TCP
# handshake, an "offline" entry counting as attached, and an env-file writer
# that discards the keys it was not asked about.
# ----------------------------------------------------
# The `adb` stubs below are called only indirectly, by the library functions
# under test, so shellcheck reads every branch of them as unreachable. Must sit
# above the first command to apply file-wide.
# shellcheck disable=SC2317
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[adb_wireless_test] $*"; }
error() { echo "[adb_wireless_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[adb_wireless_test]   ok  $*"; }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import adb

# --- address from the environment -------------------------------------------
export DEV_DEVICE="203.0.113.55:41234"
if [[ "$(adb_wireless_addr)" == "203.0.113.55:41234" ]]; then
  ok "DEV_DEVICE wins — it is the dev-cli convention for which device"
else
  error "DEV_DEVICE not preferred: '$(adb_wireless_addr)'"
fi

# A USB serial in DEV_DEVICE has no colon and is not something to `adb connect`,
# so it must NOT be treated as an address.
export DEV_DEVICE="R5CRC2WANMT"
export ANDROID_DEVICE_IP="203.0.113.10"
export ANDROID_DEVICE_PORT="5555"
if [[ "$(adb_wireless_addr)" == "203.0.113.10:5555" ]]; then
  ok "a USB serial in DEV_DEVICE falls through to the split form"
else
  error "serial mishandled: '$(adb_wireless_addr)'"
fi
unset DEV_DEVICE

export ANDROID_DEVICE_IP="203.0.113.10"
export ANDROID_DEVICE_PORT="5555"
if [[ "$(adb_wireless_addr)" == "203.0.113.10:5555" ]]; then
  ok "adb_wireless_addr joins ip and port"
else
  error "adb_wireless_addr returned '$(adb_wireless_addr)'"
fi

unset ANDROID_DEVICE_PORT
if [[ "$(adb_wireless_addr)" == "203.0.113.10:5555" ]]; then
  ok "port defaults to 5555"
else
  error "port default wrong: '$(adb_wireless_addr)'"
fi

unset ANDROID_DEVICE_IP
if adb_wireless_addr >/dev/null 2>&1; then
  error "adb_wireless_addr must fail with no ANDROID_DEVICE_IP"
else
  ok "no address configured returns non-zero"
fi

# --- attached-ness reads the STATE column, not just the name ----------------
export ANDROID_DEVICE_IP="203.0.113.10"
export ANDROID_DEVICE_PORT="5555"

adb() {
  case "${1:-}" in
    devices) printf 'List of devices attached\n203.0.113.10:5555\tdevice\n' ;;
    *) return 0 ;;
  esac
}
if adb_wireless_attached "203.0.113.10:5555"; then
  ok "a ready device counts as attached"
else
  error "ready device not detected"
fi

adb() {
  case "${1:-}" in
    devices) printf 'List of devices attached\n203.0.113.10:5555\toffline\n' ;;
    *) return 0 ;;
  esac
}
if adb_wireless_attached "203.0.113.10:5555"; then
  error "an OFFLINE device must not count as attached"
else
  ok "an offline device does not count as attached"
fi

adb() {
  case "${1:-}" in
    devices) printf 'List of devices attached\n203.0.113.10:5555\tunauthorized\n' ;;
    *) return 0 ;;
  esac
}
if adb_wireless_attached "203.0.113.10:5555"; then
  error "an UNAUTHORIZED device must not count as attached"
else
  ok "an unauthorized device does not count as attached"
fi

# --- connect confirms against `adb devices`, it does not trust `adb connect` -
#
# This is the case that matters. `adb connect` exits 0 on a bare TCP handshake,
# so a stale address pointing at anything listening reports success while no
# device is usable.
adb() {
  case "${1:-}" in
    connect) return 0 ;;                                    # claims success...
    devices) printf 'List of devices attached\n' ;;         # ...but nothing attached
    *) return 0 ;;
  esac
}
if adb_wireless_connect "203.0.113.10:5555"; then
  error "connect must not trust adb connect's exit status"
else
  ok "a lying 'adb connect' is caught by re-checking adb devices"
fi

adb() {
  case "${1:-}" in
    connect) return 0 ;;
    devices) printf 'List of devices attached\n203.0.113.10:5555\tdevice\n' ;;
    *) return 0 ;;
  esac
}
if adb_wireless_connect "203.0.113.10:5555"; then
  ok "connect succeeds when the device really is attached"
else
  error "connect failed on an attached device"
fi

# --- env writing upserts and preserves ---------------------------------------
envfile="$(mktemp)"
cat >"$envfile" <<'EOF'
# a comment
SOME_OTHER_KEY=keep-me
DEV_DEVICE=198.51.100.1:5555
EOF

adb_wireless_write_env "$envfile" "203.0.113.77" "41234"

if grep -q '^DEV_DEVICE=203.0.113.77:41234$' "$envfile"; then
  ok "existing DEV_DEVICE is replaced"
else
  error "not replaced: $(cat "$envfile")"
fi
if [[ "$(grep -c '^DEV_DEVICE=' "$envfile")" == "1" ]]; then
  ok "exactly one DEV_DEVICE line"
else
  error "duplicate lines: $(cat "$envfile")"
fi
if grep -q '^SOME_OTHER_KEY=keep-me$' "$envfile" && grep -q '^# a comment$' "$envfile"; then
  ok "unrelated keys and comments survive"
else
  error "clobbered unrelated content: $(cat "$envfile")"
fi

# Created then removed, rather than `mktemp -u`: -u returns a path without
# reserving it, so another process can win the race and create it first.
missing="$(mktemp)"
rm -f "$missing"
adb_wireless_write_env "$missing" "203.0.113.9"
if grep -q '^DEV_DEVICE=203.0.113.9:5555$' "$missing"; then
  ok "a missing env file is created with the port defaulted"
else
  error "file not created properly: $(cat "$missing" 2>/dev/null)"
fi
# Permissions must survive the rewrite. An env file holding local config is
# often 0600, and `mv` from a temp file on another filesystem would replace it
# with one at the default mode — a quiet widening of a file people are told to
# keep private. This is why the writer uses `cat >` rather than `mv`.
# A symlinked env file must be written THROUGH, not replaced. `mv` swaps the
# symlink for a regular file and leaves the real target stale, so the write
# looks like it worked and changes nothing anyone reads. Measured, not assumed.
linkdir="$(mktemp -d)"
printf 'DEV_DEVICE=198.51.100.1:5555\n' >"$linkdir/real.env"
ln -s real.env "$linkdir/link.env"
adb_wireless_write_env "$linkdir/link.env" "203.0.113.6" 5555
if [[ -L "$linkdir/link.env" ]] && grep -q '^DEV_DEVICE=203.0.113.6:5555$' "$linkdir/real.env"; then
  ok "a symlinked env file is written through, not replaced"
else
  error "symlink handling wrong: link=$(test -L "$linkdir/link.env" && echo symlink || echo regular), target=$(cat "$linkdir/real.env")"
fi
rm -rf "$linkdir"

perms="$(mktemp)"
printf 'DEV_DEVICE=198.51.100.1:5555\n' >"$perms"
chmod 600 "$perms"
adb_wireless_write_env "$perms" "203.0.113.5" 5555
mode="$(stat -c '%a' "$perms" 2>/dev/null || stat -f '%Lp' "$perms")"
if [[ "$mode" == "600" ]]; then
  ok "the rewrite preserves file permissions"
else
  error "permissions changed to $mode (expected 600)"
fi
rm -f "$perms"

rm -f "$envfile" "$missing"

# --- the env file is SOURCED, so what goes into it is executed ---------------
inj="$(mktemp)"
: >"$inj"
# Single quotes deliberate: the payload must reach the function unexpanded, which
# is the whole point — expanding it here would test nothing.
# shellcheck disable=SC2016
if adb_wireless_write_env "$inj" "$(printf '203.0.113.1\nINJECTED=$(echo pwned)')" 2>/dev/null; then
  error "write_env accepted a newline in the address"
elif grep -q 'INJECTED' "$inj"; then
  error "write_env rejected but still wrote the injected line"
else
  ok "write_env refuses a newline in the address"
fi

# Single quotes deliberate: these are the literal strings being rejected.
# shellcheck disable=SC2016
for hostile in 'a;id' 'a$(id)' 'a b' '' ; do
  : >"$inj"
  adb_wireless_write_env "$inj" "$hostile" 2>/dev/null || true
  if grep -q '^DEV_DEVICE=' "$inj"; then
    error "write_env accepted hostile host '$hostile'"
  else
    ok "write_env rejects host '$hostile'"
  fi
done

for badport in 0 99999 abc '5555; id'; do
  : >"$inj"
  adb_wireless_write_env "$inj" "203.0.113.1" "$badport" 2>/dev/null || true
  if grep -q '^DEV_DEVICE=' "$inj"; then
    error "write_env accepted bad port '$badport'"
  else
    ok "write_env rejects port '$badport'"
  fi
done

for good in "203.0.113.10" "phone.local"; do
  : >"$inj"
  adb_wireless_write_env "$inj" "$good" 41234
  if grep -q "^DEV_DEVICE=$good:41234$" "$inj"; then
    ok "write_env accepts '$good'"
  else
    error "write_env rejected legitimate host '$good'"
  fi
done
rm -f "$inj"

# --- the private-IP gate ------------------------------------------------------
gate="./scripts/check_no_private_ips.sh"
fixture="$(mktemp -d)"

# Assembled from octets so no private-range literal appears in this tracked
# file. The gate is deliberately literal-blind — it cannot tell a real home
# address from a synthetic one — so building the fixture is the only way to keep
# tracked files clean AND still exercise the detector.
for quad in "10 0 0 1" "192 168 1 20" "172 16 5 5"; do
  # shellcheck disable=SC2086
  set -- $quad
  printf 'host %d.%d.%d.%d\n' "$1" "$2" "$3" "$4" >>"$fixture/bad.conf"
done
if bash "$gate" --path "$fixture" >/dev/null 2>&1; then
  error "gate passed a file containing private-range literals"
else
  ok "gate fails on 10/8, 192.168/16 and 172.16/12"
fi

clean="$(mktemp -d)"
printf 'docs use 203.0.113.10 and 198.51.100.4; flutter 3.44.7; sdk 10.0.2\n' >"$clean/ok.md"
printf '127.0.0.1 localhost\nphone.local\n' >>"$clean/ok.md"
if bash "$gate" --path "$clean" >/dev/null 2>&1; then
  ok "gate allows RFC 5737, loopback, .local and version strings"
else
  error "false positive: $(bash "$gate" --path "$clean" 2>&1)"
fi
# "Checked nothing" must never be a pass. A gate that suppresses its own errors
# reports success when run outside a git repo or pointed at a missing directory,
# and a green security gate is read as evidence the tree is clean.
# `|| rc=$?`, not a bare call then `$?`. Under `set -e` a command that exits
# non-zero aborts the script before the next line runs — and these commands are
# SUPPOSED to fail, so the naive form killed the suite silently right here.
notgit="$(mktemp -d)"
rc=0
bash "$gate" --repo "$notgit" >/dev/null 2>&1 || rc=$?
if (( rc == 2 )); then
  ok "gate fails (2) outside a git repository"
else
  error "gate returned $rc outside a git repo; must be 2"
fi
rm -rf "$notgit"

rc=0
bash "$gate" --path /no/such/directory/here >/dev/null 2>&1 || rc=$?
if (( rc == 2 )); then
  ok "gate fails (2) on a missing --path"
else
  error "gate returned $rc for a missing path; must be 2"
fi

# And the three outcomes stay distinguishable: 0 clean, 1 violation, 2 unable.
# Explicit ifs: `A && B || C` is not if-then-else, and C runs when B fails.
rc=0
bash "$gate" --path "$clean" >/dev/null 2>&1 || rc=$?
if (( rc == 0 )); then
  ok "a clean scan exits 0"
else
  error "clean scan exited $rc"
fi

rc=0
bash "$gate" --path "$fixture" >/dev/null 2>&1 || rc=$?
if (( rc == 1 )); then
  ok "a violation exits 1, distinct from 'could not check'"
else
  error "violation exited $rc, expected 1"
fi

rm -rf "$fixture" "$clean"

if (( failures )); then
  note "FAILED ($failures)"
  exit 1
fi
note "all tests passed"
