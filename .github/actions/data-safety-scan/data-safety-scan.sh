#!/usr/bin/env bash
# Reject sensitive-key fields in JSON data files under a caller-provided path.
set -euo pipefail

scan_path="${1:-}"
if [[ -z "$scan_path" ]]; then
  echo "::error::data-safety-scan requires a scan path."
  exit 2
fi

if [[ ! -d "$scan_path" ]]; then
  echo "::error::Data safety scan path does not exist: $scan_path"
  exit 2
fi

found=0
unreadable=0
# The file list is written first so find's own exit status is checked: a
# directory it could not enter was otherwise skipped without a word, and every
# file inside it passed unchecked.
file_list="$(mktemp)"
trap 'rm -f "$file_list"' EXIT
find_rc=0
find "$scan_path" -type f -name '*.json' -print0 > "$file_list" || find_rc=$?
if [[ "$find_rc" -ne 0 ]]; then
  echo "::error::Could not list every file under $scan_path (find exited $find_rc); some were not checked."
  unreadable=1
fi
while IFS= read -r -d '' file; do
  # grep exits 0 on a match, 1 on none, and 2 when it could not read the file.
  # A file that could not be read has not been checked, so it must not pass.
  rc=0
  grep -qiE '"(api_key|api_secret|password|passwd|token|secret|auth|cookie|session|credential|private_key)"[[:space:]]*:' "$file" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "::error::Potentially sensitive key found in $file"
    found=1
  elif [[ "$rc" -ge 2 ]]; then
    echo "::error::Could not read $file; it was not checked."
    unreadable=1
  fi
done < "$file_list"

[[ "$unreadable" -eq 0 ]] || exit 2
[[ "$found" -eq 0 ]] || exit 1
echo "Data safety check passed."
