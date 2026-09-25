#!/usr/bin/env bash
# SCRIPT: example_package_publish.sh
# DESCRIPTION: Demonstrate package_publish helpers in a safe, non-network way.
# USAGE: ./example_package_publish.sh
# EXAMPLE: ./example_package_publish.sh
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${SCRIPT_DIR}/..}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging package_publish

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
# Guarded: a subshell inherits an EXIT trap, and bash runs it there when the
# subshell is signalled -- so this could tear down the caller's stack, or
# delete a directory, while the run is still using it. ${BASHPID-$$} rather
# than $BASHPID alone: bash 3.2, which macOS ships, does not define BASHPID,
# and $$ is the top-level shell's pid in every subshell, so the comparison
# degrades to always-true there rather than to always-false.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup; fi' EXIT

repo_dir="$tmp_dir/repo"
mkdir -p "$repo_dir"
touch "$tmp_dir/example.changes"

log_info "Created temp repo at $repo_dir"
if pkg_require_cmds dpkg-buildpackage; then
  log_info "dpkg-buildpackage is available"
else
  log_warn "dpkg-buildpackage missing; build demo skipped"
fi

changes_file="$(pkg_find_changes_file "$repo_dir")"
log_info "Found changes file: $changes_file"
