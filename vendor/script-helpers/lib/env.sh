#!/usr/bin/env bash
# Environment and project helpers

# Usage: get_project_root; prints repo root based on caller script location.
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

  dirname "$script_dir"
}

# Usage: load_env [env_file]; sources environment file if present.
load_env() {
  local env_file="${1:-.env}"
  if [[ -f "$env_file" ]]; then
    log_debug "Loading environment from $env_file"
    # A caller that already had allexport on keeps it: switching it off here
    # silently stopped exporting everything the caller assigned afterwards.
    local had_allexport=0
    [[ -o allexport ]] && had_allexport=1
    set -o allexport
    # shellcheck disable=SC1090
    source "$env_file"
    [[ "$had_allexport" -eq 1 ]] || set +o allexport
  fi
}

# Usage: require_env <VAR...>; returns non-zero if any are missing.
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
    # Up to the FIRST '=': a greedy match kept only the text after the last
    # one, so base64 padding and URL query strings came back truncated.
    value=$(grep -E "^${key}=" "$env_file" | tail -n1 | sed 's/^[^=]*=//')
  fi
  value="$(_env__parse_value "$value")"
  [[ -z "$value" ]] && value="$default"
  printf '%s\n' "$value"
}

# Internal: normalise one raw dotenv value. Usage: _env__parse_value RAW
#
# Parameter expansion only. The old `echo | xargs` trim printed nothing for
# -n or -e, dropped backslashes, and failed outright on an apostrophe.
_env__parse_value() {
  local value="${1:-}" q rest inner="" c i after
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  q="${value:0:1}"
  if [[ "$q" == '"' || "$q" == "'" ]]; then
    # A quoted value runs to its closing quote; '#' inside it is not a comment.
    # Double quotes honour \" and \\ as the shell does; single quotes nothing.
    rest="${value:1}"
    local closed=0
    if [[ "$q" == "'" || "$rest" != *"\\"* ]]; then
      # Nothing to unescape: cut at the first closing quote. The loop below
      # indexes one character at a time, which is quadratic -- a 20KB value
      # took seconds.
      if [[ "$rest" == *"$q"* ]]; then
        inner="${rest%%"$q"*}"
        # Not ${rest#*"$q"}: a shortest-prefix match is itself quadratic.
        after="${rest:$((${#inner} + 1))}"
        closed=1
      fi
    else
      i=0
      while [[ $i -lt ${#rest} ]]; do
        c="${rest:$i:1}"
        if [[ "$c" == "\\" && ( "${rest:$((i+1)):1}" == '"' || "${rest:$((i+1)):1}" == "\\" ) ]]; then
          inner+="${rest:$((i+1)):1}"; i=$((i+2)); continue
        fi
        if [[ "$c" == "$q" ]]; then closed=1; break; fi
        inner+="$c"; i=$((i+1))
      done
      after="${rest:$((i+1))}"
    fi
    if [[ "$closed" -eq 1 ]]; then
      after="${after#"${after%%[![:space:]]*}"}"
      # Only a comment may follow the closing quote; anything else is not a
      # quoted value, and falls through to the unquoted reading below.
      if [[ -z "$after" || "$after" == '#'* ]]; then
        printf '%s' "$inner"
        return 0
      fi
    fi
  fi
  # Unquoted: a comment starts at a '#' that follows whitespace, as in the
  # shell and in dotenv; "ab#cd" is a value. A value that begins with '#'
  # (KEY=#x) is read as empty here and so returns the default, as it always
  # did -- the shell and dotenv both read it as "#x".
  [[ "$value" == '#'* ]] && value=""
  value="${value%%[[:space:]]#*}"
  value="${value%"${value##*[![:space:]]}"}"
  # A stray leading or trailing quote is dropped, as it always was.
  value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
  printf '%s' "$value"
}

# Usage: run_superuser_setup; runs scripts/superuser.sh from project root.
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

# Usage: init_include; sets up traps, cd to root, and loads .env.
init_include() {
  # Initialize traps, move to project root, and load .env
  if declare -F setup_traps >/dev/null 2>&1; then setup_traps; fi
  local project_root; project_root=$(get_project_root)
  if [[ "$(pwd)" != "$project_root" ]]; then
    log_debug "Changing to project root: $project_root"
    cd "$project_root" || return 1
  fi
  load_env
  log_debug "script-helpers initialized"
}
