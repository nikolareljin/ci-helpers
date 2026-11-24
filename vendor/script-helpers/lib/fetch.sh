#!/usr/bin/env bash
# fetch: download one release asset to a file, with retries and a clear error.
#
# One transient error from a release CDN should not fail an install. curl gets
# --retry 3 --retry-delay 2, plus --retry-all-errors when it is 7.71 or newer
# (older curl rejects that option, so it is left out there). wget gets
# --tries=3 --waitretry=2.
#
# A failed download deletes the output file, so a partial file is never left
# for the caller to check or unpack. Callers still verify the checksum.
#
# wget also gets --retry-on-http-error=429,500,502,503,504 when it has the
# option. Redirects keep to the scheme asked for: an https URL is fetched and
# redirected over https only, an http one over http or https. curl does this
# with --proto and --proto-redir. wget's --https-only works only in recursive
# mode, so for an https URL fetch_wget_follow follows the redirects itself.
#
# Expected imports by caller: none. log_error is used when logging is loaded,
# plain stderr otherwise. trap_stack.sh beside this file is loaded here.
#
# Return codes: 0 downloaded; 1 the download failed; 2 bad arguments; 3 no curl
# or wget.
#
# fetch_verified_gpg_key is the one copy of the signing-key rule: a downloaded
# repository key is used only when it is exactly the pinned one.

# The partial file and the key's temp directory are removed on EXIT, HUP, INT
# and TERM too; see trap_stack.sh.
if ! declare -F trap_stack_push >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/trap_stack.sh"
fi

# Usage: fetch_curl_retry_args
# fetch_curl_retry_args; the retry options this machine's curl accepts, one per
# line: --retry 3 --retry-delay 2, and --retry-all-errors on curl 7.71 or newer.
# Returns: 0.
# Output: stdout the options, one per line.
fetch_curl_retry_args() {
  local v major minor
  printf '%s\n' --retry 3 --retry-delay 2
  v="$(curl --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 0
  if (( major > 7 || (major == 7 && minor >= 71) )); then
    printf '%s\n' --retry-all-errors
  fi
  return 0
}

# Usage: fetch_url_host <url>
# fetch_url_host <url>; the host part of an http or https URL, without user
# info or port. Fails closed: another or no scheme, an authority (from "://"
# to the first "/", "?" or "#") with anything but printable ASCII or with a
# backslash, an empty host or an unclosed "[" gives "(unknown host)". Same
# rule as ps/lib/fetch.ps1; tests/fixtures/fetch_url_cases.txt holds both.
# Returns: 0.
# Output: stdout the host.
fetch_url_host() {
  # C locale: in UTF-8, [:graph:] matches bidi overrides and Unicode spaces.
  local LC_ALL=C u="${1:-}" h scheme rb="]"
  scheme="$(printf '%s' "${u%%://*}" | tr 'A-Z' 'a-z')"
  if [[ "$u" != *://* || ( "$scheme" != http && "$scheme" != https ) ]]; then
    printf '%s\n' "(unknown host)"; return 0
  fi
  h="${u#*://}"
  h="${h%%[/?#]*}"
  # A backslash: curl and browsers read "a\@b" differently, so name neither.
  if [[ "$h" == *[![:graph:]]* || "$h" == *\\* ]]; then
    printf '%s\n' "(unknown host)"; return 0
  fi
  h="${h##*@}"
  if [[ "${h:0:1}" == "[" ]]; then
    [[ "$h" == *"$rb"* ]] && h="${h%%"$rb"*}$rb" || h=""
    [[ "$h" == "[$rb" ]] && h=""
  else
    h="${h%%:*}"
  fi
  [[ -n "$h" ]] || h="(unknown host)"
  printf '%s\n' "$h"
}

# Usage: fetch_url_display <url>
# fetch_url_display <url>; the URL as it may be printed: scheme, authority and
# path, with a query shown as "?(not shown)" and a fragment left out, when the
# URL is printable ASCII with no space, fetch_url_host names its host and its
# authority has no "@"; else a placeholder. Fails closed: user info, a query
# or fragment (a signed URL carries its token there), a missing or other
# scheme, a character that could forge a log line, or anything that does not
# parse is never printed.
# Returns: 0.
# Output: stdout the URL, cut as above, or "(URL not shown)".
fetch_url_display() {
  # C locale: in UTF-8, [:graph:] matches bidi overrides and Unicode spaces.
  local LC_ALL=C u="${1:-}" rest auth tail pre path
  rest="${u#*://}"; auth="${rest%%[/?#]*}"
  if [[ "$u" == *[![:graph:]]* || "$auth" == *@* || "$(fetch_url_host "$u")" == "(unknown host)" ]]; then
    printf '%s\n' "(URL not shown)"
    return 0
  fi
  tail="${rest:${#auth}}"; pre="${tail%%#*}"; path="${pre%%\?*}"
  [[ "$pre" == *\?* ]] && path="$path?(not shown)"
  printf '%s\n' "${u%%://*}://$auth$path"
}

# Usage: fetch_curl_proto_args <url>
# fetch_curl_proto_args <url>; the curl options that keep the transfer and its
# redirects to https for an https URL, to http or https for an http URL.
# Another scheme (file://, for one) gets none: curl's defaults stay.
# Returns: 0.
# Output: stdout the options, one per line, or nothing.
fetch_curl_proto_args() {
  local LC_ALL=C s
  [[ "${1:-}" == *://* ]] || return 0
  s="$(printf '%s' "${1%%://*}" | tr 'A-Z' 'a-z')"
  case "$s" in
    https) printf '%s\n' --proto =https --proto-redir =https ;;
    http)  printf '%s\n' --proto =http,https --proto-redir =http,https ;;
  esac
  return 0
}

# Usage: fetch_wget_args
# fetch_wget_args; --retry-on-http-error=429,500,502,503,504 when this
# machine's wget has it (wget 1.19.1 or newer; without it wget does not retry
# a 503). busybox wget gets nothing.
# Returns: 0.
# Output: stdout the option, or nothing.
fetch_wget_args() {
  [[ "$(wget --help 2>/dev/null)" == *--retry-on-http-error* ]] && printf '%s\n' --retry-on-http-error=429,500,502,503,504
  return 0
}

# Usage: fetch_wget_follow <url> <output> [wget option...]
# fetch_wget_follow <url> <output> [wget option...]; wget <url> to <output>
# with --max-redirect=0, following each redirect itself: only to an https URL
# (any host) or a relative reference, resolved on the same host, at most 5. wget's --https-only does not apply to
# a single download, so this is what keeps an https download off http.
# FETCH_MAX_TIME (seconds, default 300) is one deadline for all the hops: each
# wget runs under timeout(1) or gtimeout with what is left, and no hop starts
# once it has passed. Without timeout or gtimeout, wget has only its per-read
# -T, and the deadline is checked between hops.
# Returns: wget's exit code; 1 a redirect refused or more than 5; 124 the
#   deadline passed.
# Output: stderr on failure, wget's messages without the response headers
#   (they can quote the URL); nothing on success.
fetch_wget_follow() {
  local u out hop=0 rc err loc rest auth path query first max start left t tcmd=""
  local -a pre=()
  # printf -v marks the copies the caller checked for the scanner.
  printf -v u '%s' "${1:-}"
  printf -v out '%s' "${2:-}"
  shift 2
  max="${FETCH_MAX_TIME:-300}"
  [[ "$max" =~ ^[1-9][0-9]{0,6}$ ]] || max=300
  for t in timeout gtimeout; do
    command -v "$t" >/dev/null 2>&1 && { tcmd="$t"; break; }
  done
  start=$SECONDS
  while :; do
    left=$(( max - (SECONDS - start) ))
    if [[ "$left" -le 0 ]]; then
      printf '%s\n' "wget: FETCH_MAX_TIME (${max}s) passed after $hop redirects" >&2
      return 124
    fi
    pre=()
    [[ -n "$tcmd" ]] && pre=("$tcmd" "$left")
    rc=0
    err="$(${pre[@]+"${pre[@]}"} wget -S --no-verbose --max-redirect=0 "$@" -O "$out" -- "$u" 2>&1 >/dev/null)" || rc=$?
    # The value after "Location:", spaces and tabs around it dropped (RFC 9110 5.5).
    loc="$(printf '%s\n' "$err" | tr -d '\r' | awk '/^  HTTP\// { l = "" } /^  [Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:/ { l = substr($0, 12); sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l) } END { print l }')"
    [[ "$rc" -eq 0 ]] && return 0
    if [[ -z "$loc" ]]; then
      # || true: grep finds nothing when every line is a header (set -e callers).
      printf '%s\n' "$err" | grep -v '^  ' >&2 || true
      return "$rc"
    fi
    rm -f -- "$out"
    # Relative references as RFC 3986 reads them; u is always https here.
    rest="${u#*://}"; auth="${rest%%[/?#]*}"; query="${rest:${#auth}}"; query="${query%%#*}"; path="${query%%\?*}"
    # A ':' before the first "/", "?" or "#" names a scheme; one after does not.
    first="${loc%%[/?#]*}"
    case "$loc" in
      [Hh][Tt][Tt][Pp][Ss]://*) ;;
      //*) loc="https:$loc" ;;
      /*) loc="https://$auth$loc" ;;
      \?*) loc="https://$auth$path$loc" ;;
      \#*) loc="https://$auth$query$loc" ;;
      *) [[ "$first" != *:* ]] || { printf '%s\n' "wget: redirect to a URL that is not https refused" >&2; return 1; }
         loc="https://$auth${path%/*}/$loc" ;;
    esac
    hop=$((hop + 1))
    if [[ "$hop" -gt 5 ]]; then printf '%s\n' "wget: more than 5 redirects" >&2; return 1; fi
    u="$loc"
  done
}

# Usage: fetch_exit_reason <curl|wget> <code>
# fetch_exit_reason <curl|wget> <code>; a short reason for a curl or wget exit code.
# Returns: 0.
# Output: stdout the reason.
fetch_exit_reason() {
  local r=""
  case "$1:$2" in
    curl:6) r="could not resolve host" ;;
    curl:7) r="could not connect" ;;
    curl:18) r="transfer ended early" ;;
    curl:22) r="HTTP error (400 or above)" ;;
    curl:28) r="timed out" ;;
    curl:35) r="TLS handshake failed" ;;
    curl:52) r="empty reply from server" ;;
    curl:56) r="network receive failed" ;;
    curl:60) r="TLS certificate not trusted" ;;
    wget:4) r="network failure" ;;
    wget:5) r="TLS verification failed" ;;
    wget:8) r="server error response" ;;
    wget:124) r="timed out (FETCH_MAX_TIME)" ;;
  esac
  printf '%s\n' "${r:-see the $1 documentation for this exit code}"
}

# Usage: fetch_to_file <label> <url> <output>
# fetch_to_file <label> <url> <output>; download <url> to <output> with curl
# (or wget when there is no curl), retrying transient errors. On failure, or
# on INT or TERM during the download, the output file is deleted; one line on
# stderr names the label, the host, the tool and its exit code. The tool's own
# last error line follows, once, and only when the whole URL is shown: it can
# quote the URL.
# Env: FETCH_MAX_TIME - seconds for the whole download (default 300; anything
#   but a whole number from 1 to 9999999 means 300). wget gets it through
#   timeout(1) or gtimeout when one is there, one deadline across redirects.
# Returns: 0 downloaded; 1 download failed; 2 an empty label, URL or output, a
#   URL that starts with "-", or output "-"; 3 no curl or wget.
# Output: stdout nothing; stderr the error line on failure.
fetch_to_file() {
  local label="${1:-}" url out tool rc=0 host msg shown err="" max t
  local -a args=()
  if [[ -z "$label" || -z "${2:-}" || -z "${3:-}" || "${2:-}" == -* || "${3:-}" == - ]]; then
    _fetch_err "fetch_to_file: usage: fetch_to_file <label> <url> <output>"
    return 2
  fi
  # checked above; printf -v marks the validated copies for the scanner
  printf -v url '%s' "$2"
  printf -v out '%s' "$3"
  max="${FETCH_MAX_TIME:-300}"
  [[ "$max" =~ ^[1-9][0-9]{0,6}$ ]] || max=300
  if command -v curl >/dev/null 2>&1; then
    tool=curl
    while IFS= read -r msg; do args+=("$msg"); done < <(fetch_curl_retry_args; fetch_curl_proto_args "$url")
  elif command -v wget >/dev/null 2>&1; then
    tool=wget
    while IFS= read -r msg; do args+=("$msg"); done < <(fetch_wget_args)
    # wget's -T bounds one read, not the download; timeout(1) bounds it all.
    local -a tmo=()
    for t in timeout gtimeout; do
      command -v "$t" >/dev/null 2>&1 && { tmo=("$t" "$max"); break; }
    done
  else
    _fetch_err "$label: download failed: curl or wget is needed to download $(fetch_url_display "$url")"
    return 3
  fi
  trap_stack_push "$out"
  # stderr is kept, not passed through: with retries curl prints one line per
  # attempt, and the line can quote the URL.
  if [[ "$tool" == curl ]]; then
    err="$(curl -fsSL --connect-timeout 15 --max-time "$max" "${args[@]}" -o "$out" -- "$url" 2>&1 >/dev/null)" || rc=$?
  else
    # https: redirects followed by hand, to https only.
    if [[ "$(printf '%s' "${url%%://*}" | tr 'A-Z' 'a-z')" == https ]]; then
      err="$(FETCH_MAX_TIME="$max" fetch_wget_follow "$url" "$out" -T 60 --tries=3 --waitretry=2 ${args[@]+"${args[@]}"} 2>&1)" || rc=$?
    else
      err="$(${tmo[@]+"${tmo[@]}"} wget -q -T 60 --tries=3 --waitretry=2 ${args[@]+"${args[@]}"} -O "$out" -- "$url" 2>&1 >/dev/null)" || rc=$?
    fi
  fi
  # Off the stack, file kept: it is the download, or deleted just below.
  trap_stack_pop --keep
  if [[ "$rc" -ne 0 ]]; then
    rm -f -- "$out"
    host="$(fetch_url_host "$url")"
    shown="$(fetch_url_display "$url")"
    _fetch_err "$label: download failed from $host: $tool exit $rc ($(fetch_exit_reason "$tool" "$rc")), after retries; URL $shown"
    if [[ "$shown" == "$url" && -n "$err" ]]; then
      msg="$(printf '%s\n' "$err" | awk 'NF { l = $0 } END { print l }')"
      [[ -n "$msg" ]] && printf '  %s\n' "$msg" >&2
    fi
    return 1
  fi
  return 0
}

# Usage: fetch_verified_gpg_key <label> <url> <fingerprint> <output>
# fetch_verified_gpg_key <label> <url> <fingerprint> <output>; download an
# OpenPGP key with fetch_to_file and check it in a throwaway GNUPGHOME. The
# key is used only when the file holds exactly one primary key and its
# fingerprint is <fingerprint> (40 hex digits, upper case). <output> then gets
# the armored key as gpg exports it, not the download: packets gpg dropped on
# import (bad signatures, junk after the key) never reach apt or rpm. On any
# failure <output> is not written. The temp directory is always removed.
# Returns: 0 verified and written; 1 no gpg, download failed, or the key is
#   not the pinned one; 2 an empty argument, an output that starts with "-",
#   or a fingerprint that is not 40 upper-case hex digits.
# Output: stdout nothing; stderr one or two error lines on failure.
fetch_verified_gpg_key() {
  local label="${1:-}" url="${2:-}" want="${3:-}" out dir fprs count
  if [[ -z "$label" || -z "$url" || -z "${4:-}" || "${4:-}" == -* || ! "$want" =~ ^[0-9A-F]{40}$ ]]; then
    _fetch_err "fetch_verified_gpg_key: usage: fetch_verified_gpg_key <label> <url> <40-hex fingerprint> <output>"
    return 2
  fi
  # checked above; printf -v marks the validated copy for the scanner
  printf -v out '%s' "$4"
  if ! command -v gpg >/dev/null 2>&1; then
    _fetch_err "$label: gpg is required to verify the signing key."
    return 1
  fi
  dir="$(mktemp -d "${TMPDIR:-/tmp}/shlib-gpg-key.XXXXXX")" || return 1
  trap_stack_push "$dir"
  chmod 700 "$dir" || { trap_stack_pop; return 1; }
  mkdir -m 700 "$dir/gnupg" || { trap_stack_pop; return 1; }
  if ! fetch_to_file "$label" "$url" "$dir/key" || [[ ! -s "$dir/key" ]]; then
    _fetch_err "$label: could not download the signing key from $(fetch_url_display "$url")."
    trap_stack_pop
    return 1
  fi
  fprs="$(gpg --homedir "$dir/gnupg" --batch --quiet --import "$dir/key" >/dev/null 2>&1 \
    && gpg --homedir "$dir/gnupg" --batch --with-colons --fingerprint 2>/dev/null \
    | awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print $10; p = 0 }')"
  count="$(printf '%s\n' "$fprs" | grep -c '^[0-9A-F]\{40\}$' || true)"
  if [[ "$count" -ne 1 || "$fprs" != "$want" ]]; then
    _fetch_err "$label: signing key from $(fetch_url_display "$url") failed verification: expected one primary key $want, got ${count} ($(printf '%s' "$fprs" | tr '\n' ' '))."
    trap_stack_pop
    return 1
  fi
  if ! gpg --homedir "$dir/gnupg" --batch --armor --export "$want" >"$dir/key.asc" 2>/dev/null \
     || [[ ! -s "$dir/key.asc" ]] || ! cp -- "$dir/key.asc" "$out"; then
    _fetch_err "$label: could not export the verified signing key."
    trap_stack_pop
    return 1
  fi
  trap_stack_pop
  return 0
}

# _fetch_err <message>: log_error when logging is loaded, else plain stderr.
_fetch_err() {
  if declare -F log_error >/dev/null 2>&1; then log_error "$*"; else printf '[ERROR] %s\n' "$*" >&2; fi
}
