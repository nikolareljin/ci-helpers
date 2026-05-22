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
while IFS= read -r -d '' file; do
  if grep -qiE '"(api_key|api_secret|password|passwd|token|secret|auth|cookie|session|credential|private_key)"[[:space:]]*:' "$file"; then
    echo "::error::Potentially sensitive key found in $file"
    found=1
  fi
done < <(find "$scan_path" -type f -name '*.json' -print0)

[[ "$found" -eq 0 ]] || exit 1
echo "Data safety check passed."
