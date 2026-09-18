#!/usr/bin/env bash
# SCRIPT: docs_site.sh
# DESCRIPTION: Build, serve and validate the MkDocs documentation site locally.
# USAGE: ./scripts/docs_site.sh [serve|build|preview|check|deps|clean] [--port N] [--venv DIR] [-h]
# PARAMETERS:
#   serve     Run `mkdocs serve` with live reload. The default; what you use while writing.
#   build     Run `mkdocs build --strict` into ./site.
#   preview   Build, then serve ./site over HTTP through bin/serve-pages.
#   check     Build --strict into a temporary directory, assert the entry file and
#             the search index exist, then delete it. For CI and hooks.
#   deps      Create or refresh the documentation virtualenv and exit.
#   clean     Remove ./site and the virtualenv.
#   --port N  Port for serve/preview. Default 8000.
#   --venv D  Virtualenv location. Default: ${XDG_CACHE_HOME:-$HOME/.cache}/nr-docs-venv/ci-helpers
#   -h        Show this help message.
# EXIT CODES:
#   0 ok; 1 build or check failed; 2 bad arguments; 3 no usable python3.
#   serve_static_site's codes 2, 3 and 4 are passed through unchanged.
# EXAMPLE: ./scripts/docs_site.sh preview --port 8080
# ----------------------------------------------------
#
# `preview` is the mode that proves what actually ships, and the reason is
# specific: lunr fetches search_index.json over HTTP, so opening site/index.html
# from a file:// URL gives a site whose search silently returns nothing. Only an
# actual HTTP server over the built output exercises the link rewriting and the
# search index the way a visitor does. Do not "simplify" preview into serve.
#
# Why a virtualenv, and why outside the repository: MkDocs Material is a Python
# dependency of a Shell repository and has no business on the system Python of
# anyone who clones this. It lives in the user cache rather than the working
# tree because scripts/build_brew_tarball.sh rsyncs the whole tree excluding
# only .git and .env files, so a venv at the repository root would be shipped
# inside a Homebrew tarball. Keeping it out of the tree removes that surface
# rather than relying on an exclude list staying correct.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}/vendor/script-helpers}"
if [[ ! -f "${SCRIPT_HELPERS_DIR}/helpers.sh" ]]; then
  echo "docs_site: vendored script-helpers not found at ${SCRIPT_HELPERS_DIR}" >&2
  echo "docs_site: run ./scripts/sync_script_helpers.sh, or set SCRIPT_HELPERS_DIR" >&2
  exit 3
fi
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help python

mode="serve"
port="8000"
venv_dir="${DOCS_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/nr-docs-venv/ci-helpers}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    serve|build|preview|check|deps|clean) mode="$1"; shift ;;
    # Validated BEFORE the shift. `shift 2` with only one positional left
    # returns non-zero, and under `set -e` that killed the script before the
    # check below could say anything -- a trailing `--port` exited 1 in silence
    # while the header promised 2 and a message.
    --port)
      if [[ $# -lt 2 || ! "${2:-}" =~ ^[0-9]+$ ]]; then
        log_error "docs_site: --port expects a number, got '${2:-<nothing>}'"
        exit 2
      fi
      port="$2"; shift 2 ;;
    --venv)
      if [[ $# -lt 2 || -z "${2:-}" || "${2}" == -* ]]; then
        log_error "docs_site: --venv expects a directory, got '${2:-<nothing>}'"
        exit 2
      fi
      venv_dir="$2"; shift 2 ;;
    -h|--help) display_help "${BASH_SOURCE[0]}"; exit 0 ;;
    *) log_error "docs_site: unknown argument '$1' (try -h)"; exit 2 ;;
  esac
done

if [[ "$mode" == "clean" ]]; then
  rm -rf "${ROOT_DIR}/site" "$venv_dir"
  log_info "docs_site: removed ./site and ${venv_dir}"
  exit 0
fi

# Resolve an interpreter, build the venv, install the pinned toolchain, and
# print the mkdocs entry point. python_resolve_3 and python_ensure_venv come
# from lib/python.sh rather than being hand-rolled here.
ensure_venv() {
  local py venv_py
  if ! py="$(python_resolve_3 "" 3 9)"; then
    log_error "docs_site: no python3 >= 3.9 found; the documentation toolchain needs one"
    exit 3
  fi
  if ! venv_py="$(python_ensure_venv "$py" "$venv_dir")"; then
    log_error "docs_site: could not create a virtualenv at ${venv_dir}"
    exit 3
  fi
  # >&2: this function's stdout IS its return value (the mkdocs path), so
  # anything pip prints there would be prepended to it and produce a nonsense
  # path with a confusing "command not found". pip is quiet today; this makes it
  # structural rather than lucky.
  "$venv_py" -m pip install --quiet --disable-pip-version-check \
    -r "${ROOT_DIR}/requirements-docs.txt" >&2
  printf '%s' "${venv_dir}/bin/mkdocs"
}

mkdocs_bin="$(ensure_venv)"

case "$mode" in
  deps)
    log_info "docs_site: toolchain ready in ${venv_dir}"
    ;;
  serve)
    log_info "docs_site: live reload on http://127.0.0.1:${port}/ (Ctrl-C to stop)"
    exec "$mkdocs_bin" serve -a "127.0.0.1:${port}"
    ;;
  build)
    "$mkdocs_bin" build --strict
    log_info "docs_site: built ./site"
    ;;
  preview)
    "$mkdocs_bin" build --strict
    # Delegates to the existing wrapper rather than reimplementing a server:
    # lib/serve.sh already picks a free port and degrades python3 -> python ->
    # npx, and its exit codes 2/3/4 propagate untouched.
    exec bash "${SCRIPT_HELPERS_DIR}/bin/serve-pages" "${ROOT_DIR}/site" "$port"
    ;;
  check)
    out="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand $out now: it is gone by trap time otherwise
    trap "rm -rf '$out'" EXIT
    "$mkdocs_bin" build --strict --site-dir "$out"
    if [[ ! -f "$out/index.html" ]]; then
      log_error "docs_site: no index.html at the site root; the published site would serve 404"
      exit 1
    fi
    if [[ ! -s "$out/search/search_index.json" ]]; then
      log_error "docs_site: no search index was produced; search would silently find nothing"
      exit 1
    fi
    # MkDocs copies every file inside docs_dir into the output verbatim, so a
    # stray .bak, an editor swapfile or a script dropped in docs/ is published.
    # exclude_docs filters the names we thought of; this checks what actually
    # came out, which is the only version that catches the ones we did not.
    stray="$(cd "$out" && find . -type f \
      ! -name '*.html' ! -name '*.css' ! -name '*.js' ! -name '*.svg' \
      ! -name '*.png' ! -name '*.jpg' ! -name '*.gif' ! -name '*.ico' \
      ! -name '*.woff' ! -name '*.woff2' ! -name '*.json' ! -name '*.map' \
      ! -name '*.xml' ! -name '*.xml.gz' ! -name '*.txt')"
    if [[ -n "$stray" ]]; then
      log_error "docs_site: unexpected files in the built site — anything under docs/ is published verbatim:"
      printf '%s\n' "$stray" >&2
      exit 1
    fi
    log_info "docs_site: site builds clean ($(find "$out" -type f | wc -l | tr -d ' ') files)"
    ;;
esac
