#!/usr/bin/env bash
# SCRIPT: check_runner_retirement.sh
# DESCRIPTION: Find every pinned Ubuntu runner image (ubuntu-NN.NN, with or
#              without -arm) in the workflow and action YAML, then ask
#              actions/runner-images whether GitHub has announced that image's
#              deprecation or removal. A pin GitHub has announced fails, and
#              the output names the announcement and each file:line that pins
#              it. A pin only GitHub can retire otherwise goes unnoticed until
#              the first job that needs it cannot start.
# USAGE: ./scripts/check_runner_retirement.sh [--dir <path>] [--list]
# PARAMETERS:
#   --dir <path>   Directory to scan recursively (default: .github)
#   --list         Print the pinned images and where they are; ask nothing.
#   -h, --help     Show this help message.
# EXIT CODES:
#   0  No pinned image has a retirement announcement (or --list).
#   1  A pinned image is announced for retirement, a lookup failed, or the
#      search no longer finds the known 20.04 announcement.
# ----------------------------------------------------
set -euo pipefail

dir=".github"
list_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo "Error: --dir requires a value." >&2; exit 1; }
      dir="$2"; shift 2 ;;
    --list) list_only=true; shift ;;
    -h|--help) grep '^#[^!]' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -d "$dir" ]] || { echo "Error: directory '$dir' does not exist." >&2; exit 1; }

# file:line:version for each pin. A whole-line comment is not a pin, and
# neither is a version after a `#` on the same line.
pins="$(grep -rnE --include='*.yml' --include='*.yaml' 'ubuntu-[0-9]{2}\.[0-9]{2}' "$dir" \
  | while IFS= read -r hit; do
      loc="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
      code="${text%%#*}"
      grep -oE 'ubuntu-[0-9]{2}\.[0-9]{2}' <<< "$code" | while IFS= read -r label; do
        echo "$loc:$line:${label#ubuntu-}"
      done
    done | sort -u || true)"

if [[ -z "$pins" ]]; then
  echo "No pinned Ubuntu runner image under $dir."
  exit 0
fi

versions="$(cut -d: -f3 <<< "$pins" | sort -uV)"

if [[ "$list_only" == true ]]; then
  for v in $versions; do
    echo "ubuntu-$v:"
    awk -F: -v v="$v" '$3 == v { print "  " $1 ":" $2 }' <<< "$pins"
  done
  exit 0
fi

# GitHub announces a retirement as an issue labelled Announcement in
# actions/runner-images: "The Ubuntu 20.04 Actions runner image will begin
# deprecation on 2025-02-01 and will be fully unsupported by 2025-04-15", and
# the same shape for 18.04, macOS 12 and Windows 2019; 16.04 was "environment
# will be removed". Far more announcements name a version and remove one tool
# from it ("Clang 12 will be removed from Ubuntu 22.04 image"), so a bare
# "removed" is not a retirement.
retire_re='deprecat|fully unsupported|environment will be removed|retire|brownout'

# search <query>: url<TAB>title per matching issue, or exit non-zero.
search() {
  gh api -X GET search/issues -f q="$1" -f per_page=50 \
    --jq '.items[] | [.html_url, .title] | @tsv'
}

# A search that finds nothing looks the same as an image nobody is retiring.
# If GitHub renamed the label or reworded these titles, every run would pass
# for good, so first prove the search still finds a retirement it already
# announced: 20.04's.
canary_q='repo:actions/runner-images label:Announcement in:title "Ubuntu 20.04" deprecation'
if ! canary="$(search "$canary_q" 2>&1)"; then
  echo "::error::Could not search actions/runner-images: $canary"
  exit 1
fi
if ! grep -iE 'ubuntu' <<< "$canary" | grep -qiE "$retire_re"; then
  echo "::error::The search no longer finds GitHub's Ubuntu 20.04 retirement announcement (actions/runner-images#11101), so it cannot be trusted to find the next one. Check the label and title wording there and update this script."
  exit 1
fi

status=0
for v in $versions; do
  query="repo:actions/runner-images label:Announcement in:title \"$v\""
  if ! found="$(search "$query" 2>&1)"; then
    echo "::error::Could not ask actions/runner-images about ubuntu-$v: $found"
    status=1
    continue
  fi
  # "Ubuntu 22.04 and 24.04 images ..." names 24.04 without "Ubuntu" before
  # it, so the title needs both, not one next to the other.
  hits="$(grep -iE 'ubuntu' <<< "$found" | grep -E "(^|[^0-9.])${v//./\\.}([^0-9]|$)" \
    | grep -iE "$retire_re" || true)"
  if [[ -z "$hits" ]]; then
    echo "OK ubuntu-$v: no retirement announcement."
    continue
  fi
  status=1
  while IFS=$'\t' read -r url title; do
    echo "::error::ubuntu-$v is announced for retirement: $title ($url)"
  done <<< "$hits"
  echo "Pinned at:"
  awk -F: -v v="$v" '$3 == v { print "  " $1 ":" $2 }' <<< "$pins"
done

exit "$status"
