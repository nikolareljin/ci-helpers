#!/usr/bin/env bash
# serve.sh — serve a static site directory locally for preview/testing.
# Part of script-helpers. Source via helpers.sh, or run bin/serve-pages.

# serve_static_site <dir> [port]
# Serves <dir> over HTTP on the first free port at/after [port] (default 8000).
# Prefers python3, then `python` (3 or 2), then npx http-server. Blocks until Ctrl-C.
serve_static_site() {
  local dir="${1:-}"
  local port="${2:-8000}"

  if [[ -z "$dir" || ! -d "$dir" ]]; then
    echo "serve_static_site: directory not found: '${dir}'" >&2
    return 2
  fi

  # Reject non-numeric ports early: the free-port probe below does arithmetic
  # on this value, which would fail noisily on e.g. "abc".
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "serve_static_site: invalid port: '${port}' (expected 1-65535)" >&2
    return 2
  fi

  # Find a free port, trying up to 20 above the requested one. `found` tells a
  # genuine free port apart from exhausting the window on an all-busy range.
  local p="$port" tries=0 found=0
  while (( tries < 20 && p <= 65535 )); do
    if ! { : <>"/dev/tcp/127.0.0.1/${p}"; } 2>/dev/null; then
      found=1                    # connect failed => nothing listening => port is free
      break
    fi
    p=$(( p + 1 )); tries=$(( tries + 1 ))
  done
  if (( ! found )); then
    # Report the actual range probed (last attempted port is p-1), which may end
    # before port+19 if the search hit the 65535 ceiling.
    echo "serve_static_site: no free port found in ${port}..$(( p - 1 ))" >&2
    return 4
  fi

  local url="http://localhost:${p}/"
  echo "Serving '${dir}' at ${url}  (Ctrl-C to stop)"

  # Run the server in the foreground WITHOUT `exec`: when this function is called
  # from a sourced context (`source helpers.sh; serve_static_site ...`), `exec`
  # would replace the caller's shell, so Ctrl-C would kill their session instead
  # of just the server. As a plain child, Ctrl-C stops the server and returns here.
  if command -v python3 >/dev/null 2>&1; then
    python3 -m http.server "${p}" --directory "${dir}"
  elif command -v python >/dev/null 2>&1; then
    # `python` may be Python 3 or 2; the stdlib server module differs between them.
    if python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
      ( cd "${dir}" && python -m http.server "${p}" )
    else
      ( cd "${dir}" && python -m SimpleHTTPServer "${p}" )
    fi
  elif command -v npx >/dev/null 2>&1; then
    npx --yes http-server "${dir}" -p "${p}"
  else
    echo "serve_static_site: need python3, python, or npx to serve" >&2
    return 3
  fi
}
