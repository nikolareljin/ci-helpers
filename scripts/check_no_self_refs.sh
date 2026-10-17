#!/usr/bin/env bash
# SCRIPT: check_no_self_refs.sh
# DESCRIPTION: Fail when a workflow or action of this library calls another part
#              of the library by <owner>/ci-helpers[/<path>]@<ref>. Inside the library
#              that ref floats: a caller pinned to a SHA would still run whatever
#              <ref> is today. Use a checkout at job.workflow_sha instead
#              (see gitleaks-scan.yml). Comment lines are usage examples and pass.
# USAGE: ./scripts/check_no_self_refs.sh [path ...]
# PARAMETERS:
#   path ...    Files or directories to scan (default: .github).
#   -h, --help  Show this help message.
# EXIT CODES:
#   0  No such reference.
#   1  One or more found; each is listed.
# ----------------------------------------------------
set -euo pipefail

paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) grep '^#[^!]' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done
[[ ${#paths[@]} -gt 0 ]] || paths=(.github)

# The library's root or any path in it: <owner>/ci-helpers@ref and
# <owner>/ci-helpers/<path>@ref both run code at a ref this commit does not fix.
hits="$(git grep -n -E '^[^#]*uses:[[:space:]]*["'\'']?[A-Za-z0-9_.-]+/ci-helpers(/[^@[:space:]]+)?@' -- "${paths[@]}" || true)"
if [[ -n "$hits" ]]; then
  echo "The library calls itself by a floating ref:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "No workflow or action calls the library by <owner>/ci-helpers/...@<ref>."
