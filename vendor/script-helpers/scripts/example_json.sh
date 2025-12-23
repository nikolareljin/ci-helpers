#!/usr/bin/env bash
set -euo pipefail

# Demo: JSON helpers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/..}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging json

RAW='{"response":"Hello\\nWorld"}'
echo "Raw JSON: $RAW"

if command -v jq >/dev/null 2>&1; then
  OUT=$(format_response "$RAW")
  print_success "Parsed .response via jq: $OUT"
else
  print_warning "jq not installed; demonstrating json_escape only"
  ESCAPED=$(json_escape "Hello \"World\"\nNew line")
  echo "Escaped: $ESCAPED"
fi

