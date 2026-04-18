#!/usr/bin/env bash
# SCRIPT: version_bump.sh
# DESCRIPTION: Bump VERSION and update docs/examples that reference @X.Y.Z.
# USAGE: ./version_bump.sh [major|minor|patch] [-h]
# PARAMETERS:
#   major|minor|patch   Which part of the version to increment.
#   -h                 Show this help message.
# EXAMPLE: ./version_bump.sh patch
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}/vendor/script-helpers}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help env version file

usage() { display_help; }

if [[ "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  major|minor|patch) ;;
  *) usage; exit 1 ;;
esac

if ! command_exists rg; then
  log_error "rg is required for version updates."
  exit 1
fi

repo_root="$(get_project_root)"
version_file="${repo_root}/VERSION"
if [[ ! -f "${version_file}" ]]; then
  log_error "VERSION file not found at ${version_file}"
  exit 1
fi

current_version="$(tr -d ' \t\r\n' < "${version_file}")"
version_bump "$1" -f "${version_file}"
next_version="$(tr -d ' \t\r\n' < "${version_file}")"

old_tag="${current_version}"
new_tag="${next_version}"

mapfile -t tag_files < <(rg -F -l "@${old_tag}" --glob '!vendor/**' "${repo_root}")
for file in "${tag_files[@]}"; do
  OLD_LITERAL="@${old_tag}" NEW_LITERAL="@${new_tag}" \
    perl -0pi -e 's/\Q$ENV{OLD_LITERAL}\E/$ENV{NEW_LITERAL}/g' "${file}"
done

mapfile -t production_files < <(rg -F -l "Current production tag: ${old_tag}" --glob '!vendor/**' "${repo_root}")
for file in "${production_files[@]}"; do
  OLD_LITERAL="Current production tag: ${old_tag}" NEW_LITERAL="Current production tag: ${new_tag}" \
    perl -0pi -e 's/\Q$ENV{OLD_LITERAL}\E/$ENV{NEW_LITERAL}/g' "${file}"
done

log_info "Updated references for ${old_tag} -> ${new_tag}"
