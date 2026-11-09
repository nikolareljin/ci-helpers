#!/usr/bin/env bash
# SCRIPT: github_release.sh
# DESCRIPTION: Create or update a GitHub release and upload its assets with
#              the GitHub CLI the runner ships, in place of
#              softprops/action-gh-release. Nothing but `gh` touches the token
#              or the files. Every former input is an environment variable:
#
#   TAG_NAME                 required; `refs/tags/X` is read as `X`
#   RELEASE_NAME             title; a new release defaults to the tag, an
#                            existing one keeps its title when empty
#   BODY_PATH                notes file; replaces the body when set
#   TARGET_COMMITISH         commit or branch the tag is created from when
#                            the tag does not exist yet
#   DRAFT                    true|false; empty: a new release is not a draft,
#                            an existing one is left as it is
#   PRERELEASE               true|false; same rule
#   MAKE_LATEST              true|false|legacy; empty: GitHub's default for a
#                            new release, unchanged for an existing one
#   FILES                    glob patterns, one per line, of files to upload
#   OVERWRITE_FILES          default true: an asset with the same name is
#                            replaced; false: it is kept and the file skipped
#   FAIL_ON_UNMATCHED_FILES  default false: a pattern that matches nothing is
#                            a warning; true: an error
#   GH_TOKEN or GITHUB_TOKEN required; GITHUB_REPOSITORY names the repository
#
#              Writes `url` and `upload_url` to GITHUB_OUTPUT when it is set.
# USAGE: env TAG_NAME=1.2.3 FILES='dist/*' bash scripts/github_release.sh
# ----------------------------------------------------
set -euo pipefail

fail() { echo "::error::github_release: $*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 \
  || fail "the GitHub CLI (gh) is not on PATH; the release job's runner needs it"
[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] || fail "GH_TOKEN (or GITHUB_TOKEN) is not set"
repo="${GITHUB_REPOSITORY:-}"
printf '%s' "$repo" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
  || fail "GITHUB_REPOSITORY must be owner/name, got '$repo'"

tag="${TAG_NAME:-}"
tag="${tag#refs/tags/}"
[ -n "$tag" ] || fail "TAG_NAME is empty"
# A tag is a ref name as `git check-ref-format` reads it, and must not start
# with '-' (gh would take it for a flag). `pkg@1.2.3` is a tag; `a b` is not.
bad_tag=0
case "$tag" in
  -*|/*|*/|*.|*//*|*..*|*@\{*|@|*.lock|*.lock/*|.*|*/.*) bad_tag=1 ;;
esac
if printf '%s' "$tag" | LC_ALL=C grep -q '[[:cntrl:][:space:]~^:?*[\\]'; then bad_tag=1; fi
[ "$bad_tag" = 0 ] || fail "TAG_NAME '$tag' is not a tag name"

# true, false or empty; anything else is a typo, refused rather than read as false.
flag() {  # name -> prints true|false|"" or fails
  local name="$1" value="${!1:-}"
  case "$value" in
    true|false|"") printf '%s' "$value" ;;
    *) fail "$name must be true or false, got '$value'" ;;
  esac
}
draft="$(flag DRAFT)"
prerelease="$(flag PRERELEASE)"
case "${MAKE_LATEST:-}" in
  true|false|legacy|"") ;;
  *) fail "MAKE_LATEST must be true, false or legacy, got '${MAKE_LATEST}'" ;;
esac
overwrite="${OVERWRITE_FILES:-true}"
case "$overwrite" in true|false) ;; *) fail "OVERWRITE_FILES must be true or false, got '$overwrite'" ;; esac
unmatched_fails="${FAIL_ON_UNMATCHED_FILES:-false}"
case "$unmatched_fails" in true|false) ;; *) fail "FAIL_ON_UNMATCHED_FILES must be true or false, got '$unmatched_fails'" ;; esac
body="${BODY_PATH:-}"
if [ -n "$body" ]; then
  [ -f "$body" ] || fail "BODY_PATH '$body' is not a file"
fi

# Resolve the files first: an unmatched pattern that must fail does so
# before anything is created or changed.
files=()
if [ -n "${FILES:-}" ]; then
  # One pattern per line: split with globbing off, so a `*` in FILES is not
  # expanded before it is read as a pattern.
  patterns=()
  oldifs="$IFS"; IFS=$'\n'; set -f
  for pattern in ${FILES}; do
    pattern="${pattern%$'\r'}"
    [ -n "$pattern" ] || continue
    patterns[${#patterns[@]}]="$pattern"
  done
  set +f; IFS="$oldifs"
  shopt -s nullglob
  # "${patterns[@]}" on an empty array is an unbound variable under set -u
  # before bash 4.4; FILES of blank lines only means no file.
  [ "${#patterns[@]}" -gt 0 ] || patterns=("")
  for pattern in "${patterns[@]}"; do
    [ -n "$pattern" ] || continue
    matched=0
    # Expand the glob with IFS set to newline, so a path with a space survives.
    IFS=$'\n'
    for f in $pattern; do
      IFS="$oldifs"
      [ -f "$f" ] || continue
      # gh reads `path#label`, so a '#' would name another file.
      case "$f" in *'#'*) IFS="$oldifs"; fail "file '$f' has a '#', which gh reads as a label" ;; esac
      files[${#files[@]}]="$f"
      matched=1
    done
    IFS="$oldifs"
    if [ "$matched" = 0 ]; then
      if [ "$unmatched_fails" = true ]; then
        fail "pattern '$pattern' matches no file"
      fi
      echo "::warning::github_release: pattern '$pattern' matches no file"
    fi
  done
  shopt -u nullglob
fi

# Is there a release for the tag? gh finds a draft by its tag too. Only
# "not found" means no; any other failure stops the run.
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
existing=""
if ! existing="$(gh release view "$tag" -R "$repo" --json url 2>"$err")"; then
  if ! grep -qi "not found" "$err"; then
    fail "could not read release $tag: $(head -c 300 "$err")"
  fi
  existing=""
fi

if [ -z "$existing" ]; then
  args=(release create "$tag" -R "$repo" --title "${RELEASE_NAME:-$tag}")
  if [ -n "$body" ]; then
    args+=(--notes-file "$body")
  else
    args+=(--notes "")
  fi
  [ "$draft" = true ] && args+=(--draft)
  [ "$prerelease" = true ] && args+=(--prerelease)
  [ -n "${TARGET_COMMITISH:-}" ] && args+=(--target "$TARGET_COMMITISH")
  case "${MAKE_LATEST:-}" in
    true|false) args+=("--latest=${MAKE_LATEST}") ;;
  esac
  # The files go with the create: gh makes a draft, uploads them, then
  # publishes, so an immutable release gets its assets before it locks.
  if [ "${#files[@]}" -gt 0 ]; then args+=(-- "${files[@]}"); fi
  echo "Creating release $tag on $repo"
  gh "${args[@]}" >/dev/null
  [ "${#files[@]}" -eq 0 ] || echo "Uploaded ${#files[@]} file(s) to $tag"
  files=()
else
  args=(release edit "$tag" -R "$repo")
  changes=0
  if [ -n "${RELEASE_NAME:-}" ]; then args+=(--title "$RELEASE_NAME"); changes=1; fi
  if [ -n "$body" ]; then args+=(--notes-file "$body"); changes=1; fi
  if [ -n "$draft" ]; then args+=("--draft=$draft"); changes=1; fi
  if [ -n "$prerelease" ]; then args+=("--prerelease=$prerelease"); changes=1; fi
  if [ -n "${TARGET_COMMITISH:-}" ]; then args+=(--target "$TARGET_COMMITISH"); changes=1; fi
  case "${MAKE_LATEST:-}" in
    true|false) args+=("--latest=${MAKE_LATEST}"); changes=1 ;;
  esac
  if [ "$changes" = 1 ]; then
    echo "Updating release $tag on $repo"
    gh "${args[@]}" >/dev/null
  else
    echo "Release $tag exists on $repo; nothing to change"
  fi
fi
# `gh release` has no legacy value for --latest; the REST field does.
if [ "${MAKE_LATEST:-}" = legacy ]; then
  gh api -X PATCH "repos/$repo/releases/$(gh release view "$tag" -R "$repo" --json databaseId -q .databaseId)" \
    -f make_latest=legacy >/dev/null
fi

if [ "${#files[@]}" -gt 0 ]; then
  upload=()
  if [ "$overwrite" = true ]; then
    upload=("${files[@]}")
    gh release upload "$tag" -R "$repo" --clobber "${upload[@]}"
  else
    # Keep what is published: upload only names the release does not have.
    published="$(gh release view "$tag" -R "$repo" --json assets -q '.assets[].name')"
    for f in "${files[@]}"; do
      name="$(basename "$f")"
      if printf '%s\n' "$published" | grep -qxF -- "$name"; then
        echo "::notice::github_release: $name is already on $tag; kept (OVERWRITE_FILES=false)"
        continue
      fi
      upload[${#upload[@]}]="$f"
    done
    if [ "${#upload[@]}" -gt 0 ]; then
      gh release upload "$tag" -R "$repo" "${upload[@]}"
    fi
  fi
  echo "Uploaded ${#upload[@]} file(s) to $tag"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  gh release view "$tag" -R "$repo" --json url,uploadUrl \
    -q '"url=\(.url)\nupload_url=\(.uploadUrl)"' >> "$GITHUB_OUTPUT"
fi
