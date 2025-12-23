#!/usr/bin/env bash
# SCRIPT: tag_release.sh
# DESCRIPTION: Tag the current commit with the version from the VERSION file and push the tag to origin.
# USAGE: ./tag_release.sh
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

version=$(cat VERSION | tr -d ' \t\n\r')
tag="${version}"

if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "Tag $tag already exists" >&2
  exit 1
fi

echo "Tagging $tag and pushing..."
git tag -a "$tag" -m "Release $tag"
git push origin "$tag"
echo "Done."
