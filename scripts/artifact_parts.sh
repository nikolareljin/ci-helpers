#!/usr/bin/env bash
# SCRIPT: artifact_parts.sh
# DESCRIPTION: The two ends of a build-to-publish artifact hand-off.
#              `split` stores every file over 60 MiB under DIR as
#              <name>.split-NNN parts of 60 MiB (publication-check reads a
#              file over 64 MiB only in part). `verify` checks a downloaded artifact
#              against the sha256 manifest the build job wrote: every line
#              matches `<64 hex>  ./<path>` with <path> matching PATH_RE, the
#              tree holds only regular files and directories, the file list
#              equals the manifest's, `sha256sum --check --strict` passes,
#              and then the parts are joined back into their files.
#              Runs on Linux, macOS (BSD tools) and Git Bash.
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
# grep that fails closed: 0 match, 1 no match, anything else (a malformed
# pattern, a read error) is a refusal, never a pass.
grep_rc() {
  local rc=0
  grep "$@" || rc=$?
  (( rc <= 1 )) || fail "grep failed (exit $rc); refusing."
  return "$rc"
}

part_bytes=62914560  # 60 MiB

split_tree() {
  local dir="$1" big size n
  [[ -d "$dir" && ! -L "$dir" ]] || { echo "::error::$dir is not a directory." >&2; exit 2; }
  # find, not globstar: bash 3.2 (macOS /bin/bash) has no globstar. The
  # list is read in full first, so the parts written below are not walked.
  local files=()
  while IFS= read -r -d '' big; do files+=("$big"); done < <(find "$dir" -mindepth 1 -type f -print0)
  for big in ${files[@]+"${files[@]}"}; do
    [[ -f "$big" && ! -L "$big" ]] || continue
    size="$(wc -c < "$big" | tr -d ' ')"
    (( size > part_bytes )) || continue
    [[ ! -e "${big}.split-000" && ! -L "${big}.split-000" ]] || fail "${big}.split-000 already exists."
    # dd, not split: BSD split has no numeric suffixes on every macOS.
    n=0
    while (( n * part_bytes < size )); do
      dd if="$big" of="$(printf '%s.split-%03d' "$big" "$n")" bs=1048576 \
        skip=$(( n * part_bytes / 1048576 )) count=$(( part_bytes / 1048576 )) 2>/dev/null
      n=$((n + 1))
    done
    rm -f -- "$big"
  done
}

verify_tree() {
  local dir="$1" list="$2" re="$3" want have first whole n parts out sha
  [[ -d "$dir" && ! -L "$dir" ]] || fail "$dir is not a directory."
  [[ -f "$list" && ! -L "$list" ]] || fail "the manifest $list is not a regular file."
  [[ -s "$list" ]] || fail "the manifest is empty."
  # A malformed PATH_RE makes grep exit 2, which must refuse, not pass.
  grep_rc -qE -- "^(${re})\$" </dev/null || true
  if grep_rc -qvE "^[0-9a-f]{64}  \\./(${re})(\\.split-[0-9]{3})?\$" "$list"; then
    fail "the manifest is malformed or names a path outside the artifact."
  fi
  if grep_rc -qE '(^|/)\.\.?(/|$|\.split-)' <(sed -E 's/^[0-9a-f]{64}  \.\///' "$list"); then
    fail "the manifest names a . or .. path component."
  fi
  if [[ -n "$(cd "$dir" && find . -mindepth 1 ! -type f ! -type d -print -quit)" ]]; then
    fail "the artifact holds something other than regular files."
  fi
  want="$(sed -E 's/^[0-9a-f]{64}  //' "$list" | sort)"
  have="$(cd "$dir" && find . -type f | sort)"
  [[ "$want" == "$have" ]] || fail "the artifact's files differ from the manifest."
  # Absolute path: a relative one would be read from inside DIR.
  list="$(cd "$(dirname -- "$list")" && pwd -P)/$(basename -- "$list")"
  if command -v sha256sum >/dev/null; then sha=(sha256sum); else sha=(shasum -a 256); fi
  if ! out="$(cd "$dir" && "${sha[@]}" --check --strict "$list" 2>&1)"; then
    printf '%s\n' "$out" | grep -v ': OK$' >&2 || true
    fail "a file's sha256 differs from the manifest."
  fi
  # Every symlink was refused above, so find walks only the tree.
  local firsts=()
  while IFS= read -r -d '' first; do firsts+=("$first"); done < <(find "$dir" -mindepth 1 -type f -name '*.split-000' -print0)
  shopt -s nullglob
  for first in ${firsts[@]+"${firsts[@]}"}; do
    [[ -f "$first" && ! -L "$first" ]] || continue
    whole="${first%.split-000}"
    [[ ! -e "$whole" && ! -L "$whole" ]] || fail "the artifact holds both a file and its parts."
    # Parts are numbered from 000 with no gap.
    n=0
    while [[ -f "$(printf '%s.split-%03d' "$whole" "$n")" ]]; do n=$((n + 1)); done
    parts=("$whole".split-*)
    [[ "${#parts[@]}" == "$n" ]] || fail "the parts of a file are not numbered 000 up with no gap."
    cat -- "${parts[@]}" > "$whole"
    rm -f -- "${parts[@]}"
  done
  shopt -u nullglob
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
