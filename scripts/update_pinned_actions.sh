#!/usr/bin/env bash
# SCRIPT: update_pinned_actions.sh
# DESCRIPTION: Refresh SHA pins for third-party GitHub Actions in workflow/action YAML files.
#              Reads the annotated ref from the inline comment (e.g. "# master @ 2026-04-13"),
#              fetches the current HEAD SHA for that ref via the GitHub API, and updates stale
#              pins in place.
#              A pin whose SHA is the commit of a release tag newer than the one its
#              comment names (a Dependabot bump, which moves the SHA and leaves the
#              comment) gets its comment moved to that tag instead of its SHA moved back.
# USAGE: ./scripts/update_pinned_actions.sh [--dir <path>] [--check] [--allow-newer-tag] [-h]
# PARAMETERS:
#   --dir <path>       Directory to scan recursively (default: .github).
#   --check            Dry-run: report stale pins and lookup warnings; exit 1 if any are found.
#   --allow-newer-tag  With --check: a pin whose SHA is the commit of a release tag of the
#                      same repository, newer than the tag in its comment, is reported as
#                      NEWER and does not fail. Anything else that differs is still STALE.
#                      Ordinary pull requests, non-release pushes to main and the weekly scan
#                      pass it. Release pull requests, the auto-tag gate on a release merge
#                      and production-branch.yml do not.
#   -h, --help         Show this help message.
# REQUIREMENTS:
#   - gh CLI authenticated (gh auth status)
#   - bash 4.0+
#   - python3
#   - perl
#   - scripts/semver_compare.sh (next to this script) and the helpers it sources
#     (vendor/script-helpers, or SCRIPT_HELPERS_DIR), unless --check runs without
#     --allow-newer-tag. If the comparer fails, the pin gets a warning and is left alone.
# EXAMPLES:
#   ./scripts/update_pinned_actions.sh             # update all stale pins
#   ./scripts/update_pinned_actions.sh --check     # CI gate: fail if pins are stale
#   ./scripts/update_pinned_actions.sh --check --allow-newer-tag   # gate on ordinary work, not a release
#   ./scripts/update_pinned_actions.sh --dir .github/workflows
# ----------------------------------------------------
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Error: bash 4.0+ is required (associative arrays are used by this script)." >&2
  exit 1
fi

dir=".github"
check_only=false
allow_newer_tag=false
today="$(date +%Y-%m-%d)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
semver_compare="${script_dir}/semver_compare.sh"

usage() {
  cat <<'EOF'
#!/usr/bin/env bash
# SCRIPT: update_pinned_actions.sh
# DESCRIPTION: Refresh SHA pins for third-party GitHub Actions in workflow/action YAML files.
#              Reads the annotated ref from the inline comment (e.g. "# master @ 2026-04-13"),
#              fetches the current HEAD SHA for that ref via the GitHub API, and updates stale
#              pins in place.
#              A pin whose SHA is the commit of a release tag newer than the one its
#              comment names (a Dependabot bump, which moves the SHA and leaves the
#              comment) gets its comment moved to that tag instead of its SHA moved back.
# USAGE: ./scripts/update_pinned_actions.sh [--dir <path>] [--check] [--allow-newer-tag] [-h]
# PARAMETERS:
#   --dir <path>       Directory to scan recursively (default: .github).
#   --check            Dry-run: report stale pins and lookup warnings; exit 1 if any are found.
#   --allow-newer-tag  With --check: a pin whose SHA is the commit of a release tag of the
#                      same repository, newer than the tag in its comment, is reported as
#                      NEWER and does not fail. Anything else that differs is still STALE.
#                      Ordinary pull requests, non-release pushes to main and the weekly scan
#                      pass it. Release pull requests, the auto-tag gate on a release merge
#                      and production-branch.yml do not.
#   -h, --help         Show this help message.
# REQUIREMENTS:
#   - gh CLI authenticated (gh auth status)
#   - bash 4.0+
#   - python3
#   - perl
#   - scripts/semver_compare.sh (next to this script) and the helpers it sources
#     (vendor/script-helpers, or SCRIPT_HELPERS_DIR), unless --check runs without
#     --allow-newer-tag. If the comparer fails, the pin gets a warning and is left alone.
# EXAMPLES:
#   ./scripts/update_pinned_actions.sh             # update all stale pins
#   ./scripts/update_pinned_actions.sh --check     # CI gate: fail if pins are stale
#   ./scripts/update_pinned_actions.sh --check --allow-newer-tag   # gate on ordinary work, not a release
#   ./scripts/update_pinned_actions.sh --dir .github/workflows
# ----------------------------------------------------
EOF
}

require_arg_value() {
  local flag="$1"
  local value="${2-}"

  if [[ -z "$value" || "$value" == -* ]]; then
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
    --allow-newer-tag) allow_newer_tag=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found. Install from https://cli.github.com/" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found. Install Python 3 to URL-encode refs." >&2
  exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "Error: perl not found. Install Perl to apply in-place replacements." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

# The tag lookup compares versions. A plain --check never looks up a tag, so it
# does not need the comparer; every other mode does.
if { $allow_newer_tag || ! $check_only; } && [[ ! -f "$semver_compare" ]]; then
  echo "Error: ${semver_compare} not found; it compares a pin's tag with its comment." >&2
  exit 1
fi

if [[ ! -d "$dir" ]]; then
  echo "Error: directory not found: $dir" >&2
  exit 1
fi

# Caches as files, not associative arrays, which bash 3.2 (macOS) does not
# have: sha ("owner/repo@ref" -> sha), tags ("owner/repo" -> "<tag> <commit
# sha>" lines) and tags_failed (repositories whose tag listing failed; asked
# once per run). A key is stored under its hex encoding.
cache_dir="$(mktemp -d)"
trap 'rm -rf -- "$cache_dir"' EXIT
mkdir "$cache_dir/sha" "$cache_dir/tags" "$cache_dir/tags_failed"
cache_file() {  # cache_file <cache> <key>
  printf '%s/%s/%s' "$cache_dir" "$1" "$(printf '%s' "$2" | od -An -tx1 | tr -d ' \n')"
}
cache_val=""
cache_get() {  # cache_get <cache> <key>: 0 and cache_val set on a hit
  local f
  f="$(cache_file "$1" "$2")"
  [[ -f "$f" ]] || return 1
  cache_val=""
  IFS= read -r -d '' cache_val < "$f" || true
}
cache_set() {  # cache_set <cache> <key> <value>
  printf '%s' "$3" > "$(cache_file "$1" "$2")"
}

stale_count=0
ok_count=0
newer_count=0
warn_count=0

url_encode_path_segment() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Fetch SHA for repo+ref, with caching. The result is returned in `fetched_sha`
# rather than on stdout: a `$(fetch_sha ...)` caller runs it in a subshell,
# where the cache write is thrown away, so every pin paid for its own API call.
fetched_sha=""
fetch_sha() {
  local repo="$1" ref="$2"
  local cache_key="${repo}@${ref}"
  fetched_sha=""

  if cache_get sha "$cache_key"; then
    fetched_sha="$cache_val"
    return
  fi

  local encoded_ref sha
  encoded_ref="$(url_encode_path_segment "$ref")"
  sha="$(gh api "repos/${repo}/commits/${encoded_ref}" --jq '.sha' 2>/dev/null)" || return 1
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    return 1
  fi
  cache_set sha "$cache_key" "$sha"
  fetched_sha="$sha"
}

# A release version: v1, v1.2 or v1.2.3, with or without the v. A pre-release
# (v1.2.3-rc1) or a branch (main, stable) is not one.
is_release_version() {
  [[ "$1" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]]
}

# How many dotted components a version has, so a comment that tracks a major
# (`v7`) is only ever moved to another major (`v8`), never to `v8.0.2`.
version_shape() {
  local v="${1#v}"
  v="${v//[^.]/}"
  echo "${#v}"
}

# gt, lt or eq: `a` against `b`, each padded to X.Y.Z for semver_compare.sh.
compare_versions() {
  local a="${1#v}" b="${2#v}"
  local -a pa pb
  IFS='.' read -r -a pa <<< "$a"
  IFS='.' read -r -a pb <<< "$b"
  bash "$semver_compare" "${pa[0]}.${pa[1]:-0}.${pa[2]:-0}" "${pb[0]}.${pb[1]:-0}.${pb[2]:-0}"
}

# compare_versions in `order`. Returns 1 unless the comparer answered gt, lt or
# eq: a crash is an unanswered question, not "not newer".
order=""
version_order() {
  order="$(compare_versions "$1" "$2")" || return 1
  case "$order" in
    gt|lt|eq) ;;
    *) return 1 ;;
  esac
}

# The highest release tag of $repo at commit $sha that is newer than $ref and
# of the same shape, in `found_tag`; empty when there is none. The highest such
# tag of another shape goes in `found_other_tag`. Returns 1 when the tag listing,
# a tag lookup or a comparison failed, which the caller reports as a warning:
# an unanswered question is not a pass.
#
# A longer tag is cut to the comment's shape first: `v7.0.1` is not newer than a
# `# v7` comment, it is an old commit of that line, and the pin is merely stale.
#
# The listing says which tags sit on the commit (`commit.sha` is the commit
# even for an annotated tag). Each candidate is then resolved the way the
# comment's ref is, through fetch_sha, so the two SHAs being compared come
# from the same lookup.
found_tag=""
found_other_tag=""
find_newer_tag() {
  local repo="$1" sha="$2" ref="$3"
  found_tag=""
  found_other_tag=""
  is_release_version "$ref" || return 0
  ! cache_get tags_failed "$repo" || return 1

  local listing
  if cache_get tags "$repo"; then
    listing="$cache_val"
  else
    if ! listing="$(gh api --paginate "repos/${repo}/tags?per_page=100" --jq '.[] | "\(.name) \(.commit.sha)"' 2>/dev/null)"; then
      cache_set tags_failed "$repo" 1
      return 1
    fi
    cache_set tags "$repo" "$listing"
  fi

  local name tag_sha best="" other="" shape
  shape="$(version_shape "$ref")"
  while read -r -u 3 name tag_sha; do
    [[ "$tag_sha" == "$sha" ]] || continue
    is_release_version "$name" || continue
    fetch_sha "$repo" "$name" || return 1
    [[ "$fetched_sha" == "$sha" ]] || continue
    if [[ "$(version_shape "$name")" == "$shape" ]]; then
      version_order "$name" "$ref" || return 1
      [[ "$order" == "gt" ]] || continue
      if [[ -n "$best" ]]; then
        version_order "$name" "$best" || return 1
        [[ "$order" == "gt" ]] || continue
      fi
      best="$name"
    else
      version_order "$(cut -d. -f"1-$((shape + 1))" <<< "$name")" "$ref" || return 1
      [[ "$order" == "gt" ]] || continue
      if [[ -n "$other" ]]; then
        version_order "$name" "$other" || return 1
        [[ "$order" == "gt" ]] || continue
      fi
      other="$name"
    fi
  done 3<<< "$listing"
  found_tag="$best"
  found_other_tag="$other"
}

# $line with its `# <ref> @ <date>` comment moved to `# <tag> @ <today>`, in
# `rewritten`. Splits at the SHA so the ref is only ever replaced inside the
# comment, not in the action path. Returns 1 when the comment is not where the
# pin pattern put it, so nothing is written.
rewritten=""
rewrite_pin_comment() {
  local line="$1" sha="$2" tag="$3"
  local head="${line%%@"${sha}"*}@${sha}" tail="${line#*@"${sha}"}"
  rewritten=""
  local re_comment='^([[:space:]]+#[[:space:]]+)[^[:space:]@]+([[:space:]]+@[[:space:]]+)[0-9]{4}-[0-9]{2}-[0-9]{2}(.*)$'
  if [[ "$tail" =~ $re_comment ]]; then
    rewritten="${head}${BASH_REMATCH[1]}${tag}${BASH_REMATCH[2]}${today}${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

# Regexes in variables: a pattern written inline in [[ =~ ]] with quotes or
# braces is one foxguard's bash parser cannot read, so the file went unscanned.
re_pin_any='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'"'"']?[a-zA-Z0-9_./-]+@[0-9a-fA-F]{40}'
re_pin_flow='(^[[:space:]]*(-[[:space:]]*)?|[:[,][[:space:]]*)\{[^}]*uses:[[:space:]]*["'"'"']?[a-zA-Z0-9_./-]+@[0-9a-fA-F]{40}'

# Find all YAML files under dir
files=()
while IFS= read -r yml_file; do files+=("$yml_file"); done < <(find "$dir" -type f \( -name "*.yml" -o -name "*.yaml" \) | sort)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No YAML files found under: $dir"
  exit 0
fi

for file in "${files[@]}"; do
  replacements_old=()
  replacements_new=()

  # Detect lines with a pinned SHA and an annotated ref comment.
  # Supported patterns:
  #   uses: owner/repo@<sha40> # <ref> @ <date>
  #   uses: owner/repo/subdir@<sha40> # <ref> @ <date>
  # `|| [[ -n "$line" ]]`: a file whose last line has no trailing newline makes
  # that final `read` fail after filling `line`, so without it the last line --
  # a pin like any other -- was never looked at and never warned about.
  while IFS= read -r line || [[ -n "$line" ]]; do
    # A YAML comment is not a pin, whatever text it quotes.
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Must match: uses: <path>@<40hex> # <ref> @ <YYYY-MM-DD>
    # Ref may be a branch (master/main), a tag (v1, v1.2.3), or similar.
    # The `- ` is optional because both spellings are valid YAML and both are
    # used here: a step whose only key is `uses:` is written `- uses: ...`,
    # while one with a `name:` or an `if:` carries `uses:` on its own line.
    # Anchoring on the second form alone made this audit skip every step of the
    # first -- 59 of 209 pins, actions/checkout in nearly every workflow --
    # and report "0 stale" for a SHA it had never looked at.
    if [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+([a-zA-Z0-9_./-]+)@([0-9a-f]{40})[[:space:]]+#[[:space:]]+([^[:space:]@]+)[[:space:]]+@[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
      action_path="${BASH_REMATCH[2]}"
      old_sha="${BASH_REMATCH[3]}"
      ref="${BASH_REMATCH[4]}"
      old_date="${BASH_REMATCH[5]}"

      # Repo = first two path segments (owner/repo); subpaths are subdirectories within that repo
      IFS='/' read -r -a path_parts <<< "$action_path"
      if [[ ${#path_parts[@]} -lt 2 ]]; then
        echo "WARN  $file: invalid action path '${action_path}' (expected owner/repo[/subdir]) — skipping" >&2
        warn_count=$((warn_count + 1))
        continue
      fi
      repo="${path_parts[0]}/${path_parts[1]}"

      # An annotation that names a commit rather than a branch or tag resolves
      # to itself, so the pin could never be reported stale: it would count as
      # OK forever without anything having been compared.
      if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "WARN  $file: ${action_path} is annotated with a commit SHA (${ref}), not a branch or tag, so it cannot be audited — skipping" >&2
        warn_count=$((warn_count + 1))
        continue
      fi

      resolved=true
      fetch_sha "$repo" "$ref" || resolved=false
      new_sha="$fetched_sha"

      if $resolved && [[ "$old_sha" == "$new_sha" ]]; then
        echo "OK    ${file}: ${action_path} # ${ref} (${old_sha:0:12}…)"
        ok_count=$((ok_count + 1))
        continue
      fi

      # The SHA is not the comment's ref, or the ref is gone upstream. Dependabot
      # moves a SHA to the next release and leaves the comment, so before calling
      # that stale, ask whether the SHA is a newer release tag of the same
      # repository. A plain --check does not ask: it gates release pull requests,
      # release merges and production-branch.yml, where the comment must be right.
      # Without --check the comment is the thing to correct; moving the SHA back
      # to the comment's tag undid the bump.
      newer_tag=""
      other_tag=""
      if $allow_newer_tag || ! $check_only; then
        if ! find_newer_tag "$repo" "$old_sha" "$ref"; then
          if $resolved; then
            echo "WARN  $file: could not resolve the tags of ${repo} to place ${old_sha:0:12}, skipping" >&2
          else
            echo "WARN  $file: could not fetch SHA for ${repo}@${ref} or resolve its tags, skipping" >&2
          fi
          warn_count=$((warn_count + 1))
          continue
        fi
        newer_tag="$found_tag"
        other_tag="$found_other_tag"
      fi

      # `# v1` at the commit of v2.0.0 with no v2 tag: the comment has no tag of
      # its shape to move to, and moving the SHA back would undo the bump.
      if [[ -z "$newer_tag" && -n "$other_tag" ]]; then
        echo "WARN  $file: ${action_path} is pinned at ${other_tag}, newer than its comment ${ref} but of another shape; correct the comment by hand, skipping" >&2
        warn_count=$((warn_count + 1))
        continue
      fi

      if ! $resolved && [[ -z "$newer_tag" ]]; then
        echo "WARN  $file: could not fetch SHA for ${repo}@${ref}, skipping" >&2
        warn_count=$((warn_count + 1))
        continue
      fi

      if [[ -n "$newer_tag" ]]; then
        newer_count=$((newer_count + 1))
        echo "NEWER ${file}: ${action_path}"
        echo "      comment: ${ref}  (${old_date})"
        echo "      pinned:  ${old_sha}  = ${newer_tag}"

        if ! $check_only; then
          if ! rewrite_pin_comment "$line" "$old_sha" "$newer_tag"; then
            echo "WARN  $file: could not rewrite the comment of ${action_path}, skipping" >&2
            warn_count=$((warn_count + 1))
            continue
          fi
          replacements_old+=("${line}")
          replacements_new+=("${rewritten}")
        fi
      else
        stale_count=$((stale_count + 1))
        echo "STALE ${file}: ${action_path}"
        echo "      ref:  ${ref}"
        echo "      old:  ${old_sha}  (${old_date})"
        echo "      new:  ${new_sha}  (${today})"

        if ! $check_only; then
          matched_fragment="$line"
          updated_fragment="${matched_fragment/@${old_sha}/@${new_sha}}"
          updated_fragment="${updated_fragment/${old_date}/${today}}"
          replacements_old+=("${matched_fragment}")
          replacements_new+=("${updated_fragment}")
        fi
      fi
    elif [[ "$line" =~ $re_pin_any ]] || [[ "$line" =~ $re_pin_flow ]]; then
      # A pinned action this audit could not parse. Silently skipping one is how
      # the gap above went unnoticed for as long as it did: the summary counted
      # only what matched, so a pin the pattern could not see was indistinguishable
      # from a pin that was up to date. Warnings fail --check, so an unreadable
      # pin now stops a release instead of passing as one that was never read.
      #
      # A quoted scalar -- `uses: 'owner/action@<sha>'` -- is valid YAML that
      # GitHub runs, and the strict parser above does not accept it, so it too
      # must land here rather than pass unseen. Same reasoning as uppercase hex.
      # So is a flow mapping -- `- { uses: owner/action@<sha> }`, `job: { uses: ... }`
      # or `steps: [ { uses: ... } ]` -- where the `{` starts the line or follows
      # `:`, `[` or `,`. A `{` inside a quoted string (`run: echo "{uses: ...}"`)
      # or a comment line is not a mapping and is not read as a pin.
      # Uppercase hex is deliberate here and not above: git and the GitHub API
      # resolve an uppercase object id, so `@ABCDEF...` is a pin that really
      # runs, and matching it only in the strict parser would mean comparing it
      # against a lowercase API answer and calling every such pin stale. Caught
      # here it fails --check as unreadable, and normalising it to lowercase is
      # then a one-line edit that puts it back under the real audit.
      echo "WARN  $file: pinned action not recognised, so not checked — ${line#"${line%%[![:space:]]*}"}" >&2
      echo "      expected: uses: <owner>/<repo>@<40 lowercase hex> # <ref> @ <YYYY-MM-DD>" >&2
      warn_count=$((warn_count + 1))
    fi
  done < "$file"

  if ! $check_only && [[ ${#replacements_old[@]} -gt 0 ]]; then
    for i in "${!replacements_old[@]}"; do
      OLD_FRAGMENT="${replacements_old[$i]}" NEW_FRAGMENT="${replacements_new[$i]}" \
        perl -0pi -e 's/\Q$ENV{OLD_FRAGMENT}\E/$ENV{NEW_FRAGMENT}/g' "$file"
    done
    echo "      UPDATED."
  fi
done

echo ""
echo "Summary: ${ok_count} up-to-date, ${stale_count} stale, ${newer_count} newer than their comment, ${warn_count} warnings."

if $check_only && [[ $newer_count -gt 0 ]]; then
  echo "Run without --check to move each NEWER comment to the tag its SHA is."
fi

if $check_only && [[ $stale_count -gt 0 || $warn_count -gt 0 ]]; then
  if [[ $stale_count -gt 0 ]]; then
    echo "Run without --check to apply updates."
  fi
  if [[ $warn_count -gt 0 ]]; then
    echo "Fix the lookup warnings above and rerun --check; warnings fail verification."
  fi
  exit 1
fi
