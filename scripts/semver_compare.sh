#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS_DIR="$ROOT_DIR/vendor/script-helpers"
if [[ -f "$HELPERS_DIR/helpers.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HELPERS_DIR/helpers.sh"
  shlib_import logging
fi

usage() {
  cat <<'USAGE'
Usage: semver_compare.sh <version_a> <version_b>

Outputs one of: lt, eq, gt
Exit codes: 0 on success, 2 on invalid input.
USAGE
}

normalize() {
  local v="$1"
  v="${v#v}"
  echo "$v"
}

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

compare_semver() {
  local a b a1 a2 a3 b1 b2 b3
  a="$(normalize "$1")"
  b="$(normalize "$2")"

  if ! is_semver "$a" || ! is_semver "$b"; then
    if declare -F log_error >/dev/null 2>&1; then
      log_error "Invalid semver input: '$1' vs '$2'"
    else
      echo "Invalid semver input: '$1' vs '$2'" >&2
    fi
    return 2
  fi

  IFS='.' read -r a1 a2 a3 <<< "$a"
  IFS='.' read -r b1 b2 b3 <<< "$b"

  if (( a1 > b1 )); then
    echo "gt"; return 0
  elif (( a1 < b1 )); then
    echo "lt"; return 0
  fi

  if (( a2 > b2 )); then
    echo "gt"; return 0
  elif (( a2 < b2 )); then
    echo "lt"; return 0
  fi

  if (( a3 > b3 )); then
    echo "gt"; return 0
  elif (( a3 < b3 )); then
    echo "lt"; return 0
  fi

  echo "eq"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

compare_semver "$1" "$2"
