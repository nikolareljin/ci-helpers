#!/usr/bin/env bash
# Cleanup and signal traps

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log_error "Script failed with exit code $exit_code"
  fi
}

setup_traps() {
  trap cleanup EXIT
  trap 'log_error "Script interrupted"; exit 130' INT
  trap 'log_error "Script terminated"; exit 143' TERM
}

