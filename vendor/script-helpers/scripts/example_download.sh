#!/usr/bin/env bash
set -euo pipefail

# Demo: Download a URL with a dialog gauge (auto-enabled in download_file)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/..}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging dialog file

URL="${1:-https://speed.hetzner.de/10MB.bin}"
OUT="${2:-/tmp/example-download.bin}"

print_info "Downloading: $URL"
print_info "Destination: $OUT"

# Use the integrated helper; it will show the dialog gauge when available
download_file "$URL" "$OUT"

if [[ -f "$OUT" ]]; then
  SIZE=$(stat -c %s "$OUT" 2>/dev/null || stat -f%z "$OUT" 2>/dev/null || echo 0)
  print_success "Downloaded file exists ($SIZE bytes): $OUT"
else
  print_error "Download appears to have failed: $OUT"
  exit 1
fi
