#!/usr/bin/env bash
# SCRIPT: ci_laravel.sh
# DESCRIPTION: Run a Laravel application's tests, in CI or on a laptop, with the database in Docker.
# USAGE: scripts/ci_laravel.sh [options]
# PARAMETERS:
#   --workdir <path>              Application directory (default: .).
#   --db-connection <name>        sqlite | mysql | pgsql (default: sqlite).
#   --db-image <image>            Start this database in Docker and use it. Implies a
#                                 server connection; the image name decides mysql or pgsql
#                                 unless --db-connection says otherwise.
#   --db-host <host>              Database host when one is not started (default: 127.0.0.1).
#   --db-port <port>              Host port for a started database (default: 3306 / 5432).
#   --db-name <name>              Database name (default: laravel).
#   --db-user <user>              Database user (default: laravel).
#   --db-password <password>      Database password (default: laravel).
#   --db-root-password <password> Root password for a started MySQL image (default: root).
#                                 Empty starts it with MYSQL_ALLOW_EMPTY_PASSWORD. Ignored
#                                 by postgres, which has no separate root account.
#   --db-wait-seconds <n>         How long to wait for it to answer (default: 60).
#   --install-command <command>   Dependency install. Empty skips it
#                                 (default: composer install --no-interaction --prefer-dist).
#   --migrate-command <command>   Schema. Empty skips it (default: php artisan migrate --force).
#   --test-command <command>      The tests (default: php artisan test).
#   --env-file <path>             Environment file to copy to .env. Empty picks
#                                 .env.testing, then .env.example, when .env is absent.
#   --php-image <image>           Run everything in this image instead of on the host.
#                                 The image must have bash.
#   --docker-user <user>          User for that image, as uid:gid (default: the invoking user).
#   -h, --help                    Show this help message.
# EXIT_CODES:
#   0  The tests passed.
#   1  A step failed; its own exit code is used where there is one.
#   2  Bad arguments, or a combination that cannot work.
# ----------------------------------------------------
#
# Laravel's test suite needs three things a generic PHP runner does not provide:
# a .env, an APP_KEY in it, and a database its config can reach. Without the key
# every test fails with "No application encryption key has been specified", which
# says nothing about the real problem -- that nobody ran `artisan key:generate`.
#
# sqlite is the default because it needs no infrastructure and is what most
# Laravel suites already use. `--db-image` swaps in a real server for the suites
# that need one, and the same command then runs in CI and on a laptop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { show_help "${BASH_SOURCE[0]}"; }

# Existence, not non-emptiness: several options here take an empty value on
# purpose (--install-command '' skips the install, --db-root-password '' means
# an empty root password). Without this, a flag written last with no value
# reached `"$2"` under `set -u` and the script died with
# "line 82: $2: unbound variable" and exit 1 -- a bash internal error where its
# own EXIT_CODES promise 2 and a sentence naming the option.
need_value() {
  [[ $# -ge 2 ]] || { log_error "$1 requires a value"; usage >&2; exit 2; }
}

workdir="."
db_connection=""
db_image=""
db_host="127.0.0.1"
db_port=""
db_name="laravel"
db_user="laravel"
db_password="laravel"
db_root_password="root"
db_wait_seconds=60
install_command="composer install --no-interaction --prefer-dist"
migrate_command="php artisan migrate --force"
test_command="php artisan test"
env_file=""
php_image=""
docker_user="$(id -u):$(id -g)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) need_value "$@"; workdir="$2"; shift 2 ;;
    --db-connection) need_value "$@"; db_connection="$2"; shift 2 ;;
    --db-image) need_value "$@"; db_image="$2"; shift 2 ;;
    --db-host) need_value "$@"; db_host="$2"; shift 2 ;;
    --db-port) need_value "$@"; db_port="$2"; shift 2 ;;
    --db-name) need_value "$@"; db_name="$2"; shift 2 ;;
    --db-user) need_value "$@"; db_user="$2"; shift 2 ;;
    --db-password) need_value "$@"; db_password="$2"; shift 2 ;;
    --db-root-password) need_value "$@"; db_root_password="$2"; shift 2 ;;
    --db-wait-seconds) need_value "$@"; db_wait_seconds="$2"; shift 2 ;;
    --install-command) need_value "$@"; install_command="$2"; shift 2 ;;
    --migrate-command) need_value "$@"; migrate_command="$2"; shift 2 ;;
    --test-command) need_value "$@"; test_command="$2"; shift 2 ;;
    --env-file) need_value "$@"; env_file="$2"; shift 2 ;;
    --php-image) need_value "$@"; php_image="$2"; shift 2 ;;
    --docker-user) need_value "$@"; docker_user="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

[[ -d "$workdir" ]] || { log_error "--workdir does not exist: ${workdir}"; exit 2; }
abs_workdir="$(cd "$workdir" && pwd -P)"

[[ -f "${abs_workdir}/artisan" ]] || {
  log_error "No artisan in ${abs_workdir}; this does not look like a Laravel application."
  exit 2
}

# The image name decides the engine when the caller did not say. Checked before
# anything starts, so a typo is an argument error rather than a container that
# comes up and is then talked to in the wrong dialect.
if [[ -n "$db_image" && -z "$db_connection" ]]; then
  case "$db_image" in
    *postgres*|*pgsql*) db_connection="pgsql" ;;
    *mysql*|*mariadb*) db_connection="mysql" ;;
    *)
      log_error "Cannot tell which engine '${db_image}' is. Pass --db-connection mysql or pgsql."
      exit 2 ;;
  esac
fi
db_connection="${db_connection:-sqlite}"

case "$db_connection" in
  sqlite|mysql|pgsql) : ;;
  *) log_error "--db-connection must be sqlite, mysql or pgsql: ${db_connection}"; exit 2 ;;
esac

if [[ "$db_connection" == "sqlite" && -n "$db_image" ]]; then
  log_error "--db-image starts a database server; --db-connection sqlite does not use one."
  exit 2
fi

if [[ -z "$db_port" ]]; then
  [[ "$db_connection" == "pgsql" ]] && db_port=5432 || db_port=3306
fi

# The sqlite file lives inside the application, because that is the directory
# the container mounts -- anywhere else and the steps would not share it. Named
# for this run so a concurrent one cannot collide, and removed on the way out.
sqlite_file=""
sqlite_path_in_env=""

if [[ "$db_connection" == "sqlite" ]]; then
  mkdir -p "${abs_workdir}/database"
  sqlite_file="${abs_workdir}/database/ci_laravel_$$.sqlite"
  : > "$sqlite_file"
  # The path as the steps will see it: the mount point inside the container, or
  # the real path when they run on the host.
  if [[ -n "$php_image" ]]; then
    sqlite_path_in_env="/app/database/$(basename "$sqlite_file")"
  else
    sqlite_path_in_env="$sqlite_file"
  fi
fi

db_container=""
db_network=""


cleanup() {
  if [[ -n "$sqlite_file" && -f "$sqlite_file" ]]; then
    rm -f "$sqlite_file"
  fi
  if [[ -n "$db_container" ]]; then
    log_info "Removing database container ${db_container}"
    # -v as well as -f: the mysql and postgres images declare a VOLUME, so
    # `docker run -d` creates an anonymous volume for every container. Without
    # -v the container goes and the volume stays -- three runs of this script
    # left 612 MB of orphans on a laptop before anyone noticed. -v removes only
    # anonymous volumes; a named one passed by a caller is left alone.
    docker rm -f -v "$db_container" >/dev/null 2>&1 || true
  fi
  if [[ -n "$db_network" ]]; then
    docker network rm "$db_network" >/dev/null 2>&1 || true
  fi
}
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup; fi' EXIT

# ---------------------------------------------------------------------------
# The database, when one is asked for.
# ---------------------------------------------------------------------------
start_database() {
  db_container="laravel-db-$$"
  local net_args=()
  if [[ -n "$php_image" ]]; then
    # A user-defined network rather than --network host: the PHP container
    # reaches the database by container name, which works the same on Linux and
    # macOS. Publishing to loopback would only work on Linux.
    db_network="laravel-net-$$"
    docker network create "$db_network" >/dev/null
    net_args=(--network "$db_network")
  fi

  # Publish only when the tests run on the host and need to reach it. With
  # --php-image they reach it by container name, and publishing anyway fails the
  # run with "port is already allocated" for a port nothing was going to use.
  local publish=()
  local internal_port=3306
  [[ "$db_connection" == "pgsql" ]] && internal_port=5432
  if [[ -z "$php_image" ]]; then
    publish=(-p "${db_host}:${db_port}:${internal_port}")
    log_info "Starting ${db_image} as ${db_container} on ${db_host}:${db_port}"
  else
    log_info "Starting ${db_image} as ${db_container} on the ${db_network} network"
  fi

  local env_args=()
  if [[ "$db_connection" == "pgsql" ]]; then
    env_args=(-e POSTGRES_DB="$db_name" -e POSTGRES_USER="$db_user" -e POSTGRES_PASSWORD="$db_password")
  else
    env_args=(-e MYSQL_DATABASE="$db_name" -e MYSQL_USER="$db_user"
              -e MYSQL_PASSWORD="$db_password")
    # The image refuses to initialise without one of these, and it dies during
    # entrypoint rather than on connect -- so the symptom is the readiness poll
    # timing out after --db-wait-seconds with nothing about a password in it.
    if [[ -n "$db_root_password" ]]; then
      env_args+=(-e MYSQL_ROOT_PASSWORD="$db_root_password")
    else
      env_args+=(-e MYSQL_ALLOW_EMPTY_PASSWORD=yes)
    fi
  fi

  # ${arr[@]+"${arr[@]}"}: bash 3.2, which macOS still ships, treats an empty
  # array as an unbound variable under `set -u`.
  docker run -d --name "$db_container" \
    ${net_args[@]+"${net_args[@]}"} \
    ${publish[@]+"${publish[@]}"} \
    "${env_args[@]}" \
    "$db_image" >/dev/null

  # Poll rather than sleep: the image is ready when it answers, and a fixed
  # sleep is either too short on a loaded machine or wasted time on a fast one.
  local waited=0
  local probe
  if [[ "$db_connection" == "pgsql" ]]; then
    probe="pg_isready -U '${db_user}' -d '${db_name}' -h 127.0.0.1"
  else
    probe="mysqladmin ping -h 127.0.0.1 --silent"
  fi
  while (( waited < db_wait_seconds )); do
    if docker exec "$db_container" sh -c "$probe" >/dev/null 2>&1; then
      log_info "Database ready after ${waited}s"
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  log_error "Database did not become ready within ${db_wait_seconds}s"
  exit 1
}

[[ -n "$db_image" ]] && start_database

# Where the tests reach the database from. Inside a PHP container on the shared
# network that is the container's name; on the host it is what was published.
if [[ -n "$php_image" && -n "$db_container" ]]; then
  effective_db_host="$db_container"
  effective_db_port=3306
  [[ "$db_connection" == "pgsql" ]] && effective_db_port=5432
else
  if [[ -n "$php_image" && "$db_connection" != "sqlite" ]]; then
    case "$db_host" in
      127.0.0.1|localhost|::1)
        log_error "--php-image runs the tests in a container, where '${db_host}' is that container."
        log_error "Pass --db-image to have one started, or --db-host with an address the container can reach."
        exit 2 ;;
    esac
  fi
  effective_db_host="$db_host"
  effective_db_port="$db_port"
fi

# ---------------------------------------------------------------------------
# Steps, on the host or in a container.
# ---------------------------------------------------------------------------
step_failed() {   # <label> <command> <rc>
  [[ "$3" -eq 0 ]] && return 0
  log_error "${1} failed (exit ${3}): ${2}"
  exit "$3"
}

# The environment Laravel's config reads. Passed as real environment rather than
# written into .env: env() reads the process environment first, so a caller's
# .env stays as it is and nothing has to be edited back afterwards.
app_env_args() {
  printf '%s\n' \
    "APP_ENV=testing" \
    "DB_CONNECTION=${db_connection}"
  if [[ "$db_connection" == "sqlite" ]]; then
    # A file, not :memory:. Each step is its own process -- a separate container
    # when --php-image is used -- so an in-memory database dies with the step
    # that made it: `migrate` reported every migration DONE and the very next
    # step answered "Migration table not found". The schema has to outlive the
    # step that creates it, exactly as it does for a real server.
    printf '%s\n' "DB_DATABASE=${sqlite_path_in_env}"
  else
    printf '%s\n' \
      "DB_HOST=${effective_db_host}" \
      "DB_PORT=${effective_db_port}" \
      "DB_DATABASE=${db_name}" \
      "DB_USERNAME=${db_user}" \
      "DB_PASSWORD=${db_password}"
  fi
}

run_step() {   # <label> <command>
  local label="$1" command="$2" rc=0
  [[ -n "$command" ]] || { log_info "${label}: skipped (no command)"; return 0; }

  # Read once. The host form is NAME=value for `env`; the container form is the
  # same pairs each behind -e. Building both every time meant the host branch
  # assembled a docker array it then returned without using.
  local pairs=()
  while IFS= read -r pair; do
    [[ -n "$pair" ]] && pairs+=("$pair")
  done < <(app_env_args)

  if [[ -z "$php_image" ]]; then
    log_info "${label} (host): ${command}"
    ( cd "$abs_workdir" && env "${pairs[@]}" bash -c "$command" ) || rc=$?
    step_failed "$label" "$command" "$rc"
    return 0
  fi

  local env_args=()
  local p
  for p in "${pairs[@]}"; do env_args+=(-e "$p"); done

  local user_args=()
  # As the invoking user, or composer and artisan leave root-owned files in the
  # caller's repository. HOME with it: a uid the image does not know has no home,
  # and composer wants one.
  [[ -n "$docker_user" ]] && user_args=(-u "$docker_user" -e HOME=/tmp)

  local net_args=()
  [[ -n "$db_network" ]] && net_args=(--network "$db_network")

  log_info "${label} (${php_image}): ${command}"
  # bash -c, not -lc: a login shell sources /etc/profile and replaces PATH.
  docker run --rm -t \
    ${user_args[@]+"${user_args[@]}"} \
    ${net_args[@]+"${net_args[@]}"} \
    "${env_args[@]}" \
    -v "${abs_workdir}":/app -w /app \
    "$php_image" bash -c "$command" || rc=$?
  step_failed "$label" "$command" "$rc"
}

# ---------------------------------------------------------------------------
# A .env with a key in it. Laravel refuses to boot without APP_KEY, and the
# error it gives names the key rather than the missing file.
# ---------------------------------------------------------------------------
if [[ ! -f "${abs_workdir}/.env" ]]; then
  candidate="$env_file"
  if [[ -z "$candidate" ]]; then
    for c in .env.testing .env.example; do
      [[ -f "${abs_workdir}/${c}" ]] && { candidate="$c"; break; }
    done
  fi
  if [[ -n "$candidate" ]]; then
    # Resolved as given first, then relative to the application. Prefixing the
    # application directory unconditionally refused an absolute path -- and said
    # "not found" about a file that was there, naming a path nobody had passed.
    source_env=""
    if [[ -f "$candidate" ]]; then
      source_env="$candidate"
    elif [[ -f "${abs_workdir}/${candidate}" ]]; then
      source_env="${abs_workdir}/${candidate}"
    else
      log_error "--env-file not found, as given or under ${abs_workdir}: ${candidate}"
      exit 2
    fi
    log_info "Creating .env from ${source_env}"
    cp "$source_env" "${abs_workdir}/.env"
  else
    log_info "No .env, .env.testing or .env.example; creating an empty .env"
    : > "${abs_workdir}/.env"
  fi
fi

# ---------------------------------------------------------------------------
# The PDO driver, before anything tries to use it.
#
# The official php images ship no database drivers at all, so `php:8.4-cli`
# against a started MySQL fails inside artisan with "could not find driver" and
# a stack trace about Connector.php -- which reads like a Laravel problem and is
# an image problem. Checked here so the message names the cause and the fix.
# ---------------------------------------------------------------------------
require_pdo_driver() {
  # php itself first. Without it every step dies with 127 and a message that
  # names the step rather than the cause -- "Application key failed (exit 127)"
  # is true and unhelpful.
  require_step_command "PHP" "php --version"

  [[ "$db_connection" == "sqlite" ]] && return 0

  local driver="$db_connection"
  [[ "$driver" == "pgsql" ]] && driver="pgsql" || driver="mysql"

  local probe="php -r 'exit(in_array(\"${driver}\", PDO::getAvailableDrivers()) ? 0 : 1);'"
  local ok=0
  if [[ -z "$php_image" ]]; then
    ( cd "$abs_workdir" && bash -c "$probe" ) >/dev/null 2>&1 || ok=$?
  else
    local user_args=()
    [[ -n "$docker_user" ]] && user_args=(-u "$docker_user" -e HOME=/tmp)
    docker run --rm ${user_args[@]+"${user_args[@]}"} "$php_image" \
      bash -c "$probe" >/dev/null 2>&1 || ok=$?
  fi

  if [[ "$ok" -ne 0 ]]; then
    local where="this PHP"
    [[ -n "$php_image" ]] && where="$php_image"
    log_error "${where} has no pdo_${driver} driver, so --db-connection ${db_connection} cannot connect."
    log_error "The official php images ship no database drivers. Either use an image that has one,"
    log_error "or build one:  FROM ${php_image:-php:8.4-cli}"
    log_error "               RUN docker-php-ext-install pdo_${driver}"
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# The command that installs dependencies has to exist.
#
# The official php images ship no composer either, so the default
# `composer install` against `php:8.4-cli` dies at the first step with
# "composer: command not found" and exit 127. Checked in the environment the
# step will actually run in, so the message can name the image.
# ---------------------------------------------------------------------------
require_step_command() {   # <label> <command>
  local label="$1" command="$2"
  [[ -n "$command" ]] || return 0

  # The first word is what has to be on PATH; the rest is arguments.
  local program="${command%% *}"
  # A command that is a shell construct rather than a program is left alone.
  case "$program" in
    *=*|*\;*|'('|'{') return 0 ;;
  esac

  local probe="command -v ${program} >/dev/null 2>&1"
  local ok=0
  if [[ -z "$php_image" ]]; then
    bash -c "$probe" || ok=$?
  else
    local user_args=()
    [[ -n "$docker_user" ]] && user_args=(-u "$docker_user" -e HOME=/tmp)
    docker run --rm ${user_args[@]+"${user_args[@]}"} "$php_image" \
      bash -c "$probe" >/dev/null 2>&1 || ok=$?
  fi

  if [[ "$ok" -ne 0 ]]; then
    local where="this machine"
    [[ -n "$php_image" ]] && where="$php_image"
    log_error "${label}: '${program}' is not on PATH in ${where}."
    if [[ "$program" == "php" ]]; then
      log_error "Run it in a container with --php-image, or install PHP on this machine."
    elif [[ "$program" == "composer" ]]; then
      log_error "The official php images ship no composer. Use an image that has it,"
      log_error "install the dependencies beforehand and pass --install-command '',"
      log_error "or build one:  FROM ${php_image:-php:8.4-cli}"
      log_error "               COPY --from=composer:2 /usr/bin/composer /usr/bin/composer"
    else
      log_error "Pass a command the image has, or an empty one to skip the step."
    fi
    exit 2
  fi
}

require_pdo_driver
require_step_command "Dependencies" "$install_command"

run_step "Dependencies" "$install_command"

# key:generate after the install, because artisan needs the autoloader. Only
# when the file has no usable key, so a caller's own key is left alone.
if ! grep -qE '^APP_KEY=.+' "${abs_workdir}/.env" 2>/dev/null; then
  run_step "Application key" "php artisan key:generate --force"
fi

run_step "Schema" "$migrate_command"
run_step "Tests" "$test_command"

log_info "Laravel tests passed"
