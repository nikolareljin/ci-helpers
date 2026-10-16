#!/usr/bin/env bash
# docs_site.sh - build, serve, preview and verify a repository's documentation
# site, the same way in every repository. Part of script-helpers.
#
#   shlib_import logging python ports serve docs_site
#   docs_site_check   <repo>          # what CI and pre-push run
#   docs_site_build   <repo> [out]
#   docs_site_serve   <repo> [port]   # live reload while writing
#   docs_site_preview <repo> [port]   # the built site over HTTP: what ships
#   docs_site_verify  <site dir>      # crawl a built site over HTTP
#
# Generators:
#   mkdocs   a mkdocs.yml at the repository root (the default when one is there)
#   command  DOCS_SITE_BUILD_CMD builds into DOCS_SITE_OUT; for repositories
#            with their own builder. serve is then the same as preview.
#
# Settings (environment, or scripts/project.sh):
#   DOCS_SITE_GENERATOR   mkdocs | command; detected when unset
#   DOCS_SITE_BUILD_CMD   command generator: run from the repository root
#   DOCS_SITE_OUT         command generator: its output directory (default site)
#   DOCS_SITE_REQUIREMENTS  mkdocs: the pinned toolchain; default the
#                         repository's requirements-docs.txt, else this
#                         library's (one set of pins for every repository)
#   DOCS_SITE_PORT        serve and preview (default 8000); a taken port is
#                         asked about on a terminal and refused without one
#   DOCS_VENV             mkdocs: virtualenv (default ~/.cache/nr-docs-venv/<repo>)
#   DOCS_SITE_ALLOW_EXT   mkdocs: more file extensions the site publishes on
#                         purpose, space separated (for example "zip csv")
#
# Exit codes: 0 ok; 1 build or check failed, or a port is taken with nobody
# to ask; 2 bad arguments or no generator; 3 no usable python3.

# Its own needs, so `shlib_import docs_site` alone is enough.
if declare -F shlib_import >/dev/null 2>&1; then
  for _docs_site__need in logging:log_error python:python_resolve_3 ports:port_choose serve:serve_static_site; do
    declare -F "${_docs_site__need#*:}" >/dev/null 2>&1 || shlib_import "${_docs_site__need%%:*}"
  done
  unset _docs_site__need
fi

_docs_site__lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_docs_site__root="$(cd "${_docs_site__lib_dir}/.." && pwd)"

# Internal: the repository root, as an absolute path; fails on a non-directory.
_docs_site__repo() {
  local repo="${1:-.}"
  if [[ ! -d "$repo" ]]; then
    log_error "docs_site: not a directory: '${repo}'"
    return 2
  fi
  (cd "$repo" && pwd)
}

# Usage: docs_site_generator <repo>; prints mkdocs or command.
docs_site_generator() {
  local repo
  repo="$(_docs_site__repo "${1:-.}")" || return 2
  case "${DOCS_SITE_GENERATOR:-}" in
    mkdocs|command) printf '%s\n' "$DOCS_SITE_GENERATOR"; return 0 ;;
    "") ;;
    *) log_error "docs_site: DOCS_SITE_GENERATOR is mkdocs or command, not '${DOCS_SITE_GENERATOR}'"; return 2 ;;
  esac
  if [[ -n "${DOCS_SITE_BUILD_CMD:-}" ]]; then printf 'command\n'; return 0; fi
  if [[ -f "$repo/mkdocs.yml" || -f "$repo/mkdocs.yaml" ]]; then printf 'mkdocs\n'; return 0; fi
  log_error "docs_site: no site here: no mkdocs.yml in ${repo}, and DOCS_SITE_BUILD_CMD is not set"
  return 2
}

# Usage: docs_site_toolchain <repo>; prints the mkdocs entry point, after
# creating or refreshing the virtualenv from the pinned requirements.
docs_site_toolchain() {
  local repo req venv py venv_py
  repo="$(_docs_site__repo "${1:-.}")" || return 2
  req="${DOCS_SITE_REQUIREMENTS:-}"
  if [[ -z "$req" ]]; then
    req="$repo/requirements-docs.txt"
    [[ -f "$req" ]] || req="${_docs_site__root}/requirements-docs.txt"
  fi
  if [[ ! -f "$req" ]]; then
    log_error "docs_site: requirements file not found: ${req}"
    return 2
  fi
  # Outside the tree: a venv in the repository is shipped by anything that
  # copies the tree, and published by MkDocs if it lands under docs/.
  venv="${DOCS_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/nr-docs-venv/$(basename "$repo")}"
  if ! py="$(python_resolve_3 "" 3 9)"; then
    log_error "docs_site: no python3 >= 3.9 found; the documentation toolchain needs one"
    return 3
  fi
  if ! venv_py="$(python_ensure_venv "$py" "$venv")"; then
    log_error "docs_site: could not create a virtualenv at ${venv}"
    return 3
  fi
  "$venv_py" -m pip install --quiet --disable-pip-version-check -r "$req" >&2 || return 1
  printf '%s\n' "${venv}/bin/mkdocs"
}

# Usage: docs_site_out <repo>; prints where the build writes.
docs_site_out() {
  local repo gen dir
  repo="$(_docs_site__repo "${1:-.}")" || return 2
  gen="$(docs_site_generator "$repo")" || return 2
  if [[ "$gen" == "command" ]]; then
    dir="${DOCS_SITE_OUT:-site}"
  else
    # site_dir from mkdocs.yml when it is a plain value, else MkDocs' default.
    dir="$(sed -n 's/^site_dir:[[:space:]]*["'\'']\{0,1\}\([^"'\''#]*\).*/\1/p' "$repo"/mkdocs.y*ml 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')"
    dir="${dir:-site}"
  fi
  case "$dir" in /*) printf '%s\n' "$dir" ;; *) printf '%s\n' "$repo/$dir" ;; esac
}

# Usage: docs_site_build <repo> [out]; builds the site, strictly.
docs_site_build() {
  local repo gen out mkdocs
  repo="$(_docs_site__repo "${1:-.}")" || return 2
  gen="$(docs_site_generator "$repo")" || return 2
  if [[ "$gen" == "command" ]]; then
    # The builder chooses its own output; [out] does not apply to it.
    (cd "$repo" && bash -c "$DOCS_SITE_BUILD_CMD") || { log_error "docs_site: the build command failed: ${DOCS_SITE_BUILD_CMD}"; return 1; }
    return 0
  fi
  out="${2:-$(docs_site_out "$repo")}"
  mkdocs="$(docs_site_toolchain "$repo")" || return $?
  (cd "$repo" && "$mkdocs" build --strict --site-dir "$out") || return 1
}

# Usage: docs_site_verify <site dir>; fetches every page, link and asset over
# HTTP and reports what does not answer (scripts/site_verify.py).
docs_site_verify() {
  local dir="${1:-}"
  if [[ ! -d "$dir" ]]; then
    log_error "docs_site: no built site at '${dir}'"
    return 2
  fi
  python3 "${_docs_site__root}/scripts/site_verify.py" "$dir"
}

# Internal: the docs directory of a MkDocs site (docs_dir, default docs).
_docs_site__docs_dir() {
  local repo="$1" dir
  dir="$(sed -n 's/^docs_dir:[[:space:]]*["'\'']\{0,1\}\([^"'\''#]*\).*/\1/p' "$repo"/mkdocs.y*ml 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')"
  printf '%s\n' "$repo/${dir:-docs}"
}

# Usage: docs_site_stray_files <site dir>; lists, and fails on, files a site
# should not publish. MkDocs copies every file under docs_dir verbatim, so a
# .bak, a script or a swapfile dropped in docs/ is published. Web assets,
# fonts, documents and media a site links on purpose are kept, plus the
# extensions in DOCS_SITE_ALLOW_EXT. Returns 0 none, 1 some (listed).
docs_site_stray_files() {
  local out="${1:-}" ext stray
  [[ -d "$out" ]] || { log_error "docs_site: no built site at '${out}'"; return 2; }
  local -a keep=(html css js mjs map json xml xml.gz txt svg png jpg jpeg gif ico webp avif
    woff woff2 ttf otf eot pdf webmanifest mp4 webm mp3 ogg)
  for ext in ${DOCS_SITE_ALLOW_EXT:-}; do keep+=("${ext#.}"); done
  local -a not_kept=()
  for ext in "${keep[@]}"; do not_kept+=(! -name "*.${ext}"); done
  stray="$(cd "$out" && find . -type f "${not_kept[@]}" ! -name 'CNAME' ! -name '.nojekyll')"
  [[ -z "$stray" ]] && return 0
  log_error "docs_site: unexpected files in the built site; anything under docs/ is published verbatim:"
  printf '%s\n' "$stray" >&2
  return 1
}

# Internal: does the MkDocs site have search? MkDocs adds it unless a
# plugins: list is given without it.
_docs_site__wants_search() {
  local cfg
  cfg="$(cat "$1"/mkdocs.y*ml 2>/dev/null)" || return 0
  grep -q '^plugins:' <<<"$cfg" || return 0
  grep -qE '^[[:space:]]*-[[:space:]]*search([[:space:]:]|$)' <<<"$cfg"
}

# Usage: docs_site_check <repo>; build into a temporary directory and prove it:
# no unclosed code fence in the sources, an entry page, a search index
# (MkDocs), nothing published by accident, and every link answering over HTTP.
# Writes nothing in the repository (the command generator writes its own
# output, which is then verified where it is).
docs_site_check() {
  local repo gen out docs rc=0
  repo="$(_docs_site__repo "${1:-.}")" || return 2
  gen="$(docs_site_generator "$repo")" || return 2
  if [[ "$gen" == "mkdocs" ]]; then
    docs="$(_docs_site__docs_dir "$repo")"
    if [[ -d "$docs" ]]; then
      python3 "${_docs_site__root}/scripts/site_verify.py" --fences "$docs" || return 1
    fi
    out="$(mktemp -d)" || return 1
    docs_site_build "$repo" "$out" || rc=$?
  else
    docs_site_build "$repo" || rc=$?
    out="$(docs_site_out "$repo")"
  fi
  if [[ "$rc" -eq 0 && "$gen" == "mkdocs" ]]; then
    if [[ ! -s "$out/search/search_index.json" ]] && _docs_site__wants_search "$repo"; then
      log_error "docs_site: no search index was produced; search would silently find nothing"
      rc=1
    fi
    docs_site_stray_files "$out" || rc=1
  fi
  if [[ "$rc" -eq 0 ]]; then
    docs_site_verify "$out" || rc=1
  fi
  if [[ "$rc" -eq 0 ]]; then
    log_info "docs_site: site builds clean, every link answers ($(find "$out" -type f | wc -l | tr -d ' ') files)"
  fi
  [[ "$gen" != "mkdocs" ]] || rm -rf "$out"
  return "$rc"
}

# Internal: the port to serve on, from [port], DOCS_SITE_PORT or 8000; a
# taken one is asked about, or refused with the fix named (port_choose).
_docs_site__port() {
  port_choose "${1:-${DOCS_SITE_PORT:-8000}}" "--port N, or DOCS_SITE_PORT=N"
}

# Usage: docs_site_preview <repo> [port]; build, then serve the built site
# over HTTP. Search and link rewriting only work over HTTP, not file://.
docs_site_preview() {
  local repo out port
  repo="$(_docs_site__repo "${1:-.}")" || return 2
  port="$(_docs_site__port "${2:-}")" || return $?
  docs_site_build "$repo" || return $?
  out="$(docs_site_out "$repo")"
  serve_static_site "$out" "$port"
}

# Usage: docs_site_serve <repo> [port]; live reload while writing (MkDocs).
# A command generator has no live mode, so this is preview for it.
docs_site_serve() {
  local repo gen port mkdocs path
  repo="$(_docs_site__repo "${1:-.}")" || return 2
  gen="$(docs_site_generator "$repo")" || return 2
  [[ "$gen" == "mkdocs" ]] || { docs_site_preview "$repo" "${2:-}"; return $?; }
  port="$(_docs_site__port "${2:-}")" || return $?
  mkdocs="$(docs_site_toolchain "$repo")" || return $?
  # mkdocs serve answers under site_url's path (/name/ for a project site), so
  # print that address, not one that is a 404.
  path="$(sed -n 's#^site_url:[[:space:]]*["'\'']\{0,1\}[a-z]*://[^/]*\(/[^"'\''#[:space:]]*\).*#\1#p' "$repo"/mkdocs.y*ml 2>/dev/null | head -1)"
  path="${path:-/}"; [[ "$path" == */ ]] || path="${path}/"
  log_info "docs_site: live reload on http://127.0.0.1:${port}${path} (Ctrl-C to stop)"
  (cd "$repo" && "$mkdocs" serve -a "127.0.0.1:${port}")
}
