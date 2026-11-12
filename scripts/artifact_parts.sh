#!/usr/bin/env bash
# SCRIPT: artifact_parts.sh
# DESCRIPTION: The two ends of a build-to-publish artifact hand-off.
#              `split` stores every file over 60 MiB under DIR as
#              <name>.split-NNN parts of 60 MiB (publication-check refuses a
#              file over 64 MiB). `verify` checks a downloaded artifact
#              against the sha256 manifest the build job wrote: every line
#              matches `<64 hex>  ./<path>` with <path> matching PATH_RE, the
#              tree holds only regular files and directories, the file list
#              equals the manifest's, `sha256sum --check --strict` passes,
#              and then the parts are joined back into their files.
# USAGE: bash scripts/artifact_parts.sh split DIR
#        bash scripts/artifact_parts.sh verify DIR MANIFEST_FILE PATH_RE
# PARAMETERS:
#   DIR            The artifact tree.
#   MANIFEST_FILE  `sha256sum` lines, paths relative to DIR as ./<path>.
#   PATH_RE        Extended regex one <path> must match whole, without the
#                  leading ./ (anchors are added). Part suffixes are added.
# EXIT CODES:
#   0  Done.
#   1  A refusal: malformed manifest, a symlink or special file, a list or
#      checksum mismatch, a file and its parts both present.
#   2  Usage error.
# ----------------------------------------------------
set -euo pipefail
export LC_ALL=C

usage() { grep '^#[^!]' "$0" | sed 's/^# \?//'; }
fail() { echo "::error::$*" >&2; exit 1; }

part_bytes=62914560  # 60 MiB

split_tree() {
  local dir="$1" big
  [[ -d "$dir" && ! -L "$dir" ]] || { echo "::error::$dir is not a directory." >&2; exit 2; }
  while IFS= read -r -d '' big; do
    (( $(stat -c %s -- "$big") > part_bytes )) || continue
    [[ ! -e "${big}.split-000" && ! -L "${big}.split-000" ]] || fail "${big}.split-000 already exists."
    split -b "$part_bytes" -d -a 3 -- "$big" "${big}.split-"
    rm -f -- "$big"
  done < <(find "$dir" -type f -print0)
}

verify_tree() {
  local dir="$1" list="$2" re="$3" want have first whole n
  [[ -d "$dir" && ! -L "$dir" ]] || fail "$dir is not a directory."
  [[ -f "$list" && ! -L "$list" ]] || fail "the manifest $list is not a regular file."
  [[ -s "$list" ]] || fail "the manifest is empty."
  if grep -qvE "^[0-9a-f]{64}  \\./(${re})(\\.split-[0-9]{3})?\$" "$list"; then
    fail "the manifest is malformed or names a path outside the artifact."
  fi
  if grep -qE '(^|/)\.\.?(/|$|\.split-)' <(sed -E 's/^[0-9a-f]{64}  \.\///' "$list"); then
    fail "the manifest names a . or .. path component."
  fi
  if [[ -n "$(cd "$dir" && find . -mindepth 1 ! -type f ! -type d -print -quit)" ]]; then
    fail "the artifact holds something other than regular files."
  fi
  want="$(sed -E 's/^[0-9a-f]{64}  //' "$list" | sort)"
  have="$(cd "$dir" && find . -type f | sort)"
  [[ "$want" == "$have" ]] || fail "the artifact's files differ from the manifest."
  # Absolute path: a relative one would be read from inside DIR.
  list="$(realpath -e -- "$list")"
  (cd "$dir" && sha256sum --check --strict --quiet "$list") || fail "a file's sha256 differs from the manifest."
  while IFS= read -r -d '' first; do
    whole="${first%.split-000}"
    [[ ! -e "$whole" && ! -L "$whole" ]] || fail "the artifact holds both a file and its parts."
    # Parts are numbered from 000 with no gap.
    n=0
    while [[ -f "$(printf '%s.split-%03d' "$whole" "$n")" ]]; do n=$((n + 1)); done
    [[ "$(find "$(dirname -- "$whole")" -maxdepth 1 -type f -name "$(basename -- "$whole").split-*" | wc -l)" == "$n" ]] \
      || fail "the parts of a file are not numbered 000 up with no gap."
    cat -- "$whole".split-[0-9][0-9][0-9] > "$whole"
    rm -f -- "$whole".split-[0-9][0-9][0-9]
  done < <(cd "$dir" && find "$PWD" -type f -name '*.split-000' -print0)
}

case "${1:-}" in
  split)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    split_tree "$2" ;;
  verify)
    [[ $# -eq 4 && -n "$4" ]] || { usage >&2; exit 2; }
    verify_tree "$2" "$3" "$4" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
