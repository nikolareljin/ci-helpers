#!/usr/bin/env bash
# SCRIPT: semver_compare.sh
# DESCRIPTION: Compare two semantic versions.
# USAGE: ./semver_compare.sh <version_a> <version_b>
# EXAMPLE: ./semver_compare.sh 1.2.3 1.3.0
# PARAMETERS:
#   version_a   First semver (X.Y.Z).
#   version_b   Second semver (X.Y.Z).
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}/vendor/script-helpers}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { display_help; }

normalize() {
  local v="$1"
  v="${v#v}"
  echo "$v"
}

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Compare two non-negative decimal integers of any length as strings.
# Bash arithmetic reads a leading zero as octal (1.010.0 compared below 1.9.0,
# and 1.08.0 was an arithmetic error that still printed "eq") and wraps past
# 64 bits, so neither is used: strip leading zeros, then the longer number is
# larger, and equal-length digit strings order the same as their values.
compare_component() {
  local x="$1" y="$2"
  x="${x#"${x%%[!0]*}"}"; x="${x:-0}"
  y="${y#"${y%%[!0]*}"}"; y="${y:-0}"
  if (( ${#x} != ${#y} )); then
    (( ${#x} > ${#y} )) && echo "gt" || echo "lt"
  elif [[ "$x" == "$y" ]]; then
    echo "eq"
  else
    local LC_ALL=C
    [[ "$x" > "$y" ]] && echo "gt" || echo "lt"
  fi
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

  local r
  r="$(compare_component "$a1" "$b1")"
  [[ "$r" == "eq" ]] && r="$(compare_component "$a2" "$b2")"
  [[ "$r" == "eq" ]] && r="$(compare_component "$a3" "$b3")"
  echo "$r"
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
