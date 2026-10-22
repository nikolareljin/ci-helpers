#!/usr/bin/env bash
# SCRIPT: example_json.sh
# DESCRIPTION: Example script for JSON helpers including formatting and escaping.
# USAGE: ./example_json.sh
# PARAMETERS: No required parameters.
#   -h, --help   Show this help and exit.
# EXIT_CODES:
#   0  The demo ran.
#   1  A json helper failed.
# EXAMPLE: ./example_json.sh
# ----------------------------------------------------
set -euo pipefail

# Demo: JSON helpers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/..}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging json

case "${1:-}" in -h|--help) print_help "${BASH_SOURCE[0]}"; exit 0 ;; esac

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
