#!/usr/bin/env bash
# Environment and project helpers

get_project_root() {
  local source_path="" script_dir=""

  # Walk the source stack from the outermost caller inward to find the real script file
  if [[ ${#BASH_SOURCE[@]} -gt 0 ]]; then
    local i
    for ((i=${#BASH_SOURCE[@]}-1; i>=0; i--)); do
      source_path="${BASH_SOURCE[$i]}"
      [[ -z "$source_path" || "$source_path" == "environment" ]] && continue
      [[ -f "$source_path" ]] && break
    done
  fi

  if [[ -n "$source_path" && -f "$source_path" ]]; then
    script_dir="$(cd "$(dirname "$source_path")" && pwd)"
  else
    script_dir="$(pwd)"
  fi

  echo "$(dirname "$script_dir")"
}

load_env() {
  local env_file="${1:-.env}"
  if [[ -f "$env_file" ]]; then
    log_debug "Loading environment from $env_file"
    set -o allexport
    # shellcheck disable=SC1090
    source "$env_file"
    set +o allexport
  fi
}

require_env() {
  local missing=()
  local var
  for var in "$@"; do
    [[ -z "${!var:-}" ]] && missing+=("$var")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required environment variables: ${missing[*]}"
    return 1
  fi
}

# Read a key from environment or .env file, with default fallback
resolve_env_value() {
  local key="$1" default="$2" env_file="${3:-.env}"
  local value=""
  if [[ -n "${!key:-}" ]]; then
    value="${!key}"
  elif [[ -n "$env_file" && -f "$env_file" ]]; then
    value=$(grep -E "^${key}=" "$env_file" | tail -n1 | sed 's/^.*=//')
  fi
  value="${value%$'\r'}"; value="${value%%#*}"; value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"; value="$(echo "$value" | xargs)"
  [[ -z "$value" ]] && value="$default"
  echo "$value"
}

run_superuser_setup() {
  local project_root su_script
  project_root=$(get_project_root)
  su_script="$project_root/scripts/superuser.sh"
  if [[ ! -x "$su_script" ]]; then
    log_error "Superuser script not found or not executable: $su_script"
    return 1
  fi
  log_info "Launching superuser setup..."
  "$su_script"
}

init_include() {
  # Initialize traps, move to project root, and load .env
  if declare -F setup_traps >/dev/null 2>&1; then setup_traps; fi
  local project_root; project_root=$(get_project_root)
  if [[ "$(pwd)" != "$project_root" ]]; then
    log_debug "Changing to project root: $project_root"
    cd "$project_root"
  fi
  load_env
  log_debug "script-helpers initialized"
}
