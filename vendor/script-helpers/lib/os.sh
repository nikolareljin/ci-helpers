#!/usr/bin/env bash
# OS detection, shell capability probes and sudo helpers.

# Usage: get_os; prints linux|mac|windows|unknown.
#
# OSTYPE is dereferenced defensively: a caller running under `set -u` that has
# unset it would abort here rather than be told "unknown".
get_os() {
  case "${OSTYPE:-}" in
    # linux* rather than linux-gnu*: bash reports linux-musl on Alpine and
    # linux-android on Termux, and both are Linux. Matching only the glibc
    # spelling reported "unknown" there, which sent every get_os consumer --
    # docker_install, deps, certs -- down its do-nothing branch.
    linux*)      echo "linux" ;;
    darwin*)     echo "mac" ;;
    cygwin|msys) echo "windows" ;;
    *)           echo "unknown" ;;
  esac
}

# Alias used in some projects
getos() { get_os; }

# Usage: is_macos; returns success when running on macOS.
is_macos() { [[ "$(get_os)" == "mac" ]]; }

# Usage: is_linux; returns success when running on Linux.
is_linux() { [[ "$(get_os)" == "linux" ]]; }

# Usage: is_wsl; returns success when running under WSL.
is_wsl() {
  grep -qi "microsoft" /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]
}

# Usage: bash_major; prints the running bash major version (3, 5, ...).
bash_major() { echo "${BASH_VERSINFO[0]:-0}"; }

# Usage: bash_at_least <major> [minor]; success when the running bash is at
# least that version.
bash_at_least() {
  # Defaulted so a caller under `set -u` gets a false rather than an abort.
  local want_major="${1:-0}" want_minor="${2:-0}"
  local have_major="${BASH_VERSINFO[0]:-0}" have_minor="${BASH_VERSINFO[1]:-0}"
  [[ "$have_major" -gt "$want_major" ]] && return 0
  [[ "$have_major" -lt "$want_major" ]] && return 1
  [[ "$have_minor" -ge "$want_minor" ]]
}

# Usage: require_bash4 <feature>; fails loudly when the running bash predates 4.0.
#
# Reserved for the few entry points that genuinely cannot work on bash 3.2 --
# those taking an associative array from the caller. Everything else in this
# library is written to run unchanged on 3.2, so this must not become a general
# guard: an error the caller cannot act on is worse than no error at all.
require_bash4() {
  local feature="${1:-this feature}"
  bash_at_least 4 && return 0
  local msg="${feature} needs bash 4.0 or newer; this is bash ${BASH_VERSION:-unknown}."
  if [[ "$(get_os)" == "mac" ]]; then
    msg="${msg} macOS ships bash 3.2 as /bin/bash -- install a current one with 'brew install bash'."
  fi
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$msg"
  else
    echo "[ERROR] $msg" >&2
  fi
  return 1
}

# Run with sudo optionally based on a boolean flag argument
run_with_optional_sudo() {
  local use_sudo="$1"; shift
  if [[ "$use_sudo" == "true" ]] && command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}
