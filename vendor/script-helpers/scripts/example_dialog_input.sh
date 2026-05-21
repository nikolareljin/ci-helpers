#!/usr/bin/env bash
# SCRIPT: example_dialog_input.sh
# DESCRIPTION: Example script showing dialog input prompts via script-helpers.
# USAGE: ./example_dialog_input.sh
# PARAMETERS: No required parameters.
# EXAMPLE: ./example_dialog_input.sh
# ----------------------------------------------------
set -euo pipefail

# Demo: Prompt user for input via dialog

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/..}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging dialog

name=$(get_value "Your Name" "Please enter your name:" "Anonymous") || exit 1
print_success "Hello, $name!"
