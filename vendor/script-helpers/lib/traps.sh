#!/usr/bin/env bash
# Cleanup and signal traps

# Usage: cleanup; logs non-zero exit status on script exit.
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log_error "Script failed with exit code $exit_code"
  fi
}

# Usage: setup_traps; installs EXIT/INT/TERM handlers.
setup_traps() {
  # Guarded here too, though this cleanup only logs: from a signalled subshell it
  # would print "Script failed with exit code N" for a failure the script never had.
  trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup; fi' EXIT
  trap 'log_error "Script interrupted"; exit 130' INT
  trap 'log_error "Script terminated"; exit 143' TERM
}
