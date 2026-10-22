#!/usr/bin/env bash
# HTTP helpers for talking to a JSON service: probe an endpoint, and prove an
# API key against it without putting the key in argv.
#
# Requires: curl. Uses lib/logging.sh.

# Usage: http_probe_json URL PATH [TIMEOUT_SECONDS]; prints the response body.
# Returns 1 when nothing answers, the status is not 2xx, or the body is empty.
# One request with a short deadline: the service is serving or it is not.
# Returns: 0 a 2xx response with a non-empty body; 1 missing argument, bad TIMEOUT, no answer, non-2xx status or empty body.
# Output: stdout the response body on success; stderr an error for bad arguments.
http_probe_json() {
  local url="${1:-}" path="${2:-}" timeout="${3:-5}"
  [[ -n "$url" && -n "$path" ]] || { log_error "http_probe_json: URL and PATH required"; return 1; }
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { log_error "http_probe_json: TIMEOUT must be a whole number of seconds (got '$timeout')"; return 1; }
  url="${url%/}"
  [[ "$path" == /* ]] || path="/$path"
  local body
  if ! body="$(curl -fsS --connect-timeout "$timeout" --max-time "$timeout" "$url$path" 2>/dev/null)"; then
    return 1
  fi
  [[ -n "$body" ]] || return 1
  printf '%s\n' "$body"
}

# Usage: http_check_key URL PATH HEADER KEY
# 0 = the key is accepted; 2 = the service answered and refused it (401/403);
# 1 = nothing answered, or it answered something else.
#
# PATH should be an authenticated read that answers 200 for any valid key. A
# 200 counts only with a JSON body: a single-page app or a captive portal
# answers every path with 200 and HTML, and that is not a key being accepted.
# The key reaches curl on stdin as a config line (`-K -`), never in argv,
# where every other user on the machine could read it with ps.
# Returns: 0 key accepted (200 with a JSON content type); 2 the service refused it (401/403); 1 bad arguments, no answer, or any other response.
# Output: stdout nothing; stderr an error for bad arguments.
http_check_key() {
  local url="${1:-}" path="${2:-}" header="${3:-}" key="${4:-}"
  [[ -n "$url" && -n "$path" && -n "$header" && -n "$key" ]] || { log_error "http_check_key: URL, PATH, HEADER and KEY required"; return 1; }
  [[ "$header" =~ ^[A-Za-z0-9-]+$ ]] || { log_error "http_check_key: '$header' is not a header name"; return 1; }
  # The key becomes an HTTP header; a CR or LF inside it is header injection.
  case "$key" in
    *$'\r'*|*$'\n'*) log_error "http_check_key: KEY must not contain CR or LF"; return 1 ;;
  esac
  url="${url%/}"
  [[ "$path" == /* ]] || path="/$path"
  # curl config syntax: inside double quotes, \\ and \" are the escapes.
  local esc="${key//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  local out code ctype
  out="$(printf 'header = "%s: %s"\n' "$header" "$esc" \
    | curl -sS -K - -o /dev/null -w '%{http_code} %{content_type}' --connect-timeout 5 --max-time 10 \
      -H 'Accept: application/json' "$url$path" 2>/dev/null)" || return 1
  code="${out%% *}"
  ctype="$(printf '%s' "${out#* }" | tr '[:upper:]' '[:lower:]')"
  # The media type without its parameters; RFC 7231 allows whitespace before
  # the `;` (`application/json ; charset=utf-8`).
  ctype="${ctype%%;*}"
  ctype="${ctype%"${ctype##*[![:space:]]}"}"
  case "$code" in
    200)
      case "$ctype" in
        application/json|application/*+json) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    401|403) return 2 ;;
    *) return 1 ;;
  esac
}
