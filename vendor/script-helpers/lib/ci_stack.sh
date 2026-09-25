#!/usr/bin/env bash
# Disposable service containers for a CI runner: start a database, wait for it
# to answer, and remove it with its anonymous volume afterwards.
#
# Extracted from ci_laravel.sh, which had the most complete implementation, and
# written to be the one copy. Before this, ci_laravel.sh and ci_wp_phpunit.sh
# each carried their own `start_database` and `cleanup`; the two had already
# drifted far enough that one guarded its EXIT trap against inherited subshells
# and the other did not, which is a bug that removes the caller's database
# container mid-run. A third and fourth copy for Drupal and Django would have
# made that worse.
#
# Everything here takes its inputs as arguments rather than reading the
# caller's variables, so a caller can be read without knowing this file.
#
# Usage:
#   shlib_import logging ci_stack
#   ci_stack_engine_for_image postgres:16        -> echoes "pgsql"
#   ci_stack_start_database --image mysql:8.0 --name db-1 ...
#   ci_stack_remove          --container db-1 --network net-1

# Usage: ci_stack_engine_for_image <image>
# Echoes mysql, pgsql or mariadb-as-mysql for a known image; returns 1 for an
# image it cannot place, so a caller can refuse rather than guess. Guessing is
# how a container comes up and is then talked to in the wrong dialect.
ci_stack_engine_for_image() {
  local image="${1:-}"
  case "$image" in
    *postgres*|*pgsql*) printf 'pgsql\n' ;;
    *mysql*|*mariadb*|*percona*) printf 'mysql\n' ;;
    *) return 1 ;;
  esac
}

# Usage: ci_stack_default_port <engine>
ci_stack_default_port() {
  case "${1:-}" in
    pgsql) printf '5432\n' ;;
    *)     printf '3306\n' ;;
  esac
}

# Usage: ci_stack_start_database --image <img> --engine <mysql|pgsql> --name <container>
#          [--network <name>] [--publish <host>:<port>] [--db <name>] [--user <u>]
#          [--password <p>] [--root-password <p>] [--wait-seconds <n>]
#
# --network and --publish are alternatives, not both: a caller whose steps run
# in a container reaches the database by name on a shared network, and one whose
# steps run on the host reaches a published port. Publishing when nothing will
# use it fails the run with "port is already allocated" for a port nobody wanted.
ci_stack_start_database() {
  local image="" engine="mysql" name="" network="" publish_spec=""
  local db_name="app" db_user="app" db_password="app" root_password="root"
  local wait_seconds=60

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)         image="$2"; shift 2 ;;
      --engine)        engine="$2"; shift 2 ;;
      --name)          name="$2"; shift 2 ;;
      --network)       network="$2"; shift 2 ;;
      --publish)       publish_spec="$2"; shift 2 ;;
      --db)            db_name="$2"; shift 2 ;;
      --user)          db_user="$2"; shift 2 ;;
      --password)      db_password="$2"; shift 2 ;;
      --root-password) root_password="$2"; shift 2 ;;
      --wait-seconds)  wait_seconds="$2"; shift 2 ;;
      *) log_error "ci_stack_start_database: unknown argument: $1"; return 2 ;;
    esac
  done

  [[ -n "$image" ]] || { log_error "ci_stack_start_database: --image is required"; return 2; }
  [[ -n "$name" ]]  || { log_error "ci_stack_start_database: --name is required"; return 2; }
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || {
    log_error "ci_stack_start_database: --wait-seconds must be a number: ${wait_seconds}"; return 2; }
  # Zero would run the readiness loop no times and return success against a
  # container that has not started. A caller asking for no wait wants no
  # database.
  (( wait_seconds > 0 )) || { log_error "ci_stack_start_database: --wait-seconds must be above 0"; return 2; }

  local internal_port; internal_port="$(ci_stack_default_port "$engine")"

  local net_args=() publish=()
  if [[ -n "$network" ]]; then
    docker network create "$network" >/dev/null || {
      log_error "ci_stack_start_database: could not create network ${network}"; return 1; }
    net_args=(--network "$network")
  fi
  if [[ -n "$publish_spec" ]]; then
    publish=(-p "${publish_spec}:${internal_port}")
    log_info "Starting ${image} as ${name} on ${publish_spec}"
  else
    log_info "Starting ${image} as ${name} on the ${network:-default} network"
  fi

  local env_args=()
  if [[ "$engine" == "pgsql" ]]; then
    env_args=(-e POSTGRES_DB="$db_name" -e POSTGRES_USER="$db_user" -e POSTGRES_PASSWORD="$db_password")
  else
    env_args=(-e MYSQL_DATABASE="$db_name" -e MYSQL_USER="$db_user" -e MYSQL_PASSWORD="$db_password")
    # The image refuses to initialise without one of these, and it dies during
    # its entrypoint rather than on connect -- so the symptom is the readiness
    # poll timing out with nothing about a password anywhere in the output.
    if [[ -n "$root_password" ]]; then
      env_args+=(-e MYSQL_ROOT_PASSWORD="$root_password")
    else
      env_args+=(-e MYSQL_ALLOW_EMPTY_PASSWORD=yes)
    fi
  fi

  # ${arr[@]+"${arr[@]}"}: bash 3.2, which macOS still ships, treats an empty
  # array as an unbound variable under `set -u`.
  docker run -d --name "$name" \
    ${net_args[@]+"${net_args[@]}"} \
    ${publish[@]+"${publish[@]}"} \
    "${env_args[@]}" \
    "$image" >/dev/null || {
      log_error "ci_stack_start_database: docker run failed for ${image}"; return 1; }

  # Poll rather than sleep: the image is ready when it answers, and a fixed
  # sleep is either too short on a loaded machine or wasted on a fast one.
  local probe waited=0
  if [[ "$engine" == "pgsql" ]]; then
    probe="pg_isready -U '${db_user}' -d '${db_name}' -h 127.0.0.1"
  else
    probe="mysqladmin ping -h 127.0.0.1 --silent"
  fi
  while (( waited < wait_seconds )); do
    if docker exec "$name" sh -c "$probe" >/dev/null 2>&1; then
      log_info "Database ready after ${waited}s"
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  log_error "Database did not become ready within ${wait_seconds}s"
  return 1
}

# Usage: ci_stack_command_program <command>
# Echoes the program a step command would run, or nothing when the command is a
# shell construct rather than a plain invocation. Environment prefixes are
# stepped over: `DJANGO_SETTINGS_MODULE=x python manage.py test` runs `python`.
ci_stack_command_program() {
  local command="${1:-}" word
  [[ -n "$command" ]] || return 0
  # A pipeline, a subshell, a redirect or a chain is not one program, and
  # guessing at which part to check is worse than not checking.
  case "$command" in
    *\;*|*\|*|*\&*|'('*|'{'*|*'>'*|*'<'*) return 0 ;;
    # A quoted program -- `"/opt/my tools/python" manage.py test` -- cannot be
    # split on whitespace without a shell, and splitting it anyway yields a
    # token like `"/opt/my` that no probe can find. Skipping the check is the
    # conservative answer; refusing a command that works is not.
    '"'*|"'"*) return 0 ;;
  esac
  for word in $command; do
    case "$word" in
      *=*) continue ;;          # an environment prefix, not the program
      env) continue ;;          # `env FOO=bar prog`
      *) printf '%s\n' "$word"; return 0 ;;
    esac
  done
}

# Usage: ci_stack_command_available <workdir> <image-or-empty> <docker-user-or-empty> <program>
# Returns 0 when the program can be run, 1 when it cannot.
#
# The probe runs WITH THE WORKDIR AS ITS CURRENT DIRECTORY. It did not, and a
# step command naming a path inside the project -- `bin/thing`,
# `.venv/bin/python`, `vendor/bin/phpunit` -- was refused before it ran, while
# the step itself would have `cd`-ed there and run it happily. A check that
# fires on correct input is worse than no check: it gets switched off.
ci_stack_command_available() {
  local workdir="${1:-.}" image="${2:-}" docker_user="${3:-}" program="${4:-}"
  [[ -n "$program" ]] || return 0
  # docker refuses a relative bind-mount source with a message about the source
  # path, which says nothing about the probe. Both shipped callers pass an
  # absolute path; normalise anyway so a future one cannot be surprised.
  [[ "$workdir" == /* ]] || workdir="$(cd "$workdir" 2>/dev/null && pwd -P)" || return 1
  local probe="command -v -- ${program} >/dev/null 2>&1"
  if [[ -z "$image" ]]; then
    ( cd "$workdir" 2>/dev/null && bash -c "$probe" ) && return 0
    return 1
  fi
  local user_args=()
  [[ -n "$docker_user" ]] && user_args=(-u "$docker_user" -e HOME=/tmp)
  docker run --rm ${user_args[@]+"${user_args[@]}"} \
    -v "${workdir}:/work" -w /work "$image" bash -c "$probe" >/dev/null 2>&1 && return 0
  return 1
}

# Usage: ci_stack_remove [--container <name>] [--network <name>]
#
# -v as well as -f: the mysql and postgres images declare a VOLUME, so every
# `docker run -d` creates an anonymous volume. Without -v the container goes and
# the volume stays -- seven runs of these scripts left 1.4 GB of orphaned data
# directories on one laptop, referenced by nothing. -v removes anonymous volumes
# and leaves a named one a caller supplied alone.
#
# Never fails: it is called from an EXIT trap, where a non-zero return would
# replace the real exit status with the cleanup's.
ci_stack_remove() {
  local container="" network=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --container) container="$2"; shift 2 ;;
      --network)   network="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$container" ]]; then
    log_info "Removing database container ${container}"
    docker rm -f -v "$container" >/dev/null 2>&1 || true
  fi
  if [[ -n "$network" ]]; then
    docker network rm "$network" >/dev/null 2>&1 || true
  fi
  return 0
}
