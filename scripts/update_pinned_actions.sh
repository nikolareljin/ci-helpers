#!/usr/bin/env bash
# SCRIPT: update_pinned_actions.sh
# DESCRIPTION: Refresh SHA pins for third-party GitHub Actions in workflow/action YAML files.
#              Reads the annotated ref from the inline comment (e.g. "# master @ 2026-04-13"),
#              fetches the current HEAD SHA for that ref via the GitHub API, and updates stale
#              pins in place.
# USAGE: ./update_pinned_actions.sh [--dir <path>] [--check] [-h]
# PARAMETERS:
#   --dir <path>   Directory to scan recursively (default: .github).
#   --check        Dry-run: report stale pins and lookup warnings; exit 1 if any are found.
#   -h, --help     Show this help message.
# REQUIREMENTS:
#   - gh CLI authenticated (gh auth status)
#   - bash 4.0+
# EXAMPLES:
#   ./scripts/update_pinned_actions.sh             # update all stale pins
#   ./scripts/update_pinned_actions.sh --check     # CI gate: fail if pins are stale
#   ./scripts/update_pinned_actions.sh --dir .github/workflows
# ----------------------------------------------------
set -euo pipefail

dir=".github"
check_only=false
today="$(date +%Y-%m-%d)"

usage() { sed -n '1,28p' "$0"; }

require_arg_value() {
  local flag="$1"
  local value="${2-}"

  if [[ -z "$value" ]]; then
    echo "Missing value for ${flag}" >&2
    usage
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      require_arg_value "$1" "${2-}"
      dir="$2"
      shift 2
      ;;
    --check) check_only=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found. Install from https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

if [[ ! -d "$dir" ]]; then
  echo "Error: directory not found: $dir" >&2
  exit 1
fi

# Cache: "owner/repo@ref" -> "sha"
declare -A sha_cache=()

stale_count=0
ok_count=0
warn_count=0

# Fetch SHA for repo+ref, with caching
fetch_sha() {
  local repo="$1" ref="$2"
  local cache_key="${repo}@${ref}"

  if [[ "${sha_cache[$cache_key]+_}" ]]; then
    echo "${sha_cache[$cache_key]}"
    return
  fi

  local sha
  sha="$(gh api "repos/${repo}/commits/${ref}" --jq '.sha' 2>/dev/null)" || {
    echo ""
    return 1
  }
  sha_cache["$cache_key"]="$sha"
  echo "$sha"
}

# Find all YAML files under dir
mapfile -t files < <(find "$dir" -type f \( -name "*.yml" -o -name "*.yaml" \) | sort)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No YAML files found under: $dir"
  exit 0
fi

for file in "${files[@]}"; do
  # Detect lines with a pinned SHA and an annotated ref comment.
  # Supported patterns:
  #   uses: owner/repo@<sha40> # <ref> @ <date>
  #   uses: owner/repo/subdir@<sha40> # <ref> @ <date>
  while IFS= read -r line; do
    # Must match: uses: <path>@<40hex> # <ref> @ <YYYY-MM-DD>
    # Ref may be a branch (master/main), a tag (v1, v1.2.3), or similar.
    if [[ "$line" =~ ^[[:space:]]*uses:[[:space:]]+([a-zA-Z0-9_./-]+)@([0-9a-f]{40})[[:space:]]+#[[:space:]]+([^[:space:]@]+)[[:space:]]+@[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
      action_path="${BASH_REMATCH[1]}"
      old_sha="${BASH_REMATCH[2]}"
      ref="${BASH_REMATCH[3]}"
      old_date="${BASH_REMATCH[4]}"

      # Repo = first two path segments (owner/repo); subpaths are subdirectories within that repo
      IFS='/' read -r -a path_parts <<< "$action_path"
      repo="${path_parts[0]}/${path_parts[1]}"

      new_sha="$(fetch_sha "$repo" "$ref")" || {
        echo "WARN  $file: could not fetch SHA for ${repo}@${ref} — skipping" >&2
        warn_count=$((warn_count + 1))
        continue
      }

      if [[ -z "$new_sha" ]]; then
        echo "WARN  $file: empty SHA returned for ${repo}@${ref} — skipping" >&2
        warn_count=$((warn_count + 1))
        continue
      fi

      if [[ "$old_sha" == "$new_sha" ]]; then
        echo "OK    ${file}: ${action_path} # ${ref} (${old_sha:0:12}…)"
        ok_count=$((ok_count + 1))
      else
        stale_count=$((stale_count + 1))
        echo "STALE ${file}: ${action_path}"
        echo "      ref:  ${ref}"
        echo "      old:  ${old_sha}  (${old_date})"
        echo "      new:  ${new_sha}  (${today})"

        if ! $check_only; then
          # sed: replace old_sha + old_date, keep everything else unchanged.
          # Use | as delimiter — safe because SHAs are hex and dates are digits/hyphens.
          sed -i.bak \
            "s|@${old_sha} # ${ref} @ ${old_date}|@${new_sha} # ${ref} @ ${today}|g" \
            "$file"
          rm -f "${file}.bak"
          echo "      UPDATED."
        fi
      fi
    fi
  done < "$file"
done

echo ""
echo "Summary: ${ok_count} up-to-date, ${stale_count} stale, ${warn_count} warnings."

if $check_only && [[ $stale_count -gt 0 || $warn_count -gt 0 ]]; then
  if [[ $stale_count -gt 0 ]]; then
    echo "Run without --check to apply updates."
  fi
  if [[ $warn_count -gt 0 ]]; then
    echo "Fix the lookup warnings above and rerun --check; warnings fail verification."
  fi
  exit 1
fi
