#!/usr/bin/env bash
# SCRIPT: example_docker_compose_cmd.sh
# DESCRIPTION: Example script that detects and prints the available docker compose command.
# USAGE: ./example_docker_compose_cmd.sh
# PARAMETERS: No required parameters.
#   -h, --help   Show this help and exit.
# EXIT_CODES:
#   0  A compose command was found and printed.
#   1  Neither `docker compose` nor `docker-compose` is available.
# EXAMPLE: ./example_docker_compose_cmd.sh
# ----------------------------------------------------
set -euo pipefail

# Demo: Detect docker compose command

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/..}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging docker

case "${1:-}" in -h|--help) print_help "${BASH_SOURCE[0]}"; exit 0 ;; esac

if cmd=$(get_docker_compose_cmd); then
  print_success "Detected compose command: $cmd"
else
  print_error "Docker compose not available"
  exit 1
fi
