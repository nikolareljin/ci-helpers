#!/usr/bin/env bash
# SCRIPT: ci_pimcore_bundle_check.sh
# DESCRIPTION: Run Pimcore bundle standalone and Docker-based checks from GitHub Actions or similar CI workflows.
# USAGE: scripts/ci_pimcore_bundle_check.sh [options]
# PARAMETERS:
#   --compose-file <path>                 Path to the Docker Compose file to use (default: test/docker-compose.yml).
#   --bundle-src <path>                   Path to the Pimcore bundle source directory (default: .).
#   --bundle-src-env <name>               Environment variable name used for the bundle source path (default: BUNDLE_SRC).
#   --php-service <name>                  Docker Compose service name for the PHP container (default: php).
#   --db-service <name>                   Docker Compose service name for the database container (default: db).
#   --db-user <user>                      Database user for the readiness check (default: empty; mysqladmin uses its default user).
#   --db-password <password>              Database password for the readiness check (default: empty).
#   --db-wait-seconds <seconds>           Seconds to wait for the database service to become ready (default: 20).
#   --out-dir <path>                      Directory for temporary or output artifacts (default: test/tmp).
#   --composer-command <command>          Composer command to run for dependency installation (default: composer install --no-interaction --prefer-dist).
#   --php-lint-command <command>          Standalone PHP lint command to run before Docker-based checks.
#   --phpcs-standalone-command <command>  Standalone PHPCS command to run before Docker-based checks.
#   --phpunit-standalone-command <command> Standalone PHPUnit command to run before Docker-based checks.
#   --phpunit-working-directory <path>    Working directory for standalone PHPUnit execution (default: .).
#   --phpcs-command <command>             PHPCS command to run inside the PHP container (default: vendor/bin/phpcs --standard=PSR12 --extensions=php src/).
#   --phpstan-command <command>           PHPStan command to run inside the PHP container.
#   --phpunit-command <command>           PHPUnit command to run inside the PHP container (default: vendor/bin/phpunit --testdox).
#   --phpunit-coverage-command <command>  PHPUnit coverage command to run inside the PHP container.
#   --fail-on-findings <true|false>       Whether findings should fail the script (default: true).
#   --cleanup <true|false>                Whether Docker resources should be cleaned up after execution (default: true).
#   -h, --help                            Show this help message.
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help docker

usage() { show_help "${BASH_SOURCE[0]}"; }

compose_file="test/docker-compose.yml"
bundle_src="."
bundle_src_env="BUNDLE_SRC"
php_service="php"
db_service="db"
db_user=""
db_password=""  # gitleaks:allow
db_wait_seconds="20"
out_dir="test/tmp"
composer_command="composer install --no-interaction --prefer-dist"
php_lint_command=""
phpcs_standalone_command=""
phpunit_standalone_command=""
phpunit_working_directory="."
phpcs_command="vendor/bin/phpcs --standard=PSR12 --extensions=php src/"
phpstan_command=""
phpunit_command="vendor/bin/phpunit --testdox"
phpunit_coverage_command=""
fail_on_findings="true"
cleanup="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) compose_file="$2"; shift 2 ;;
    --bundle-src) bundle_src="$2"; shift 2 ;;
    --bundle-src-env) bundle_src_env="$2"; shift 2 ;;
    --php-service) php_service="$2"; shift 2 ;;
    --db-service) db_service="$2"; shift 2 ;;
    --db-user) db_user="$2"; shift 2 ;;
    --db-password) db_password="$2"; shift 2 ;;
    --db-wait-seconds) db_wait_seconds="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --composer-command) composer_command="$2"; shift 2 ;;
    --php-lint-command) php_lint_command="$2"; shift 2 ;;
    --phpcs-standalone-command) phpcs_standalone_command="$2"; shift 2 ;;
    --phpunit-standalone-command) phpunit_standalone_command="$2"; shift 2 ;;
    --phpunit-working-directory) phpunit_working_directory="$2"; shift 2 ;;
    --phpcs-command) phpcs_command="$2"; shift 2 ;;
    --phpstan-command) phpstan_command="$2"; shift 2 ;;
    --phpunit-command) phpunit_command="$2"; shift 2 ;;
    --phpunit-coverage-command) phpunit_coverage_command="$2"; shift 2 ;;
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

validate_bool_option "--fail-on-findings" "$fail_on_findings"
validate_bool_option "--cleanup" "$cleanup"

if [[ ! "$db_wait_seconds" =~ ^[0-9]+$ ]] || (( db_wait_seconds <= 0 )); then
  log_error "Invalid value for --db-wait-seconds: '$db_wait_seconds'. Expected a positive integer."
  exit 2
fi

if [[ ! -f "$compose_file" ]]; then
  log_error "Compose file not found: ${compose_file}. Provide a caller-repo path with --compose-file."
  exit 2
fi

if ! resolved_bundle_src="$(cd "$bundle_src" 2>/dev/null && pwd -P)"; then
  log_error "Unable to resolve bundle source directory: ${bundle_src}"
  exit 2
fi

run_in_bundle_src() {
  local command="$1"
  (
    cd "$resolved_bundle_src"
    bash -lc "$command"
  )
}

run_in_bundle_src_dir() {
  local working_directory="$1"
  local command="$2"
  (
    cd "$resolved_bundle_src/$working_directory"
    bash -lc "$command"
  )
}

cleanup_stack() {
  local exit_code=$?

  if [[ "$cleanup" == "true" ]]; then
    if ! docker_compose -f "$compose_file" down -v --remove-orphans; then
      log_error "Failed to tear down test stack."
    else
      log_info "Test stack torn down."
    fi
  fi

  return "$exit_code"
}
trap cleanup_stack EXIT

if [[ -n "$php_lint_command" || -n "$phpcs_standalone_command" || -n "$phpunit_standalone_command" ]]; then
  if [[ -n "$composer_command" ]]; then
    run_in_bundle_src "$composer_command"
  fi
  if [[ -n "$php_lint_command" ]]; then
    run_in_bundle_src "$php_lint_command"
  fi
  if [[ -n "$phpcs_standalone_command" ]]; then
    run_in_bundle_src "$phpcs_standalone_command"
  fi
  if [[ -n "$phpunit_standalone_command" ]]; then
    run_in_bundle_src_dir "$phpunit_working_directory" "$phpunit_standalone_command"
  fi
fi

mkdir -p "$out_dir"
if [[ ! "$bundle_src_env" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
  log_error "Invalid bundle source environment variable name: '$bundle_src_env'. Expected pattern: ^[A-Z_][A-Z0-9_]*$"
  exit 2
fi
export "${bundle_src_env}=${resolved_bundle_src}"
docker_compose -f "$compose_file" up -d "$db_service" "$php_service"

db_ping_args=(-h 127.0.0.1 --silent)
[[ -n "$db_user" ]] && db_ping_args+=("-u$db_user")
db_exec_env_args=()
[[ -n "$db_password" ]] && db_exec_env_args+=(-e MYSQL_PWD)

elapsed=0
until MYSQL_PWD="$db_password" DEBUG=false docker_compose -f "$compose_file" exec "${db_exec_env_args[@]}" -T "$db_service" mysqladmin ping "${db_ping_args[@]}" 2>/dev/null; do
  sleep 2
  elapsed=$((elapsed + 2))
  if [[ "$elapsed" -ge "$db_wait_seconds" ]]; then
    log_error "Database did not become healthy within ${db_wait_seconds}s."
    docker_compose -f "$compose_file" logs "$db_service"
    exit 1
  fi
done

docker_compose -f "$compose_file" exec -T "$php_service" sh -lc "$composer_command"

if [[ -n "$phpcs_command" ]]; then
  if docker_compose -f "$compose_file" exec -T "$php_service" sh -lc "${phpcs_command} --report=checkstyle --report-file=/tmp/phpcs.xml"; then
    log_info "PHPCS: no violations."
  else
    docker_compose -f "$compose_file" cp "${php_service}:/tmp/phpcs.xml" "${out_dir}/phpcs.xml" 2>/dev/null || true
    log_error "PHPCS: violations found. Report saved to ${out_dir}/phpcs.xml"
    [[ "$fail_on_findings" == "true" ]] && exit 1
  fi
fi

if [[ -n "$phpstan_command" ]]; then
  if docker_compose -f "$compose_file" exec -T "$php_service" sh -lc "${phpstan_command} --error-format=checkstyle > /tmp/phpstan.xml 2>&1"; then
    log_info "PHPStan: no issues."
  else
    docker_compose -f "$compose_file" cp "${php_service}:/tmp/phpstan.xml" "${out_dir}/phpstan.xml" 2>/dev/null || true
    log_error "PHPStan: issues found. Report saved to ${out_dir}/phpstan.xml"
    [[ "$fail_on_findings" == "true" ]] && exit 1
  fi
fi

if [[ -n "$phpunit_command" ]]; then
  if docker_compose -f "$compose_file" exec -T "$php_service" sh -lc "${phpunit_command} --log-junit /tmp/phpunit.xml"; then
    log_info "PHPUnit: all tests passed."
  else
    docker_compose -f "$compose_file" cp "${php_service}:/tmp/phpunit.xml" "${out_dir}/phpunit.xml" 2>/dev/null || true
    log_error "PHPUnit: test failures. Report saved to ${out_dir}/phpunit.xml"
    [[ "$fail_on_findings" == "true" ]] && exit 1
  fi
fi

if [[ -n "$phpunit_coverage_command" ]]; then
  docker_compose -f "$compose_file" exec -T "$php_service" sh -lc "mkdir -p /tmp/coverage && ${phpunit_coverage_command} --coverage-clover /tmp/coverage/clover.xml"
  docker_compose -f "$compose_file" cp "${php_service}:/tmp/coverage/clover.xml" "${out_dir}/coverage-clover.xml" 2>/dev/null || true
  log_info "Coverage report saved to ${out_dir}/coverage-clover.xml"
fi
