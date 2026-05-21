#!/usr/bin/env bash
# Loader for script-helpers. Source this file, then call shlib_import module names.

# Do not set strict mode here to avoid altering caller's shell options.

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
