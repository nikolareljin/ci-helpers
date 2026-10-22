#!/usr/bin/env bash
# SCRIPT: tag_release.sh
# DESCRIPTION: Tag the current commit with the version from the VERSION file and push the tag to origin.
# USAGE: ./tag_release.sh
# PARAMETERS: No parameters.
#   -h, --help prints this header and exits without tagging. Runs in the
#   script-helpers checkout that holds this script, from any directory.
# EXIT_CODES:
#   0  tag created and pushed (or help shown)
#   1  VERSION is missing or empty, the tag already exists, or git tag or
#      git push failed
#   2  bad arguments
# EXAMPLE: scripts/tag_release.sh
# ----------------------------------------------------
set -euo pipefail

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,/^# ----/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "tag_release.sh: unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

version="$(tr -d ' \t\n\r' < VERSION 2>/dev/null || true)"
if [[ -z "$version" ]]; then
  echo "VERSION is missing or empty in $ROOT_DIR" >&2
  exit 1
fi
tag="${version}"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists" >&2
  exit 1
fi

echo "Tagging $tag and pushing..."
git tag -a "$tag" -m "Release $tag"
git push origin "$tag"
echo "Done."
