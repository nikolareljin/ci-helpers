#!/usr/bin/env bash
# adb / Android device utilities — a general toolkit for inspecting and debugging
# Android devices over USB via the Android Debug Bridge (`adb`).
#
# Everything is MULTI-DEVICE SAFE: functions target a device with
# `adb -s <serial>` rather than a bare `adb shell`, which errors with "more than
# one device" once a second device is attached. All functions return non-zero /
# no-op when `adb` is missing, so callers degrade cleanly.

# --- discovery -------------------------------------------------------------

# Usage: adb_available; returns 0 if the adb CLI is on PATH.
adb_available() { command -v adb >/dev/null 2>&1; }

# Usage: adb_ready_serials; prints the serial of each *ready* device, one per
# line, skipping the header and any offline/unauthorized entries (state column
# must be exactly "device"). Prints nothing when none are ready.
adb_ready_serials() {
  adb_available || return 1
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}'
}

# --- device info -----------------------------------------------------------

# Usage: adb_getprop <serial> <prop>; prints a system property (CR/LF trimmed).
adb_getprop() {
  local serial="$1" prop="$2"
  adb_available || return 1
  [[ -n "$serial" && -n "$prop" ]] || return 1
  adb -s "$serial" shell getprop "$prop" 2>/dev/null | tr -d '\r\n'
}

# Usage: adb_device_model <serial>; prints ro.product.model (e.g. "Pixel 5").
adb_device_model() { adb_getprop "$1" ro.product.model; }

# Usage: adb_android_version <serial>; prints the Android OS release (e.g. "9").
adb_android_version() { adb_getprop "$1" ro.build.version.release; }

# Usage: adb_device_api <serial>; prints the supported API / SDK level (e.g. 28).
adb_device_api() { adb_getprop "$1" ro.build.version.sdk; }

# Usage: adb_device_ip <serial> [iface=wlan0]; prints the device's IPv4 on the
# interface (default wlan0 / Wi-Fi; pass e.g. rmnet_data0 for cellular). Returns
# non-zero with no output when adb is missing or the interface has no address.
adb_device_ip() {
  local serial="$1" iface="${2:-wlan0}" ip=""
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  ip="$(adb -s "$serial" shell ip -f inet addr show "$iface" 2>/dev/null \
        | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -n1)"
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "$ip"
}

# Usage: adb_list_devices [iface=wlan0]; prints a table of every ready device
# with its model, Android OS version, API level and IP. Works with any number of
# devices attached. Returns 1 when adb is missing; 0 (empty table) when none.
adb_list_devices() {
  local iface="${1:-wlan0}" s
  local -a serials=()
  if ! adb_available; then
    log_warn "adb not found. Install the Android platform-tools and put adb on PATH."
    return 1
  fi
  mapfile -t serials < <(adb_ready_serials)
  if [[ ${#serials[@]} -eq 0 ]]; then
    log_warn "No ready devices. Check the USB cable and 'adb devices' — authorize the on-phone prompt if it shows 'unauthorized'."
    return 0
  fi
  printf '%-20s %-18s %-9s %-5s %s\n' "SERIAL" "MODEL" "ANDROID" "API" "IP ($iface)"
  for s in "${serials[@]}"; do
    printf '%-20s %-18s %-9s %-5s %s\n' \
      "$s" \
      "$(adb_device_model "$s" 2>/dev/null || echo '?')" \
      "$(adb_android_version "$s" 2>/dev/null || echo '?')" \
      "$(adb_device_api "$s" 2>/dev/null || echo '?')" \
      "$(adb_device_ip "$s" "$iface" 2>/dev/null || echo '-')"
  done
}

# --- shell / debugging -----------------------------------------------------

# Usage: adb_shell <serial> <command...>; run a shell command on a device.
adb_shell() {
  local serial="$1"; shift || true   # drop the serial; the rest is the command
  adb_available || return 1
  [[ -n "$serial" && $# -gt 0 ]] || { log_error "adb_shell: need <serial> <command...>"; return 2; }
  adb -s "$serial" shell "$@"
}

# Usage: adb_logcat <serial> [regex]; dump the current logcat buffer (-d),
# optionally filtered to lines matching <regex>. Non-streaming (scriptable); for
# a live tail use `adb -s <serial> logcat` directly.
adb_logcat() {
  local serial="$1" regex="${2:-}"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  if [[ -n "$regex" ]]; then
    # `--` so a regex starting with '-' isn't taken as a grep option.
    adb -s "$serial" logcat -d 2>/dev/null | grep -E -- "$regex"
  else
    adb -s "$serial" logcat -d 2>/dev/null
  fi
}

# Usage: adb_clear_logcat <serial>; clears the device's logcat buffer.
adb_clear_logcat() {
  local serial="$1"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  adb -s "$serial" logcat -c 2>/dev/null
}

# --- file transfer ---------------------------------------------------------

# Usage: adb_push <serial> <local> <remote>; copy a local file/dir TO the device.
adb_push() {
  local serial="$1" local_path="$2" remote_path="$3"
  adb_available || return 1
  [[ -n "$serial" && -n "$local_path" && -n "$remote_path" ]] \
    || { log_error "adb_push: need <serial> <local> <remote>"; return 2; }
  [[ -e "$local_path" ]] || { log_error "adb_push: local path not found: $local_path"; return 2; }
  log_info "push $local_path -> $serial:$remote_path"
  adb -s "$serial" push "$local_path" "$remote_path"
}

# Usage: adb_pull <serial> <remote> [local=.]; copy a file/dir FROM the device.
adb_pull() {
  local serial="$1" remote_path="$2" local_path="${3:-.}"
  adb_available || return 1
  [[ -n "$serial" && -n "$remote_path" ]] \
    || { log_error "adb_pull: need <serial> <remote> [local]"; return 2; }
  log_info "pull $serial:$remote_path -> $local_path"
  adb -s "$serial" pull "$remote_path" "$local_path"
}

# --- apps ------------------------------------------------------------------

# Usage: adb_install <serial> <apk> [--user <id>] [extra adb install args...];
# (re)install an APK to one device (-r keeps app data). Returns adb's exit status.
#
# --user defaults to 0, the device owner, and is passed through to adb. This is
# not a cosmetic default. An unqualified `adb install` can land the package in a
# profile the shell cannot subsequently read — on a device with a work profile or
# Samsung Secure Folder, the install prints Success and exits 0 while
# `pm list packages` fails with "SecurityException: Shell does not have
# permission to access user <id>". The app is then absent from the launcher and
# unstartable, with every signal saying the install worked. Pass an explicit
# --user to target a profile deliberately; see adb_installed_for_user to confirm
# it landed.
adb_install() {
  # ${1:-} rather than $1: a caller running with `set -u` would otherwise get a
  # fatal unbound-variable error instead of the documented exit 2.
  local serial="${1:-}" apk="${2:-}"; shift 2 2>/dev/null || true   # drop serial+apk; rest = adb flags
  local user="0"
  local -a extra=()
  adb_available || return 1
  [[ -n "$serial" && -n "$apk" ]] || { log_error "adb_install: need <serial> <apk>"; return 2; }
  [[ -f "$apk" ]] || { log_error "adb_install: APK not found: $apk"; return 2; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        user="${2:-}"
        [[ "$user" =~ ^[0-9]+$ ]] || { log_error "adb_install: --user must be a number, got '${user:-<empty>}'"; return 2; }
        shift 2 ;;
      *) extra+=("$1"); shift ;;
    esac
  done
  log_info "install $apk -> $serial (user $user)"
  adb -s "$serial" install -r --user "$user" "${extra[@]+"${extra[@]}"}" "$apk"
}

# Usage: adb_installed_for_user <serial> <package> [user=0]; returns 0 when the
# package is visible to that user, 1 when it is not, and 3 when the shell is not
# permitted to query the user at all — which is itself the answer, because a
# package the shell cannot see is a package the launcher will not show.
#
# Call this after adb_install. An installer's exit code asserts that adb accepted
# the command, not that the app is usable.
adb_installed_for_user() {
  local serial="${1:-}" pkg="${2:-}" user="${3:-0}" out
  adb_available || return 1
  [[ -n "$serial" && -n "$pkg" ]] || { log_error "adb_installed_for_user: need <serial> <package> [user]"; return 2; }
  [[ "$user" =~ ^[0-9]+$ ]] || { log_error "adb_installed_for_user: user must be a number, got '$user'"; return 2; }
  # `adb shell` frequently exits 0 even when the command inside it failed, so the
  # output is checked before the status. Observed on a Galaxy S21 FE (Android 16):
  # `pm list packages --user 150` prints "SecurityException: Shell does not have
  # permission to access user 150" and still exits 0. Reading the status alone
  # would classify that as "package absent" — the same trusting-an-exit-code
  # mistake this function exists to catch.
  out="$(adb -s "$serial" shell pm list packages --user "$user" 2>&1)" || true
  out="${out//$'\r'/}"
  if grep -q 'SecurityException\|Error: could not access user\|Bad user number' <<<"$out"; then
    log_error "adb_installed_for_user: the shell cannot read user $user on $serial."
    log_error "A package installed there will not appear in the launcher. Available users:"
    adb -s "$serial" shell pm list users 2>/dev/null >&2 || true
    return 3
  fi
  grep -qx "package:$pkg" <<<"$out"
}

# Usage: adb_install_verified <serial> <apk> <package> [--user <id>] [extra args...];
# install, then confirm the package is actually visible to that user. This is the
# function a deploy path should call: adb_install alone reports what adb accepted,
# not what the device will show.
#
# Returns adb's status on an install failure, 4 when the install reported success
# but the package is not visible to the target user, and 0 only when both hold.
adb_install_verified() {
  local serial="${1:-}" apk="${2:-}" pkg="${3:-}"; shift 3 2>/dev/null || true
  local user="0" rc=0
  local -a passthru=()
  [[ -n "$serial" && -n "$apk" && -n "$pkg" ]] \
    || { log_error "adb_install_verified: need <serial> <apk> <package>"; return 2; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="${2:-}"; passthru+=(--user "$user"); shift 2 ;;
      *) passthru+=("$1"); shift ;;
    esac
  done

  adb_install "$serial" "$apk" "${passthru[@]+"${passthru[@]}"}" || return $?

  # Capture the status directly. After a failed `if` with no `else`, `$?` is the
  # status of the `if` statement itself — zero — so reading it afterwards loses
  # the distinction between "not installed" and "cannot read that profile".
  rc=0
  adb_installed_for_user "$serial" "$pkg" "$user" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    log_info "verified: $pkg is present for user $user on $serial"
    return 0
  fi
  log_error "adb_install_verified: '$pkg' installed without error but is NOT visible to user $user."
  log_error "This is what a work profile or Secure Folder install looks like: adb reports Success,"
  log_error "the launcher shows nothing, and 'am start' cannot find it."
  log_error "Pick the right profile with --user <id>. Available users:"
  adb -s "$serial" shell pm list users 2>/dev/null >&2 || true
  [[ "$rc" -eq 3 ]] && return 3
  return 4
}

# Usage: adb_install_all <apk> [extra adb install args...]; install the APK to
# every ready device. Continues past failures; returns non-zero if any failed.
adb_install_all() {
  local apk="$1"; shift || true   # drop the apk; rest = extra adb install flags
  local s rc=0 ok=0 fail=0
  local -a serials=()
  adb_available || return 1
  [[ -n "$apk" && -f "$apk" ]] || { log_error "adb_install_all: APK not found: ${apk:-<none>}"; return 2; }
  mapfile -t serials < <(adb_ready_serials)
  [[ ${#serials[@]} -gt 0 ]] || { log_warn "No ready devices to install to."; return 0; }
  for s in "${serials[@]}"; do
    if adb_install "$s" "$apk" "$@" >/dev/null 2>&1; then
      log_info "installed on $s"; ok=$((ok + 1))
    else
      log_warn "install FAILED on $s"; fail=$((fail + 1)); rc=1
    fi
  done
  log_info "install summary: $ok ok, $fail failed of ${#serials[@]} device(s)"
  return $rc
}

# Usage: adb_uninstall <serial> <package>; uninstall an app package.
adb_uninstall() {
  local serial="$1" pkg="$2"
  adb_available || return 1
  [[ -n "$serial" && -n "$pkg" ]] || { log_error "adb_uninstall: need <serial> <package>"; return 2; }
  adb -s "$serial" uninstall "$pkg"
}

# --- status ----------------------------------------------------------------

# Usage: adb_battery_level <serial>; prints battery charge percent (0-100).
adb_battery_level() {
  local serial="$1"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  adb -s "$serial" shell dumpsys battery 2>/dev/null \
    | awk -F': *' '/ level:/{print $2; exit}' | tr -d '\r'
}

# Usage: adb_screen_on <serial>; returns 0 if the display is on, 1 if off, 2 if
# it can't be determined (varies across Android versions).
adb_screen_on() {
  local serial="$1" out
  adb_available || return 2
  [[ -n "$serial" ]] || return 2
  # No pipe / guarded substitution so a failed adb call can't abort a caller
  # running with `set -e -o pipefail`; we always reach the `return 2` contract.
  out="$(adb -s "$serial" shell dumpsys power 2>/dev/null)" || out=""
  out="${out//$'\r'/}"
  if grep -qE 'Display Power: state=ON|mScreenOn=true|mWakefulness=Awake' <<<"$out"; then
    return 0
  elif grep -qE 'Display Power: state=OFF|mScreenOn=false|mWakefulness=(Asleep|Dozing)' <<<"$out"; then
    return 1
  fi
  return 2
}

# Usage: adb_device_status <serial>; print a human-readable status block (model,
# Android + API, battery, screen, Wi-Fi IP) for one device.
adb_device_status() {
  local serial="$1" screen="unknown"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  if adb_screen_on "$serial"; then screen="on"; elif [[ $? -eq 1 ]]; then screen="off"; fi
  printf 'serial:  %s\n' "$serial"
  printf 'model:   %s\n' "$(adb_device_model "$serial" 2>/dev/null || echo '?')"
  printf 'android: %s (API %s)\n' "$(adb_android_version "$serial" 2>/dev/null || echo '?')" "$(adb_device_api "$serial" 2>/dev/null || echo '?')"
  printf 'battery: %s%%\n' "$(adb_battery_level "$serial" 2>/dev/null || echo '?')"
  printf 'screen:  %s\n' "$screen"
  printf 'wifi_ip: %s\n' "$(adb_device_ip "$serial" 2>/dev/null || echo '-')"
}

# --- wireless (adb over Wi-Fi) ---------------------------------------------
#
# A phone on the desk is not always a phone on a cable. These wrap the parts of
# `adb connect` that are easy to get wrong:
#
#  - tcpip mode is LOST ON REBOOT, and the failure looks identical to a wrong
#    address, so the recovery (one USB cable, once) has to be spelled out;
#  - Android 11+ "Wireless debugging" allocates a RANDOM port per session, so a
#    hard-coded 5555 silently stops working;
#  - the device's address belongs in a gitignored env file, never in a tracked
#    one — see `check_no_private_ips` in scripts/.
#
# Address is taken from ANDROID_DEVICE_IP / ANDROID_DEVICE_PORT, which
# `load_env` (lib/env.sh) puts in scope from a project's .env.

# Usage: adb_wireless_addr; prints "ip:port" from the environment, or returns
# non-zero when nothing is configured.
#
# DEV_DEVICE first: that is the dev-cli convention (templates/dev-cli) for
# "which device", it is what --device sets, and for a wireless device the device
# id IS "ip:port". One variable rather than two spellings of the same fact.
#
# A DEV_DEVICE holding a USB serial is correctly ignored here — a serial has no
# colon, so it is not something to `adb connect`, and the split form below (or
# nothing) applies instead.
#
# ANDROID_DEVICE_IP / ANDROID_DEVICE_PORT remain supported as an explicit split
# form. Port defaults to 5555.
adb_wireless_addr() {
  local dev="${DEV_DEVICE:-}"
  if [[ "$dev" == *:* ]]; then
    printf '%s\n' "$dev"
    return 0
  fi
  [[ -n "${ANDROID_DEVICE_IP:-}" ]] || return 1
  printf '%s:%s\n' "$ANDROID_DEVICE_IP" "${ANDROID_DEVICE_PORT:-5555}"
}

# Usage: adb_wireless_attached <addr>; returns 0 when that exact address is
# attached AND ready. Checks the state column, so an "offline" or
# "unauthorized" entry correctly counts as not attached.
adb_wireless_attached() {
  local addr="${1:-}" found=""
  [[ -n "$addr" ]] || return 1
  adb_available || return 1
  found="$(adb devices 2>/dev/null | awk -v a="$addr" 'NR>1 && $1==a && $2=="device"')"
  [[ -n "$found" ]]
}

# Usage: adb_wireless_connect [addr]; attaches the device, defaulting to
# adb_wireless_addr. Returns 0 if it ends up attached — including when it
# already was, so this is safe to call before every command.
#
# `adb connect` reports success on a bare TCP handshake even when the far end is
# not a usable adb daemon, so the result is confirmed against `adb devices`
# rather than trusted.
adb_wireless_connect() {
  local addr="${1:-$(adb_wireless_addr 2>/dev/null || true)}"
  [[ -n "$addr" ]] || return 1
  adb_available || return 1
  adb_wireless_attached "$addr" && return 0
  adb connect "$addr" >/dev/null 2>&1 || true
  adb_wireless_attached "$addr"
}

# Usage: adb_wireless_disconnect [addr]; detaches. Always returns 0 — detaching
# something already detached is not an error worth propagating.
adb_wireless_disconnect() {
  local addr="${1:-$(adb_wireless_addr 2>/dev/null || true)}"
  adb_available || return 0
  [[ -n "$addr" ]] || return 0
  adb disconnect "$addr" >/dev/null 2>&1 || true
  return 0
}

# Usage: adb_wireless_enable <serial> [port=5555]; puts a USB-attached device
# into tcpip mode. This is the step that needs the cable, and the step that is
# undone by a reboot.
adb_wireless_enable() {
  local serial="${1:-}" port="${2:-5555}"
  adb_available || return 1
  [[ -n "$serial" ]] || return 1
  adb -s "$serial" tcpip "$port" >/dev/null 2>&1 || return 1
  # The daemon restarts on the device; connecting immediately races it.
  sleep 2
  return 0
}

# Usage: adb_wireless_setup [serial] [port=5555] [iface=wlan0]
#
# The whole cable-to-wireless handover in one call: find the device's Wi-Fi
# address, switch it to tcpip, connect, and print the resulting "ip:port" for a
# caller to store. Returns non-zero without printing if any step fails.
#
# With no serial it uses the first ready device, which is the common case (one
# phone, just plugged in).
adb_wireless_setup() {
  local serial="${1:-}" port="${2:-5555}" iface="${3:-wlan0}" ip="" addr=""
  adb_available || return 1
  [[ -n "$serial" ]] || serial="$(adb_ready_serials | head -n1)"
  [[ -n "$serial" ]] || return 1

  ip="$(adb_device_ip "$serial" "$iface")" || return 1
  adb_wireless_enable "$serial" "$port" || return 1

  addr="$ip:$port"
  adb_wireless_connect "$addr" || return 1
  printf '%s\n' "$addr"
}

# Usage: adb_wireless_write_env <env_file> <ip> [port=5555]
#
# Upserts DEV_DEVICE=<ip>:<port> in an env file, creating it if absent and
# leaving every other line untouched. Rewriting the file wholesale would discard
# whatever else the project keeps there, and appending would leave two DEV_DEVICE
# lines with the stale one winning or losing depending on who reads it.
#
# The caller is responsible for that file being gitignored. A LAN address in a
# tracked file is a permanent disclosure about someone's network.
# Usage: adb_wireless_valid_host <value>; returns 0 for an IPv4 address or a
# hostname, non-zero for anything else.
#
# A SECURITY boundary, not tidiness. An env file is SOURCED by the shell that
# reads it, so whatever is written there is executed. A newline in the value
# injects an extra line:
#
#   adb_wireless_write_env .env "$(printf '203.0.113.1\nFOO=$(id)')"
#
# wrote a literal `FOO=$(id)` line, and sourcing ran it. The value is not always
# hand-typed either — adb_wireless_setup takes it from `adb shell ip ...`, which
# is whatever the attached device chose to print.
adb_wireless_valid_host() {
  [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$ ]]
}

# Usage: adb_wireless_valid_port <value>; returns 0 for 1-65535.
adb_wireless_valid_port() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

adb_wireless_write_env() {
  local file="${1:-}" ip="${2:-}" port="${3:-5555}" tmp=""
  [[ -n "$file" && -n "$ip" ]] || return 1

  # Validated at the sink, so every caller is covered rather than each one
  # having to remember.
  adb_wireless_valid_host "$ip" || return 1
  adb_wireless_valid_port "$port" || return 1

  if [[ ! -f "$file" ]]; then
    printf '# Local environment. Gitignored — do not commit.\n\n' >"$file" || return 1
  fi

  tmp="$(mktemp)" || return 1
  awk -v addr="$ip:$port" '
    /^[[:space:]]*DEV_DEVICE=/ { print "DEV_DEVICE=" addr; seen=1; next }
    { print }
    END { if (!seen) print "DEV_DEVICE=" addr }
  ' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }

  # Rewrite in place rather than `mv`, matching lib/changelog.sh and
  # lib/manifest.sh.
  #
  # `mv` replaces the file, it does not write to it. Measured difference: when
  # the env file is a SYMLINK -- a dotfile-managed or shared config, which is a
  # normal setup -- mv silently replaces the symlink with a regular file and the
  # real target keeps its old contents, so the write appears to succeed and
  # changes nothing anyone reads. `cat >` follows the link. It also keeps the
  # inode, and with it ownership, ACLs and any open handles.
  cat "$tmp" >"$file" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# Usage: adb_wireless_recovery_hint [port=5555]; prints what to do when a
# wireless device will not attach. Worth a function rather than a comment: the
# reboot case is indistinguishable from a wrong address at the point of failure,
# and without the hint the natural response is to retry forever.
adb_wireless_recovery_hint() {
  local port="${1:-${ANDROID_DEVICE_PORT:-5555}}"
  cat <<EOF
adb's tcpip mode does not survive a device reboot. To restore it:
  1. connect the device by USB
  2. adb tcpip $port      (or: adb_wireless_setup, which also stores the address)
  3. unplug, then reconnect
On Android 11+ "Wireless debugging" the port is RANDOM per session — read it
from Developer options -> Wireless debugging and update ANDROID_DEVICE_PORT.
EOF
}
