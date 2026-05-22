#!/usr/bin/env bash
# SCRIPT: check_floating_refs.sh
# DESCRIPTION: Detect mutable channel-style action refs (@master/@main/@latest/@stable)
#              in GitHub Actions workflow and action YAML files. Versioned tags (@v5) and
#              SHA-pinned refs (@abc123...) are accepted per repo policy.
# USAGE: ./scripts/check_floating_refs.sh [--dir <path>]
# PARAMETERS:
#   --dir <path>   Directory to scan recursively (default: .github)
#   -h, --help     Show this help message.
# EXIT CODES:
#   0  No mutable channel refs detected.
#   1  One or more mutable channel refs detected.
# ----------------------------------------------------
set -euo pipefail

dir=".github"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo "Error: --dir requires a value." >&2; exit 1; }
      dir="$2"; shift 2 ;;
    -h|--help) grep '^#[^!]' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -d "$dir" ]] || { echo "Error: directory '$dir' does not exist." >&2; exit 1; }

floating=$(grep -rn --include="*.yml" --include="*.yaml" 'uses:' "$dir" \
  | grep -vE ':[0-9]+:[[:space:]]*#' \
  | grep -v 'uses:[[:space:]]*\./\.' \
  | grep -vE '@[0-9a-f]{40}' \
  | grep -E '@(master|main|latest|stable)([[:space:]]|$)' \
  || true)

if [[ -n "$floating" ]]; then
  echo "::warning::Mutable channel refs (@master/@main/@latest/@stable) detected:"
  echo "$floating"
  echo ""
  echo "These refs can move upstream at any time without notice."
  echo "Pin each to a commit SHA and annotate with: # <ref> @ <date>"
  exit 1
fi
echo "No mutable channel refs (@master/@main/@latest/@stable) detected."
