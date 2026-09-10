#!/usr/bin/env bash
# Loader for script-helpers. Source this file, then call shlib_import module names.

# Do not set strict mode here to avoid altering caller's shell options.

# Minimum shell. This file is the single entry point every consumer sources, so
# it is the only place that can report an unusable shell before some module
# fails later in a more confusing way. Written deliberately without arrays or
# bash-4 syntax so that it still runs on the shell it is reporting on.
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "[script-helpers] These helpers require bash." >&2
  return 1 2>/dev/null || exit 1
fi

_shlib_bash_major="${BASH_VERSINFO[0]:-0}"
_shlib_bash_minor="${BASH_VERSINFO[1]:-0}"

if [[ "$_shlib_bash_major" -lt 3 ]] ||
   [[ "$_shlib_bash_major" -eq 3 && "$_shlib_bash_minor" -lt 2 ]]; then
  echo "[script-helpers] bash 3.2 or newer is required; this is bash ${BASH_VERSION}." >&2
  return 1 2>/dev/null || exit 1
fi

if [[ "$_shlib_bash_major" -lt 4 ]]; then
  # The library supports bash 3.2 (which is what stock macOS ships), so this is
  # advice and never fatal. Printed once, to stderr, and only to a terminal: on
  # stdout it would corrupt any caller parsing a helper's output, and in CI it
  # would be noise on every job.
  export SHLIB_BASH_LEGACY=1
  if [[ -z "${SHLIB_BASH_ADVISORY_SHOWN:-}" && -z "${SHLIB_NO_BASH_ADVISORY:-}" && -t 2 ]]; then
    export SHLIB_BASH_ADVISORY_SHOWN=1
    echo "[script-helpers] Running on bash ${BASH_VERSION}. This is supported; bash 4+ is faster and enables the few helpers that take an associative array. On macOS: brew install bash" >&2
  fi
else
  export SHLIB_BASH_LEGACY=0
fi

_shlib_dir_resolve() {
  local base="${SCRIPT_HELPERS_DIR:-}" root=""
  if [[ -n "$base" && -d "$base" ]]; then
    root="$base"
  else
    # Resolve relative to this file
    local src="${BASH_SOURCE[0]}"
    root="$(cd "$(dirname "$src")" && pwd)"
  fi
  echo "$root"
}

_SHLIB_ROOT_DIR="$(_shlib_dir_resolve)"
_SHLIB_LIB_DIR="$_SHLIB_ROOT_DIR/lib"

# Track the script that sourced helpers.sh for consistent help output.
if [[ -n "${BASH_SOURCE[1]:-}" ]]; then
  export SHLIB_CALLER_SCRIPT="${BASH_SOURCE[1]}"
fi

# Import modules by name. Example: shlib_import logging docker json
shlib_import() {
  local name file
  # Ensure logging is available first if not explicitly requested
  local requested=("$@")
  local need_logging=true
  for name in "${requested[@]}"; do [[ "$name" == "logging" ]] && need_logging=false; done
  if $need_logging; then
    file="$_SHLIB_LIB_DIR/logging.sh"
    # shellcheck disable=SC1090
    [[ -f "$file" ]] && source "$file"
  fi
  for name in "${requested[@]}"; do
    file="$_SHLIB_LIB_DIR/${name}.sh"
    if [[ -f "$file" ]]; then
      # shellcheck disable=SC1090
      source "$file"
    else
      echo "[script-helpers] Unknown module: $name" >&2
      return 1
    fi
  done
}

# Convenience: import-all when requested
shlib_import_all() {
  local f
  for f in "$_SHLIB_LIB_DIR"/*.sh; do
    # shellcheck disable=SC1090
    source "$f"
  done
}

export SCRIPT_HELPERS_DIR="$_SHLIB_ROOT_DIR"
