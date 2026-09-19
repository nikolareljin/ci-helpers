#!/usr/bin/env bash
# Cloudflare deploy helpers: resolve credentials, derive the deploy config and
# the version string, confirm a destructive environment, run wrangler, and prove
# afterwards that what answers is what was just deployed.
#
# This module is one half of a pair. The other half is a reusable GitHub Actions
# workflow that supplies credentials, the environment gate and the kill switch.
# Both call the same deploy sequence, and that is the point: a deploy run from a
# laptop and a deploy run from CI must not be two implementations that drift.
#
# The mechanism is a contract of CF_DEPLOY_* environment variables. When CI has
# already resolved a value it exports it, and the function here returns it
# verbatim instead of computing its own. So a single run never has two live
# definitions of the version string or the base URL -- CI's definition wins in
# CI, this file's definition wins on a laptop, and neither is a copy of the
# other kept in step by hand.
#
# Return codes, used by every function in this module:
#   0  success
#   1  the operation failed, or a required value could not be resolved
#   2  bad arguments, or a value outside its allowed set
#   3  a required tool is missing
#   4  no usable Cloudflare credentials
#   5  refused -- a protected environment was not confirmed
#
# No function here calls `exit`: these are library functions, and a sourced
# function that exits takes the caller's shell with it.
#
# Requires: curl. Uses wrangler through a runner it picks (see
# _cloudflare__runner). Uses jq or python3 for JSON when present, a grep/sed
# fallback when neither is. Uses lib/logging.sh and lib/env.sh
# (resolve_env_value).

# Sibling modules, sourced only if the caller has not already.
if ! type resolve_env_value >/dev/null 2>&1 && [[ -n "${_SHLIB_LIB_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/env.sh"
fi
# ci_defaults is the single place versions are pinned. Without this the literal
# below was the effective default and a bump to ci_defaults.sh had no effect --
# two live definitions of one version, which is the drift this module exists to
# stop. helpers.sh does not autoload it, so it is sourced explicitly.
if [[ -z "${CI_DEFAULT_WRANGLER_VERSION:-}" && -n "${_SHLIB_LIB_DIR:-}" && -r "$_SHLIB_LIB_DIR/ci_defaults.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_SHLIB_LIB_DIR/ci_defaults.sh"
fi

# Environments that require a typed confirmation before a deploy. Space
# separated so bash 3.2 can hold it without an array in a variable.
: "${CLOUDFLARE_PROTECTED_ENVS:=production}"

# The health path used by cloudflare_smoke_test when the caller gives none.
: "${CLOUDFLARE_HEALTH_PATH:=/health}"

# Pinned in lib/ci_defaults.sh; defaulted here too so this module works when
# imported on its own.
: "${CLOUDFLARE_WRANGLER_VERSION:=${CI_DEFAULT_WRANGLER_VERSION:-4.42.0}}"

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

# Usage: _cloudflare__runner; prints how to invoke wrangler, or nothing.
#
# A project that has wrangler in its lockfile should use that one: the version
# the project was tested against, not whatever npm resolves today. Only when
# there is no lockfile do we fall back to fetching a pinned version, and that
# fallback is convenience, not supply-chain hygiene.
_cloudflare__runner() {
  if [[ -n "${CLOUDFLARE_WRANGLER_CMD:-}" ]]; then
    printf '%s\n' "$CLOUDFLARE_WRANGLER_CMD"
    return 0
  fi
  if [[ -f pnpm-lock.yaml ]] && command -v pnpm >/dev/null 2>&1; then
    printf '%s\n' "pnpm exec wrangler"
    return 0
  fi
  if [[ -f yarn.lock ]] && command -v yarn >/dev/null 2>&1; then
    printf '%s\n' "yarn wrangler"
    return 0
  fi
  if [[ -f package-lock.json ]] && command -v npm >/dev/null 2>&1; then
    printf '%s\n' "npm exec -- wrangler"
    return 0
  fi
  if command -v wrangler >/dev/null 2>&1; then
    printf '%s\n' "wrangler"
    return 0
  fi
  if command -v npx >/dev/null 2>&1; then
    printf '%s\n' "npx --yes wrangler@${CLOUDFLARE_WRANGLER_VERSION:-${CI_DEFAULT_WRANGLER_VERSION:-4.42.0}}"
    return 0
  fi
  return 1
}

# Usage: _cloudflare__json_field BODY KEY; prints a top-level scalar, or nothing.
#
# Same degradation ladder as hub_probe_field, and the same reason for exiting 0
# on a miss: a missing field must not surface through a caller's pipefail.
_cloudflare__json_field() {
  local body="${1:-}" key="${2:-}"
  # A word, nothing else: the fallback interpolates the key into a grep pattern.
  [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true
    return 0
  fi
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
  # The quoted key keeps "api_version" from matching "version".
  printf '%s' "$body" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true
  return 0
}

# Usage: _cloudflare__is_protected ENV; 0 when ENV needs a typed confirmation.
_cloudflare__is_protected() {
  local env_name="${1:-}" candidate="" restore_glob=0
  [[ -n "$env_name" ]] || return 1
  # Word splitting is wanted here; pathname expansion is NOT. Unquoted, a list
  # like "prod*" was expanded against the working directory, so a file named
  # prod-notes.txt replaced the entry and `production` silently stopped being
  # protected -- a safety gate that fails open is worse than no gate.
  case "$-" in *f*) : ;; *) restore_glob=1; set -f ;; esac
  for candidate in ${CLOUDFLARE_PROTECTED_ENVS:-production}; do
    if [[ "$candidate" = "$env_name" ]]; then
      [[ "$restore_glob" -eq 1 ]] && set +f
      return 0
    fi
  done
  [[ "$restore_glob" -eq 1 ]] && set +f
  return 1
}

# ---------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------

# Usage: cloudflare_wrangler <args...>
# Runs wrangler with the resolved runner. Returns wrangler's own status, 2 with
# no arguments, 3 when no runner is available.
#
# The API token is passed through the environment, never in argv: every other
# user on the machine can read argv with ps.
cloudflare_wrangler() {
  [[ $# -gt 0 ]] || { log_error "cloudflare_wrangler: at least one argument required"; return 2; }
  local runner=""
  if ! runner="$(_cloudflare__runner)" || [[ -z "$runner" ]]; then
    log_error "cloudflare_wrangler: no way to run wrangler. Install it, set CLOUDFLARE_WRANGLER_CMD, or install node so npx can fetch it."
    return 3
  fi
  # Word splitting is deliberate: the runner is a command plus its arguments
  # ("pnpm exec wrangler"), assembled by this module, never by a caller.
  # shellcheck disable=SC2086
  $runner "$@"
}

# Usage: cloudflare_credentials_ok
# 0 when a token is set or an interactive wrangler session is authenticated,
# 4 when neither, 3 when wrangler cannot run.
cloudflare_credentials_ok() {
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    return 0
  fi
  local runner=""
  if ! runner="$(_cloudflare__runner)" || [[ -z "$runner" ]]; then
    log_error "cloudflare_credentials_ok: no CLOUDFLARE_API_TOKEN and no wrangler to check a session with."
    return 3
  fi
  # shellcheck disable=SC2086
  if $runner whoami >/dev/null 2>&1; then
    return 0
  fi
  log_error "cloudflare_credentials_ok: no Cloudflare credentials. Set CLOUDFLARE_API_TOKEN, or run 'wrangler login' for an interactive session."
  return 4
}

# Usage: cloudflare_account_id [env_file]
# Prints the account id. 0 found, 1 not found.
#
# This exists because an empty account id is not an error to wrangler: it falls
# back to resolving the account from the token, which is right for a token
# scoped to one account and a coin toss otherwise. A deploy that lands on the
# wrong account looks exactly like a deploy that worked.
#
# shellcheck disable=SC2120  # env_file is an optional argument; callers inside
# this module use the default, callers outside may not.
cloudflare_account_id() {
  local env_file="${1:-.env}" value=""
  if [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    printf '%s\n' "$CLOUDFLARE_ACCOUNT_ID"
    return 0
  fi
  if type resolve_env_value >/dev/null 2>&1; then
    value="$(resolve_env_value CLOUDFLARE_ACCOUNT_ID "" "$env_file" 2>/dev/null || true)"
  fi
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  log_error "cloudflare_account_id: no account id. Export CLOUDFLARE_ACCOUNT_ID, or set it in ${env_file}. Find it on the Cloudflare dashboard under Workers & Pages."
  return 1
}

# Usage: cloudflare_version_string [version_file]
# Prints the version string a deploy should advertise. 0 ok, 1 unreadable file,
# 2 the argument is not a file.
#
# Returns CF_DEPLOY_VERSION verbatim when CI has exported it, so the workflow's
# definition is the only live one in a CI run and this one is a pure fallback.
cloudflare_version_string() {
  local version_file="${1:-VERSION}" base="" sha=""
  if [[ -n "${CF_DEPLOY_VERSION:-}" ]]; then
    printf '%s\n' "$CF_DEPLOY_VERSION"
    return 0
  fi
  if [[ ! -e "$version_file" ]]; then
    log_error "cloudflare_version_string: no version file at '${version_file}'. Pass one, or export CF_DEPLOY_VERSION."
    return 2
  fi
  if [[ ! -r "$version_file" ]]; then
    log_error "cloudflare_version_string: cannot read '${version_file}'."
    return 1
  fi
  base="$(tr -d '[:space:]' < "$version_file")"
  if [[ -z "$base" ]]; then
    log_error "cloudflare_version_string: '${version_file}' is empty."
    return 1
  fi
  if sha="$(git rev-parse --short=7 HEAD 2>/dev/null)" && [[ -n "$sha" ]]; then
    printf '%s-%s\n' "$base" "$sha"
  else
    log_warn "cloudflare_version_string: not a git checkout; version will not identify a commit."
    printf '%s-unknown\n' "$base"
  fi
  return 0
}

# Usage: cloudflare_deploy_config <wrangler-config> <dist-dir>
# Prints the path of the deploy config a bundler-generated build emits.
# 0 ok, 1 the worker name could not be read, 2 missing arguments.
#
# Derived rather than hardcoded: a build plugin writes its generated config
# under a directory named after the worker, so reading the name out of the
# authored config is what keeps the two in step when the name changes.
cloudflare_deploy_config() {
  local config="${1:-}" dist="${2:-}" name="" dir_name=""
  if [[ -z "$config" || -z "$dist" ]]; then
    log_error "cloudflare_deploy_config: usage: cloudflare_deploy_config <wrangler-config> <dist-dir>"
    return 2
  fi
  if [[ -n "${CLOUDFLARE_DEPLOY_CONFIG:-}" ]]; then
    printf '%s\n' "$CLOUDFLARE_DEPLOY_CONFIG"
    return 0
  fi
  if [[ ! -r "$config" ]]; then
    log_error "cloudflare_deploy_config: cannot read '${config}'."
    return 1
  fi
  name="$(sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n 1)"
  if [[ -z "$name" ]]; then
    log_error "cloudflare_deploy_config: no top-level name in '${config}'. Set CLOUDFLARE_DEPLOY_CONFIG to name the generated config directly."
    return 1
  fi
  # Build tooling writes the directory with underscores where the name has
  # hyphens.
  dir_name="$(printf '%s' "$name" | tr '-' '_')"
  printf '%s/%s/wrangler.json\n' "${dist%/}" "$dir_name"
  return 0
}

# Usage: cloudflare_base_url <environment> [env_file]
# Prints the base URL to smoke-test. 0 ok, 1 nothing found, 2 empty environment.
#
# Resolution order: CF_DEPLOY_BASE_URL (CI has already decided), then
# <ENVIRONMENT>_BASE_URL, then BASE_URL. The per-environment name is what lets
# one .env describe a laptop's view of several environments.
cloudflare_base_url() {
  local env_name="${1:-}" env_file="${2:-.env}" upper="" value=""
  if [[ -z "$env_name" ]]; then
    log_error "cloudflare_base_url: environment required"
    return 2
  fi
  if [[ -n "${CF_DEPLOY_BASE_URL:-}" ]]; then
    printf '%s\n' "$CF_DEPLOY_BASE_URL"
    return 0
  fi
  # No ${x^^}: that is bash 4, and this library runs on macOS bash 3.2.
  upper="$(printf '%s' "$env_name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
  upper="${upper%_}"
  if type resolve_env_value >/dev/null 2>&1; then
    value="$(resolve_env_value "${upper}_BASE_URL" "" "$env_file" 2>/dev/null || true)"
    if [[ -z "$value" ]]; then
      value="$(resolve_env_value BASE_URL "" "$env_file" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$value" ]]; then
    log_error "cloudflare_base_url: no base URL for '${env_name}'. Set ${upper}_BASE_URL or BASE_URL in ${env_file}, or export CF_DEPLOY_BASE_URL."
    return 1
  fi
  printf '%s\n' "$value"
  return 0
}

# Usage: cloudflare_confirm_environment <environment> [--yes]
# 0 confirmed, 2 empty environment, 5 declined or unattended without --yes.
#
# Only protected environments prompt. With no terminal on stdin this returns 5
# immediately rather than blocking forever on a read nobody can answer: an
# unattended run that hangs to its timeout is worse than one that says what it
# needed.
cloudflare_confirm_environment() {
  local env_name="${1:-}" assume_yes="" reply=""
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      *) ;;
    esac
    shift
  done
  if [[ -z "$env_name" ]]; then
    log_error "cloudflare_confirm_environment: environment required"
    return 2
  fi
  if ! _cloudflare__is_protected "$env_name"; then
    return 0
  fi
  if [[ -n "$assume_yes" || -n "${CLOUDFLARE_DEPLOY_YES:-}" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log_error "cloudflare_confirm_environment: '${env_name}' is protected and there is no terminal to confirm on. Re-run with --yes, or set CLOUDFLARE_DEPLOY_YES=1."
    return 5
  fi
  printf 'About to deploy to %s. Type %s to confirm: ' "$env_name" "$env_name" >&2
  IFS= read -r reply || reply=""
  if [[ "$reply" = "$env_name" ]]; then
    return 0
  fi
  log_error "cloudflare_confirm_environment: not confirmed; nothing was deployed."
  return 5
}

# Usage: cloudflare_smoke_test <base-url> <expected-version> [status-path] [field]
# 0 pass, 1 unreachable or the wrong version is live, 2 bad args, 3 no curl.
#
# Two separate assertions. Reachability proves something answers. The version
# assertion proves it is the thing just deployed -- without it a smoke test
# passes against the previous release, which is the failure it exists to catch.
cloudflare_smoke_test() {
  local base="${1:-}" expected="${2:-}" status_path="${3:-}" field="${4:-version}"
  local body="" actual=""
  if [[ -z "$base" ]]; then
    log_error "cloudflare_smoke_test: base URL required"
    return 2
  fi
  command -v curl >/dev/null 2>&1 || { log_error "cloudflare_smoke_test: curl is required"; return 3; }
  base="${base%/}"

  # Retry: a deploy that has just landed may take a moment to be reachable
  # everywhere, and a smoke test that fails on that is a false alarm.
  local health="${CLOUDFLARE_HEALTH_PATH:-/health}"
  # --retry-all-errors needs curl >= 7.71 (2020). Ubuntu 20.04, RHEL 8 and older
  # macOS ship less, where curl exits 2 on the unknown option -- which, with
  # stderr discarded, read as "the service did not answer" and failed a deploy
  # that had worked. Probe once and drop the flag rather than mis-report.
  local retry_all=""
  if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
    retry_all="--retry-all-errors"
  fi
  local curl_err=""
  # shellcheck disable=SC2086  # retry_all is one optional flag, assembled here
  if ! curl_err="$(curl -fsSL --retry 5 --retry-delay 5 ${retry_all} --max-time 30 \
      -o /dev/null "${base}${health}" 2>&1)"; then
    log_error "cloudflare_smoke_test: ${base}${health} did not answer: ${curl_err}"
    return 1
  fi

  if [[ -z "$status_path" ]]; then
    log_warn "cloudflare_smoke_test: reachability only. Pass a status path to assert the deployed version is the one now live."
    return 0
  fi
  if [[ -z "$expected" ]]; then
    log_error "cloudflare_smoke_test: a status path was given but no expected version to compare against."
    return 2
  fi

  # shellcheck disable=SC2086  # retry_all is one optional flag, assembled above
  if ! body="$(curl -fsSL --retry 5 --retry-delay 5 ${retry_all} --max-time 30 \
      "${base}${status_path}" 2>/dev/null)"; then
    log_error "cloudflare_smoke_test: ${base}${status_path} did not answer."
    return 1
  fi
  actual="$(_cloudflare__json_field "$body" "$field")"
  if [[ -z "$actual" ]]; then
    log_error "cloudflare_smoke_test: no '${field}' field in the response from ${base}${status_path}."
    return 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    log_error "cloudflare_smoke_test: live version is '${actual}', expected '${expected}'. The deploy did not take effect."
    return 1
  fi
  return 0
}

# Usage: cloudflare_deploy [options] [-- extra wrangler args...]
#   --env NAME            environment to deploy (also wrangler --env)
#   --config PATH         wrangler config; skips deriving it from --dist
#   --dist DIR            build output holding a generated deploy config
#   --source CONFIG       authored wrangler config to read the worker name from
#   --build-command CMD   run before wrangler, with CLOUDFLARE_ENV exported
#   --command KIND        deploy | versions upload | pages deploy
#   --version-file FILE   defaults to VERSION
#   --status-path PATH    JSON endpoint carrying the deployed version
#   --yes                 skip the typed confirmation for a protected environment
#   --dry-run             validate and build, run no deploy
#   --no-smoke            skip the post-deploy check
#
# 0 ok, 1 a step failed, 2 bad option or unknown command, 4 no credentials,
# 5 a protected environment was not confirmed.
#
# This is the single deploy sequence. CI calls it through the workflow's
# deploy_command so that a laptop and a pipeline run the same steps in the same
# order.
cloudflare_deploy() {
  local env_name="" config="" dist="" source_config="" build_command=""
  local command_kind="deploy" version_file="VERSION" status_path=""
  local assume_yes="" dry_run="" no_smoke=""
  local version="" account_id="" base="" runner=""

  # Every value-taking option goes through this. `shift 2` when only one
  # positional remains returns 1 AND SHIFTS NOTHING, so a trailing `--env` used
  # to spin this loop forever -- and under `set -euo pipefail`, which is what
  # ./dev runs, it died with no message at all. A deploy that hangs to its
  # timeout is the failure this module exists to refuse.
  _need_value() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
      log_error "cloudflare_deploy: $1 needs a value"
      return 2
    fi
    return 0
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)            _need_value "$@" || return 2; env_name="$2";       shift 2 ;;
      --config)         _need_value "$@" || return 2; config="$2";         shift 2 ;;
      --dist)           _need_value "$@" || return 2; dist="$2";           shift 2 ;;
      --source)         _need_value "$@" || return 2; source_config="$2";  shift 2 ;;
      --build-command)  _need_value "$@" || return 2; build_command="$2";  shift 2 ;;
      --command)        _need_value "$@" || return 2; command_kind="$2";   shift 2 ;;
      --version-file)   _need_value "$@" || return 2; version_file="$2";   shift 2 ;;
      --status-path)    _need_value "$@" || return 2; status_path="$2";    shift 2 ;;
      --yes|-y) assume_yes="--yes"; shift ;;
      --dry-run) dry_run=1; shift ;;
      --no-smoke) no_smoke=1; shift ;;
      --) shift; break ;;
      *) log_error "cloudflare_deploy: unknown option '$1'"; return 2 ;;
    esac
  done

  if [[ -z "$env_name" ]]; then
    log_error "cloudflare_deploy: --env is required."
    return 2
  fi
  # An allowlist, not a free string: this value becomes argv.
  case "$command_kind" in
    deploy|"versions upload"|"pages deploy") ;;
    *) log_error "cloudflare_deploy: --command must be 'deploy', 'versions upload' or 'pages deploy', not '${command_kind}'."; return 2 ;;
  esac

  if [[ -n "$assume_yes" ]]; then
    cloudflare_confirm_environment "$env_name" --yes || return $?
  else
    cloudflare_confirm_environment "$env_name" || return $?
  fi

  if [[ -z "$dry_run" ]]; then
    cloudflare_credentials_ok || return $?
    # 1, not 4: cloudflare_account_id returns 1, and 4 means "no usable
    # credentials" -- which would send the operator to check a token that is
    # fine.
    if ! account_id="$(cloudflare_account_id)"; then
      return 1
    fi
    export CLOUDFLARE_ACCOUNT_ID="$account_id"
  fi

  # Before the build, not after: a missing VERSION file is a five-second
  # failure, and discovering it only once a full build has been spent is a
  # waste that the operator pays for every time.
  if ! version="$(cloudflare_version_string "$version_file")"; then
    return 1
  fi

  if [[ -n "$build_command" ]]; then
    log_info "cloudflare_deploy: building for ${env_name}"
    # CLOUDFLARE_ENV is wrangler's own environment selector and build plugins
    # read it; scoped to this command so it cannot alter the deploy below.
    if ! CLOUDFLARE_ENV="$env_name" eval "$build_command"; then
      log_error "cloudflare_deploy: build command failed; nothing was deployed."
      return 1
    fi
  fi

  if [[ -z "$config" && -n "$dist" ]]; then
    if ! config="$(cloudflare_deploy_config "${source_config:-wrangler.toml}" "$dist")"; then
      return 1
    fi
  fi
  if [[ -n "$config" && ! -r "$config" ]]; then
    log_error "cloudflare_deploy: deploy config '${config}' does not exist. The build may not have produced it."
    return 1
  fi
  if [[ "$command_kind" = "pages deploy" && -n "$config" ]]; then
    log_warn "cloudflare_deploy: --config is not passed to 'pages deploy'; ignoring '${config}'."
  fi

  if [[ -n "$dry_run" ]]; then
    log_info "cloudflare_deploy: dry run; would deploy ${version} to ${env_name}"
    [[ -n "$config" ]] && log_info "cloudflare_deploy: config ${config}"
    return 0
  fi

  # The remaining "$@" is whatever followed `--`: extra wrangler arguments the
  # caller wants passed through untouched. Prepend the subcommand and append
  # the flags this function owns.
  #
  # $command_kind is split on purpose -- "versions upload" and "pages deploy"
  # are two argv words each -- and it has already been checked against the
  # allowlist above, so it can only be one of three known strings.
  # shellcheck disable=SC2086
  set -- $command_kind "$@"
  if [[ "$command_kind" != "pages deploy" ]]; then
    if [[ -n "$config" ]]; then
      set -- "$@" --config "$config"
    fi
    set -- "$@" --env "$env_name" --var "VERSION:${version}"
  fi

  log_info "cloudflare_deploy: deploying ${version} to ${env_name}"
  if ! cloudflare_wrangler "$@"; then
    log_error "cloudflare_deploy: wrangler failed; see its output above."
    return 1
  fi

  if [[ -n "$no_smoke" ]]; then
    return 0
  fi
  if ! base="$(cloudflare_base_url "$env_name" 2>/dev/null)"; then
    # Silenced above: this path is benign, and the inner log_error would print a
    # red ERROR immediately before a WARN saying it does not matter.
    log_warn "cloudflare_deploy: deployed, but no base URL to verify against; set <ENV>_BASE_URL or BASE_URL to enable the check."
    return 0
  fi
  cloudflare_smoke_test "$base" "$version" "$status_path" || return 1
  log_info "cloudflare_deploy: ${version} is live on ${env_name}"
  return 0
}
