#!/usr/bin/env bash
set -euo pipefail

# Demo: Environment helpers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/..}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging env

print_info "Project root: $(get_project_root)"

# Demonstrate resolve_env_value with default
export EXAMPLE_FOO="${EXAMPLE_FOO:-}"
VAL=$(resolve_env_value EXAMPLE_FOO "default-value")
print_success "Resolved EXAMPLE_FOO: $VAL"

# Demonstrate require_env (will fail if missing)
if ! require_env HOME PATH; then
  print_error "Missing required env vars"
  exit 1
fi
print_success "Required env vars are present"

