#!/usr/bin/env bash
# SCRIPT: ci_python.sh
# DESCRIPTION: Run Python CI steps (install + pytest) with configurable commands.
# USAGE: scripts/ci_python.sh [--workdir <path>] [--no-install] [--requirements <file>] [--constraints <file>]
# PARAMETERS:
#   --workdir <path>     Working directory for Python commands (default: current dir).
#   --no-install         Skip dependency install step.
#   --requirements <f>   Requirements file to install (default: requirements.txt if present).
#   --constraints <f>    Constraints file to use (optional).
#   --extra-install <c>  Extra packages to install (e.g. "pytest tldextract").
#   --test-cmd <c>       Test command (default: python -m pytest -q).
#   --pip-cmd <c>        Override pip install command (replaces default install logic).
#   --version <tag>      Docker image tag (default: from ci_defaults module).
#   --image <img>        Docker image override (default: python:<version>).
#   --no-docker          Run on the host instead of Docker.
#   --db-image <image>   Start this database in Docker and export a connection to it.
#                        The image name decides mysql or pgsql unless --db-engine says.
#   --db-engine <name>   mysql | pgsql. Only needed for an image the name cannot place.
#   --db-name <name>     Database name (default: app).
#   --db-user <user>     Database user (default: app).
#   --db-password <p>    Database password (default: app).
#   --db-root-password <p>  Root password for a started MySQL image (default: root).
#                        Empty starts it with MYSQL_ALLOW_EMPTY_PASSWORD; postgres ignores it.
#   --db-port <port>     Host port, when the steps run with --no-docker (default: 3306 / 5432).
#   --db-wait-seconds <n>   How long to wait for it to answer (default: 60).
#   --env NAME=VALUE     Extra environment for every step. Repeatable.
#   -h, --help           Show this help message.
# ----------------------------------------------------
#
# No database is started unless --db-image says so, because most Python projects
# do not want one: of the six Flask applications this was measured against, one
# used a database and five did not. A runner that starts postgres by default
# would be wrong five times out of six.
#
# When one is asked for, the connection is exported as environment --
# DATABASE_URL and the discrete DB_* variables -- rather than written into a
# settings file. Code that reads os.environ works unchanged in CI and locally;
# code that CI rewrites works only where CI rewrote it.
#
# scripts/ci_django.sh remains the runner for a Django project: it also creates
# the database, applies migrations and knows what manage.py is.
set -euo pipefail

if [[ "${CI:-}" == "true" ]]; then
  echo "This script is intended for local use only." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging ci_defaults ci_stack

WORKDIR="."
NO_INSTALL=false
REQ_FILE=""
CONSTRAINTS_FILE=""
EXTRA_INSTALL=""
TEST_CMD="python -m pytest -q"
PIP_CMD=""
USE_DOCKER=true
IMAGE_TAG="$CI_DEFAULT_PYTHON_VERSION"
IMAGE_OVERRIDE=""
DB_IMAGE=""
DB_ENGINE=""
DB_NAME="app"
DB_USER="app"
DB_PASSWORD="app"
DB_ROOT_PASSWORD="root"
DB_PORT=""
DB_WAIT_SECONDS=60
EXTRA_ENV=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --no-install) NO_INSTALL=true; shift;;
    --requirements) REQ_FILE="$2"; shift 2;;
    --constraints) CONSTRAINTS_FILE="$2"; shift 2;;
    --extra-install) EXTRA_INSTALL="$2"; shift 2;;
    --test-cmd) TEST_CMD="$2"; shift 2;;
    --pip-cmd) PIP_CMD="$2"; shift 2;;
    --version) IMAGE_TAG="$2"; shift 2;;
    --image) IMAGE_OVERRIDE="$2"; shift 2;;
    --no-docker) USE_DOCKER=false; shift;;
    --db-image) DB_IMAGE="$2"; shift 2;;
    --db-engine) DB_ENGINE="$2"; shift 2;;
    --db-name) DB_NAME="$2"; shift 2;;
    --db-user) DB_USER="$2"; shift 2;;
    --db-password) DB_PASSWORD="$2"; shift 2;;
    --db-root-password) DB_ROOT_PASSWORD="$2"; shift 2;;
    --db-port) DB_PORT="$2"; shift 2;;
    --db-wait-seconds) DB_WAIT_SECONDS="$2"; shift 2;;
    --env)
      case "$2" in
        *=*) EXTRA_ENV+=("$2") ;;
        *) log_error "--env expects NAME=VALUE, got: $2"; exit 1 ;;
      esac
      shift 2;;
    -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# The database, when one is asked for. lib/ci_stack.sh is the one copy of this;
# ci_laravel.sh, ci_django.sh and ci_wp_phpunit.sh use the same functions.
# ---------------------------------------------------------------------------
DB_CONTAINER=""
DB_NETWORK=""

cleanup_database() {
  ci_stack_remove ${DB_CONTAINER:+--container "$DB_CONTAINER"} ${DB_NETWORK:+--network "$DB_NETWORK"}
}
# Guarded: a subshell inherits an EXIT trap, and bash runs it there when the
# subshell is signalled -- it would remove the database while the tests are
# still using it. ${BASHPID-$$} rather than $BASHPID: bash 3.2, which macOS
# ships, does not define BASHPID, and $$ is the top-level shell's pid in every
# subshell, so the comparison degrades to always-true rather than disabling
# cleanup.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup_database; fi' EXIT

DB_HOST_FOR_STEPS=""
DB_PORT_FOR_STEPS=""
if [[ -n "$DB_IMAGE" ]]; then
  if [[ -z "$DB_ENGINE" ]]; then
    DB_ENGINE="$(ci_stack_engine_for_image "$DB_IMAGE")" || {
      log_error "Cannot tell which engine '${DB_IMAGE}' is. Pass --db-engine mysql or pgsql."
      exit 1
    }
  fi
  [[ -n "$DB_PORT" ]] || DB_PORT="$(ci_stack_default_port "$DB_ENGINE")"

  DB_CONTAINER="ci-python-db-$$"
  publish_arg=""
  if [[ "$USE_DOCKER" == "true" ]]; then
    # The steps run in a container, so they reach the database by name on a
    # shared network. Publishing a port nothing will use fails the run with
    # "port is already allocated".
    DB_NETWORK="ci-python-net-$$"
  else
    publish_arg="127.0.0.1:${DB_PORT}"
  fi
  ci_stack_start_database \
    --image "$DB_IMAGE" --engine "$DB_ENGINE" --name "$DB_CONTAINER" \
    ${DB_NETWORK:+--network "$DB_NETWORK"} \
    ${publish_arg:+--publish "$publish_arg"} \
    --db "$DB_NAME" --user "$DB_USER" --password "$DB_PASSWORD" \
    --root-password "$DB_ROOT_PASSWORD" --wait-seconds "$DB_WAIT_SECONDS" || exit 1

  if [[ "$USE_DOCKER" == "true" ]]; then
    DB_HOST_FOR_STEPS="$DB_CONTAINER"
    DB_PORT_FOR_STEPS="$(ci_stack_default_port "$DB_ENGINE")"
  else
    DB_HOST_FOR_STEPS="127.0.0.1"
    DB_PORT_FOR_STEPS="$DB_PORT"
  fi

  scheme="postgresql"
  [[ "$DB_ENGINE" == "mysql" ]] && scheme="mysql"
  EXTRA_ENV+=(
    "DATABASE_URL=${scheme}://${DB_USER}:${DB_PASSWORD}@${DB_HOST_FOR_STEPS}:${DB_PORT_FOR_STEPS}/${DB_NAME}"
    "DB_ENGINE=${DB_ENGINE}"
    "DB_NAME=${DB_NAME}"
    "DB_USER=${DB_USER}"
    "DB_PASSWORD=${DB_PASSWORD}"
    "DB_HOST=${DB_HOST_FOR_STEPS}"
    "DB_PORT=${DB_PORT_FOR_STEPS}"
  )
fi

if [[ -n "$IMAGE_OVERRIDE" ]]; then
  IMAGE="$IMAGE_OVERRIDE"
else
  IMAGE="${CI_DEFAULT_PYTHON_IMAGE}:${IMAGE_TAG}"
fi

if [[ "$USE_DOCKER" == "true" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is required when running in Docker mode (default). Use --no-docker to run on the host instead."
    exit 1
  fi
  ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"
  DOCKER_CMD=(docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -e HOME=/tmp -e PIP_CACHE_DIR=/tmp/.cache/pip -v "$ABS_WORKDIR":/work -w /work)
  # The shared network, so the steps reach the database by container name.
  [[ -n "$DB_NETWORK" ]] && DOCKER_CMD+=(--network "$DB_NETWORK")
  # Values as -e pairs, not interpolated into the command string: a password
  # holding a quote would otherwise break the quoting or run as code.
  if (( ${#EXTRA_ENV[@]} )); then
    for pair in "${EXTRA_ENV[@]}"; do DOCKER_CMD+=(-e "$pair"); done
  fi
  if [[ -n "${HOME:-}" ]]; then
    mkdir -p "$HOME/.cache/pip"
    DOCKER_CMD+=(-v "$HOME/.cache/pip":/tmp/.cache/pip)
  fi
  # bash -c, not -lc. A login shell sources /etc/profile, which replaces PATH
  # with a default built for a shell session. A container already has the
  # environment its image set; a login shell there has nothing to add and can
  # only take away. This cost every Docker-mode run in ci_go.sh: the golang
  # image keeps its toolchain in /usr/local/go/bin, which the profile default
  # does not carry, so every run exited 127.
  #
  # Measured 2026-09-22 against python:3.12-slim: the toolchain resolves under -c.
  DOCKER_CMD+=("$IMAGE" bash -c)

  # Build a single command string so pip-installed packages persist within
  # the same container (each docker run is a fresh container).
  CMDS=()
  if [[ "$NO_INSTALL" == "false" ]]; then
    if [[ -n "$PIP_CMD" ]]; then
      CMDS+=("$PIP_CMD")
    else
      CMDS+=("python -m pip install --user --upgrade pip")
      if [[ -z "$REQ_FILE" && -f "$ABS_WORKDIR/requirements.txt" ]]; then
        REQ_FILE="requirements.txt"
      fi
      if [[ -n "$REQ_FILE" ]]; then
        install_cmd="python -m pip install --user -r \"$REQ_FILE\""
        if [[ -n "$CONSTRAINTS_FILE" ]]; then
          install_cmd+=" -c \"$CONSTRAINTS_FILE\""
        fi
        CMDS+=("$install_cmd")
      fi
      if [[ -n "$EXTRA_INSTALL" ]]; then
        # Word splitting is intentional: EXTRA_INSTALL may contain multiple
        # space-separated package names (e.g. "pytest tldextract").
        CMDS+=("python -m pip install --user $EXTRA_INSTALL")
      fi
    fi
  fi
  CMDS+=("export PATH=\"/tmp/.local/bin:\$PATH\" && $TEST_CMD")

  # Joined explicitly: "${CMDS[*]}" uses only the first character of IFS, so
  # IFS=' && ' joined with a single space and every step ran as arguments to
  # the first command.
  FULL_CMD=""
  for step in "${CMDS[@]}"; do
    FULL_CMD="${FULL_CMD:+$FULL_CMD && }$step"
  done
  log_info "$FULL_CMD"
  "${DOCKER_CMD[@]}" "$FULL_CMD"
else
  if ! command -v python >/dev/null 2>&1; then
    log_error "python is required on PATH."
    exit 1
  fi
  pushd "$WORKDIR" >/dev/null
  if [[ "$NO_INSTALL" == "false" ]]; then
    if [[ -n "$PIP_CMD" ]]; then
      log_info "$PIP_CMD"
      bash -lc "$PIP_CMD"
    else
      log_info "python -m pip install --upgrade pip"
      python -m pip install --upgrade pip
      if [[ -z "$REQ_FILE" && -f "requirements.txt" ]]; then
        REQ_FILE="requirements.txt"
      fi
      if [[ -n "$REQ_FILE" ]]; then
        install_cmd="python -m pip install -r \"$REQ_FILE\""
        if [[ -n "$CONSTRAINTS_FILE" ]]; then
          install_cmd+=" -c \"$CONSTRAINTS_FILE\""
        fi
        log_info "$install_cmd"
        bash -lc "$install_cmd"
      fi
      if [[ -n "$EXTRA_INSTALL" ]]; then
        log_info "python -m pip install $EXTRA_INSTALL"
        # shellcheck disable=SC2086 # Intentional: EXTRA_INSTALL contains space-separated package names.
        python -m pip install $EXTRA_INSTALL
      fi
    fi
  fi
  log_info "$TEST_CMD"
  # env, not an inline NAME=value prefix, so a value containing a space or a
  # quote is passed as one argument rather than re-parsed by the shell.
  if (( ${#EXTRA_ENV[@]} )); then
    env "${EXTRA_ENV[@]}" bash -lc "$TEST_CMD"
  else
    bash -lc "$TEST_CMD"
  fi
  popd >/dev/null
fi
