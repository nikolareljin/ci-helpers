#!/usr/bin/env bash
# SCRIPT: wrangler_run.sh
# DESCRIPTION: Run the pinned wrangler with an argv built by
#              cloudflare_wrangler.py from checked values only, in a clean
#              environment: a private HOME, no npmrc, no caller variable.
#              `dryrun` bundles the Worker into CF_BUNDLE_DIR (build job,
#              no token). `deploy` uploads the bundle or Pages directory the
#              build job made, from the verified artifact (deploy job).
#              A Pages deploy runs beside an empty wrangler.json, so wrangler
#              reads no config from a parent directory.
# USAGE: bash scripts/wrangler_run.sh dryrun|deploy
# ENVIRONMENT:
#   NODE, WRANGLER_JS      From setup_wrangler.sh (absolute paths).
#   CF_WORKDIR             Directory wrangler runs in (absolute).
#   CF_COMMAND, CF_DEPLOY_ARGS, CF_ENV_NAME, CF_VERSION_VAR, CF_VERSION,
#   CF_CONFIG, CF_ENTRY, CF_BUNDLE_DIR, CF_PAGES_DIR
#                          See cloudflare_wrangler.py argv.
#   CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID
#                          deploy only; passed to wrangler through its
#                          environment, never argv.
# EXIT CODES: wrangler's, 1 on a refusal, 2 on a usage error.
# ----------------------------------------------------
set -euo pipefail
export LC_ALL=C
fail() { echo "::error::$*" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mode="${1:-}"
case "$mode" in dryrun|deploy) ;; *) echo "usage: wrangler_run.sh dryrun|deploy" >&2; exit 2 ;; esac
[[ "${NODE:-}" == /* && -x "$NODE" ]] || fail "NODE is not an absolute path to node."
[[ "${WRANGLER_JS:-}" == /*/node_modules/wrangler/bin/wrangler.js && -f "$WRANGLER_JS" ]] || fail "WRANGLER_JS is not the installed wrangler."
[[ "${CF_WORKDIR:-}" == /* && -d "$CF_WORKDIR" ]] || fail "CF_WORKDIR is not an absolute directory."

py=/usr/bin/python3
[[ -x "$py" ]] || py="$(command -v python3)"
home="$(mktemp -d "${RUNNER_TEMP:-/tmp}/wrangler-home.XXXXXX")"
chmod 700 "$home"
trap 'rm -rf -- "$home"' EXIT
CF_MODE="$mode" "$py" -I "$here/cloudflare_wrangler.py" argv > "$home/argv" || exit 1
mapfile -d '' argv < "$home/argv"
[[ "${#argv[@]}" -gt 0 ]] || fail "no wrangler arguments."

if [[ "$mode" == deploy ]]; then
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || fail "no CLOUDFLARE_API_TOKEN."
  CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}" "$py" -I "$here/cloudflare_wrangler.py" account || exit 1
fi

CF_COMMAND_KEPT="${CF_COMMAND:-}" CF_ENV_KEPT="${CF_ENV_NAME:-}" CF_WORKDIR_KEPT="$CF_WORKDIR"
# `pages deploy` takes no --config: it reads the first wrangler config in its
# directory or any parent. An empty one here ends that search (wrangler
# warns that it has no pages_build_output_dir and ignores it).
if [[ "$mode" == deploy && "$CF_COMMAND_KEPT" == "pages deploy" ]]; then
  for f in wrangler.json wrangler.jsonc wrangler.toml; do
    [[ ! -e "$CF_WORKDIR/$f" && ! -L "$CF_WORKDIR/$f" ]] || fail "$CF_WORKDIR/$f already exists; Pages deploys run beside an empty config only."
  done
  printf '{}' > "$CF_WORKDIR/wrangler.json"
fi
echo "wrangler ${argv[*]}"
# A clean environment, built in this shell: the token stays out of every
# argv, including env(1)'s.
(
  token="${CLOUDFLARE_API_TOKEN:-}" account="${CLOUDFLARE_ACCOUNT_ID:-}" node_bin="$NODE" js="$WRANGLER_JS"
  for v in $(compgen -e); do unset "$v" 2>/dev/null || true; done
  export PATH="${node_bin%/*}:/usr/bin:/bin" HOME="$home" LANG=C.UTF-8 CI=true
  export WRANGLER_SEND_METRICS=false NO_UPDATE_NOTIFIER=1 XDG_CONFIG_HOME="$home/.config"
  export NPM_CONFIG_USERCONFIG=/dev/null NPM_CONFIG_GLOBALCONFIG=/dev/null
  if [[ "$mode" == deploy ]]; then
    export CLOUDFLARE_API_TOKEN="$token" CLOUDFLARE_ACCOUNT_ID="$account"
  fi
  unset token account
  # CLOUDFLARE_ENV selects wrangler's environment as --env does. Pages has
  # no environment and 'none' opts out, so neither sets it.
  if [[ "${CF_COMMAND_KEPT}" != "pages deploy" && "${CF_ENV_KEPT}" != none ]]; then
    export CLOUDFLARE_ENV="$CF_ENV_KEPT"
  fi
  cd "$CF_WORKDIR_KEPT"
  exec "$node_bin" "$js" "${argv[@]}"
)
