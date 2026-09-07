#!/usr/bin/env bash
# Docker installation helpers — Docker Engine on Linux, Docker Desktop on
# macOS and Windows, with explicit WSL handling.
#
# Companion to lib/docker.sh: that module assumes Docker exists and helps you
# drive it. This one gets it onto the machine in the first place, so a project
# bootstrap script can go from a bare host to a working `docker compose`
# without sending the operator off to read platform-specific install docs.
#
# Depends on: logging, os
#
# The functions here modify the system: they add package repositories, install
# system packages, and on Linux change group membership. They need sudo or
# Administrator rights. Nothing runs without an explicit confirmation unless
# the caller passes --yes.

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

# Usage: docker_cli_installed; success when the `docker` binary is on PATH.
docker_cli_installed() { command -v docker >/dev/null 2>&1; }

# Usage: docker_daemon_running; success when the CLI can reach a live daemon.
docker_daemon_running() { docker info >/dev/null 2>&1; }

# Usage: docker_compose_v2_available; success when `docker compose` works.
docker_compose_v2_available() { docker compose version >/dev/null 2>&1; }

# Usage: docker_ready; success only when CLI, daemon and compose v2 all work.
# This is the condition most projects actually care about.
docker_ready() {
  docker_cli_installed && docker_daemon_running && docker_compose_v2_available
}

# Usage: docker_install_status; prints one of:
#   ready | no-cli | no-daemon | no-compose
docker_install_status() {
  if ! docker_cli_installed; then echo "no-cli"; return 0; fi
  if ! docker_daemon_running; then echo "no-daemon"; return 0; fi
  if ! docker_compose_v2_available; then echo "no-compose"; return 0; fi
  echo "ready"
}

# Usage: docker_report_state; logs what is present. Returns 0 only when ready.
docker_report_state() {
  if ! docker_cli_installed; then
    log_warn "Docker CLI: not found"
    return 1
  fi
  log_info "Docker CLI: $(docker --version 2>/dev/null || echo 'present, version unknown')"
  if ! docker_daemon_running; then
    log_warn "Docker daemon: not reachable"
    return 1
  fi
  log_info "Docker daemon: reachable"
  if docker_compose_v2_available; then
    log_info "Compose plugin: $(docker compose version --short 2>/dev/null || echo present)"
  else
    log_warn "Compose plugin: not found ('docker compose' v2 unavailable)"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

# Module-scoped option state, reset by install_docker on every call.
_shlib_docker_dry_run=false
_shlib_docker_assume_yes=false
_shlib_docker_do_start=true
_shlib_docker_add_group=true
_shlib_docker_timeout=120

_shlib_docker_run() {
  if [[ "$_shlib_docker_dry_run" == true ]]; then
    echo "  [dry-run] $*" >&2
    return 0
  fi
  "$@"
}

_shlib_docker_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    _shlib_docker_run "$@"
  elif command -v sudo >/dev/null 2>&1; then
    _shlib_docker_run sudo "$@"
  else
    log_error "Root privileges needed for: $*"
    log_error "sudo is unavailable — re-run as root."
    return 1
  fi
}

_shlib_docker_confirm() {
  [[ "$_shlib_docker_assume_yes" == true ]] && return 0
  [[ "$_shlib_docker_dry_run" == true ]] && return 0
  if [[ ! -t 0 ]]; then
    log_error "No terminal attached and --yes was not passed."
    return 1
  fi
  local reply
  printf '%s ' "$1 [y/N]" >&2
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

_shlib_docker_distro_field() {
  # $1 = field name, e.g. ID, ID_LIKE, VERSION_CODENAME
  [[ -r /etc/os-release ]] || { echo ""; return 0; }
  # shellcheck source=/dev/null
  ( . /etc/os-release; echo "${!1:-}" )
}

# Usage: wait_for_docker_daemon [timeout_seconds]
# Polls `docker info` until it answers. Returns 1 on timeout.
wait_for_docker_daemon() {
  local timeout="${1:-$_shlib_docker_timeout}" waited=0
  if [[ ! "$timeout" =~ ^[1-9][0-9]*$ ]]; then
    log_error "wait_for_docker_daemon: timeout must be a positive integer."
    return 2
  fi
  [[ "$_shlib_docker_dry_run" == true ]] && return 0
  log_info "Waiting for the Docker daemon (up to ${timeout}s)…"
  while (( waited < timeout )); do
    if docker_daemon_running; then
      log_info "Docker daemon is up after ${waited}s."
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
    (( waited % 15 == 0 )) && log_info "  …still waiting (${waited}s)"
  done
  return 1
}

# ---------------------------------------------------------------------------
# Linux — Docker Engine from Docker's official repositories
# ---------------------------------------------------------------------------

_shlib_docker_install_apt() {
  local id codename arch line
  id="$(_shlib_docker_distro_field ID)"

  # Docker publishes repositories for debian and ubuntu only. Derivatives must
  # be mapped onto their upstream or the repository URL 404s.
  case "$id" in
    ubuntu|debian) ;;
    linuxmint|pop|neon|zorin|elementary) id="ubuntu" ;;
    raspbian|kali|parrot)                id="debian" ;;
    *)
      case " $(_shlib_docker_distro_field ID_LIKE) " in
        *" ubuntu "*) id="ubuntu" ;;
        *" debian "*) id="debian" ;;
        *) log_warn "Unrecognised apt distribution '$id' — assuming debian."; id="debian" ;;
      esac
      ;;
  esac

  # UBUNTU_CODENAME is the upstream release on derivatives; VERSION_CODENAME is
  # the derivative's own name, which Docker's repository does not know about.
  codename="$(_shlib_docker_distro_field UBUNTU_CODENAME)"
  [[ -n "$codename" ]] || codename="$(_shlib_docker_distro_field VERSION_CODENAME)"
  if [[ -z "$codename" ]]; then
    log_error "Cannot determine the distribution codename from /etc/os-release."
    return 1
  fi

  log_info "Installing Docker Engine from Docker's apt repository ($id / $codename)."

  _shlib_docker_sudo apt-get update -qq || return 1
  _shlib_docker_sudo apt-get install -y -qq ca-certificates curl gnupg || return 1
  _shlib_docker_sudo install -m 0755 -d /etc/apt/keyrings || return 1

  if [[ "$_shlib_docker_dry_run" == true ]]; then
    echo "  [dry-run] curl -fsSL https://download.docker.com/linux/$id/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" >&2
  else
    curl -fsSL "https://download.docker.com/linux/$id/gpg" \
      | _shlib_docker_sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg || return 1
    _shlib_docker_sudo chmod a+r /etc/apt/keyrings/docker.gpg || return 1
  fi

  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  line="deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$id $codename stable"
  if [[ "$_shlib_docker_dry_run" == true ]]; then
    echo "  [dry-run] echo '$line' > /etc/apt/sources.list.d/docker.list" >&2
  else
    echo "$line" | _shlib_docker_sudo tee /etc/apt/sources.list.d/docker.list >/dev/null || return 1
  fi

  _shlib_docker_sudo apt-get update -qq || return 1
  _shlib_docker_sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

_shlib_docker_install_dnf() {
  local id mgr
  id="$(_shlib_docker_distro_field ID)"
  mgr="dnf"; command -v dnf >/dev/null 2>&1 || mgr="yum"

  case "$id" in
    fedora) ;;
    rhel|centos|rocky|almalinux|ol) id="centos" ;;
    *)
      case " $(_shlib_docker_distro_field ID_LIKE) " in
        *" fedora "*) id="fedora" ;;
        *) id="centos" ;;
      esac
      ;;
  esac

  log_info "Installing Docker Engine from Docker's $mgr repository ($id)."

  _shlib_docker_sudo "$mgr" -y install dnf-plugins-core 2>/dev/null \
    || _shlib_docker_sudo "$mgr" -y install yum-utils || true

  if command -v dnf >/dev/null 2>&1; then
    _shlib_docker_sudo dnf config-manager --add-repo \
      "https://download.docker.com/linux/$id/docker-ce.repo" 2>/dev/null \
      || _shlib_docker_sudo dnf config-manager addrepo --from-repofile \
           "https://download.docker.com/linux/$id/docker-ce.repo" || return 1
  else
    _shlib_docker_sudo yum-config-manager --add-repo \
      "https://download.docker.com/linux/$id/docker-ce.repo" || return 1
  fi

  _shlib_docker_sudo "$mgr" -y install \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

_shlib_docker_install_zypper() {
  log_warn "Docker publishes no official SUSE repository — using the distribution package."
  _shlib_docker_sudo zypper --non-interactive install docker docker-compose
}

_shlib_docker_install_pacman() {
  log_info "Installing Docker from the Arch repositories."
  _shlib_docker_sudo pacman -Sy --noconfirm docker docker-compose
}

# Usage: docker_start_daemon; start the Linux daemon via systemd or service.
docker_start_daemon() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    _shlib_docker_sudo systemctl enable --now docker
  elif command -v service >/dev/null 2>&1; then
    _shlib_docker_sudo service docker start
  else
    log_warn "Neither systemd nor 'service' found — start the Docker daemon manually."
    return 1
  fi
}

# Usage: docker_add_user_to_group [user]
# Adds the user to the `docker` group so Docker works without sudo.
# Returns 10 when the group was added but the current shell cannot use it yet —
# group membership does not apply to an already-running session.
docker_add_user_to_group() {
  local user="${1:-${USER:-$(id -un)}}"

  if [[ "$(id -u)" -eq 0 ]]; then
    log_info "Running as root — no group change needed."
    return 0
  fi
  if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    log_info "User '$user' is already in the docker group."
    return 0
  fi

  log_warn "Membership of the 'docker' group is effectively root-equivalent."
  log_info "Adding '$user' to the docker group."
  _shlib_docker_sudo groupadd -f docker || return 1
  _shlib_docker_sudo usermod -aG docker "$user" || return 1

  log_warn "Group changes do not apply to your current shell."
  log_warn "Log out and back in, or run:  newgrp docker"
  return 10
}

_shlib_docker_install_linux() {
  if is_wsl; then
    log_info "WSL detected (${WSL_DISTRO_NAME:-unknown distro})."
    log_warn "Two options, and they are not equivalent:"
    log_warn "  1. Docker Desktop on Windows with WSL integration enabled (recommended)."
    log_warn "     Install from Windows, then Docker Desktop → Settings → Resources →"
    log_warn "     WSL Integration. One Docker shared across Windows and every distro."
    log_warn "  2. Docker Engine inside this distro — what continuing will do. WSL1"
    log_warn "     cannot run it; on WSL2 without systemd you must start the daemon"
    log_warn "     yourself each session ('sudo service docker start')."
    _shlib_docker_confirm "Install Docker Engine inside this WSL distro?" || {
      log_info "Nothing installed."
      return 1
    }
  fi

  if   command -v apt-get >/dev/null 2>&1; then _shlib_docker_install_apt || return 1
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    _shlib_docker_install_dnf || return 1
  elif command -v zypper >/dev/null 2>&1; then _shlib_docker_install_zypper || return 1
  elif command -v pacman >/dev/null 2>&1; then _shlib_docker_install_pacman || return 1
  else
    log_error "No supported package manager found (apt-get, dnf, yum, zypper, pacman)."
    log_error "Install Docker Engine manually: https://docs.docker.com/engine/install/"
    return 1
  fi

  [[ "$_shlib_docker_do_start" == true ]] && { docker_start_daemon || true; }

  if [[ "$_shlib_docker_add_group" == true ]]; then
    local rc=0
    docker_add_user_to_group || rc=$?
    return "$rc"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# macOS — Docker Desktop
# ---------------------------------------------------------------------------

_shlib_docker_install_mac() {
  local arch dmg_arch url dmg mnt
  arch="$(uname -m)"
  case "$arch" in
    arm64)  dmg_arch="arm64" ;;
    x86_64) dmg_arch="amd64" ;;
    *) log_error "Unsupported macOS architecture: $arch"; return 1 ;;
  esac

  if command -v brew >/dev/null 2>&1; then
    log_info "Installing Docker Desktop via Homebrew."
    # The cask was renamed from `docker` to `docker-desktop`; try the current
    # name first so this also works on older Homebrew installations.
    _shlib_docker_run brew install --cask docker-desktop || {
      log_warn "Cask 'docker-desktop' unavailable — trying legacy cask 'docker'."
      _shlib_docker_run brew install --cask docker || return 1
    }
  else
    log_info "Homebrew not found — downloading Docker Desktop directly ($dmg_arch)."
    url="https://desktop.docker.com/mac/main/${dmg_arch}/Docker.dmg"
    dmg="$(mktemp -d)/Docker.dmg"
    _shlib_docker_run curl -fsSL --retry 3 -o "$dmg" "$url" || {
      log_error "Download failed: $url"
      return 1
    }
    if [[ "$_shlib_docker_dry_run" == true ]]; then
      echo "  [dry-run] hdiutil attach / Docker.app install / detach" >&2
    else
      mnt="$(mktemp -d)"
      hdiutil attach "$dmg" -mountpoint "$mnt" -nobrowse -quiet || return 1
      # Docker's own installer sets up the app bundle and privileged helper.
      _shlib_docker_sudo "$mnt/Docker.app/Contents/MacOS/install" --accept-license || {
        hdiutil detach "$mnt" -quiet || true
        return 1
      }
      hdiutil detach "$mnt" -quiet || true
      rm -rf "$mnt" "$(dirname "$dmg")"
    fi
  fi

  if [[ "$_shlib_docker_do_start" == true ]]; then
    log_info "Launching Docker Desktop."
    _shlib_docker_run open -a Docker \
      || log_warn "Could not launch Docker Desktop — open it from Applications."
    log_info "First launch may ask for a password and takes a minute or two."
  fi
}

# ---------------------------------------------------------------------------
# Windows (Git Bash / MSYS2) — Docker Desktop
# ---------------------------------------------------------------------------

_shlib_docker_install_windows_fallback() {
  local url exe
  if command -v choco >/dev/null 2>&1; then
    log_info "Installing via Chocolatey."
    _shlib_docker_run choco install docker-desktop -y && return 0
    log_warn "Chocolatey install failed — falling back to the official installer."
  fi

  log_info "Downloading the official Docker Desktop installer."
  url="https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
  exe="$(mktemp -d)/DockerDesktopInstaller.exe"
  _shlib_docker_run curl -fsSL --retry 3 -o "$exe" "$url" || {
    log_error "Download failed. Install manually: https://docs.docker.com/desktop/install/windows-install/"
    return 1
  }
  log_info "Running the installer silently (several minutes)."
  _shlib_docker_run "$exe" install --quiet --accept-license || {
    log_error "Installer failed. Run it interactively: $exe"
    return 1
  }
}

_shlib_docker_install_windows() {
  local desktop_exe="/c/Program Files/Docker/Docker/Docker Desktop.exe"

  log_warn "Installing Docker Desktop needs Administrator rights."
  log_warn "If this fails with an elevation error, re-run your shell as Administrator."

  if command -v winget >/dev/null 2>&1; then
    log_info "Installing via winget."
    _shlib_docker_run winget install --id Docker.DockerDesktop -e --silent \
      --accept-package-agreements --accept-source-agreements || {
      log_warn "winget install failed — falling back."
      _shlib_docker_install_windows_fallback || return 1
    }
  else
    _shlib_docker_install_windows_fallback || return 1
  fi

  if [[ "$_shlib_docker_do_start" == true ]]; then
    if [[ -x "$desktop_exe" ]]; then
      log_info "Launching Docker Desktop."
      _shlib_docker_run "$desktop_exe" &
    else
      log_warn "Docker Desktop not at the default path — launch it from the Start menu."
    fi
    log_info "A reboot may be needed to finish enabling WSL2 or Hyper-V."
  fi
}

# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

# Usage: install_docker [--yes] [--dry-run] [--no-start] [--no-group] [--timeout N]
#
# Installs Docker for the detected platform. Idempotent: returns 0 immediately
# when Docker is already usable. When the CLI exists but the daemon does not
# respond it tries to start what is already installed before installing
# anything — a closed Docker Desktop is the common case and reinstalling is the
# wrong fix.
#
# Returns:
#   0  Docker is installed and the daemon is reachable
#   1  Installation failed, or the caller declined
#   2  Bad usage / unsupported platform
#   3  Installed, but the daemon did not come up before the timeout
install_docker() {
  _shlib_docker_dry_run=false
  _shlib_docker_assume_yes=false
  _shlib_docker_do_start=true
  _shlib_docker_add_group=true
  _shlib_docker_timeout=120

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)     _shlib_docker_assume_yes=true; shift ;;
      -n|--dry-run) _shlib_docker_dry_run=true; shift ;;
      --no-start)   _shlib_docker_do_start=false; shift ;;
      --no-group)   _shlib_docker_add_group=false; shift ;;
      --timeout)
        if [[ $# -lt 2 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
          log_error "install_docker: --timeout requires a positive integer."
          return 2
        fi
        _shlib_docker_timeout="$2"
        shift 2
        ;;
      *) log_error "install_docker: unknown option '$1'"; return 2 ;;
    esac
  done

  local os; os="$(get_os)"
  log_info "Docker installer — platform: $os$(is_wsl && echo ' (WSL)' || true)"

  if docker_ready; then
    docker_report_state
    log_info "Docker is already installed and working."
    return 0
  fi

  # CLI present but no daemon: try starting what is already there first.
  if docker_cli_installed && ! docker_daemon_running && [[ "$_shlib_docker_do_start" == true ]]; then
    log_warn "Docker CLI found but the daemon is unreachable — trying to start it."
    case "$os" in
      linux) docker_start_daemon || true ;;
      mac)   _shlib_docker_run open -a Docker >/dev/null 2>&1 || true ;;
      windows)
        local exe="/c/Program Files/Docker/Docker/Docker Desktop.exe"
        [[ -x "$exe" ]] && _shlib_docker_run "$exe" & ;;
    esac
    if wait_for_docker_daemon && docker_ready; then
      docker_report_state
      log_info "Docker is working now — no installation needed."
      return 0
    fi
    log_warn "Still unreachable — proceeding with installation."
  fi

  case "$os" in
    linux)   log_info "Plan: Docker Engine + compose plugin, start the daemon, add the current user to the docker group." ;;
    mac)     log_info "Plan: Docker Desktop (Homebrew cask, else the official .dmg), then launch it." ;;
    windows) log_info "Plan: Docker Desktop (winget, then Chocolatey, then the official installer), then launch it." ;;
    *)
      log_error "Unsupported platform: ${OSTYPE:-unknown}"
      log_error "Install Docker manually: https://docs.docker.com/get-docker/"
      return 2
      ;;
  esac

  log_warn "This modifies the system: package repositories, system packages, and on"
  log_warn "Linux group membership. Requires sudo or Administrator."
  _shlib_docker_confirm "Continue?" || { log_info "Aborted — nothing changed."; return 1; }

  local rc=0 group_pending=false
  case "$os" in
    linux)   _shlib_docker_install_linux   || rc=$? ;;
    mac)     _shlib_docker_install_mac     || rc=$? ;;
    windows) _shlib_docker_install_windows || rc=$? ;;
  esac

  # 10 from the Linux path means installed fine, but this shell has no docker
  # group yet. That is not a failure.
  if [[ "$rc" -eq 10 ]]; then group_pending=true; rc=0; fi
  if [[ "$rc" -ne 0 ]]; then
    log_error "Docker installation failed (exit $rc)."
    return 1
  fi

  if [[ "$_shlib_docker_dry_run" == true ]]; then
    log_info "Dry run complete — nothing was changed."
    return 0
  fi
  if [[ "$_shlib_docker_do_start" != true ]]; then
    log_info "Installed. Daemon not started (--no-start)."
    return 0
  fi

  if wait_for_docker_daemon; then
    docker_report_state || true
    log_info "Docker is ready."
    return 0
  fi

  log_warn "Installed, but the daemon did not become reachable in ${_shlib_docker_timeout}s."
  if [[ "$group_pending" == true ]]; then
    log_warn "Most likely your shell predates the docker group change."
    log_warn "Run:  newgrp docker   (or log out and back in)"
  elif [[ "$os" != "linux" ]]; then
    log_warn "Docker Desktop is probably still starting, or waiting on a prompt or reboot."
  else
    log_warn "Check the service:  systemctl status docker"
  fi
  return 3
}

# Usage: ensure_docker [install_docker options...]
# Idempotent guard for bootstrap scripts: succeed silently when Docker is
# already usable, otherwise install it. Returns install_docker's exit code.
ensure_docker() {
  if docker_ready; then
    log_debug "Docker already usable — nothing to do."
    return 0
  fi
  install_docker "$@"
}
