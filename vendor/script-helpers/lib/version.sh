#!/usr/bin/env bash
# Version helpers for bumping and comparing semantic versions.

# Usage: _version__parse_triplet <version>; internal parser for X.Y.Z.
_version__parse_triplet() {
  local raw="$1"

  # Trim optional leading v/V and any suffix after a dash
  if [[ "$raw" =~ ^[vV](.*)$ ]]; then
    raw="${BASH_REMATCH[1]}"
  fi
  raw="${raw%%-*}"

  if [[ ! "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print_error "Invalid version format: $raw (expected X.Y.Z)"
    return 1
  fi

  IFS='.' read -r major minor patch <<< "$raw"
  echo "$major $minor $patch"
}

# Usage: version_compare <version_a> <version_b>; returns 0 if equal.
# Returns: 0 equal; 1 a > b; 255 a < b; 2 missing argument; 3 not X.Y.Z.
# Output: stdout the usage error (print_error) on code 2; else nothing.
version_compare() {
  local left="${1:-}" right="${2:-}"
  if [[ -z "$left" || -z "$right" ]]; then
    print_error "Usage: version_compare <version_a> <version_b>"
    return 2
  fi

  local left_parts right_parts
  if ! left_parts=$(_version__parse_triplet "$left"); then return 3; fi
  if ! right_parts=$(_version__parse_triplet "$right"); then return 3; fi

  read -r l_major l_minor l_patch <<< "$left_parts"
  read -r r_major r_minor r_patch <<< "$right_parts"

  # Forced to base 10. Arithmetic reads a leading zero as octal, so a CalVer
  # `2026.08.1` was an error ("value too great for base") and `1.010.0` was 8.
  l_major=$((10#$l_major)); l_minor=$((10#$l_minor)); l_patch=$((10#$l_patch))
  r_major=$((10#$r_major)); r_minor=$((10#$r_minor)); r_patch=$((10#$r_patch))

  if (( l_major == r_major && l_minor == r_minor && l_patch == r_patch )); then
    return 0
  elif (( l_major > r_major )); then
    return 1
  elif (( l_major < r_major )); then
    return 255  # represents -1 in shell return codes
  elif (( l_minor > r_minor )); then
    return 1
  elif (( l_minor < r_minor )); then
    return 255
  elif (( l_patch > r_patch )); then
    return 1
  else
    return 255
  fi
}

# Usage: version_project_root
# The caller's project root: the top of the git work tree holding the cwd, or
# the cwd outside git. When that work tree is a script-helpers checkout vendored
# as a submodule, the superproject is the project.
# Returns: 0 always.
# Output: stdout the absolute directory; stderr nothing.
version_project_root() {
  local top super
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [[ -z "$top" ]]; then pwd; return 0; fi
  if [[ -f "$top/helpers.sh" && -d "$top/lib" ]]; then
    super="$(git -C "$top" rev-parse --show-superproject-working-tree 2>/dev/null)" || super=""
    [[ -n "$super" ]] && top="$super"
  fi
  printf '%s\n' "$top"
}

# Usage: version_bump {major|minor|patch} [-f VERSION_FILE]; bumps version file.
# Without -f: VERSION at version_project_root (the project's, never a vendored
# script-helpers copy's). A relative -f is relative to the cwd. A missing file
# is created, bumped from 0.1.0.
# Returns: 0 bumped or help shown; 1 bad arguments, unparseable version, or the file could not be written.
# Output: stdout success or error lines (print_success/print_error) and help.
version_bump() {
  local bump_type="" version_file="" prefix="" suffix="" normalized

  while [[ $# -gt 0 ]]; do
    case "$1" in
      major|minor|patch)
        if [[ -n "$bump_type" ]]; then
          print_error "Bump type already specified ($bump_type)"
          return 1
        fi
        bump_type="$1"
        shift
        ;;
      -f|--file)
        if [[ $# -lt 2 ]]; then
          print_error "Missing file after $1"
          return 1
        fi
        version_file="$2"
        shift 2
        ;;
      -h|--help)
        if declare -F show_help >/dev/null 2>&1 && [[ -n "${SHLIB_CALLER_SCRIPT:-}" && -f "$SHLIB_CALLER_SCRIPT" ]]; then
          show_help "$SHLIB_CALLER_SCRIPT"
        else
          echo "Usage: version_bump {major|minor|patch} [-f VERSION_FILE]"
        fi
        return 0
        ;;
      *)
        print_error "Unknown argument: $1"
        return 1
        ;;
    esac
  done

  if [[ -z "$bump_type" ]]; then
    print_error "Bump type required: major|minor|patch"
    return 1
  fi

  if [[ -z "$version_file" ]]; then
    # The default: VERSION at the caller's project root, never in a vendored
    # script-helpers copy.
    version_file="$(version_project_root)/VERSION"
  elif [[ "$version_file" != /* ]]; then
    # An explicit relative path means relative to where the caller stands.
    version_file="${PWD}/${version_file}"
  fi

  local version_dir
  version_dir="$(dirname "$version_file")"
  if [[ ! -d "$version_dir" ]]; then
    if ! mkdir -p "$version_dir"; then
      print_error "Failed to create directory for version file: $version_dir"
      return 1
    fi
  fi

  local current_version
  if [[ -f "$version_file" ]]; then
    current_version="$(tr -d ' \t\r\n' < "$version_file")"
  else
    current_version="0.1.0"
  fi

  # Preserve prefix/suffix when present
  if [[ "$current_version" =~ ^([vV])(.*)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    current_version="${BASH_REMATCH[2]}"
  fi
  suffix="${current_version#"${current_version%%-*}"}"
  normalized="${current_version%%-*}"

  local parsed
  if ! parsed=$(_version__parse_triplet "$normalized"); then
    return 1
  fi
  read -r major minor patch <<< "$parsed"

  case "$bump_type" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    patch)
      patch=$((patch + 1))
      ;;
  esac

  local new_core="${major}.${minor}.${patch}"
  local new_version="${prefix}${new_core}${suffix}"

  if ! printf "%s\n" "$new_version" > "$version_file"; then
    print_error "Failed to write version file: $version_file"
    return 1
  fi
  print_success "Bumped version: ${prefix}${normalized}${suffix} -> $new_version"
}

# Usage: version_offer_update [--label TEXT] [--hint TEXT] RUNNING LATEST COMMAND [ARG...]
#
# RUNNING older than LATEST and a person present (ui_mode is not none): ask,
# and on yes run COMMAND ARG... in this shell, returning its status (a COMMAND
# that execs replaces the caller, as an updater usually should). No person:
# print one line naming the update, and the hint (default: the command).
# Equal, newer or unreadable versions: nothing to offer, return 0. A declined
# offer is not a failure. --label names what is running ("App" -> "App 1.2.0
# is running"). Needs lib/dialog.sh for ui_mode and ui_yesno.
# Returns: 0 nothing to offer, declined, or no person present; 1 bad arguments, dialog.sh or ui_mode failed; else COMMAND's exit code.
# Output: stderr log_info/log_error lines; a dialog prompt when interactive.
version_offer_update() {
  local label="" hint=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) [[ $# -ge 2 ]] || { log_error "version_offer_update: --label needs a value"; return 1; }; label="${2:+$2 }"; shift 2 ;;
      --hint) [[ $# -ge 2 ]] || { log_error "version_offer_update: --hint needs a value"; return 1; }; hint="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local running="${1:-}" latest="${2:-}"
  [[ $# -ge 3 ]] || { log_error "version_offer_update: RUNNING, LATEST and COMMAND required"; return 1; }
  shift 2
  [[ -n "$hint" ]] || hint="$*"
  [[ -n "$running" && -n "$latest" ]] || return 0
  if ! declare -F ui_yesno >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
    # shellcheck source=/dev/null
    source "$_SHLIB_LIB_DIR/dialog.sh" || return 1
  fi
  local rc=0
  version_compare "$running" "$latest" >/dev/null 2>&1 || rc=$?
  # 255 means running < latest. 0 equal, 1 newer (a checkout ahead of its tags).
  [[ "$rc" -eq 255 ]] || return 0
  # An invalid SHLIB_UI is a misconfiguration to surface, not a silent "none".
  local mode; mode="$(ui_mode)" || return 1
  if [[ "$mode" == "none" ]]; then
    log_info "${label}$running is running; $latest is available: $hint"
    return 0
  fi
  if ui_yesno "Update available" "${label}$running is running and $latest is available. Run $hint now?"; then
    "$@"
    return $?
  fi
  log_info "Not updating. Later: $hint"
  return 0
}
