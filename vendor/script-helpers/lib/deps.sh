#!/usr/bin/env bash
# Dependency installation helpers. May use sudo and network. Use cautiously.
#
# Expected imports by caller (via shlib_import): logging, os. ci_defaults and
# fetch are sourced here.

# Always sourced: ci_defaults only fills variables that are unset or empty.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/ci_defaults.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/fetch.sh"

# Usage: install_dependencies [package...]
# Generic multi-distro installer. Accepts a list of packages, or installs a common set.
# Returns: 1 no supported package manager; otherwise the exit code of the package manager install command.
# Output: stdout/stderr whatever the package manager prints; stdout an [Error!] message when none is found.
install_dependencies() {
  local pkgs=("$@")
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    pkgs=(dialog curl jq wget util-linux)
  fi

  if command -v apt-get >/dev/null 2>&1; then
    run_with_optional_sudo true apt-get update
    run_with_optional_sudo true apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    run_with_optional_sudo true dnf install -y "${pkgs[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    run_with_optional_sudo true pacman -S --noconfirm "${pkgs[@]}"
  elif command -v brew >/dev/null 2>&1; then
    brew install "${pkgs[@]}"
  else
    print_error "No supported package manager found. Please install: ${pkgs[*]} manually."
    return 1
  fi
}

# _deps_number <text>: <text> as a plain number when it is 1 to 4 digits, else
# 0. Leading zeros are dropped, so bash does not read "08" as octal.
_deps_number() {
  local v="${1:-}"
  [[ "$v" =~ ^[0-9]{1,4}$ ]] || v=0
  v="${v#"${v%%[!0]*}"}"
  printf '%s\n' "${v:-0}"
}

# Usage: _deps_node_major
# The major version of the node on PATH, or 0 when there is none or its
# version does not parse. Always a plain number, so it is safe in [[ -lt ]].
# Returns: 0.
# Output: stdout the number.
_deps_node_major() {
  local v=""
  # A node installed a moment ago is found, not a path bash remembered.
  hash -r 2>/dev/null || true
  if command -v node >/dev/null 2>&1; then
    v="$(node -v 2>/dev/null)" || v=""
  fi
  v="${v#v}"
  _deps_number "${v%%.*}"
}

# _deps_node_manual <major>: how to install Node.js by hand, on stderr.
_deps_node_manual() {
  print_error "Node.js $1 or newer was not installed. Install it by hand: https://nodejs.org/en/download (or the nodejs package of your distribution), then run this again." >&2
}

# _deps_node_restore <dir>: put NodeSource's keyring and source list back to
# what <dir>/old holds (the files before this run), or remove them when there
# were none.
_deps_node_restore() {
  local f dest
  for f in keyrings/nodesource.gpg sources.list.d/nodesource.list; do
    dest="/etc/apt/$f"
    if [[ -f "$1/old/${f##*/}" ]]; then
      run_with_optional_sudo true install -m 0644 "$1/old/${f##*/}" "$dest" || true
    else
      run_with_optional_sudo true rm -f -- "$dest" || true
    fi
  done
}

# Usage: _deps_install_node_linux <major>
# Node.js <major> or newer on a Debian or Ubuntu host. Nothing is run when the
# node on PATH is already new enough. The distribution's nodejs is installed
# when apt offers <major> or newer. Else NodeSource's apt repository is added:
# its key is fetched to a temp file and used only when it is exactly
# CI_DEFAULT_NODESOURCE_APT_FPR (fetch_verified_gpg_key). No remote script is
# run. A key that does not match writes nothing under /etc/apt, and a failed
# apt-get update puts the key and source list back as they were.
# Returns: 0 node is <major> or newer; 1 otherwise (stderr says what to do); 2 bad argument.
# Output: stdout [Info] progress and what apt prints; stderr errors.
_deps_install_node_linux() {
  local want="${1:-}" cand arch dir f
  if [[ ! "$want" =~ ^[1-9][0-9]{0,3}$ ]]; then
    print_error "_deps_install_node_linux: usage: _deps_install_node_linux <major>" >&2
    return 2
  fi
  [[ "$(_deps_node_major)" -ge "$want" ]] && return 0
  if ! command -v apt-get >/dev/null 2>&1; then
    _deps_node_manual "$want"
    return 1
  fi

  # The distribution's package, when it is new enough. An older one is not
  # installed first: NodeSource's nodejs would then have to replace it.
  # LC_ALL=C: "Candidate:" is translated in other locales.
  cand="$(LC_ALL=C apt-cache policy nodejs 2>/dev/null | awk '$1 == "Candidate:" && !n++ { print $2 }')"
  cand="${cand#*:}"; cand="$(_deps_number "${cand%%.*}")"
  if [[ "$cand" -ge "$want" ]]; then
    print_info "Installing Node.js from the distribution (nodejs $cand)..."
    run_with_optional_sudo true apt-get install -y nodejs || true
    [[ "$(_deps_node_major)" -ge "$want" ]] && return 0
  fi

  arch="$(dpkg --print-architecture 2>/dev/null)" || arch=""
  case "$arch" in
    amd64|arm64|armhf) ;;
    *)
      print_error "NodeSource has no Node.js $want packages for architecture '${arch:-unknown}'." >&2
      _deps_node_manual "$want"
      return 1
      ;;
  esac
  print_info "Installing Node.js $want from NodeSource's apt repository..."
  dir="$(mktemp -d "${TMPDIR:-/tmp}/shlib-deps-node.XXXXXX")" || return 1
  if ! chmod 700 "$dir" || ! mkdir -m 700 "$dir/gnupg"; then rm -rf -- "$dir"; return 1; fi
  # --homedir: gpg makes ~/.gnupg otherwise, even to dearmor.
  if ! fetch_verified_gpg_key deps "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
         "$CI_DEFAULT_NODESOURCE_APT_FPR" "$dir/key.asc" \
     || ! gpg --homedir "$dir/gnupg" --batch --yes --dearmor -o "$dir/nodesource.gpg" <"$dir/key.asc" \
     || [[ ! -s "$dir/nodesource.gpg" ]]; then
    rm -rf -- "$dir"
    print_error "NodeSource's signing key was not accepted. Nothing was written." >&2
    _deps_node_manual "$want"
    return 1
  fi
  printf '%s\n' "deb [arch=$arch signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${want}.x nodistro main" \
    >"$dir/nodesource.list"
  # A host that ran NodeSource's setup script before may have these files
  # already. They are kept, so a failure below puts them back.
  mkdir -m 700 "$dir/old" || { rm -rf -- "$dir"; return 1; }
  for f in keyrings/nodesource.gpg sources.list.d/nodesource.list; do
    if run_with_optional_sudo true test -f "/etc/apt/$f" \
       && ! run_with_optional_sudo true cat "/etc/apt/$f" >"$dir/old/${f##*/}"; then
      rm -rf -- "$dir"; print_error "Could not read /etc/apt/$f. Nothing was written." >&2; return 1
    fi
  done
  if ! run_with_optional_sudo true install -m 0755 -d /etc/apt/keyrings \
     || ! run_with_optional_sudo true install -m 0644 "$dir/nodesource.gpg" /etc/apt/keyrings/nodesource.gpg \
     || ! run_with_optional_sudo true install -m 0644 "$dir/nodesource.list" /etc/apt/sources.list.d/nodesource.list; then
    _deps_node_restore "$dir"
    rm -rf -- "$dir"
    print_error "Could not write NodeSource's key and source list under /etc/apt." >&2
    _deps_node_manual "$want"
    return 1
  fi
  # A source list apt cannot read breaks every later apt run, so it is taken
  # back out when the update fails, and the files it replaced are put back.
  if ! run_with_optional_sudo true apt-get update; then
    _deps_node_restore "$dir"
    rm -rf -- "$dir"
    print_error "apt-get update failed with NodeSource's repository added; the key and source list were put back as they were." >&2
    _deps_node_manual "$want"
    return 1
  fi
  rm -rf -- "$dir"
  if run_with_optional_sudo true apt-get install -y nodejs \
     && [[ "$(_deps_node_major)" -ge "$want" ]]; then
    return 0
  fi
  print_error "NodeSource's repository is set up (/etc/apt/sources.list.d/nodesource.list), but apt did not install Node.js $want." >&2
  _deps_node_manual "$want"
  return 1
}

# Usage: _deps_install_node_mac <major>
# Node.js <major> or newer on macOS: brew install node@<major>, then link it,
# because a versioned formula is keg-only and is not on PATH until linked.
# Returns: 0 node is <major> or newer; 1 otherwise; 2 bad argument.
# Output: stdout [Info] progress and what brew prints; stderr errors.
_deps_install_node_mac() {
  local want="${1:-}"
  if [[ ! "$want" =~ ^[1-9][0-9]{0,3}$ ]]; then
    print_error "_deps_install_node_mac: usage: _deps_install_node_mac <major>" >&2
    return 2
  fi
  [[ "$(_deps_node_major)" -ge "$want" ]] && return 0
  if command -v brew >/dev/null 2>&1; then
    print_info "Installing Node.js $want with Homebrew..."
    if brew install "node@$want" && brew link --overwrite --force "node@$want"; then
      [[ "$(_deps_node_major)" -ge "$want" ]] && return 0
    fi
  fi
  _deps_node_manual "$want"
  return 1
}

# Usage: install_dependencies_ai_runner
# Installer profile for the AI tooling consumers (R-643 and its runner)
# Returns: 1 a dependency cannot be installed on Windows, ollama_install failed, or Node.js CI_DEFAULT_NODE_APT_MAJOR could not be installed; otherwise 0 (failures of the other install steps are not checked).
# Output: stdout [Info]/[Warning!]/[Error!] progress; stdout/stderr whatever the installers print.
install_dependencies_ai_runner() {
  local os; os=$(get_os)
  # No nodejs here: the Node.js step below installs the pinned major, once.
  local deps=(dialog curl jq python3 python3-pip)
  local dep node_rc=0
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      print_info "$dep is not installed. Installing..."
      case "$os" in
        linux) run_with_optional_sudo true apt-get install -y "$dep";;
        mac) brew install "$dep";;
        windows) print_error "$dep is not supported on Windows. Please install manually."; return 1;;
      esac
    else
      print_info "$dep is already installed."
    fi
  done

  # Ollama: the pinned release, checked against its SHA-256 (lib/ollama_install.sh),
  # not the one-line installer, which runs whatever script the server returns.
  # Called whether or not one is there: an older Ollama is upgraded, a current
  # one is left alone.
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/ollama_install.sh"
  ollama_install || return 1

  # Git
  if ! command -v git >/dev/null 2>&1; then
    print_info "Git is not installed. Installing..."
    case "$os" in
      linux) run_with_optional_sudo true apt-get install -y git ;;
      mac) brew install git ;;
      windows) print_error "Git is not supported on Windows. Install manually."; return 1 ;;
    esac
  fi

  # Clipboard utilities
  case "$os" in
    linux)
      if ! command -v xclip >/dev/null 2>&1; then
        print_info "Installing xclip..."
        run_with_optional_sudo true apt-get install -y xclip
      fi
      ;;
    mac)
      if ! command -v pbcopy >/dev/null 2>&1; then
        print_warning "pbcopy should be available on macOS; ensure Xcode CLI tools installed."
      fi
      ;;
    windows)
      print_error "Clipboard utility not supported in this shell on Windows."
      ;;
  esac

  # Node.js: the major pinned in ci_defaults, from a package repository whose
  # signing key is checked. Never a remote script run as root. A failure is
  # reported at the end, after the remaining steps.
  case "$os" in
    linux) _deps_install_node_linux "$CI_DEFAULT_NODE_APT_MAJOR" || node_rc=1 ;;
    mac) _deps_install_node_mac "$CI_DEFAULT_NODE_APT_MAJOR" || node_rc=1 ;;
    windows)
      if [[ "$(_deps_node_major)" -lt "$CI_DEFAULT_NODE_APT_MAJOR" ]]; then
        _deps_node_manual "$CI_DEFAULT_NODE_APT_MAJOR"
        node_rc=1
      fi
      ;;
  esac

  # npx
  if ! command -v npx >/dev/null 2>&1; then
    print_info "Installing npm (for npx)..."
    case "$os" in
      linux) run_with_optional_sudo true apt-get install -y npm ;;
      mac) brew install npm ;;
    esac
  fi

  # pip3
  if ! command -v pip3 >/dev/null 2>&1; then
    print_info "Installing pip3..."
    case "$os" in
      linux) run_with_optional_sudo true apt-get install -y python3-pip ;;
      mac) brew install python3 ;;
    esac
  fi
  [[ "$node_rc" -eq 0 ]] || return 1
}
