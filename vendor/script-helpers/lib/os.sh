#!/usr/bin/env bash
# OS detection and sudo helpers.

# Usage: get_os; prints linux|mac|windows|unknown.
get_os() {
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "linux"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "mac"
  elif [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]]; then
    echo "windows"
  else
    echo "unknown"
  fi
}

# Alias used in some projects
getos() { get_os; }

# Run with sudo optionally based on a boolean flag argument
run_with_optional_sudo() {
  local use_sudo="$1"; shift
  if [[ "$use_sudo" == "true" ]] && command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}
