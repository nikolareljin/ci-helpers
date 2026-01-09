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
trap cleanup EXIT

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
