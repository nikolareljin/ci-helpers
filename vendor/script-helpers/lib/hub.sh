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
# Requires: curl, git. Uses python3 for JSON when present, a sed fallback when
# not. Uses lib/logging.sh, lib/env.sh (resolve_env_value), lib/version.sh
# (version_compare) and, in dialog mode, lib/dialog.sh (dialog_init).

# Sibling modules, sourced only if the caller has not already.
if ! type resolve_env_value >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/env.sh"
fi
if ! type version_compare >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/version.sh"
fi
if ! type dialog_init >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/dialog.sh"
fi

# ---------------------------------------------------------------------------
# The UI layer: one set of prompts, three renderers.
# ---------------------------------------------------------------------------

# Usage: hub_ui_mode; prints dialog | plain | none.
#
# HUB_UI forces a renderer (tests, and a caller that knows better). Otherwise:
# no terminal on stdin or stdout means no prompts at all -- a systemd unit or a
# CI job must fail naming what it wanted rather than wait forever on a read;
# HUB_SETUP_PLAIN=1 means plain prompts even when `dialog` is installed.
hub_ui_mode() {
  local forced="${HUB_UI:-}"
  if [[ -n "$forced" ]]; then
    case "$forced" in
      dialog|plain|none) ;;
      *) log_error "HUB_UI must be dialog, plain or none (got '$forced')"; return 1 ;;
    esac
    if [[ "$forced" == "dialog" && -n "${HUB_SETUP_PLAIN:-}" ]]; then
      echo plain
      return 0
    fi
    echo "$forced"
    return 0
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo none
    return 0
  fi
  if [[ -z "${HUB_SETUP_PLAIN:-}" ]] && command -v dialog >/dev/null 2>&1; then
    echo dialog
    return 0
  fi
  echo plain
}

# Internal: a menu. Usage: _hub__ui_menu TITLE TEXT DEFAULT key1 label1 [key2 label2 ...]
# Prints the chosen key. In `none` mode prints nothing and returns 1.
_hub__ui_menu() {
  local title="$1" text="$2" default="$3"; shift 3
  local mode; mode="$(hub_ui_mode)" || return 1
  local -a keys=() labels=()
  while [[ $# -ge 2 ]]; do keys+=("$1"); labels+=("$2"); shift 2; done
  case "$mode" in
    none) return 1 ;;
    dialog)
      dialog_init
      local -a items=() i
      for i in "${!keys[@]}"; do items+=("${keys[$i]}" "${labels[$i]}"); done
      local choice
      choice="$(dialog --stdout --title "$title" --default-item "$default" --menu "$text" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${items[@]}")" || return 1
      echo "$choice"
      ;;
    plain)
      local i answer
      echo "$title" >&2
      echo "$text" >&2
      for i in "${!keys[@]}"; do echo "  ${keys[$i]}  -- ${labels[$i]}" >&2; done
      read -r -p "[${default}] " answer || return 1
      answer="${answer:-$default}"
      for i in "${!keys[@]}"; do
        [[ "$answer" == "${keys[$i]}" ]] && { echo "$answer"; return 0; }
      done
      log_error "'$answer' is not one of: ${keys[*]}"
      return 1
      ;;
  esac
}

# Internal: a text input. Usage: _hub__ui_input TITLE TEXT DEFAULT
_hub__ui_input() {
  local title="$1" text="$2" default="${3:-}"
  local mode; mode="$(hub_ui_mode)" || return 1
  case "$mode" in
    none) return 1 ;;
    dialog)
      dialog_init
      local v
      v="$(dialog --stdout --title "$title" --inputbox "$text" 10 "$DIALOG_WIDTH" "$default")" || return 1
      echo "${v:-$default}"
      ;;
    plain)
      local v
      read -r -p "$text${default:+ [$default]}: " v || return 1
      echo "${v:-$default}"
      ;;
  esac
}

# Internal: a secret input; never echoed. Usage: _hub__ui_secret TITLE TEXT
_hub__ui_secret() {
  local title="$1" text="$2"
  local mode; mode="$(hub_ui_mode)" || return 1
  case "$mode" in
    none) return 1 ;;
    dialog)
      dialog_init
      dialog --stdout --title "$title" --insecure --passwordbox "$text" 10 "$DIALOG_WIDTH" || return 1
      ;;
    plain)
      local v
      if [[ -t 0 ]]; then
        read -r -s -p "$text: " v || return 1
        echo >&2
      else
        # Piped answers (tests, scripted runs): -s would still work, but a
        # pipe is not a terminal and `stty` complaints are noise.
        read -r v || return 1
      fi
      echo "$v"
      ;;
  esac
}

# Internal: yes/no. Usage: _hub__ui_yesno TITLE TEXT; 0 = yes, 1 = no or no UI.
_hub__ui_yesno() {
  local title="$1" text="$2"
  local mode; mode="$(hub_ui_mode)" || return 1
  case "$mode" in
    none) return 1 ;;
    dialog)
      dialog_init
      dialog --title "$title" --defaultno --yesno "$text" 10 "$DIALOG_WIDTH"
      ;;
    plain)
      local v
      read -r -p "$text [y/N] " v || return 1
      [[ "$v" =~ ^[Yy]([Ee][Ss])?$ ]]
      ;;
  esac
}

# Internal: a message the person should see, in whatever renderer.
_hub__ui_note() {
  local mode; mode="$(hub_ui_mode 2>/dev/null || echo none)"
  if [[ "$mode" == "dialog" ]]; then
    dialog_init
    dialog --title "Corpus hub" --msgbox "$*" 12 "$DIALOG_WIDTH" 2>/dev/null || true
    return 0
  fi
  log_info "$*"
}

# ---------------------------------------------------------------------------
# Pure helpers.
# ---------------------------------------------------------------------------

# Usage: hub_probe URL [TIMEOUT_SECONDS]; prints the /v1/service body.
# Returns 1 when the hub does not answer. One request, a short deadline:
# nothing is starting, so the hub is serving or it is not.
hub_probe() {
  local url="${1:-}" timeout="${2:-5}"
  [[ -n "$url" ]] || { log_error "hub_probe: URL required"; return 1; }
  url="${url%/}"
  local body
  if ! body="$(curl -fsS --connect-timeout "$timeout" --max-time "$timeout" "$url/v1/service" 2>/dev/null)"; then
    return 1
  fi
  [[ -n "$body" ]] || return 1
  printf '%s\n' "$body"
}

# Usage: hub_probe_field BODY KEY; prints a top-level string field, or nothing.
hub_probe_field() {
  local body="${1:-}" key="${2:-}"
  # A word, nothing else: the fallback interpolates the key into a grep
  # pattern, and a JSON field name here is never more than [A-Za-z0-9_].
  [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$body" | python3 -c '
import json, sys
key = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
v = d.get(key) if isinstance(d, dict) else None
if v is not None and not isinstance(v, (dict, list)):
    print(v)
' "$key"
    return 0
  fi
  # No python3: a string field out of compact or pretty JSON. The quoted key
  # keeps "api_version" from matching "version". A missing field prints
  # nothing and still exits 0: grep's miss must not surface through a
  # caller's set -o pipefail.
  printf '%s' "$body" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true
  return 0
}

# Usage: hub_check_key URL KEY
# 0 = the key is accepted; 2 = the hub answered and refused the key;
# 1 = the hub did not answer, or answered something else.
#
# Proves the key against an authenticated read (one document, which may not
# exist -- an empty list is still a 200). A 401 or 403 is a wrong key, and is
# reported as one: telling someone "the hub is not serving" when they pasted
# the wrong key sends them to restart a hub that is fine.
hub_check_key() {
  local url="${1:-}" key="${2:-}"
  [[ -n "$url" && -n "$key" ]] || { log_error "hub_check_key: URL and KEY required"; return 1; }
  # The key becomes an HTTP header; a CR or LF inside it is header injection.
  case "$key" in
    *$'\r'*|*$'\n'*) log_error "hub_check_key: KEY must not contain CR or LF"; return 1 ;;
  esac
  url="${url%/}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    -H "X-API-Key: $key" "$url/v1/documents?limit=1" 2>/dev/null)" || return 1
  case "$code" in
    200) return 0 ;;
    401|403) return 2 ;;
    *) return 1 ;;
  esac
}

# Usage: hub_write_env FILE KEY VALUE; upserts KEY=VALUE.
#
# Rewrites in place rather than `mv`: when the env file is a symlink (a
# dotfile-managed config is a normal setup) mv replaces the link with a
# regular file and the real target keeps its old contents, so the write
# appears to succeed and changes nothing anyone reads. `cat >` follows the
# link and keeps the inode. Same reasoning as adb_wireless_write_env.
hub_write_env() {
  local file="${1:-}" key="${2:-}" value="${3:-}" tmp=""
  [[ -n "$file" && -n "$key" ]] || { log_error "hub_write_env: FILE and KEY required"; return 1; }
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { log_error "hub_write_env: '$key' is not an environment variable name"; return 1; }
  case "$value" in
    *$'\n'*|*$'\r'*) log_error "hub_write_env: a value cannot contain a newline or carriage return"; return 1 ;;
  esac
  if [[ ! -e "$file" ]]; then
    mkdir -p "$(dirname "$file")" || return 1
    printf '# Local environment. Gitignored -- do not commit.\n\n' >"$file" || return 1
  fi
  tmp="$(mktemp)" || return 1
  awk -v k="$key" -v v="$value" '
    BEGIN { pat = "^[[:space:]]*" k "=" }
    $0 ~ pat { print k "=" v; seen = 1; next }
    { print }
    END { if (!seen) print k "=" v }
  ' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" >"$file" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
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
  local rc=0
  version_compare "$running" "$latest" >/dev/null 2>&1 || rc=$?
  # 255 means running < latest. 0 equal, 1 newer (a checkout ahead of its tags).
  [[ "$rc" -eq 255 ]] || return 0
  if [[ "${HUB_MODE:-local}" == "remote" ]]; then
    log_info "Remote hub at $url runs $running; $latest is available. It is updated where it runs, not from here."
    return 0
  fi
  # An invalid HUB_UI is a misconfiguration to surface, not a silent "none".
  local mode; mode="$(hub_ui_mode)" || return 1
  if [[ "$mode" == "none" ]]; then
    log_info "Hub $running is running; $latest is available: cd $dir && ./update"
    return 0
  fi
  if _hub__ui_yesno "Corpus hub update" "Hub $running is running and $latest is available. Run the hub's own ./update now?"; then
    log_info "Running $dir/update"
    cd "$dir" && exec ./update
  fi
  log_info "Not updating. Later: cd $dir && ./update"
  return 0
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
    [[ -n "$hub_dir" ]] || hub_dir="$(cd "$(dirname "$env_file")" && cd .. 2>/dev/null && pwd)/${HUB_CLONE_NAME:-hub}"
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
