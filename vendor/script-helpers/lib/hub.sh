#!/usr/bin/env bash
# Corpus hub helpers: ask whether the hub is local or remote, prove the answer,
# write it to .env, bootstrap a local hub through the hub's own scripts, and
# offer -- to a person -- to run the hub's own ./update.
#
# Every capture client that files to a corpus hub imports this, so two clients
# cannot drift into two ideas of "remote". The library never names a private
# repository: the clone URL is an argument, and the hub's scripts are invoked
# by path in the clone the caller names.
#
# The rules this implements are the fleet's ADR-0013 (the hub is a service; a
# client never runs its compose or stops it), ADR-0015 (a client may install
# the hub once and may offer, to a person, to update it) and the corpus-client
# convention, all recorded in the contracts repository. In short: no compose,
# ever; nothing without a person when a person is needed; no prompt at all
# when stdin or stdout is not a terminal.
#
# Requires: curl, git. Built on lib/dialog.sh (ui_*), lib/http.sh, lib/json.sh
# (json_get_field), lib/env.sh (env_set_value, resolve_env_value) and
# lib/version.sh (version_offer_update); this file holds only what is
# specific to the hub.

# Sibling modules, sourced only if the caller has not already.
if ! type resolve_env_value >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/env.sh"
fi
if ! type version_compare >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/version.sh"
fi
if ! type ui_mode >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/dialog.sh"
fi
if ! type json_get_field >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/json.sh"
fi
if ! type http_check_key >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/http.sh"
fi

# ---------------------------------------------------------------------------
# The UI layer: one set of prompts, three renderers.
# ---------------------------------------------------------------------------

# Usage: hub_ui_mode; prints dialog | plain | none.
# HUB_UI and HUB_SETUP_PLAIN=1 are this module's names for ui_mode's SHLIB_UI
# and SHLIB_UI_PLAIN, and win over them.
hub_ui_mode() { _hub__ui ui_mode; }

# Internal: run a ui_* function with HUB_UI and HUB_SETUP_PLAIN applied.
_hub__ui() {
  SHLIB_UI="${HUB_UI:-${SHLIB_UI:-}}" SHLIB_UI_PLAIN="${HUB_SETUP_PLAIN:-${SHLIB_UI_PLAIN:-}}" \
    _UI_MODE_VAR="${HUB_UI:+HUB_UI}" "$@"
}
_hub__ui_menu()   { _hub__ui ui_menu "$@"; }
_hub__ui_input()  { _hub__ui ui_input "$@"; }
_hub__ui_secret() { _hub__ui ui_secret "$@"; }
_hub__ui_yesno()  { _hub__ui ui_yesno "$@"; }
_hub__ui_note()   { _hub__ui ui_note "Corpus hub" "$@"; }

# ---------------------------------------------------------------------------
# Pure helpers.
# ---------------------------------------------------------------------------

# Usage: hub_probe URL [TIMEOUT_SECONDS]; prints the /v1/service body.
# Returns 1 when the hub does not answer.
hub_probe() {
  [[ -n "${1:-}" ]] || { log_error "hub_probe: URL required"; return 1; }
  http_probe_json "$1" /v1/service "${2:-5}"
}

# Usage: hub_probe_field BODY KEY; prints a top-level string field, or nothing.
hub_probe_field() { json_get_field "$@"; }

# Usage: hub_check_key URL KEY
# 0 = the key is accepted; 2 = the hub answered and refused the key;
# 1 = the hub did not answer, or answered something else.
# Proves the key against an authenticated read (one document, which may not
# exist -- an empty list is still a 200). A 401 or 403 is a wrong key, and is
# reported as one: telling someone "the hub is not serving" when they pasted
# the wrong key sends them to restart a hub that is fine.
hub_check_key() {
  [[ -n "${1:-}" && -n "${2:-}" ]] || { log_error "hub_check_key: URL and KEY required"; return 1; }
  http_check_key "$1" "/v1/documents?limit=1" X-API-Key "$2"
}

# Usage: hub_write_env FILE KEY VALUE; upserts KEY=VALUE with env_set_value's
# quoting, in place so a symlink keeps its target. KEY is upper case. A file
# this creates (and its directory) starts with a comment and is 0600: it
# holds an API key.
hub_write_env() {
  local file="${1:-}" key="${2:-}"
  [[ -n "$file" && -n "$key" ]] || { log_error "hub_write_env: FILE and KEY required"; return 1; }
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { log_error "hub_write_env: '$key' is not an environment variable name"; return 1; }
  if [[ ! -e "$file" ]]; then
    mkdir -p "$(dirname "$file")" || return 1
    ( umask 077 && printf '# Local environment. Gitignored -- do not commit.\n\n' >"$file" ) || return 1
  fi
  env_set_value "$file" "$key" "${3:-}"
}

# Usage: hub_latest_tag CLONE_DIR; prints the newest tag, without a v prefix.
# Fetches tags first; offline, the local tags are what there is.
hub_latest_tag() {
  local dir="${1:-}"
  [[ -n "$dir" && -d "$dir/.git" ]] || return 1
  git -C "$dir" fetch --tags --quiet 2>/dev/null || true
  git -C "$dir" tag --list 2>/dev/null | sed 's/^[vV]//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1
}

# Internal: is URL http(s)://host[:port] with nothing after? An IPv6 host
# is legal only in brackets (http://[::1]:8000), as curl requires.
_hub__url_ok() {
  [[ "${1:-}" =~ ^https?://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+)(:([0-9]{1,5}))?/?$ ]] || return 1
  local port="${BASH_REMATCH[3]:-}"
  # 10# so a leading zero is not read as octal. :0 and :99999 fail here
  # rather than later, inside curl, with a worse message.
  [[ -z "$port" ]] || (( 10#$port >= 1 && 10#$port <= 65535 ))
}

# Internal: is the host part loopback? A bracketed IPv6 host keeps its
# colons, so the port strip must not run on it.
_hub__url_is_loopback() {
  local host="${1#*://}"; host="${host%%/*}"
  if [[ "$host" == \[* ]]; then
    host="${host#\[}"; host="${host%%\]*}"
  else
    host="${host%%:*}"
  fi
  [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]
}

# ---------------------------------------------------------------------------
# Flows.
# ---------------------------------------------------------------------------

# Usage: hub_bootstrap CLONE_DIR REPO_URL
#
# Makes a local hub exist, through the hub's own scripts and nothing else:
# clone when absent, then `./start --configure-superuser` (interactive, once)
# and `./install-service`. Prints the `loginctl enable-linger` step rather
# than running it -- that is a decision about this machine, not about the hub.
# A clone that is already there is left alone apart from an
# `./install-service --dry-run`, which changes nothing and shows what is
# installed. Never compose.
hub_bootstrap() {
  local dir="${1:-}" repo_url="${2:-}"
  [[ -n "$dir" ]] || { log_error "hub_bootstrap: CLONE_DIR required"; return 1; }
  if [[ ! -d "$dir" ]]; then
    [[ -n "$repo_url" ]] || { log_error "hub_bootstrap: $dir is absent and no repository URL was given (HUB_REPO_URL)"; return 1; }
    log_info "Cloning the corpus hub into $dir"
    git clone --quiet -- "$repo_url" "$dir" || { log_error "git clone failed"; return 1; }
    [[ -x "$dir/start" && -x "$dir/install-service" ]] || { log_error "$dir does not look like the hub: no executable start and install-service"; return 1; }
    log_info "Configuring the hub (the hub's own ./start --configure-superuser)"
    (cd "$dir" && ./start --configure-superuser) || { log_error "the hub's ./start --configure-superuser failed"; return 1; }
    log_info "Installing the hub's user service (the hub's own ./install-service)"
    (cd "$dir" && ./install-service) || { log_error "the hub's ./install-service failed"; return 1; }
    log_info "To keep the hub running after you log out: loginctl enable-linger \$USER"
    return 0
  fi
  [[ -x "$dir/install-service" ]] || { log_error "$dir exists but has no executable install-service; is it the hub?"; return 1; }
  log_info "Hub clone present at $dir; checking its service unit (dry run)"
  (cd "$dir" && ./install-service --dry-run) || log_warn "install-service --dry-run reported a problem; run it in $dir to see"
  return 0
}

# Usage: hub_offer_update URL CLONE_DIR
#
# Compares the version the running hub reports with the newest tag in its
# clone. Behind, and a person is present: ask, and on yes exec the hub's own
# ./update. Otherwise print one line. In remote mode (HUB_MODE=remote) only
# print -- a remote hub is somebody else's to update. Always returns 0 unless
# the arguments or HUB_UI are wrong; a declined or impossible offer is not a
# failure.
hub_offer_update() {
  local url="${1:-}" dir="${2:-}"
  [[ -n "$url" && -n "$dir" ]] || { log_error "hub_offer_update: URL and CLONE_DIR required"; return 1; }
  local body running latest
  body="$(hub_probe "$url" 5)" || { log_warn "hub at $url is not answering; nothing to compare"; return 0; }
  # Guarded: under a caller's set -e an unreadable clone would end the whole
  # script, when the contract is "nothing to offer, return 0".
  running="$(hub_probe_field "$body" version)" || running=""
  latest="$(hub_latest_tag "$dir")" || latest=""
  if [[ -z "$running" || -z "$latest" ]]; then
    return 0
  fi
  if [[ "${HUB_MODE:-local}" == "remote" ]]; then
    local rc=0
    version_compare "$running" "$latest" >/dev/null 2>&1 || rc=$?
    # 255 means running < latest. 0 equal, 1 newer (a checkout ahead of its tags).
    [[ "$rc" -eq 255 ]] || return 0
    log_info "Remote hub at $url runs $running; $latest is available. It is updated where it runs, not from here."
    return 0
  fi
  _hub__ui version_offer_update --label Hub --hint "cd $dir && ./update" "$running" "$latest" _hub__run_update "$dir"
}

# Internal: the hub's own ./update, replacing this process.
_hub__run_update() {
  log_info "Running $1/update"
  cd "$1" && exec ./update
}

# Usage: hub_setup_dialog ENV_FILE [--mode local|remote] [--url URL] [--key KEY]
#                         [--hub-dir DIR] [--repo-url URL] [--client NAME]
#
# The install-time question: is the hub local or remote? Every answer can be
# given as a flag, taken from the environment or ENV_FILE, or asked for -- in
# that order -- and with no terminal nothing is asked: the run fails naming
# the variable it wanted. On success ENV_FILE carries HUB_MODE, HUB_URL,
# HUB_API_KEY and HUB_INSTANCE_ID, and the hub has answered and accepted the
# key. Re-runnable.
hub_setup_dialog() {
  local env_file="${1:-}"; shift || true
  [[ -n "$env_file" ]] || { log_error "hub_setup_dialog: ENV_FILE required"; return 1; }
  local mode="" url="" key="" hub_dir="" repo_url="" client="${HUB_CLIENT_NAME:-capture-client}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode=*) mode="${1#--mode=}" ;;
      --url=*) url="${1#--url=}" ;;
      --key=*) key="${1#--key=}" ;;
      --hub-dir=*) hub_dir="${1#--hub-dir=}" ;;
      --repo-url=*) repo_url="${1#--repo-url=}" ;;
      --client=*) client="${1#--client=}" ;;
      --mode|--url|--key|--hub-dir|--repo-url|--client)
        # A flag at the end, or followed by another flag, has no value; the
        # silent alternative leaves the field empty or set to the next flag.
        if [[ $# -lt 2 || "$2" == --* ]]; then
          log_error "hub_setup_dialog: $1 requires a value"
          return 2
        fi
        case "$1" in
          --mode) mode="$2" ;;
          --url) url="$2" ;;
          --key) key="$2" ;;
          --hub-dir) hub_dir="$2" ;;
          --repo-url) repo_url="$2" ;;
          --client) client="$2" ;;
        esac
        shift ;;
      *) log_error "hub_setup_dialog: unknown option $1"; return 2 ;;
    esac
    shift
  done

  local ui; ui="$(hub_ui_mode)" || return 1

  # --- which hub ---------------------------------------------------------------
  [[ -n "$mode" ]] || mode="$(resolve_env_value HUB_MODE "" "$env_file")"
  if [[ -z "$mode" ]]; then
    if [[ "$ui" == "none" ]]; then
      log_error "No terminal and no HUB_MODE: set HUB_MODE=local or HUB_MODE=remote (in $env_file or the environment), or pass --mode."
      return 1
    fi
    mode="$(_hub__ui_menu "Corpus hub" "Where does the corpus hub run?" local \
      local "Install it as a service on this computer" \
      remote "Connect to one running on another computer")" || { log_error "No hub mode chosen."; return 1; }
  fi
  case "$mode" in
    local|remote) ;;
    *) log_error "HUB_MODE must be local or remote (got '$mode')"; return 1 ;;
  esac

  # --- local: make the hub exist --------------------------------------------------
  if [[ "$mode" == "local" ]]; then
    [[ -n "$hub_dir" ]] || hub_dir="$(resolve_env_value HUB_DIR "" "$env_file")"
    # Beside the client's own checkout, under the name the caller gives
    # (HUB_CLONE_NAME) -- the library does not know what the hub's repository
    # is called, and must not.
    if [[ -z "$hub_dir" ]]; then
      # Guarded: when the env file's directory does not exist yet, the cd
      # failed, the substitution was empty, and the clone went to /hub.
      local env_parent
      if ! env_parent="$(cd "$(dirname "$env_file")" 2>/dev/null && cd .. 2>/dev/null && pwd)" || [[ -z "$env_parent" ]]; then
        log_error "Cannot place the hub clone beside $(dirname "$env_file"): that directory does not exist. Create it, or set HUB_DIR (or pass --hub-dir)."
        return 1
      fi
      hub_dir="$env_parent/${HUB_CLONE_NAME:-hub}"
    fi
    [[ -n "$repo_url" ]] || repo_url="$(resolve_env_value HUB_REPO_URL "" "$env_file")"
    if [[ ! -d "$hub_dir" && -z "$repo_url" ]]; then
      if [[ "$ui" == "none" ]]; then
        log_error "No hub at $hub_dir and no HUB_REPO_URL to clone it from: set HUB_REPO_URL (or pass --repo-url), or HUB_DIR to an existing clone."
        return 1
      fi
      repo_url="$(_hub__ui_input "Corpus hub" "No hub at $hub_dir. Git URL to clone the corpus hub from" "")" || return 1
      [[ -n "$repo_url" ]] || { log_error "A repository URL is needed to clone the hub."; return 1; }
    fi
    hub_bootstrap "$hub_dir" "$repo_url" || return 1
    if [[ -z "$url" ]]; then
      url="$(resolve_env_value HUB_URL "" "$env_file")"
    fi
    if [[ -z "$url" ]]; then
      local port
      port="$(resolve_env_value BACKEND_PORT "" "$hub_dir/.env")"
      [[ -n "$port" ]] || port="$(resolve_env_value BACKEND_PORT 8000 "$hub_dir/env.example")"
      url="http://localhost:${port}"
    fi
  fi

  # --- remote: where, exactly ---------------------------------------------------
  if [[ "$mode" == "remote" ]]; then
    [[ -n "$url" ]] || url="$(resolve_env_value HUB_URL "" "$env_file")"
    if [[ -z "$url" ]]; then
      if [[ "$ui" == "none" ]]; then
        log_error "No terminal and no HUB_URL: set HUB_URL (in $env_file or the environment), or pass --url."
        return 1
      fi
      url="$(_hub__ui_input "Corpus hub" "URL of the hub, e.g. http://desk.local:8000" "http://localhost:8000")" || return 1
    fi
  fi
  url="${url%/}"
  if ! _hub__url_ok "$url"; then
    log_error "HUB_URL must look like http(s)://host[:port] (got '$url')"
    return 1
  fi
  if [[ "$url" == http://* ]] && ! _hub__url_is_loopback "$url"; then
    log_warn "$url is plain http to another machine: the API key travels unencrypted on that network."
  fi

  # --- does it answer ---------------------------------------------------------------
  local body
  while ! body="$(hub_probe "$url" 5)"; do
    if [[ "$ui" == "none" ]]; then
      log_error "The corpus hub is not serving at $url (GET /v1/service did not answer)."
      [[ "$mode" == "local" ]] && log_error "Start it in its own clone: cd $hub_dir && ./start"
      return 1
    fi
    if ! _hub__ui_yesno "Corpus hub" "Nothing answered at $url/v1/service. Try again?"; then
      log_error "The corpus hub is not serving at $url."
      return 1
    fi
  done
  local name version instance_id
  name="$(hub_probe_field "$body" name)"
  version="$(hub_probe_field "$body" version)"
  instance_id="$(hub_probe_field "$body" instance_id)"
  # Any 200 with a body passes hub_probe; a web app or captive portal on that
  # port is not a hub, and nothing it says should be recorded.
  if [[ -z "$name" && -z "$version" ]]; then
    log_error "Something answered at $url/v1/service, but not a corpus hub (no name or version in the reply)."
    return 1
  fi
  # The id comes from the remote end and lands in a file that is sourced;
  # anything outside an id's alphabet is not recorded.
  if [[ -n "$instance_id" && ! "$instance_id" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    log_warn "The hub reported an instance_id with unexpected characters; not recording HUB_INSTANCE_ID."
    instance_id=""
  fi
  log_info "Hub at $url: ${name:-?} ${version:-?}${instance_id:+ (instance $instance_id)}"

  # --- a key it accepts -------------------------------------------------------------
  [[ -n "$key" ]] || key="$(resolve_env_value HUB_API_KEY "" "$env_file")"
  if [[ -z "$key" && "$ui" == "none" ]]; then
    log_error "No terminal and no HUB_API_KEY: set HUB_API_KEY (in $env_file or the environment), or pass --key."
    [[ "$mode" == "local" ]] && log_error "Issue one in the hub's clone: cd $hub_dir && ./manage issue_api_key default \"$client\""
    return 1
  fi
  while true; do
    if [[ -z "$key" ]]; then
      if [[ "$mode" == "local" ]]; then
        _hub__ui_note "The hub needs an API key for this client. Issue one in its clone:  cd $hub_dir && ./manage issue_api_key default \"$client\"  -- then paste the X-API-Key value here."
      fi
      key="$(_hub__ui_secret "Corpus hub" "API key for $url")" || return 1
    fi
    local rc=0
    hub_check_key "$url" "$key" || rc=$?
    case "$rc" in
      0) break ;;
      2)
        log_error "The hub at $url refused that API key (HTTP 401 or 403)."
        if [[ "$ui" == "none" ]] || ! _hub__ui_yesno "Corpus hub" "The hub refused that key. Enter another?"; then
          return 1
        fi
        key=""
        ;;
      *)
        log_error "Could not verify the key: $url/v1/documents did not answer as expected."
        return 1
        ;;
    esac
  done

  # --- record it --------------------------------------------------------------------
  hub_write_env "$env_file" HUB_MODE "$mode" || return 1
  hub_write_env "$env_file" HUB_URL "$url" || return 1
  hub_write_env "$env_file" HUB_API_KEY "$key" || return 1
  if [[ -n "$instance_id" ]]; then
    hub_write_env "$env_file" HUB_INSTANCE_ID "$instance_id" || return 1
  fi
  if [[ "$mode" == "local" ]]; then
    hub_write_env "$env_file" HUB_DIR "$hub_dir" || return 1
  fi
  log_info "Recorded HUB_MODE=$mode and HUB_URL=$url in $env_file (key verified)."
  return 0
}
