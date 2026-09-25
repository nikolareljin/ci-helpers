#!/usr/bin/env bash
# SCRIPT: ci_django.sh
# DESCRIPTION: Run a Django project's tests, in CI or on a laptop, with the database in Docker.
# USAGE: scripts/ci_django.sh [options]
# PARAMETERS:
#   --workdir <path>              Directory holding manage.py (default: .).
#   --db-engine <name>            sqlite | mysql | pgsql (default: sqlite).
#   --db-image <image>            Start this database in Docker and use it. The image
#                                 name decides the engine unless --db-engine says otherwise.
#   --db-host <host>              Host for a database this script did not start (default: 127.0.0.1).
#   --db-port <port>              Host port for a started database (default: 3306 / 5432).
#   --db-name <name>              Database name (default: django).
#   --db-user <user>              Database user (default: django).
#   --db-password <password>      Database password (default: django).
#   --db-root-password <password> Root password for a started MySQL image (default: root).
#                                 Empty starts it with MYSQL_ALLOW_EMPTY_PASSWORD. Ignored
#                                 by postgres, which has no separate root account.
#   --db-wait-seconds <n>         How long to wait for it to answer (default: 60).
#   --settings <module>           DJANGO_SETTINGS_MODULE for every step.
#   --install-command <command>   Dependency install. Empty skips it
#                                 (default: pip install -r requirements.txt, when that file exists).
#   --migrate-command <command>   Schema. Empty skips it (default: python manage.py migrate --noinput).
#   --test-command <command>      The tests (default: python manage.py test --noinput).
#   --python-image <image>        Run every step in this image instead of on the host.
#   --docker-user <user>          User for that image, as uid:gid (default: the invoking user).
#   -h, --help                    Show this help message.
# EXIT_CODES:
#   0  The tests passed.
#   1  A step failed; its own exit code is used where there is one.
#   2  Bad arguments, or a combination that cannot work.
# ----------------------------------------------------
#
# Django needs two things a generic Python runner does not provide: a database
# its settings can reach, and the migrations applied to it before the suite
# runs. scripts/ci_python.sh installs and runs pytest, and has no notion of
# either.
#
# The connection is exported as environment -- DATABASE_URL, and the discrete
# DJANGO_DB_* variables -- rather than written into a settings file. A settings
# module that reads os.environ works unchanged in CI and on a laptop; one that
# is rewritten by CI only works where CI rewrote it.
#
# sqlite is the default, so this is useful with no infrastructure at all. It is
# a file, not ":memory:", because each step is its own process -- a separate
# container when --python-image is used -- and an in-memory database dies with
# the step that migrated it. That is not hypothetical: ci_laravel.sh shipped
# with :memory: and `migrate` reported every migration applied while the next
# step could not find the migrations table.
# shellcheck source=/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help ci_stack

usage() { show_help "${BASH_SOURCE[0]}"; }

# Existence, not non-emptiness: several options here take an empty value on
# purpose (--install-command '' skips the install, --db-root-password '' means
# an empty root password).
need_value() {
  [[ $# -ge 2 ]] || { log_error "$1 requires a value"; usage >&2; exit 2; }
}

workdir="."
db_engine=""
db_image=""
db_host="127.0.0.1"
db_port=""
db_name="django"
db_user="django"
db_password="django"
db_root_password="root"
db_wait_seconds=60
settings_module=""
install_command="__default__"
migrate_command="python manage.py migrate --noinput"
test_command="python manage.py test --noinput"
python_image=""
docker_user="$(id -u):$(id -g)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) need_value "$@"; workdir="$2"; shift 2 ;;
    --db-engine) need_value "$@"; db_engine="$2"; shift 2 ;;
    --db-image) need_value "$@"; db_image="$2"; shift 2 ;;
    --db-host) need_value "$@"; db_host="$2"; shift 2 ;;
    --db-port) need_value "$@"; db_port="$2"; shift 2 ;;
    --db-name) need_value "$@"; db_name="$2"; shift 2 ;;
    --db-user) need_value "$@"; db_user="$2"; shift 2 ;;
    --db-password) need_value "$@"; db_password="$2"; shift 2 ;;
    --db-root-password) need_value "$@"; db_root_password="$2"; shift 2 ;;
    --db-wait-seconds) need_value "$@"; db_wait_seconds="$2"; shift 2 ;;
    --settings) need_value "$@"; settings_module="$2"; shift 2 ;;
    --install-command) need_value "$@"; install_command="$2"; shift 2 ;;
    --migrate-command) need_value "$@"; migrate_command="$2"; shift 2 ;;
    --test-command) need_value "$@"; test_command="$2"; shift 2 ;;
    --python-image) need_value "$@"; python_image="$2"; shift 2 ;;
    --docker-user) need_value "$@"; docker_user="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

[[ -d "$workdir" ]] || { log_error "--workdir does not exist: ${workdir}"; exit 2; }
abs_workdir="$(cd "$workdir" && pwd -P)"

[[ -f "${abs_workdir}/manage.py" ]] || {
  log_error "No manage.py in ${abs_workdir}; this does not look like a Django project."
  exit 2
}

# The image name decides the engine when the caller did not say. Checked before
# anything starts, so a typo is an argument error rather than a container that
# comes up and is then talked to in the wrong dialect.
if [[ -n "$db_image" ]]; then
  if [[ -z "$db_engine" ]]; then
    db_engine="$(ci_stack_engine_for_image "$db_image")" || {
      log_error "Cannot tell which engine '${db_image}' is. Pass --db-engine mysql or pgsql."
      exit 2
    }
  elif [[ "$db_engine" == "sqlite" ]]; then
    log_error "--db-engine sqlite does not use a database image; drop --db-image."
    exit 2
  fi
else
  db_engine="${db_engine:-sqlite}"
fi

case "$db_engine" in
  sqlite|mysql|pgsql) : ;;
  *) log_error "--db-engine must be sqlite, mysql or pgsql: ${db_engine}"; exit 2 ;;
esac

[[ -n "$db_port" ]] || db_port="$(ci_stack_default_port "$db_engine")"

# The default install runs only when there is something to install, so a project
# whose dependencies are already present is not failed by a missing file.
if [[ "$install_command" == "__default__" ]]; then
  if [[ -f "${abs_workdir}/requirements.txt" ]]; then
    install_command="pip install --no-input -r requirements.txt"
  else
    install_command=""
  fi
fi

sqlite_file=""
sqlite_path_in_env=""
if [[ "$db_engine" == "sqlite" ]]; then
  sqlite_file="${abs_workdir}/ci_django_$$.sqlite3"
  : > "$sqlite_file"
  if [[ -n "$python_image" ]]; then
    sqlite_path_in_env="/app/$(basename "$sqlite_file")"
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
  # Packages installed for a --python-image run live inside the project so they
  # survive between steps; they should not survive the run itself.
  if [[ -n "$python_image" && -d "${abs_workdir}/.ci-python-packages" ]]; then
    rm -rf "${abs_workdir}/.ci-python-packages"
  fi
  ci_stack_remove ${db_container:+--container "$db_container"} ${db_network:+--network "$db_network"}
}
# Guarded: a subshell inherits an EXIT trap, and bash runs it there when the
# subshell is signalled -- it would remove the database container while the
# tests are still using it. ${BASHPID-$$} rather than $BASHPID: bash 3.2, which
# macOS ships, does not define BASHPID, and $$ is the top-level shell's pid in
# every subshell, so the comparison degrades to always-true rather than
# disabling cleanup entirely.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup; fi' EXIT

if [[ -n "$db_image" ]]; then
  db_container="django-db-$$"
  publish_arg=""
  if [[ -n "$python_image" ]]; then
    db_network="django-net-$$"
  else
    publish_arg="${db_host}:${db_port}"
  fi
  ci_stack_start_database \
    --image "$db_image" --engine "$db_engine" --name "$db_container" \
    ${db_network:+--network "$db_network"} \
    ${publish_arg:+--publish "$publish_arg"} \
    --db "$db_name" --user "$db_user" --password "$db_password" \
    --root-password "$db_root_password" --wait-seconds "$db_wait_seconds" || exit 1
fi

# Where the steps reach the database from. Inside a container on the shared
# network that is the database's container name; on the host it is the host
# and published port.
effective_db_host="$db_host"
[[ -n "$python_image" && -n "$db_container" ]] && effective_db_host="$db_container"
effective_db_port="$db_port"
[[ -n "$python_image" && -n "$db_container" ]] && effective_db_port="$(ci_stack_default_port "$db_engine")"

step_env() {
  local -a env_pairs=()
  env_pairs+=("PYTHONUNBUFFERED=1" "PYTHONDONTWRITEBYTECODE=1")
  [[ -n "$settings_module" ]] && env_pairs+=("DJANGO_SETTINGS_MODULE=${settings_module}")
  env_pairs+=("DJANGO_DB_ENGINE=${db_engine}")
  if [[ "$db_engine" == "sqlite" ]]; then
    env_pairs+=("DJANGO_DB_NAME=${sqlite_path_in_env}" "DATABASE_URL=sqlite:///${sqlite_path_in_env}")
  else
    local scheme="postgres"
    [[ "$db_engine" == "mysql" ]] && scheme="mysql"
    env_pairs+=(
      "DJANGO_DB_NAME=${db_name}"
      "DJANGO_DB_USER=${db_user}"
      "DJANGO_DB_PASSWORD=${db_password}"
      "DJANGO_DB_HOST=${effective_db_host}"
      "DJANGO_DB_PORT=${effective_db_port}"
      "DATABASE_URL=${scheme}://${db_user}:${db_password}@${effective_db_host}:${effective_db_port}/${db_name}"
    )
  fi
  printf '%s\n' "${env_pairs[@]}"
}

step_failed() {   # <label> <command> <rc>
  log_error "$1 failed (exit $3): $2"
  exit "$3"
}

# Refuses before running rather than after: a missing interpreter otherwise
# surfaces as exit 127 from a shell, which names nothing a caller can act on.
require_step_command() {   # <label> <command>
  local label="$1" command="$2"
  local program; program="$(ci_stack_command_program "$command")"
  [[ -n "$program" ]] || return 0

  ci_stack_command_available "$abs_workdir" "$python_image" "$docker_user" "$program" && return 0

  local where="this machine"
  [[ -n "$python_image" ]] && where="$python_image"
  log_error "${label}: '${program}' is not on PATH in ${where}."
  if [[ "$program" == "python" ]]; then
    log_error "The official python images provide 'python'; a system one may only provide 'python3'."
    log_error "Pass --test-command 'python3 manage.py test' or run it with --python-image."
  elif [[ "$program" == "pip" ]]; then
    log_error "Use 'python -m pip' instead of 'pip', or run it with --python-image."
  else
    log_error "Pass a command the image has, or an empty one to skip the step."
  fi
  exit 1
}

run_step() {   # <label> <command>
  local label="$1" command="$2"
  [[ -n "$command" ]] || { log_info "${label}: skipped (no command)"; return 0; }
  require_step_command "$label" "$command"

  local -a env_args=()
  while IFS= read -r pair; do env_args+=(-e "$pair"); done < <(step_env)

  if [[ -z "$python_image" ]]; then
    log_info "${label} (host): ${command}"
    local -a exports=()
    while IFS= read -r pair; do exports+=("$pair"); done < <(step_env)
    ( cd "$abs_workdir" && env "${exports[@]}" bash -c "$command" ) || step_failed "$label" "$command" "$?"
    return 0
  fi

  log_info "${label} (${python_image}): ${command}"
  local -a net_args=()
  [[ -n "$db_network" ]] && net_args=(--network "$db_network")
  local -a user_args=()
  [[ -n "$docker_user" ]] && user_args=(-u "$docker_user")
  # HOME: pip writes a cache, and with no writable HOME it warns on every run.
  #
  # PIP_TARGET and PYTHONPATH point at a directory inside the mounted workdir,
  # because each step is its own `docker run --rm`: a plain `pip install` puts
  # packages in the container's site-packages and the next step gets a fresh
  # container without them. Composer has no such problem -- it writes into the
  # mounted vendor/ -- so this only bites the Python runner, and it bit it
  # silently: the install step reported success and the step after it failed
  # with ModuleNotFoundError.
  #
  # bash -c, not -lc: a login shell replaces PATH with /etc/profile's default.
  docker run --rm \
    ${net_args[@]+"${net_args[@]}"} \
    ${user_args[@]+"${user_args[@]}"} \
    -e HOME=/tmp \
    -e PIP_TARGET=/app/.ci-python-packages \
    -e PYTHONPATH=/app/.ci-python-packages \
    -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "${env_args[@]}" \
    -v "${abs_workdir}:/app" -w /app \
    "$python_image" bash -c "$command" || step_failed "$label" "$command" "$?"
}

run_step "Dependencies" "$install_command"
run_step "Schema" "$migrate_command"
run_step "Tests" "$test_command"

log_info "Django tests passed"
