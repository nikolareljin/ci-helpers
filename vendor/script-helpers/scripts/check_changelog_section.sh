#!/usr/bin/env bash
# SCRIPT: check_changelog_section.sh
# DESCRIPTION: On a release/X.Y.Z branch, require that CHANGELOG.md has a section with entries for that version.
# USAGE: scripts/check_changelog_section.sh [--branch <name>] [--version <X.Y.Z>] [--changelog <path>] [--repo <dir>]
# PARAMETERS:
#   --branch <name>     Branch to read the version from (default: current branch).
#   --version <X.Y.Z>   Check this version instead of deriving one from a branch.
#   --changelog <path>  CHANGELOG to read, relative to --repo (default: CHANGELOG.md).
#   --repo <dir>        Repository to read (default: current directory).
#   -h, --help          Show this help message.
# ----------------------------------------------------
#
# The release body comes from the CHANGELOG section for the version being
# released. Nothing checked that the section existed, so a release could be cut
# whose notes fell back to a commit list -- or, before the fallback was fixed, to
# a placeholder. The check is cheap and the failure is silent, which is the
# combination worth gating.
#
# Off a release branch this is a no-op, so it is safe to run on every pull
# request.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/helpers.sh"
shlib_import logging changelog

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || { log_error "check_changelog_section: $1 requires a value"; usage >&2; exit 2; }
}

BRANCH_NAME=""
VERSION=""
CHANGELOG="CHANGELOG.md"
REPO_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    need_value "$@"; BRANCH_NAME="$2"; shift 2;;
    --version)   need_value "$@"; VERSION="$2"; shift 2;;
    --changelog) need_value "$@"; CHANGELOG="$2"; shift 2;;
    --repo)      need_value "$@"; REPO_DIR="$2"; shift 2;;
    -h|--help)   usage; exit 0;;
    *) log_error "check_changelog_section: unknown argument: $1"; usage >&2; exit 2;;
  esac
done

if [[ -n "$VERSION" ]] && ! [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
  log_error "check_changelog_section: not a version: '$VERSION' (expected X.Y.Z, optionally with a pre-release or build suffix)"
  exit 2
fi
[[ -d "$REPO_DIR" ]] || { log_error "check_changelog_section: not a directory: $REPO_DIR"; exit 2; }
cd "$REPO_DIR"

if [[ -z "$VERSION" ]]; then
  if [[ -z "$BRANCH_NAME" ]]; then
    # The same order check_release_version.sh uses: on a pull request the head
    # branch is what carries the version, and HEAD is a detached merge commit.
    BRANCH_NAME="${GITHUB_HEAD_REF:-}"
    [[ -n "$BRANCH_NAME" ]] || BRANCH_NAME="${GITHUB_REF_NAME:-}"
    [[ -n "$BRANCH_NAME" ]] || BRANCH_NAME="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
  fi
  [[ -n "$BRANCH_NAME" ]] || exit 0
  if [[ "$BRANCH_NAME" =~ ^release/v?([0-9]+\.[0-9]+\.[0-9]+(-rc\.?[0-9]+)?)$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  else
    log_info "check_changelog_section: $BRANCH_NAME is not a release branch; nothing to check"
    exit 0
  fi
fi

if [[ ! -f "$CHANGELOG" ]]; then
  log_error "check_changelog_section: $CHANGELOG does not exist, so the release for $VERSION has no notes to publish"
  exit 1
fi

if ! section="$(changelog_extract "$CHANGELOG" "$VERSION" 2>/dev/null)"; then
  log_error "check_changelog_section: $CHANGELOG has no section for $VERSION"
  log_error "  The release body is taken from that section. Without it the release"
  log_error "  falls back to a commit list, which is not what anyone reads."
  log_error "  Add one, in the repository's existing header shape, e.g.:"
  log_error "    ## $(date +%Y-%m-%d) — v$VERSION"
  exit 1
fi

# A header with nothing under it, or only the empty `###` headings that
# changelog_new_section writes, is not a write-up. It used to pass here and then
# ship as the release body.
if ! changelog_has_entries "$section"; then
  log_error "check_changelog_section: the $CHANGELOG section for $VERSION has no entries"
  log_error "  It has a header and at most empty headings -- the template"
  log_error "  changelog_new_section writes. Write what changed under them, and"
  log_error "  delete the headings that stay empty."
  exit 1
fi

log_info "check_changelog_section: $CHANGELOG has a written section for $VERSION"
