#!/usr/bin/env bash
# SCRIPT: pin_production.sh
# DESCRIPTION: Fast-forward the production branch to a specific tag for controlled rollouts.
# USAGE: scripts/pin_production.sh <tag>
# PARAMETERS:
#   <tag>  Release tag to fast-forward production to (e.g., 0.10.0).
#   -h, --help  Show this help message.
# EXAMPLE:
#   scripts/pin_production.sh 0.10.0
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: scripts/pin_production.sh <tag>"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

TAG="$1"

cd "$ROOT_DIR"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash changes before proceeding." >&2
  exit 1
fi

git fetch --tags origin

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag not found: $TAG" >&2
  exit 1
fi

# Create or reset local production branch to match remote, handling fresh
# clones and stale local branches.
if git rev-parse -q --verify origin/production >/dev/null; then
  git checkout -B production origin/production
else
  git checkout -b production "$TAG"
fi
git merge --ff-only "$TAG"
git push origin production

echo "production now points to tag $TAG"
