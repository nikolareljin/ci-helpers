#!/usr/bin/env bash
# SCRIPT: version_bump.sh
# DESCRIPTION: Bump VERSION and update docs/examples that reference @X.Y.Z.
# USAGE: ./version_bump.sh [major|minor|patch] [-h|--help]
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

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
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

# Only this repository's own pins move: `nikolareljin/ci-helpers[/path]@X.Y.Z`
# where the version is not the prefix of a longer one. A bare `@X.Y.Z` literal
# also rewrote other projects' pins (`other/tool@X.Y.Z`) and turned
# `@X.Y.Z-rc.2` into a different pre-release. CHANGELOG.md is history: the
# versions it names are the ones that shipped, so it is never rewritten.
# Read loops rather than mapfile, which bash 3.2 (macOS) does not have.
tag_files=()
while IFS= read -r f; do tag_files+=("$f"); done < <(rg -F -l "@${old_tag}" --glob '!vendor/**' --glob '!CHANGELOG.md' "${repo_root}")
for file in ${tag_files[@]+"${tag_files[@]}"}; do
  OLD_VERSION="${old_tag}" NEW_VERSION="${new_tag}" \
    perl -0pi -e 's{(nikolareljin/ci-helpers(?:/[^\s\@\x27"`]*)?\@)\Q$ENV{OLD_VERSION}\E(?![0-9A-Za-z-]|\.[0-9A-Za-z])}{$1$ENV{NEW_VERSION}}g' "${file}"
done

production_files=()
while IFS= read -r f; do production_files+=("$f"); done < <(rg -F -l "Current production tag: ${old_tag}" --glob '!vendor/**' --glob '!CHANGELOG.md' "${repo_root}")
for file in ${production_files[@]+"${production_files[@]}"}; do
  OLD_LITERAL="Current production tag: ${old_tag}" NEW_LITERAL="Current production tag: ${new_tag}" \
    perl -0pi -e 's/\Q$ENV{OLD_LITERAL}\E/$ENV{NEW_LITERAL}/g' "${file}"
done

log_info "Updated references for ${old_tag} -> ${new_tag}"
