#!/usr/bin/env bash
# SCRIPT: check_release_version.sh
# DESCRIPTION: Validate VERSION against release/* branch and tag state.
# USAGE: scripts/check_release_version.sh [--branch <name>] [--version-file <path>] [--repo <dir>] [--fetch-tags]
# PARAMETERS:
#   --branch <name>        Override branch name (default: current git branch).
#   --version-file <path>  Path to VERSION file, relative to --repo (default: VERSION).
#   --repo <dir>           Repository to check (default: current directory).
#   --fetch-tags           Fetch tags from origin before checks.
#   -h, --help             Show this help message.
# EXIT_CODES:
#   0  Not on a release branch, or VERSION matches the branch and the tag is free
#      (also -h/--help).
#   1  Release branch name invalid, VERSION missing, empty or mismatched, or the
#      tag already exists.
#   2  Unknown argument, an option without a value, or --repo not a directory.
# EXAMPLE:
#   scripts/check_release_version.sh --branch release/1.4.0 --fetch-tags
# ----------------------------------------------------
set -euo pipefail

usage() {
  sed -n '2,/^# ---/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'
}

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || { echo "[check_release_version] $1 requires a value" >&2; exit 2; }
}

BRANCH_NAME=""
VERSION_FILE="VERSION"
REPO_DIR="."
FETCH_TAGS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) need_value "$@"; BRANCH_NAME="$2"; shift 2;;
    --version-file) need_value "$@"; VERSION_FILE="$2"; shift 2;;
    --repo) need_value "$@"; REPO_DIR="$2"; shift 2;;
    --fetch-tags) FETCH_TAGS=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

# The repository being released, not this script's own checkout: run from a
# vendored copy, cd-ing to the script-helpers root read the submodule's
# detached HEAD, found no branch and exited 0 without checking anything.
[[ -d "$REPO_DIR" ]] || { echo "[check_release_version] not a directory: $REPO_DIR" >&2; exit 2; }
cd "$REPO_DIR"

if [[ -z "$BRANCH_NAME" ]]; then
  BRANCH_NAME="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
fi

if [[ -z "$BRANCH_NAME" ]]; then
  exit 0
fi

if [[ "$FETCH_TAGS" == "true" ]]; then
  git fetch --tags origin >/dev/null 2>&1 || true
fi

if [[ "$BRANCH_NAME" =~ ^release/v?([0-9]+)\.([0-9]+)\.([0-9]+)(-rc\.?[0-9]+)?$ ]]; then
  release_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}${BASH_REMATCH[4]:-}"
  if [[ ! -f "$VERSION_FILE" ]]; then
    echo "[check_release_version] $VERSION_FILE not found; aborting." >&2
    exit 1
  fi
  version_file="$(head -n1 "$VERSION_FILE" | xargs || true)"
  if [[ -z "$version_file" ]]; then
    echo "[check_release_version] VERSION is empty; aborting." >&2
    exit 1
  fi
  if [[ "$version_file" != "$release_version" ]]; then
    echo "[check_release_version] VERSION mismatch for release branch." >&2
    echo "  Branch: $BRANCH_NAME" >&2
    echo "  VERSION: $version_file" >&2
    exit 1
  fi
  if git rev-parse -q --verify "refs/tags/$release_version" >/dev/null; then
    echo "[check_release_version] Tag $release_version already exists; aborting." >&2
    exit 1
  fi
  if [[ "$release_version" =~ -rc\.?[0-9]+$ ]]; then
    base_version="${release_version%-rc*}"
    if git rev-parse -q --verify "refs/tags/$base_version" >/dev/null; then
      echo "[check_release_version] Warning: base tag $base_version already exists. This can be expected when creating an RC after a final release, but verify that creating $release_version is intentional." >&2
    fi
  fi
elif [[ "$BRANCH_NAME" == release/* ]]; then
  # A branch that announces itself as a release and then does not parse is the
  # case worth failing on. Until now it fell through and exited 0: every
  # assertion above lives inside the match, so `release/oops` asserted nothing
  # and reported success. The workflow caught that with its own inline pattern,
  # which is how the two definitions drifted -- that one accepted X.Y.Z only and
  # rejected the candidates this repository's tooling supports everywhere else.
  echo "[check_release_version] Release branch name '$BRANCH_NAME' is invalid." >&2
  echo "  Expected release/X.Y.Z or release/X.Y.Z-rcN (optionally with a leading v)." >&2
  exit 1
fi
