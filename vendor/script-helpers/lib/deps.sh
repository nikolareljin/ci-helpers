#!/usr/bin/env bash
# Dependency installation helpers. May use sudo and network. Use cautiously.

# Generic multi-distro installer. Accepts a list of packages, or installs a common set.
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

# AI Runner / HelperGPT specific installer profile
install_dependencies_ai_runner() {
  local os; os=$(get_os)
  local deps=(dialog curl jq python3 python3-pip nodejs)
  local dep
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

  # Ollama
  if ! command -v ollama >/dev/null 2>&1; then
    print_info "Ollama is not installed. Installing..."
    case "$os" in
      linux) curl -fsSL https://ollama.com/install.sh | sh ;;
      mac) brew install ollama/tap/ollama ;;
      windows) print_error "Ollama is not supported on Windows. Install manually."; return 1 ;;
    esac
  fi

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

  # Node.js >= 20
  case "$os" in
    linux)
      if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt 20 ]]; then
        print_info "Installing/upgrading Node.js to 20..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        run_with_optional_sudo true apt-get install -y nodejs
      fi
      ;;
    mac)
      if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt 20 ]]; then
        print_info "Installing/upgrading Node.js to 20..."
        brew install node@20
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
}

