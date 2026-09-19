#!/usr/bin/env bash
# File/dir and checksum helpers

# Usage: command_exists <command>; returns 0 when command is available.
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Usage: directory_exists <path>; returns 0 if directory exists.
directory_exists() { [[ -d "$1" ]]; }
# Usage: file_exists <path>; returns 0 if file exists.
file_exists() { [[ -f "$1" ]]; }

# Usage: create_directory <path>; creates directory if missing.
create_directory() {
  if ! directory_exists "$1"; then
    mkdir -p "$1" && { echo "Directory $1 created."; return 0; }
    echo "Failed to create directory $1" >&2; return 1
  else
    echo "Directory $1 already exists."; return 0
  fi
}

# Usage: download_file <url> [output]; downloads quietly with optional dialog.
download_file() {
  local url="$1"; local output="${2:-}"
  if [[ -z "$output" ]]; then
    output=$(basename "$url")
    if [[ "$output" != *.* ]]; then
      output=$(echo "$url" | sed -E 's|.*/([^/]+\.[^/]+)(/.*)?$|\1|')
    fi
  fi
  # Stay quiet during download; the dialog gauge (if used)
  # should be the only visible interface.

  # Prefer dialog gauge when enabled and available
  # Control via env var DOWNLOAD_USE_DIALOG: auto (default), true/1, false/0, never
  local use_dialog="${DOWNLOAD_USE_DIALOG:-auto}"
  if [[ "$use_dialog" != "false" && "$use_dialog" != "0" && "$use_dialog" != "never" ]]; then
    if command_exists dialog; then
      # Ensure dialog_download_file is available; try sourcing if missing
      if ! declare -F dialog_download_file >/dev/null 2>&1; then
        local _lib_dialog="${SCRIPT_HELPERS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib/dialog.sh"
        # shellcheck disable=SC1090
        [[ -f "$_lib_dialog" ]] && source "$_lib_dialog"
      fi
      if declare -F dialog_download_file >/dev/null 2>&1; then
        if dialog_download_file "$url" "$output" auto; then
          return 0
        else
          : # fall through to non-dialog download quietly
        fi
      fi
    fi
  fi

  # Fallback to curl/wget without dialog
  local rc=0 part
  if ! command_exists curl && ! command_exists wget; then
    print_error "Neither curl nor wget is installed."
    return 1
  fi
  # Into a temporary file beside the destination, moved into place only on
  # success: no partial or error-page file is left where the caller expects
  # the download, and a file already there survives a failed one.
  part="$(mktemp "$output.XXXXXX")" || return 1
  # mktemp makes the file 0600; a download gets the mode curl would give it.
  chmod "$(printf '%o' $(( 0666 & ~0$(umask) )))" "$part" 2>/dev/null || true
  if command_exists curl; then
    # -sS: silent progress, show errors only. -f: an HTTP error is a failure;
    # without it a 404 page was saved as the download and returned 0.
    curl --max-time 3600 -f -sS -L -o "$part" "$url" || rc=$?
  else
    # -q: quiet output
    wget -q --timeout=3600 -O "$part" "$url" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$part"
    return "$rc"
  fi
  if [[ -e "$output" || -L "$output" ]]; then
    # Written through the existing path, as curl -o always did: the file keeps
    # its mode (a downloaded script stays executable) and a symlink stays a link.
    cat "$part" >"$output" || { rm -f "$part"; return 1; }
    rm -f "$part"
  else
    mv -f "$part" "$output" || { rm -f "$part"; return 1; }
  fi
  return 0
}

# Usage: is_valid_iso <path>; returns 0 if ISO signature is detected.
is_valid_iso() { file "$1" | grep -q "ISO 9660"; }
# Usage: is_valid_checksum <path>; returns 0 if checksum file looks like text.
is_valid_checksum() { file "$1" | grep -q "ASCII text"; }

# Usage: verify_checksum <iso_file> <checksum_file> [checksum_type]; checks hashes.
verify_checksum() {
  local iso_file="$1"; local checksum_file="$2"; local checksum_type="${3:-sha256sum}"
  if ! is_valid_iso "$iso_file"; then
    print_error "$iso_file is not a valid ISO image."
    return 1
  fi
  if ! is_valid_checksum "$checksum_file"; then
    print_error "$checksum_file is not a valid checksum file."
    return 1
  fi
  if command_exists "$checksum_type"; then
    # The entry for THIS file, compared against THIS file's hash. `-c` over
    # the whole list passed whenever any entry in it said OK, whichever file
    # was asked about -- including a list that never mentions it.
    local expected actual
    expected="$(_verify_checksum_expected "$checksum_file" "$(basename "$iso_file")")"
    if [[ -z "$expected" ]]; then
      print_error "No checksum entry for $(basename "$iso_file") in $checksum_file."
      print_error "Checksum verification failed for $iso_file."
      return 1
    fi
    # shasum defaults to SHA-1 whatever the list holds (`shasum -c` chose the
    # algorithm from the digest length), so choose it the same way here.
    local -a hash_cmd=("$checksum_type")
    if [[ "$checksum_type" == "shasum" ]]; then
      case "${#expected}" in
        40) hash_cmd+=(-a 1) ;;
        56) hash_cmd+=(-a 224) ;;
        64) hash_cmd+=(-a 256) ;;
        96) hash_cmd+=(-a 384) ;;
        128) hash_cmd+=(-a 512) ;;
      esac
    fi
    actual="$("${hash_cmd[@]}" "$iso_file" 2>/dev/null | awk '{print $1; exit}')"
    actual="${actual#\\}"
    expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
    actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
    if [[ -n "$actual" && "$actual" == "$expected" ]]; then
      print_success "Checksum verification successful for $iso_file."
      return 0
    else
      print_error "Checksum verification failed for $iso_file."
      return 1
    fi
  else
    print_error "$checksum_type is not installed."
    return 1
  fi
}

# Internal: print the expected hash for file name NAME from a checksum list.
# Usage: _verify_checksum_expected CHECKSUM_FILE NAME
# Understands `HASH  name`, `HASH *name` (binary mode) and the tagged
# `ALGO (name) = HASH` form; a listed path matches on its basename.
_verify_checksum_expected() {
  _VC_NAME="$2" awk '
    function base(p) { sub(/^.*\//, "", p); return p }
    BEGIN { want = ENVIRON["_VC_NAME"] }
    {
      line = $0; sub(/\r$/, "", line)
      if (match(line, /^\\?[0-9A-Fa-f]+ [ *]/)) {
        h = substr(line, 1, RLENGTH - 2); sub(/^\\/, "", h)
        f = substr(line, RLENGTH + 1)
        if (base(f) == want) { print h; exit }
      } else if (match(line, /^[A-Za-z0-9-]+ \(.*\) = [0-9A-Fa-f]+$/)) {
        f = line; sub(/^[A-Za-z0-9-]+ \(/, "", f); sub(/\) = [0-9A-Fa-f]+$/, "", f)
        h = line; sub(/^.* = /, "", h)
        if (base(f) == want) { print h; exit }
      }
    }
  ' "$1"
}

# The DISTROS-based selectors here take an associative array *from the caller*,
# which is the one thing in this library that genuinely cannot work on bash 3.2.
# os.sh carries require_bash4, which says so with an actionable message; load it
# the way screencap.sh loads its optional modules.
if ! declare -f require_bash4 >/dev/null 2>&1; then
  if [[ -n "${_SHLIB_LIB_DIR:-}" && -f "${_SHLIB_LIB_DIR}/os.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_SHLIB_LIB_DIR}/os.sh"
  fi
fi

# Convenience used by iso-forge: expects DISTROS associative array defined by caller
download_iso() {
  require_bash4 "download_iso (DISTROS associative array)" || return 1
  local distro_name="$1"
  local url="${DISTROS[$distro_name]}"
  if [[ -z "$url" ]]; then
    print_error "No URL found for $distro_name."
    return 1
  fi
  local output; output=$(basename "$url")
  if [[ "$output" != *.* ]]; then
    output=$(echo "$url" | sed -E 's|.*/([^/]+\.[^/]+)(/.*)?$|\1|')
  fi
  if file_exists "$output"; then
    # Skip means skip: this used to say so and then download over it anyway.
    print_warning "File $output already exists. Skipping download."
  else
    download_file "$url" "$output" || return 1
    print_success "Download completed: $output"
  fi
  if is_valid_iso "$output"; then
    print_success "$output is a valid ISO image."
    return 0
  else
    print_error "$output is not a valid ISO image."
    return 1
  fi
}
