#!/usr/bin/env bash
# SCRIPT: example_dialog_input.sh
# DESCRIPTION: Example script showing dialog input prompts via script-helpers.
# USAGE: ./example_dialog_input.sh
# PARAMETERS: No required parameters.
#   -h, --help   Show this help and exit.
# EXIT_CODES:
#   0  The name was read and greeted.
#   1  dialog is missing, no terminal, or the prompt was cancelled.
# EXAMPLE: ./example_dialog_input.sh
# ----------------------------------------------------
set -euo pipefail

# Demo: Prompt user for input via dialog

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/..}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging dialog

case "${1:-}" in -h|--help) print_help "${BASH_SOURCE[0]}"; exit 0 ;; esac

name=$(get_value "Your Name" "Please enter your name:" "Anonymous") || exit 1
print_success "Hello, $name!"
