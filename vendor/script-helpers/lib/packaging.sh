#!/usr/bin/env bash
# Packaging helpers for templates and dependency formatting.

_pkg_log_info() {
  if declare -F log_info >/dev/null 2>&1; then
    log_info "$*"
  else
    echo "[INFO] $*" >&2
  fi
}

_pkg_log_error() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$*"
  else
    echo "[ERROR] $*" >&2
  fi
}

# Usage: pkg_load_metadata <file>
# Loads key/value metadata from a packaging env file.
# Returns: 0 loaded (a failing line in the file is not reported); 1 file missing. Exports every assigned variable.
# Output: stderr error when missing.
pkg_load_metadata() {
  local file="${1:-packaging/packaging.env}"
  if [[ ! -f "$file" ]]; then
    _pkg_log_error "Packaging metadata not found: $file"
    return 1
  fi
  set -o allexport
  # shellcheck disable=SC1090
  source "$file"
  set +o allexport
}

# Usage: pkg_require_vars <VAR...>
# Ensures required variables are present (non-empty).
# Returns: 0 all set; 1 any empty.
# Output: stderr the list of missing names.
pkg_require_vars() {
  local missing=() var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    _pkg_log_error "Missing required packaging vars: ${missing[*]}"
    return 1
  fi
}

# Usage: pkg_trim <value>
# Trims leading/trailing whitespace from a string.
# Returns: 0.
# Output: stdout the trimmed value.
pkg_trim() {
  local value="$1"
  echo "$value" | xargs
}

# Usage: pkg_join_list <list> <separator>
# Joins a | delimited list with the given separator.
# Returns: 0.
# Output: stdout the joined list.
pkg_join_list() {
  local list="$1" separator="$2" item out="" items
  local IFS='|'
  read -r -a items <<< "$list"
  for item in ${items[@]+"${items[@]}"}; do
    item="$(pkg_trim "$item")"
    [[ -z "$item" ]] && continue
    if [[ -n "$out" ]]; then
      out+="$separator"
    fi
    out+="$item"
  done
  echo "$out"
}

# Usage: pkg_quote_list <list>
# Quotes each item from a | delimited list for shell arrays.
# Returns: 0.
# Output: stdout the quoted items, space separated.
pkg_quote_list() {
  local list="$1" item out="" items
  local IFS='|'
  read -r -a items <<< "$list"
  for item in ${items[@]+"${items[@]}"}; do
    item="$(pkg_trim "$item")"
    [[ -z "$item" ]] && continue
    out+="'$item' "
  done
  echo "${out% }"
}

# Usage: pkg_render_lines <prefix> <list>
# Renders lines with prefix for each item in a | delimited list.
# Returns: 0.
# Output: stdout one "<prefix><item>" line per item.
pkg_render_lines() {
  local prefix="$1" list="$2" item out="" items
  local IFS='|'
  read -r -a items <<< "$list"
  for item in ${items[@]+"${items[@]}"}; do
    item="$(pkg_trim "$item")"
    [[ -z "$item" ]] && continue
    out+="${prefix}${item}"$'\n'
  done
  printf "%s" "$out"
}

# Usage: pkg_classify_name <name>
# Converts a dashed/underscored name into CamelCase for Brew formula names.
# Returns: 0.
# Output: stdout the CamelCase name.
pkg_classify_name() {
  local name="$1"
  echo "$name" | awk -F'[-_]+' '{for (i=1; i<=NF; i++) {printf toupper(substr($i,1,1)) tolower(substr($i,2))} printf "\n"}'
}

# Usage: pkg_guess_version <repo_dir>
# Attempts to infer version from VERSION file or git tags.
# Returns: 0.
# Output: stdout the VERSION file content or the latest tag (no trailing newline), else "0.1.0" and a newline.
pkg_guess_version() {
  local repo_dir="${1:-.}"
  local version_file="$repo_dir/VERSION"
  if [[ -f "$version_file" ]]; then
    tr -d ' \t\r\n' < "$version_file"
    return 0
  fi
  if command -v git >/dev/null 2>&1; then
    if git -C "$repo_dir" describe --tags --abbrev=0 >/dev/null 2>&1; then
      git -C "$repo_dir" describe --tags --abbrev=0 | tr -d ' \t\r\n'
      return 0
    fi
  fi
  echo "0.1.0"
}
