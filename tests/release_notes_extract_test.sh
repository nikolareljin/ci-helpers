#!/usr/bin/env bash
# SCRIPT: release_notes_extract_test.sh
# DESCRIPTION: The "Extract CHANGELOG notes" step of create-github-release.yml,
#              run as written under gawk and mawk: it prints nothing on
#              stderr, returns each section of tests/fixtures/release-notes
#              byte for byte, matches the version dots literally (v1.2.1
#              skips a v1a2b1 heading), and finds a section for every release
#              heading in this repo's CHANGELOG.md. In CI gawk is required.
# USAGE: bash tests/release_notes_extract_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/create-github-release.yml"
fx="$root/tests/fixtures/release-notes"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# The step's lines from `escaped=` through the closing `' CHANGELOG.md)`.
sed -n '/^ *escaped=\$(printf/,/^ *'"'"' CHANGELOG\.md)$/p' "$wf" > "$work/snippet.sh"
if ! grep -q "CHANGELOG.md)" "$work/snippet.sh" || ! grep -q '^ *escaped=' "$work/snippet.sh"; then
  echo "FAIL could not find the extractor in $wf"; exit 1
fi

# extract <awk> <tag> ; runs on $changelog, prints the body, stderr to $work/err
extract() {
  local dir="$work/run"
  rm -rf "$dir"; mkdir -p "$dir/bin"
  ln -s "$(command -v "$1")" "$dir/bin/awk"
  cp "$changelog" "$dir/CHANGELOG.md"
  (cd "$dir" && PATH="$dir/bin:$PATH" RELEASE_TAG="$2" bash -c \
    'set -euo pipefail; '"$(cat "$work/snippet.sh")"'
     printf "%s\n" "$body"') 2> "$work/err"
}

awks=()
for a in gawk mawk; do command -v "$a" > /dev/null && awks+=("$a"); done
[ "${#awks[@]}" -gt 0 ] || { echo "FAIL neither gawk nor mawk is installed"; exit 1; }
# gawk is the awk that warned; a CI run without it would check nothing.
if [ -n "${CI:-}" ] && ! command -v gawk > /dev/null; then
  echo "FAIL gawk is not installed"; exit 1
fi

sed -n 's/^## [0-9]\{4\}-[0-9][0-9]-[0-9][0-9] — \(v\{0,1\}[0-9][0-9.]*\).*/\1/p' \
  "$root/CHANGELOG.md" > "$work/tags"
[ -s "$work/tags" ] || { echo "FAIL no release heading found in CHANGELOG.md"; exit 1; }

for a in "${awks[@]}"; do
  for tag in v1.2.10 v1.2.1 1.2.0; do
    changelog="$fx/CHANGELOG.md" extract "$a" "$tag" > "$work/out"
    if [ -s "$work/err" ]; then
      echo "FAIL $a $tag wrote to stderr:"; cat "$work/err"; fail=1
    fi
    if ! cmp -s "$work/out" "$fx/$tag.txt"; then
      echo "FAIL $a $tag body differs:"; diff "$fx/$tag.txt" "$work/out" || true; fail=1
    fi
  done

  # A dot in the tag is literal: v1.2.1 must skip a v1a2b1 heading above it.
  changelog="$fx/CHANGELOG-dots.md" extract "$a" v1.2.1 > "$work/out"
  if [ -s "$work/err" ] || [ "$(cat "$work/out")" != "- this one" ]; then
    echo "FAIL $a v1.2.1 did not skip the v1a2b1 heading:"; cat "$work/err" "$work/out"; fail=1
  fi

  # Every release heading in this repo's CHANGELOG.md yields a body, quietly.
  while IFS= read -r tag; do
    changelog="$root/CHANGELOG.md" extract "$a" "$tag" > "$work/out"
    if [ -s "$work/err" ] || [ -z "$(tr -d '[:space:]' < "$work/out")" ]; then
      echo "FAIL $a $tag: empty body or stderr:"; cat "$work/err"; fail=1
    fi
  done < "$work/tags"
done

[ "$fail" -eq 0 ] && echo "OK release notes extractor (${awks[*]})"
exit "$fail"
