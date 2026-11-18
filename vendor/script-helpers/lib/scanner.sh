#!/usr/bin/env bash
# scanner: which gitleaks or foxguard found on PATH may run.
#
# One rule for both tools. A scanner on PATH is used when the version it
# reports is the pinned one (CI_DEFAULT_GITLEAKS_VERSION,
# CI_DEFAULT_FOXGUARD_VERSION) or newer. An older one, or one whose version is
# not [v]X.Y.Z, is not used: an older rule set finds less, and the scan would
# still report clean. A newer one in a later breaking series (another major,
# or another minor of 0.x) is used with a warning.
#
# Expected imports by caller: none for the lookups. scanner_resolve installs
# with <tool>_install, so it needs logging and the tool's module (gitleaks also
# needs foxguard, for foxguard_sha256). ci_defaults and version are sourced
# here when the caller has not.
#
# <tool> is gitleaks or foxguard everywhere below.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/ci_defaults.sh"
if ! type version_at_least >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/version.sh"
fi
_SCANNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Usage: scanner_pin <tool>
# scanner_pin <tool>; the pinned version of that scanner, as ci_defaults has it
# (v8.30.1, 0.14.1).
# Returns: 0 known tool; 2 another name.
# Output: stdout the version.
scanner_pin() {
  case "${1:-}" in
    gitleaks) printf '%s\n' "$CI_DEFAULT_GITLEAKS_VERSION" ;;
    foxguard) printf '%s\n' "$CI_DEFAULT_FOXGUARD_VERSION" ;;
    *) return 2 ;;
  esac
}

# Usage: scanner_path_version <tool>
# scanner_path_version <tool>; what the <tool> on PATH reports as its version:
# the first line of `gitleaks version`, or of `foxguard --version` without the
# leading "foxguard ". Carriage returns (gitleaks.exe) and control characters
# are removed and the line is cut at 40 characters, so it is safe to print.
# Returns: 0 a <tool> is on PATH (the output may be empty); 3 none on PATH; 2 unknown tool.
# Output: stdout the reported version text.
scanner_path_version() {
  local found line="" LC_ALL=C
  case "${1:-}" in gitleaks|foxguard) ;; *) return 2 ;; esac
  found="$(command -v "$1" 2>/dev/null)" || return 3
  case "$1" in
    gitleaks) line="$("$found" version 2>/dev/null </dev/null)" || true ;;
    foxguard) line="$("$found" --version 2>/dev/null </dev/null)" || true ;;
  esac
  # In the shell, so a PATH with no head, tr or cut still gets an answer.
  line="${line%%$'\n'*}"
  line="${line//[^[:print:]]/}"
  line="${line:0:40}"
  [[ "$1" == foxguard ]] && line="${line#foxguard }"
  printf '%s\n' "$line"
}

# Usage: scanner_path_bin <tool>
# scanner_path_bin <tool>; the <tool> on PATH, when it reports the pinned
# version or a newer one.
# Returns: 0 found; 3 none on PATH, an older one, or one with no [v]X.Y.Z version; 2 unknown tool.
# Output: stdout the binary path.
scanner_path_bin() {
  local found v pin
  pin="$(scanner_pin "${1:-}")" || return 2
  found="$(command -v "$1" 2>/dev/null)" || return 3
  v="$(scanner_path_version "$1")" || return 3
  version_at_least "$v" "$pin" || return 3
  printf '%s\n' "$found"
}

# Usage: scanner_path_breaking <tool>
# scanner_path_breaking <tool>; true when the <tool> on PATH is usable
# (scanner_path_bin) and newer than the pin in a breaking way: another major
# version, or another minor of a 0.x pin.
# Returns: 0 newer breaking series; 1 same series as the pin, or no usable <tool> on PATH; 2 unknown tool.
# Output: nothing.
scanner_path_breaking() {
  local v pin
  pin="$(scanner_pin "${1:-}")" || return 2
  scanner_path_bin "$1" >/dev/null || return 1
  v="$(scanner_path_version "$1")" || return 1
  version_same_series "$v" "$pin" && return 1
  return 0
}

# Usage: scanner_path_reason <tool>
# scanner_path_reason <tool>; one line saying why the <tool> on PATH is not
# used: it is older than the pin, or reports no version that can be compared.
# Returns: 0 printed; 1 nothing to say (none on PATH, or it is usable); 2 unknown tool.
# Output: stdout the reason, without a trailing full stop.
scanner_path_reason() {
  local found v pin rc=0
  pin="$(scanner_pin "${1:-}")" || return 2
  found="$(command -v "$1" 2>/dev/null)" || return 1
  v="$(scanner_path_version "$1")" || return 1
  version_at_least "$v" "$pin" || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) printf '%s is %s %s, older than the minimum %s\n' "$found" "$1" "$v" "$pin" ;;
    *) printf "%s reports no usable version ('%s'); the minimum is %s %s\n" "$found" "$v" "$1" "$pin" ;;
  esac
}

# Usage: scanner_install_hint <tool>
# scanner_install_hint <tool>; the command that installs the pinned <tool> into
# the cache (downloaded, SHA-256 checked, no sudo; a package manager's copy is
# left alone).
# Returns: always 0.
# Output: stdout the command.
scanner_install_hint() {
  local root="${_SCANNER_LIB_DIR%/*}"
  if [[ -f "$root/scripts/setup-hooks.sh" ]]; then
    printf 'bash %s/scripts/setup-hooks.sh --install-%s\n' "$root" "$1"
  else
    # The staged copies of the hooks carry no setup-hooks.sh.
    printf 'scripts/setup-hooks.sh --install-%s in a script-helpers checkout\n' "$1"
  fi
}

# Usage: scanner_version_warning <tool> <bin>
# scanner_version_warning <tool> <bin>; the warning for running <bin> when it
# is the <tool> on PATH and scanner_path_breaking holds: the found version, the
# pin, and how to install the pinned release. Nothing for any other binary. It
# is a warning only: the scan still runs.
# Returns: always 0.
# Output: stdout one line, or nothing.
scanner_version_warning() {
  local found v pin kind="a newer major version"
  pin="$(scanner_pin "${1:-}")" || return 0
  found="$(command -v "$1" 2>/dev/null)" || return 0
  [[ "${2:-}" == "$found" ]] || return 0
  scanner_path_breaking "$1" || return 0
  v="$(scanner_path_version "$1")" || return 0
  # Same major: both are 0.x, where a new minor is the breaking step.
  _version__strict "$v" && [[ "$_VERSION_MAJOR" -eq 0 ]] && kind="a newer 0.x minor version (breaking under semver)"
  printf 'WARNING: %s is %s %s, %s than the tested pin %s; it may break. To use the pinned one: %s\n' \
    "$found" "$1" "$v" "$kind" "$pin" "$(scanner_install_hint "$1")"
}

# Usage: scanner_may_install
# scanner_may_install; true when a scanner may be downloaded here: not in CI
# (it installs its own tools) and not with SCRIPT_HELPERS_NO_AUTO_INSTALL=1.
# Returns: 0 allowed; 1 not allowed.
# Output: nothing.
scanner_may_install() {
  [[ -z "${CI:-}" && "${SCRIPT_HELPERS_NO_AUTO_INSTALL:-}" != 1 ]]
}

# Usage: scanner_resolve <tool>
# scanner_resolve <tool>; the <tool> to run, as <tool>_bin finds it. When there
# is none because the one on PATH is older than the pin (or has no usable
# version) and scanner_may_install allows, the pinned release is installed into
# the cache with <tool>_install and used; the copy on PATH is not touched. The
# breaking-series warning, when it applies, goes to stderr.
# Returns: 0 found; 3 none, and none could be installed; 2 unknown tool.
# Output: stdout the binary path; stderr the upgrade message, install progress and the warning.
scanner_resolve() {
  local bin why warn
  scanner_pin "${1:-}" >/dev/null || return 2
  if ! bin="$("$1_bin")"; then
    why="$(scanner_path_reason "$1")" || return 3
    scanner_may_install || return 3
    printf '%s; installing the pinned %s %s into the cache.\n' "$why" "$1" "$(scanner_pin "$1")" >&2
    "$1_install" >&2 || return 3
    bin="$("$1_bin")" || return 3
  fi
  warn="$(scanner_version_warning "$1" "$bin")" || warn=""
  [[ -z "$warn" ]] || printf '%s\n' "$warn" >&2
  printf '%s\n' "$bin"
}
