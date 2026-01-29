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
#   -h, --help           Show this help message.
# ----------------------------------------------------
set -euo pipefail

if [[ "${CI:-}" == "true" ]]; then
  echo "This script is intended for local use only." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging ci_defaults

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
    -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

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
  if [[ -n "${HOME:-}" ]]; then
    mkdir -p "$HOME/.cache/pip"
    DOCKER_CMD+=(-v "$HOME/.cache/pip":/tmp/.cache/pip)
  fi
  DOCKER_CMD+=("$IMAGE" bash -lc)

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

  FULL_CMD="$(IFS=' && '; echo "${CMDS[*]}")"
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
  bash -lc "$TEST_CMD"
  popd >/dev/null
fi
