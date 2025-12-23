#!/usr/bin/env bash
set -euo pipefail

# Demo: Detect docker compose command

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/..}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging docker

if cmd=$(get_docker_compose_cmd); then
  print_success "Detected compose command: $cmd"
else
  print_error "Docker compose not available"
  exit 1
fi

