#!/usr/bin/env bash
# SCRIPT: os_test.sh
# DESCRIPTION: Tests for OS detection and the bash capability probes.
# USAGE: bash tests/os_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging os

failures=0
note()  { echo "[os_test] $*"; }
error() { echo "[os_test][ERROR] $*" >&2; failures=$((failures+1)); }

expect() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then note "$label"; else error "$label: want '$want', got '$got'"; fi
}

# --- get_os ----------------------------------------------------------------
expect "darwin -> mac"        mac     "$(OSTYPE=darwin23 get_os)"
expect "linux-gnu -> linux"   linux   "$(OSTYPE=linux-gnu get_os)"
# Alpine and Termux are Linux too; matching only the glibc spelling sent every
# consumer down its do-nothing branch there.
expect "linux-musl -> linux"  linux   "$(OSTYPE=linux-musl get_os)"
expect "msys -> windows"      windows "$(OSTYPE=msys get_os)"
expect "unrecognised -> unknown" unknown "$(OSTYPE=plan9 get_os)"

# OSTYPE unset under `set -u` must report unknown, not abort the caller.
out="$( set -u; unset OSTYPE; get_os 2>&1 )" || out="ABORTED"
expect "unset OSTYPE under set -u" unknown "$out"

# --- is_macos / is_linux ---------------------------------------------------
if OSTYPE=darwin23 is_macos; then note "is_macos true on darwin"; else error "is_macos false on darwin"; fi
if OSTYPE=linux-gnu is_macos; then error "is_macos true on linux"; else note "is_macos false on linux"; fi
if OSTYPE=linux-musl is_linux; then note "is_linux true on musl"; else error "is_linux false on musl"; fi

# --- bash probes -----------------------------------------------------------
expect "bash_major matches BASH_VERSINFO" "${BASH_VERSINFO[0]}" "$(bash_major)"

if bash_at_least 1; then note "bash_at_least 1 is true"; else error "bash_at_least 1 was false"; fi
if bash_at_least 99; then error "bash_at_least 99 was true"; else note "bash_at_least 99 is false"; fi
if bash_at_least 3 2; then note "bash_at_least 3 2 is true"; else error "bash_at_least 3 2 was false"; fi
if bash_at_least "${BASH_VERSINFO[0]}" "$(( ${BASH_VERSINFO[1]} + 1 ))"; then
  error "bash_at_least accepted a higher minor than we run"
else
  note "bash_at_least compares the minor version too"
fi

# --- require_bash4 ---------------------------------------------------------
# Asserted against the running shell, so this test is meaningful in both
# directions: bash 5 here, and a real bash 3.2 under make test-bash32.
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  if require_bash4 "a feature" >/dev/null 2>&1; then
    note "require_bash4 passes on bash ${BASH_VERSINFO[0]}"
  else
    error "require_bash4 failed on bash ${BASH_VERSINFO[0]}"
  fi
else
  if require_bash4 "a feature" >/dev/null 2>&1; then
    error "require_bash4 passed on bash ${BASH_VERSINFO[0]}"
  else
    note "require_bash4 refuses bash ${BASH_VERSINFO[0]}"
  fi
  msg="$(require_bash4 "select_distro" 2>&1)"
  case "$msg" in
    *select_distro*) note "the refusal names the feature" ;;
    *) error "the refusal did not name the feature: $msg" ;;
  esac
fi

# The advisory must never reach stdout: helpers whose output is parsed would
# otherwise be corrupted by it.
out="$(bash -c 'source ./helpers.sh; shlib_import os; echo MARKER' 2>/dev/null)"
expect "sourcing helpers.sh prints nothing on stdout" "MARKER" "$out"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
