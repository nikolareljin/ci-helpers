#!/usr/bin/env bash
# SCRIPT: sync_script_helpers.sh
# DESCRIPTION: Sync vendor/script-helpers to the latest release tag (or a specific ref).
# USAGE: ./sync_script_helpers.sh [--ref <ref>] [--repo-url <url>] [-h]
# PARAMETERS:
#   --ref <ref>        Git ref to pin (tag, branch, SHA). Defaults to latest semver tag.
#                      Can also be set via SCRIPT_HELPERS_REF env var.
#   --repo-url <url>   Upstream repository URL. Defaults to SCRIPT_HELPERS_REPO_URL env var
#                      or git@github.com:nikolareljin/script-helpers.git.
#   -h, --help         Show this help message.
# EXAMPLE: ./sync_script_helpers.sh
# EXAMPLE: ./sync_script_helpers.sh --ref v0.14.0
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}/vendor/script-helpers}"

# This script sources the tree it replaces, which means it could not rebuild
# that tree from nothing: delete vendor/script-helpers and the sync that exists
# to restore it fails on its own first line. That was reachable in practice --
# it is the obvious thing to do when a vendored copy looks wrong -- and the way
# out was a manual `git checkout` of the very directory being replaced.
#
# Fall back to plain output when the library is absent, so the sync can always
# bootstrap. Only logging is needed before the clone.
if [[ -f "${SCRIPT_HELPERS_DIR}/helpers.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_HELPERS_DIR}/helpers.sh"
  shlib_import logging help
else
  log_info()  { echo "[INFO] $*" >&2; }
  log_warn()  { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  display_help() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
  log_warn "vendor/script-helpers is missing; bootstrapping without it."
fi

usage() { display_help; }

REPO_URL="${SCRIPT_HELPERS_REPO_URL:-git@github.com:nikolareljin/script-helpers.git}"
REF="${SCRIPT_HELPERS_REF:-}"
REF_WAS_EXPLICIT="${SCRIPT_HELPERS_REF:+1}"  # set when REF is provided via env

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      [[ -z "${2-}" || "${2-}" == --* ]] && { log_error "Missing value for --ref"; usage; exit 2; }
      REF="$2"; REF_WAS_EXPLICIT=1; shift 2 ;;
    --repo-url)
      [[ -z "${2-}" || "${2-}" == --* ]] && { log_error "Missing value for --repo-url"; usage; exit 2; }
      REPO_URL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

# Auto-detect latest semver tag when no ref is given.
if [[ -z "$REF" ]]; then
  log_info "Fetching latest release tag from ${REPO_URL} ..."
  REF="$(
    git ls-remote --tags --refs "$REPO_URL" \
      | awk '{print $2}' \
      | sed 's|refs/tags/||' \
      | { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true; } \
      | awk '{ k=$0; gsub(/^v/,"",k); n=split(k,a,"."); printf "%010d%010d%010d %s\n",a[1],a[2],a[3],$0 }' \
      | sort -k1,1 \
      | awk '{print $2}' \
      | tail -n1
  )"
  if [[ -z "$REF" ]]; then
    log_error "No semver tags found in ${REPO_URL}"
    exit 1
  fi
  log_info "Latest tag: ${REF}"
fi

DEST_DIR="$ROOT_DIR/vendor/script-helpers"

# Skip only if already at this commit with identical files (checked below).
current_sha=""
if [[ -f "${ROOT_DIR}/vendor/.script-helpers-sha" ]]; then
  current_sha="$(cat "${ROOT_DIR}/vendor/.script-helpers-sha")"
fi

# Clone to a temp dir so vendor is only replaced on success.
TMP_DIR="$(mktemp -d)"
STAGE_DIR="${DEST_DIR}.new"
trap 'rm -rf "$TMP_DIR" "$STAGE_DIR"' EXIT

log_info "Cloning ${REPO_URL} @ ${REF} ..."
# git clone --branch only accepts tag/branch names, not raw SHAs.
# Detect any hex-only string (7–40 chars) as a SHA and use full clone + checkout.
if [[ "$REF" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  git clone --quiet "$REPO_URL" "$TMP_DIR/script-helpers"
  git -C "$TMP_DIR/script-helpers" checkout --quiet "$REF"
else
  git clone --quiet --branch "$REF" --depth 1 "$REPO_URL" "$TMP_DIR/script-helpers"
fi

COMMIT_HASH="$(git -C "$TMP_DIR/script-helpers" rev-parse HEAD)"

# For explicit-ref syncs record the pinned ref; for auto-detected "latest" syncs
# record the literal "latest" so the drift check re-resolves the newest semver tag
# on each run rather than pinning to a now-stale resolved tag.
if [[ -n "${REF_WAS_EXPLICIT:-}" ]]; then
  REF_LABEL="$REF"
else
  REF_LABEL="latest"
fi

mkdir -p "$ROOT_DIR/vendor"
# Stage into DEST_DIR.new first; only replace the live vendor dir after the
# copy succeeds, so an interruption never leaves an empty vendor tree.
rm -rf "$STAGE_DIR"
cp -r "$TMP_DIR/script-helpers" "$STAGE_DIR"
# Paths that are never vendored. `.github` is upstream's own CI configuration:
# GitHub only runs workflows at the repository root, so a copy under vendor/ can
# never execute, and it references this repository's reusable workflows back --
# which makes it read like a second, stale definition of our own CI.
# Vendor only what this repository actually consumes: helpers.sh, the lib/
# modules loaded through shlib_import, and scripts/. The sync used to take the
# whole upstream tree, and copying code nobody here runs is how a copy turns
# from a dependency into a liability. Two checks caught that in one re-vendor:
#
#   docs/, CHANGELOG.md  prose that names this repository, which the
#     circular-reference check in verify_vendor.sh refuses. That check cannot
#     tell a sentence in a changelog from a dependency and should not have to.
#
#   tests/  upstream's fixtures include a synthetic token that the secret
#     scanner flags. The value is a deliberate stand-in and stays upstream --
#     it is what proves publish_homebrew keeps a token out of argv -- but a
#     repository that never runs those tests has no reason to carry them.
#
# The alternative was an allowlist entry per fixture, maintained forever, each
# one a standing exemption in a secret scanner. Not copying the file is smaller
# and cannot rot.
VENDOR_EXCLUDES=(".git" ".github" "docs" "CHANGELOG.md" "tests")
for excluded in "${VENDOR_EXCLUDES[@]}"; do
  rm -rf "${STAGE_DIR:?}/${excluded}"
done

# "Up to date" means the vendored files, not just the SHA lockfile. Comparing
# the lockfile alone let a hand-edited file under vendor/ survive every re-sync
# (the fix for it was the one command that refused to run), and never rewrote
# the ref lock when the same commit was re-synced under a different ref.
current_ref=""
if [[ -f "${ROOT_DIR}/vendor/.script-helpers-ref" ]]; then
  current_ref="$(tr -d '[:space:]' < "${ROOT_DIR}/vendor/.script-helpers-ref")"
fi
# Executable regular files under a directory, as sorted relative paths: diff -r
# ignores modes, and a vendored script that lost its execute bit is not current.
executable_files() {
  (cd "$1" && find . -type f -perm -u+x | LC_ALL=C sort)
}
# Record what this pin brings, next to the pin itself.
#
# Upstream's CHANGELOG.md is deliberately NOT vendored: it is 116K, this
# repository never reads it, and it names this repository often enough that the
# circular-reference check in verify_vendor.sh refuses it -- the two projects
# reference each other constantly, so that is a recurring collision rather than
# bad luck. The question it answers is still worth answering, so answer it here
# instead, scoped to what is actually being taken on.
#
# This file lives in vendor/ and not vendor/script-helpers/, which matters: the
# circular check greps the vendored tree only, and the upstream file comparison
# compares that tree only. A note that quotes upstream prose therefore cannot
# trip either, and cannot be mistaken for a vendored file.
#
# It is derived, not verified. Nothing gates it against being hand-edited --
# regenerate it, never edit it.
notes_file="$ROOT_DIR/vendor/.script-helpers-notes.md"
notes_src="$TMP_DIR/script-helpers/CHANGELOG.md"
{
  echo "# What this pin brings"
  echo
  echo "Generated by scripts/sync_script_helpers.sh. Do not edit; re-run the sync."
  echo
  echo "- pinned ref: \`${REF_LABEL}\`"
  echo "- commit: \`${COMMIT_HASH}\`"
  if [[ -n "$current_ref" && "$current_ref" != "$REF_LABEL" ]]; then
    echo "- previous pin: \`${current_ref}\`"
  fi
  echo
  if [[ ! -f "$notes_src" ]]; then
    echo "_Upstream has no CHANGELOG.md at this ref._"
  elif [[ -n "$current_ref" && "$current_ref" != "$REF_LABEL" ]]; then
    echo "## Entries since \`${current_ref}\`"
    echo
    # Print from the newest header down to, but excluding, the header naming the
    # previous pin. Header form is `## YYYY-MM-DD — vX.Y.Z`, so match the version
    # at the end of the line rather than anywhere in it.
    awk -v prev="$current_ref" '
      /^## / {
        line = $0
        sub(/[[:space:]]+$/, "", line)
        if (line ~ ("v?" prev "$")) { exit }
        started = 1
      }
      started { print }
    ' "$notes_src"
  else
    echo "## \`${REF_LABEL}\`"
    echo
    awk '/^## /{ if (seen) exit; seen = 1 } seen { print }' "$notes_src"
  fi
} > "$notes_file"
log_info "Wrote $(basename "$notes_file") ($(wc -c < "$notes_file" | tr -d " ") bytes)."

# Immediately, and before the up-to-date short circuit below. These notes are
# upstream prose copied verbatim into a public repository, so a private name in
# an upstream changelog lands here -- which is how one did. The sync is a supply
# chain for text and nothing checked what it carried.
#
# Placement matters more than the check: the first version of this sat beside
# the staging step, and a re-sync at an unchanged ref rewrote the notes, put the
# name back, and exited 0 at "Already up to date" without ever reaching it.
#
# Exit codes are read individually. 1 is a name; 2 is "could not check" -- no
# list on this machine, or a vendored gate too old to know the flag -- and that
# must not block a sync, or every consumer stops until they upgrade.
notes_gate="$STAGE_DIR/scripts/check_private_names.sh"
if [[ -f "$notes_gate" ]]; then
  gate_args=(--file "$notes_file" --only-public --for-repo ci-helpers)
  # Only when the vendored copy knows it. Passing an unknown option is exit 2.
  if grep -q -- '--strict-ambiguous' "$notes_gate"; then
    gate_args+=(--strict-ambiguous)
  fi
  bash "$notes_gate" "${gate_args[@]}" >/dev/null 2>&1
  case "$?" in
    1)
      log_error "The upstream changelog names a private repository, and these notes are public."
      bash "$notes_gate" "${gate_args[@]}" >&2 || true
      log_error "Edit $(basename "$notes_file") to cite it by code, then stage it by hand."
      log_error "Re-running the sync will not help: the upstream ref does not change."
      exit 1
      ;;
    2) log_warn "Could not check the notes for private names; continuing." ;;
  esac
fi

if [[ "$COMMIT_HASH" == "$current_sha" && "$REF_LABEL" == "$current_ref" && -d "$DEST_DIR" ]] \
   && diff -r "$STAGE_DIR" "$DEST_DIR" >/dev/null 2>&1 \
   && diff <(executable_files "$STAGE_DIR") <(executable_files "$DEST_DIR") >/dev/null 2>&1; then
  log_info "Already up to date at ${REF} (${COMMIT_HASH}). Nothing to do."
  exit 0
fi

rm -rf "$DEST_DIR"
mv "$STAGE_DIR" "$DEST_DIR"

# Write SHA and ref lockfiles so vendor-drift checks can compare against upstream.
echo "$COMMIT_HASH" > "$ROOT_DIR/vendor/.script-helpers-sha"
echo "$REF_LABEL"   > "$ROOT_DIR/vendor/.script-helpers-ref"


# vendor/ is gitignored (only the two lockfiles are re-included), yet the
# vendored tree is committed. A plain `git add` therefore updates files that are
# already tracked but silently skips any file a new upstream release *adds* --
# which is how 0.28.0's release_notes.sh and check_changelog_section.sh were
# left out of a commit that claimed to bring them in. Force-stage the whole tree
# here, in the tool that owns it, so an addition can never be dropped again.
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT_DIR" add --force --all -- \
    "$DEST_DIR" \
    "$ROOT_DIR/vendor/.script-helpers-sha" \
    "$ROOT_DIR/vendor/.script-helpers-ref" \
    "$ROOT_DIR/vendor/.script-helpers-notes.md"
  log_info "Staged vendor/script-helpers (git add --force)."
fi

log_info "Synced script-helpers from ${REPO_URL}"
log_info "Ref: ${REF} — Commit: ${COMMIT_HASH}"
