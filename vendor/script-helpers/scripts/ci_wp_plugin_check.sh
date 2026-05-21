#!/usr/bin/env bash
# SCRIPT: ci_wp_plugin_check.sh
# DESCRIPTION: Run WordPress plugin-check and optional standalone PHP checks from GitHub Actions or similar CI workflows.
# USAGE: scripts/ci_wp_plugin_check.sh [options]
# PARAMETERS:
#   --compose-file <path>                    Path to the caller-repo Docker Compose file (default: test/docker-compose.yml).
#   --plugin-slug <slug>                     WordPress plugin slug (required).
#   --plugin-src <path>                      Path to the plugin source directory (default: .).
#   --plugin-src-env <name>                  Env var name for the plugin source path (default: PLUGIN_SRC).
#   --wpcli-service <name>                   Compose service for WP-CLI (default: wpcli).
#   --db-service <name>                      Compose service for the database (default: db).
#   --wordpress-service <name>               Compose service for WordPress (default: wordpress).
#   --db-name <name>                         Database name (default: wordpress).
#   --db-user <user>                         Database user (default: wordpress).
#   --db-password <password>                 Database password (default: wordpress).
#   --host-port <port>                       WordPress host port (default: 8080).
#   --out-dir <path>                         Directory for output artifacts (default: test/tmp).
#   --db-wait-seconds <seconds>              Max seconds to wait for DB readiness (default: 30).
#   --multisite <true|false>                 Enable multisite install (default: true).
#   --activate-network <true|false>          Activate plugin network-wide (default: true).
#   --admin-user <user>                      WordPress admin username (default: admin).
#   --admin-password <password>              WordPress admin password (default: admin).
#   --admin-email <email>                    WordPress admin email (default: admin@example.com).
#   --site-title <title>                     WordPress site title (default: WP Test Site).
#   --meta-check-script <path>               Optional container-visible WP eval-file script for meta checks.
#   --php-lint-command <command>             Standalone PHP lint command.
#   --phpcs-warning-command <command>        Standalone PHPCS warning command.
#   --phpunit-command <command>              Standalone PHPUnit command.
#   --phpunit-working-directory <path>       Working directory for standalone PHPUnit (default: .).
#   --fail-on-findings <true|false>          Fail on plugin-check errors (default: false).
#   --cleanup <true|false>                   Clean up Docker resources on exit (default: true).
#   -h, --help                               Show this help message.
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help docker

usage() { show_help "${BASH_SOURCE[0]}"; }

compose_file="test/docker-compose.yml"
plugin_slug=""
plugin_src="."
plugin_src_env="PLUGIN_SRC"
wpcli_service="wpcli"
db_service="db"
db_name="wordpress"
db_user="wordpress"
db_password="wordpress"
wordpress_service="wordpress"
host_port="8080"
out_dir="test/tmp"
db_wait_seconds="30"
multisite="true"
activate_network="true"
admin_user="admin"
admin_password="admin"
admin_email="admin@example.com"
site_title="WP Test Site"
meta_check_script=""
php_lint_command=""
phpcs_warning_command=""
phpunit_command=""
phpunit_working_directory="."
fail_on_findings="false"
cleanup="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) compose_file="$2"; shift 2 ;;
    --plugin-slug) plugin_slug="$2"; shift 2 ;;
    --plugin-src) plugin_src="$2"; shift 2 ;;
    --plugin-src-env) plugin_src_env="$2"; shift 2 ;;
    --wpcli-service) wpcli_service="$2"; shift 2 ;;
    --db-service) db_service="$2"; shift 2 ;;
    --db-name) db_name="$2"; shift 2 ;;
    --db-user) db_user="$2"; shift 2 ;;
    --db-password) db_password="$2"; shift 2 ;;
    --wordpress-service) wordpress_service="$2"; shift 2 ;;
    --host-port) host_port="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --db-wait-seconds) db_wait_seconds="$2"; shift 2 ;;
    --multisite) multisite="$2"; shift 2 ;;
    --activate-network) activate_network="$2"; shift 2 ;;
    --admin-user) admin_user="$2"; shift 2 ;;
    --admin-password) admin_password="$2"; shift 2 ;;
    --admin-email) admin_email="$2"; shift 2 ;;
    --site-title) site_title="$2"; shift 2 ;;
    --meta-check-script) meta_check_script="$2"; shift 2 ;;
    --php-lint-command) php_lint_command="$2"; shift 2 ;;
    --phpcs-warning-command) phpcs_warning_command="$2"; shift 2 ;;
    --phpunit-command) phpunit_command="$2"; shift 2 ;;
    --phpunit-working-directory) phpunit_working_directory="$2"; shift 2 ;;
    --fail-on-findings) fail_on_findings="$2"; shift 2 ;;
    --cleanup) cleanup="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

validate_bool_option() {
  local option="$1"
  local value="$2"

  if [[ "$value" != "true" && "$value" != "false" ]]; then
    log_error "Invalid value for ${option}: '$value'. Expected true or false."
    exit 2
  fi
}

validate_bool_option "--multisite" "$multisite"
validate_bool_option "--activate-network" "$activate_network"
validate_bool_option "--fail-on-findings" "$fail_on_findings"
validate_bool_option "--cleanup" "$cleanup"

if [[ ! "$db_wait_seconds" =~ ^[0-9]+$ ]] || (( db_wait_seconds <= 0 )); then
  log_error "Invalid value for --db-wait-seconds: '$db_wait_seconds'. Expected a positive integer."
  exit 2
fi

if [[ ! "$host_port" =~ ^[0-9]+$ ]] || (( host_port < 1 || host_port > 65535 )); then
  log_error "Invalid value for --host-port: '$host_port'. Expected an integer between 1 and 65535."
  exit 2
fi

if [[ -z "$plugin_slug" ]]; then
  log_error "--plugin-slug is required"
  exit 2
fi

if [[ ! -f "$compose_file" ]]; then
  log_error "Compose file not found: ${compose_file}. Provide a caller-repo path with --compose-file."
  exit 2
fi

if ! resolved_plugin_src="$(cd "$plugin_src" 2>/dev/null && pwd -P)"; then
  log_error "Unable to resolve plugin source directory: ${plugin_src}"
  exit 2
fi

if [[ ! "$plugin_src_env" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
  log_error "Invalid --plugin-src-env value '$plugin_src_env'. Expected a valid environment variable name matching ^[A-Z_][A-Z0-9_]*$."
  exit 2
fi

run_in_plugin_src() {
  local command="$1"
  (
    cd "$resolved_plugin_src"
    bash -lc "$command"
  )
}

run_in_plugin_src_dir() {
  local working_directory="$1"
  local command="$2"
  (
    cd "$resolved_plugin_src/$working_directory"
    bash -lc "$command"
  )
}

cleanup_stack() {
  local exit_status=$?

  if [[ "$cleanup" == "true" ]]; then
    set +e
    docker_compose -f "$compose_file" down -v --remove-orphans
  fi

  return "$exit_status"
}
trap cleanup_stack EXIT

if [[ -n "$php_lint_command" || -n "$phpcs_warning_command" || -n "$phpunit_command" ]]; then
  if [[ -n "$php_lint_command" ]]; then
    run_in_plugin_src "$php_lint_command"
  fi
  if [[ -n "$phpcs_warning_command" ]]; then
    run_in_plugin_src "$phpcs_warning_command" || true
  fi
  if [[ -n "$phpunit_command" ]]; then
    run_in_plugin_src_dir "$phpunit_working_directory" "$phpunit_command"
  fi
fi

mkdir -p "$out_dir"
wp_site_url="http://localhost:${host_port}"
cat > "${out_dir}/wp-cli.yml" <<WPCLI
path: /var/www/html
url: ${wp_site_url}
color: false
disable_wp_cron: true
apache_modules:
  - mod_rewrite
WPCLI

wp_cli_config_contents="$(cat "${out_dir}/wp-cli.yml")"
container_wp_config_file="/tmp/wp-cli.yml"

run_wp_shell() {
  DEBUG=false docker_compose -f "$compose_file" run --rm \
    -e WP_CLI_CONFIG_CONTENTS="$wp_cli_config_contents" \
    -e WP_CLI_CONFIG_PATH="$container_wp_config_file" \
    "$wpcli_service" \
    sh -lc 'printf "%s\n" "$WP_CLI_CONFIG_CONTENTS" > "$WP_CLI_CONFIG_PATH"; wp --config="$WP_CLI_CONFIG_PATH" "$@"' -- "$@"
}

run_wp() {
  run_wp_shell "$@"
}

export "${plugin_src_env}=${resolved_plugin_src}"
docker_compose -f "$compose_file" up -d "$db_service" "$wordpress_service"

db_ready="false"
mysqladmin_ping_args=(ping -h 127.0.0.1 --silent)
[[ -n "$db_user" ]] && mysqladmin_ping_args+=("-u$db_user")
db_exec_env_args=()
[[ -n "$db_password" ]] && db_exec_env_args+=(-e MYSQL_PWD)

for ((i=0; i<db_wait_seconds; i++)); do
  if MYSQL_PWD="$db_password" DEBUG=false docker_compose -f "$compose_file" exec "${db_exec_env_args[@]}" -T "$db_service" \
    mysqladmin "${mysqladmin_ping_args[@]}" >/dev/null 2>&1; then
    db_ready="true"
    break
  fi
  sleep 1
done

if [[ "$db_ready" != "true" ]]; then
  log_error "Timed out waiting for database service '$db_service' to become ready after ${db_wait_seconds}s."
  exit 1
fi

WP_DB_PASSWORD="$db_password" DEBUG=false docker_compose -f "$compose_file" run --rm \
  -e WP_DB_HOST="${db_service}:3306" \
  -e WP_DB_NAME="$db_name" \
  -e WP_DB_USER="$db_user" \
  -e WP_DB_PASSWORD \
  -e WP_CLI_CONFIG_CONTENTS="$wp_cli_config_contents" \
  -e WP_CLI_CONFIG_PATH="$container_wp_config_file" \
  "$wpcli_service" \
  sh -lc 'printf "%s\n" "$WP_CLI_CONFIG_CONTENTS" > "$WP_CLI_CONFIG_PATH"; test -f /var/www/html/wp-config.php || wp --config="$WP_CLI_CONFIG_PATH" config create --dbname="$WP_DB_NAME" --dbuser="$WP_DB_USER" --dbpass="$WP_DB_PASSWORD" --dbhost="$WP_DB_HOST" --skip-check'

if [[ "$multisite" == "true" ]]; then
  run_wp config set WP_ALLOW_MULTISITE true --raw || true
  if ! run_wp core is-installed; then
    run_wp core multisite-install --url="$wp_site_url" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email" --skip-email
  fi
else
  if ! run_wp core is-installed; then
    run_wp core install --url="$wp_site_url" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email" --skip-email
  fi
fi

if [[ "$activate_network" == "true" ]]; then
  run_wp plugin activate "$plugin_slug" --network || run_wp plugin activate "$plugin_slug"
else
  run_wp plugin activate "$plugin_slug"
fi

run_wp plugin install plugin-check --activate || true

plugin_check_available="false"
if docker_compose -f "$compose_file" run --rm \
  -e WP_CLI_CONFIG_CONTENTS="$wp_cli_config_contents" \
  -e WP_CLI_CONFIG_PATH="$container_wp_config_file" \
  "$wpcli_service" \
  sh -lc 'printf "%s\n" "$WP_CLI_CONFIG_CONTENTS" > "$WP_CLI_CONFIG_PATH"; wp --config="$WP_CLI_CONFIG_PATH" help plugin check >/dev/null 2>&1'; then
  plugin_check_available="true"
  plugin_check_tmp="${out_dir}/plugin-check.json.tmp"
  rm -f "$plugin_check_tmp"
  plugin_check_exit=0
  run_wp plugin check "$plugin_slug" --format=json > "$plugin_check_tmp" || plugin_check_exit=$?
  if [[ -s "$plugin_check_tmp" ]]; then
    mv "$plugin_check_tmp" "${out_dir}/plugin-check.json"
  else
    rm -f "$plugin_check_tmp"
  fi
  if [[ "$plugin_check_exit" -ne 0 ]]; then
    log_info "wp plugin check exited with status ${plugin_check_exit}; evaluating captured JSON output when available."
  fi
elif [[ "$fail_on_findings" == "true" ]]; then
  log_error "wp plugin check is unavailable in strict mode; cannot evaluate plugin findings."
  exit 4
fi

if [[ -n "$meta_check_script" ]]; then
  docker_compose -f "$compose_file" run --rm \
    -e WP_META_CHECK_SCRIPT="$meta_check_script" \
    -e WP_CLI_CONFIG_CONTENTS="$wp_cli_config_contents" \
    -e WP_CLI_CONFIG_PATH="$container_wp_config_file" \
    "$wpcli_service" \
    sh -lc 'printf "%s\n" "$WP_CLI_CONFIG_CONTENTS" > "$WP_CLI_CONFIG_PATH"; wp --config="$WP_CLI_CONFIG_PATH" eval-file "$WP_META_CHECK_SCRIPT"' > "${out_dir}/meta-check.json"
fi

if [[ "$fail_on_findings" == "true" ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "python3 is required to evaluate WordPress plugin-check findings."
    exit 2
  fi

  OUT_DIR="$out_dir" PLUGIN_CHECK_AVAILABLE="$plugin_check_available" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

out_dir = Path(os.environ["OUT_DIR"])
plugin_check = out_dir / "plugin-check.json"
meta_check = out_dir / "meta-check.json"
plugin_check_available = os.environ["PLUGIN_CHECK_AVAILABLE"] == "true"

error_count = 0
parse_errors = []

def load_json(path: Path, label: str):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        parse_errors.append(f"{label} is not valid JSON: {exc}")
    except OSError as exc:
        parse_errors.append(f"{label} could not be read: {exc}")
    return None

if plugin_check.exists():
    data = load_json(plugin_check, "plugin-check.json")
    if isinstance(data, dict):
        if isinstance(data.get("errors"), int):
            error_count += data.get("errors", 0)
        for key in ("results", "issues", "messages"):
            items = data.get(key)
            if isinstance(items, list):
                for item in items:
                    if isinstance(item, dict):
                        level = str(item.get("severity") or item.get("level") or item.get("type") or "").lower()
                        if level in {"error", "critical", "fatal"}:
                            error_count += 1
                    else:
                        error_count += 1
    elif isinstance(data, list):
        error_count += len(data)
elif plugin_check_available:
    parse_errors.append("plugin-check.json was not created even though wp plugin check is available")

if meta_check.exists():
    data = load_json(meta_check, "meta-check.json")
    checks = data.get("checks") if isinstance(data, dict) else None
    if isinstance(checks, dict):
        for value in checks.values():
            if isinstance(value, dict) and value.get("ok") is False:
                error_count += 1

if parse_errors:
    for message in parse_errors:
        print(message, file=sys.stderr)
    sys.exit(5)

if error_count > 0:
    print(f"Plugin checks reported {error_count} error(s)")
    sys.exit(4)

print("No plugin-check errors detected.")
PY
fi
