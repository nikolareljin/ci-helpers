#!/usr/bin/env bash
# SCRIPT: docs_site.sh
# DESCRIPTION: Build, serve, preview and verify a repository's documentation site (lib/docs_site.sh).
# USAGE: docs_site.sh [check|build|serve|preview|verify|deps|clean] [--dir REPO] [--port N] [--venv DIR] [-h]
# PARAMETERS:
#   check     Build into a temporary directory and prove it: no unclosed code fence,
#             an entry page and search index, nothing published by accident, and every
#             page, link and asset answering over HTTP. For CI and hooks.
#   build     Build into the site directory (MkDocs: --strict).
#   serve     Live reload while writing (MkDocs); preview for a command generator. The default.
#   preview   Build, then serve the built site over HTTP: what a visitor gets.
#   verify    Crawl an already built site directory over HTTP (--dir is that directory).
#   deps      Create or refresh the documentation virtualenv and exit.
#   clean     Remove the built site and the virtualenv.
#   --dir R   The repository (default: the git repository of the current directory).
#   --port N  Port for serve and preview (default DOCS_SITE_PORT or 8000). A taken port is
#             asked about on a terminal; without one it is an error naming the owner.
#   --venv D  Virtualenv (default ~/.cache/nr-docs-venv/<repo>).
#   -h        Show this help message.
# EXIT CODES:
#   0 ok; 1 build or check failed, or a taken port with nobody to ask;
#   2 bad arguments or no site here; 3 no usable python3.
# EXAMPLE: scripts/script-helpers/scripts/docs_site.sh preview --port 8080
# ----------------------------------------------------
#
# Every repository runs its site through this, so `make docs`, `./dev docs`
# and CI mean the same thing everywhere. The settings (generator, a custom
# build command, output directory) are documented in lib/docs_site.sh.
# ----------------------------------------------------
set -euo pipefail

SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SH_DIR}/helpers.sh"
shlib_import logging help python ports serve docs_site

mode="serve"
repo=""
port=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    check|build|serve|preview|verify|deps|clean) mode="$1"; shift ;;
    # Validated before the shift: `shift 2` with one argument left fails
    # under set -e and exits 1 in silence.
    --port)
      if [[ $# -lt 2 || ! "${2:-}" =~ ^[0-9]+$ ]]; then
        log_error "docs_site: --port expects a number, got '${2:-<nothing>}'"
        exit 2
      fi
      port="$2"; shift 2 ;;
    --dir)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        log_error "docs_site: --dir expects a directory"
        exit 2
      fi
      repo="$2"; shift 2 ;;
    --venv)
      if [[ $# -lt 2 || -z "${2:-}" || "${2}" == -* ]]; then
        log_error "docs_site: --venv expects a directory, got '${2:-<nothing>}'"
        exit 2
      fi
      export DOCS_VENV="$2"; shift 2 ;;
    -h|--help) display_help "${BASH_SOURCE[0]}"; exit 0 ;;
    *) log_error "docs_site: unknown argument '$1' (try -h)"; exit 2 ;;
  esac
done

if [[ -z "$repo" ]]; then
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || repo="$PWD"
fi

case "$mode" in
  check)   docs_site_check "$repo" ;;
  build)   docs_site_build "$repo" && log_info "docs_site: built $(docs_site_out "$repo")" ;;
  serve)   docs_site_serve "$repo" "$port" ;;
  preview) docs_site_preview "$repo" "$port" ;;
  verify)  docs_site_verify "$repo" ;;
  deps)    docs_site_toolchain "$repo" >/dev/null && log_info "docs_site: toolchain ready" ;;
  clean)
    # Both paths come from settings (site_dir, DOCS_SITE_OUT, --venv), so
    # neither is removed unless it is what it claims to be: the output inside
    # the repository, and a virtualenv.
    repo="$(cd "$repo" && pwd -P)"
    out="$(docs_site_out "$repo")"
    if [[ -e "$out" ]]; then
      out_real="$(cd "$out" && pwd -P)"
      case "$out_real" in
        "$repo"/?*) rm -rf "$out_real"; log_info "docs_site: removed ${out_real}" ;;
        *) log_error "docs_site: not removing ${out_real}: the site directory must be inside ${repo}"; exit 1 ;;
      esac
    fi
    venv="${DOCS_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/nr-docs-venv/$(basename "$repo")}"
    if [[ -e "$venv" ]]; then
      if [[ -f "$venv/pyvenv.cfg" ]]; then
        rm -rf "$venv"; log_info "docs_site: removed the virtualenv ${venv}"
      else
        log_error "docs_site: not removing ${venv}: it is not a virtualenv (no pyvenv.cfg)"; exit 1
      fi
    fi
    ;;
esac
