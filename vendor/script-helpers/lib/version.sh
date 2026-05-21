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

# Usage: version_bump {major|minor|patch} [-f VERSION_FILE]; bumps version file.
version_bump() {
  local bump_type="" version_file="" prefix="" suffix="" normalized current_dir

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
    version_file="VERSION"
  fi

  if [[ "$version_file" != /* ]]; then
    current_dir="$(pwd)"
    if declare -F get_project_root >/dev/null 2>&1; then
      current_dir="$(get_project_root)"
    fi
    version_file="${current_dir}/${version_file}"
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

  printf "%s\n" "$new_version" > "$version_file"
  print_success "Bumped version: ${prefix}${normalized}${suffix} -> $new_version"
}
