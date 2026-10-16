#!/usr/bin/env bash
# SCRIPT: check_no_hardcoded_repos.sh
# DESCRIPTION: Fail when workflows, actions, scripts or docs name a repository of
#              this library's owner other than script-helpers (vendored) and
#              ci-helpers (itself). The library must run for any repository, so
#              a tap, an app or a project of the owner is always a caller input.
#              The owner is read from GITHUB_REPOSITORY or the origin remote,
#              never written here. Pages URLs (<owner>.github.io/...) are links,
#              not repository references, and pass.
# USAGE: ./scripts/check_no_hardcoded_repos.sh [--owner <name>] [path ...]
# PARAMETERS:
#   --owner <name>  Owner to check for (default: from GITHUB_REPOSITORY or origin).
#   path ...        Files or directories to scan (default: .github scripts docs).
#   -h, --help      Show this help message.
# EXIT CODES:
#   0  No repository of the owner is named outside the allowed two.
#   1  One or more are named; each is listed.
#   2  Usage error, or the owner could not be determined.
# ----------------------------------------------------
set -euo pipefail

owner=""
paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo "Error: --owner requires a value." >&2; exit 2; }
      owner="$2"; shift 2 ;;
    -h|--help) grep '^#[^!]' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done

if [[ -z "$owner" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  owner="${GITHUB_REPOSITORY%%/*}"
fi
if [[ -z "$owner" ]]; then
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$url" =~ github\.com[:/]([A-Za-z0-9-]+)/ ]]; then
    owner="${BASH_REMATCH[1]}"
  fi
fi
[[ -n "$owner" ]] || { echo "Error: cannot determine the owner; pass --owner." >&2; exit 2; }
[[ "$owner" =~ ^[A-Za-z0-9-]+$ ]] || { echo "Error: invalid owner '$owner'." >&2; exit 2; }

if [[ ${#paths[@]} -eq 0 ]]; then
  paths=(.github scripts docs)
fi

# The project overview page links the owner's other projects on purpose.
excludes=(':!docs/about.md')

# <owner>/<repo> as a GitHub path, an API path, a checkout `repository:`, or a
# bare slug. A Pages host is <owner>.github.io, which this does not match.
# One match per line of output (-o), so a line naming an allowed repository
# next to another one still reports the other.
hits="$(git grep -n -o -i -E "(^|[^A-Za-z0-9.-])${owner}/[A-Za-z0-9._-]+" -- "${paths[@]}" "${excludes[@]}" 2>/dev/null \
  | grep -v -i -E "${owner}/(script-helpers|ci-helpers)(\.git)?[.]*$" || true)"

if [[ -n "$hits" ]]; then
  echo "Repositories of '${owner}' named in the library (only script-helpers and ci-helpers may be):" >&2
  printf '%s\n' "$hits" >&2
  echo "Take the repository as a caller input, use owner/repo in examples, or link a Pages site." >&2
  exit 1
fi
echo "No repository of '${owner}' is named besides script-helpers and ci-helpers."
