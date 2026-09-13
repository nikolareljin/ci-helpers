#!/usr/bin/env bash
# SCRIPT: scope_test.sh
# DESCRIPTION: Library functions must not leak variables into the caller.
# USAGE: bash tests/scope_test.sh
# ----------------------------------------------------
#
# These helpers are sourced into other people's scripts, so an undeclared loop
# variable or accumulator becomes a global in the caller and can quietly clobber
# something of theirs. The while-read loops that replaced mapfile for bash 3.2
# introduced exactly that, in nine functions across five modules.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging os ports adb flutter screencap hosts help

failures=0
note()  { echo "[scope_test] $*"; }
error() { echo "[scope_test][ERROR] $*" >&2; failures=$((failures+1)); }

# Names the rewrite introduced or relies on. None should exist after a call.
LEAKY="_sh_line line details serials sims devices vars_for_port _serials booted parts tok"
# show_help collects its fields through get_script_metadata, which writes them
# with `printf -v` -- a global unless a frame above declares them. Rendering help
# left every one of these in the caller until 0.27.0. Built from
# _HELP_META_FIELDS, the same source lib/help.sh declares from, so a new field
# is covered here the day it is added rather than the day someone remembers.
for _f in $_HELP_META_FIELDS param_lines; do
  LEAKY="$LEAKY _shlib_help_meta_$_f"
done

assert_no_leak() {
  local label="$1" name
  for name in $LEAKY; do
    if [[ -n "${!name+set}" ]]; then
      error "$label leaked \$$name into the caller"
      unset "$name"
    fi
  done
  note "$label leaks nothing"
}

# A port nothing is listening on: the lookup runs its loops and finds no rows.
port_in_use_by 65001 >/dev/null 2>&1 || true
assert_no_leak "port_in_use_by"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'API_PORT=65002\n' > "$tmp/.env"
check_required_ports_available "$tmp/.env" >/dev/null 2>&1 || true
assert_no_leak "check_required_ports_available"

# adb and flutter are absent here; the calls return early, which still exercises
# the declarations at the top of each function.
adb_list_devices >/dev/null 2>&1 || true
assert_no_leak "adb_list_devices"

flutter_resolve_device "" . >/dev/null 2>&1 || true
assert_no_leak "flutter_resolve_device"

printf '127.0.0.1\tlocalhost\n' > "$tmp/hosts"
HOSTS_FILE="$tmp/hosts" add_to_etc_hosts scope.local 127.0.0.1 >/dev/null 2>&1 || true
assert_no_leak "add_to_etc_hosts"

printf '#!/usr/bin/env bash\n# SCRIPT: s.sh\n# VERSION: 1.0.0\n' > "$tmp/s.sh"
get_script_metadata "$tmp/s.sh" scopemeta >/dev/null 2>&1 || true
assert_no_leak "get_script_metadata"

# The renderers, not just the collector. get_script_metadata writing into the
# prefix the caller asked for is the API; show_help doing it behind the caller's
# back, with a prefix nobody chose, is the leak. Use a real header so every
# field is populated and the block renderer runs.
printf '#!/usr/bin/env bash\n# SCRIPT: r.sh\n# DESCRIPTION: d\n# USAGE: r.sh\n# PARAMETERS:\n#   --x  an option\n# VERSION: 1.0.0\n' > "$tmp/r.sh"
for renderer in show_help display_help print_help; do
  "$renderer" "$tmp/r.sh" >/dev/null 2>&1 || true
  assert_no_leak "$renderer"
done

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
