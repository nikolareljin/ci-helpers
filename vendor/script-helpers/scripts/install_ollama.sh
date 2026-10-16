#!/usr/bin/env bash
# SCRIPT: install_ollama.sh
# DESCRIPTION: Install or upgrade Ollama from a checked source (ollama_install): the pinned release checked against its SHA-256, Homebrew on macOS, winget on Windows.
# USAGE: scripts/install_ollama.sh [--prefix <dir>] [--force] [--check] [-h]
# PARAMETERS:
#   --prefix <dir>  Install the release archive into this directory (bin/ollama, lib/ollama).
#                   Without it: /usr/local on Linux (sudo when needed), Homebrew on macOS,
#                   winget on Windows.
#   --force         Install even when the pinned version or a newer one is there.
#   --check         Say what is installed and what is pinned, and whether this would
#                   install, upgrade or do nothing. Changes nothing.
#   -h, --help      Show this help.
# EXIT_CODES:
#   0  installed, upgraded, or nothing to do (with --check: nothing to do)
#   1  the download failed or does not match the pinned SHA-256 (with --check: it would install or upgrade)
#   2  bad arguments
#   3  a required tool is missing, or this platform has no checkable source
# EXAMPLE:
#   scripts/install_ollama.sh --check
#   scripts/install_ollama.sh --prefix "$HOME/.local"
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging help ollama_install

args=()
check=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) display_help "$0"; exit 0 ;;
    --check) check=true; shift ;;
    --force) args+=(--force); shift ;;
    --prefix)
      [[ -n "${2:-}" ]] || { log_error "--prefix needs a directory"; exit 2; }
      args+=(--prefix "$2"); shift 2 ;;
    *) log_error "unknown option: $1"; display_help "$0"; exit 2 ;;
  esac
done

if [[ "$check" == true ]]; then
  pinned="$CI_DEFAULT_OLLAMA_VERSION"
  asset="$(ollama_install_asset 2>/dev/null || echo "none (no checkable archive for this platform)")"
  if have="$(ollama_installed_version)"; then
    where="$(command -v ollama)"
    if _ollama_install_at_least "$have" "$pinned"; then
      log_info "Ollama $have at $where; pinned $pinned. Nothing to do."
      exit 0
    fi
    log_info "Ollama $have at $where; pinned $pinned. It would be upgraded (archive: $asset)."
    exit 1
  fi
  log_info "No Ollama on PATH; pinned $pinned. It would be installed (archive: $asset)."
  exit 1
fi

rc=0
ollama_install ${args[@]+"${args[@]}"} || rc=$?
exit "$rc"
