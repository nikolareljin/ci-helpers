#!/usr/bin/env bash
# SCRIPT: example_docker_status.sh
# DESCRIPTION: Example script that prints Docker runtime status using script-helpers.
# USAGE: ./example_docker_status.sh
# PARAMETERS: No required parameters.
# EXAMPLE: ./example_docker_status.sh
# ----------------------------------------------------
set -euo pipefail

# Demo: Show docker status and compose service checks
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/../}"

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging docker

docker_status
