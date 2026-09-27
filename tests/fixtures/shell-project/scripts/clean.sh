#!/usr/bin/env bash
# Clean at warning severity: what the preset's default must accept.
set -euo pipefail

greet() {   # <name>
  local name="${1:-world}"
  printf 'hello, %s\n' "$name"
}

greet "$@"
