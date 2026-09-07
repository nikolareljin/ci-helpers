#!/usr/bin/env bash
# SCRIPT: adb_tool.sh
# DESCRIPTION: Reusable CLI over the adb module — inspect, install to, copy
#   files to/from, and debug Android devices. Multi-device safe (each command
#   takes a <serial>; list them with the `list` command). Thin wrapper so the
#   same helpers are usable from the shell, not just sourced into other scripts.
# USAGE: scripts/adb_tool.sh <command> [args...]
# PARAMETERS:
#   list [iface]                     List ready devices: serial, model, OS, API, IP
#   status <serial>                  Status block (model, OS/API, battery, screen, IP)
#   ip <serial> [iface]              Device IP on an interface (default wlan0)
#   install <serial> <apk>           Install (replace) an APK on one device
#   install-all <apk>                Install an APK on every ready device
#   push <serial> <local> <remote>   Copy a local file/dir TO the device
#   pull <serial> <remote> [local]   Copy a file/dir FROM the device
#   shell <serial> <cmd...>          Run a shell command on the device
#   logcat <serial> [regex]          Dump logcat (optionally grep a regex)
#   clear-logcat <serial>            Clear the device logcat buffer
#   uninstall <serial> <package>     Uninstall an app package
#   -h, --help                       Show this help
# EXAMPLE: scripts/adb_tool.sh list
# EXIT_CODES: 0 on success; 2 on unknown command; otherwise the exit status of
#   the underlying adb_* helper (e.g. 1 when adb is missing, or adb's own code
#   from install/push/pull) is propagated.
# CREATOR: Nik Reljin
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging help adb

cmd="${1:-}"
shift || true   # drop the subcommand; the rest are its args
case "$cmd" in
  list)         adb_list_devices "$@" ;;
  status)       adb_device_status "$@" ;;
  ip)           adb_device_ip "$@" ;;
  install)      adb_install "$@" ;;
  install-all)  adb_install_all "$@" ;;
  push)         adb_push "$@" ;;
  pull)         adb_pull "$@" ;;
  shell)        adb_shell "$@" ;;
  logcat)       adb_logcat "$@" ;;
  clear-logcat) adb_clear_logcat "$@" ;;
  uninstall)    adb_uninstall "$@" ;;
  -h | --help | help | "") parse_common_args --help ;;
  *) log_error "unknown command: '$cmd' (run with --help)"; exit 2 ;;
esac
