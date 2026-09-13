#!/usr/bin/env bash
# SCRIPT: runner_dir_test.sh
# DESCRIPTION: Every local_test_* runner resolves --dir the same way: absolute as given, relative against the repository root.
# USAGE: bash tests/runner_dir_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/runner_dir_test.sh
# ----------------------------------------------------
#
# preflight hands the runners an absolute directory, because it may itself be
# pointed at a subdirectory of a repository and the runners resolve a relative
# --dir against the git root. That contract has to hold for all of them: the
# change that introduced it updated four of seven, which would have broken
# every ordinary Flutter, Gradle and PHP preflight with <root>/<root>/<stack>.
# This probes each runner with both forms and needs none of the toolchains --
# a missing directory is refused before any of them is looked for.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[runner_dir_test] $*"; }
error() { echo "[runner_dir_test][ERROR] $*" >&2; failures=$((failures+1)); }

# Every runner preflight invokes with --dir, derived from the script rather
# than listed by hand, so a new stack is covered the day it is added.
runners="$(grep -oE 'helper_script [a-z_]+\.sh\)" --dir' scripts/preflight.sh | grep -oE 'local_test_[a-z_]+\.sh' | sort -u)"
[[ -n "$runners" ]] || { error "found no --dir runners in scripts/preflight.sh"; exit 1; }

for r in $runners; do
  abs="$(bash "scripts/$r" --dir /nonexistent/abs 2>&1 | grep -o 'Directory not found: .*' | sed 's/^Directory not found: //')"
  rel="$(bash "scripts/$r" --dir nonexistent-rel 2>&1 | grep -o 'Directory not found: .*' | sed 's/^Directory not found: //')"
  if [[ "$abs" == "/nonexistent/abs" ]]; then
    note "$r: absolute --dir honoured as given"
  else
    error "$r: absolute --dir resolved to '${abs:-<no message>}'"
  fi
  if [[ "$rel" == "$ROOT_DIR/nonexistent-rel" ]]; then
    note "$r: relative --dir joined to the repository root"
  else
    error "$r: relative --dir resolved to '${rel:-<no message>}'"
  fi
done

if [[ $failures -gt 0 ]]; then
  note "$failures check(s) failed."; exit 1
fi
note "ALL PASSED"
