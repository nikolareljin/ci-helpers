#!/usr/bin/env bash
set -euo pipefail

# Demo: Logging helpers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/..}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging

print_info "This is an info message"
print_success "This is a success message"
print_warning "This is a warning message"
print_error "This is an error message"

log_info "Structured info (log_info)"
log_warn "Structured warn (log_warn)"
log_error "Structured error (log_error)"
DEBUG=true log_debug "Structured debug (log_debug)"

