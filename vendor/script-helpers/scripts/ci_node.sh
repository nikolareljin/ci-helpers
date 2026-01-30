#!/usr/bin/env bash
# SCRIPT: ci_node.sh
# DESCRIPTION: Run Node.js CI steps (install, lint, test, build) with configurable commands.
# USAGE: scripts/ci_node.sh [--workdir <path>] [--no-install] [--skip-lint] [--skip-test] [--skip-build]
# PARAMETERS:
#   --workdir <path>   Working directory for npm commands (default: current dir).
#   --no-install       Skip npm install step.
#   --skip-lint        Skip lint command.
#   --skip-test        Skip test command.
#   --skip-build       Skip build command.
#   --install-cmd <c>  Override install command (default: npm ci).
#   --lint-cmd <c>     Override lint command (default: npm run lint).
#   --test-cmd <c>     Override test command (default: npm run test).
#   --build-cmd <c>    Override build command (default: npm run build).
#   --version <tag>    Docker image tag (default: from ci_defaults module).
#   --image <img>      Docker image override (default: node:<version>).
#   --no-docker        Run on the host instead of Docker.
#   -h, --help         Show this help message.
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
SKIP_LINT=false
SKIP_TEST=false
SKIP_BUILD=false
INSTALL_CMD="npm ci"
LINT_CMD="npm run lint"
TEST_CMD="npm run test"
BUILD_CMD="npm run build"
USE_DOCKER=true
IMAGE_TAG="$CI_DEFAULT_NODE_VERSION"
IMAGE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --no-install) NO_INSTALL=true; shift;;
    --skip-lint) SKIP_LINT=true; shift;;
    --skip-test) SKIP_TEST=true; shift;;
    --skip-build) SKIP_BUILD=true; shift;;
    --install-cmd) INSTALL_CMD="$2"; shift 2;;
    --lint-cmd) LINT_CMD="$2"; shift 2;;
    --test-cmd) TEST_CMD="$2"; shift 2;;
    --build-cmd) BUILD_CMD="$2"; shift 2;;
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
  IMAGE="${CI_DEFAULT_NODE_IMAGE}:${IMAGE_TAG}"
fi

if [[ "$USE_DOCKER" == "true" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is required when running in Docker mode (default). Use --no-docker to run on the host instead."
    exit 1
  fi
  ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"
  DOCKER_CMD=(docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -e NPM_CONFIG_CACHE=/tmp/.npm -v "$ABS_WORKDIR":/work -w /work)
  if [[ -n "${HOME:-}" ]]; then
    mkdir -p "$HOME/.npm"
    DOCKER_CMD+=(-v "$HOME/.npm":/tmp/.npm)
  fi
  DOCKER_CMD+=("$IMAGE" bash -lc)
  if [[ "$NO_INSTALL" == "false" ]]; then
    log_info "$INSTALL_CMD"
    "${DOCKER_CMD[@]}" "$INSTALL_CMD"
  fi
  if [[ "$SKIP_LINT" == "false" ]]; then
    log_info "$LINT_CMD"
    "${DOCKER_CMD[@]}" "$LINT_CMD"
  fi
  if [[ "$SKIP_TEST" == "false" ]]; then
    log_info "$TEST_CMD"
    "${DOCKER_CMD[@]}" "$TEST_CMD"
  fi
  if [[ "$SKIP_BUILD" == "false" ]]; then
    log_info "$BUILD_CMD"
    "${DOCKER_CMD[@]}" "$BUILD_CMD"
  fi
else
  if ! command -v npm >/dev/null 2>&1; then
    log_error "npm is required on PATH."
    exit 1
  fi
  pushd "$WORKDIR" >/dev/null
  if [[ "$NO_INSTALL" == "false" ]]; then
    log_info "$INSTALL_CMD"
    bash -lc "$INSTALL_CMD"
  fi
  if [[ "$SKIP_LINT" == "false" ]]; then
    log_info "$LINT_CMD"
    bash -lc "$LINT_CMD"
  fi
  if [[ "$SKIP_TEST" == "false" ]]; then
    log_info "$TEST_CMD"
    bash -lc "$TEST_CMD"
  fi
  if [[ "$SKIP_BUILD" == "false" ]]; then
    log_info "$BUILD_CMD"
    bash -lc "$BUILD_CMD"
  fi
  popd >/dev/null
fi
