#!/usr/bin/env bash
# SCRIPT: ci_go.sh
# DESCRIPTION: Run Go CI steps (lint, test, build) with configurable commands.
# USAGE: scripts/ci_go.sh [--workdir <path>] [--skip-lint] [--skip-test] [--skip-build]
# PARAMETERS:
#   --workdir <path>  Working directory for go commands (default: current dir).
#   --skip-lint       Skip lint step (default runs gofmt + go vet).
#   --skip-test       Skip test step.
#   --skip-build      Skip build step.
#   --lint-cmd <c>    Override lint command (default: go mod tidy && test -z "$(gofmt -l .)" && go vet ./...).
#   --test-cmd <c>    Override test command (default: go test -v ./...).
#   --build-cmd <c>   Override build command (default: go build -v ./...).
#   --version <tag>   Docker image tag (default: from ci_defaults module).
#   --image <img>     Docker image override (default: golang:<version>).
#   --no-docker       Run on the host instead of Docker.
#   -h, --help        Show this help message.
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
SKIP_LINT=false
SKIP_TEST=false
SKIP_BUILD=false
LINT_CMD='go mod tidy && test -z "$(gofmt -l .)" && go vet ./...'
TEST_CMD='go test -v ./...'
BUILD_CMD='go build -v ./...'
USE_DOCKER=true
IMAGE_TAG="$CI_DEFAULT_GO_VERSION"
IMAGE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --skip-lint) SKIP_LINT=true; shift;;
    --skip-test) SKIP_TEST=true; shift;;
    --skip-build) SKIP_BUILD=true; shift;;
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
  IMAGE="${CI_DEFAULT_GO_IMAGE}:${IMAGE_TAG}"
fi

if [[ "$USE_DOCKER" == "true" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is required when running in Docker mode (default). Use --no-docker to run on the host instead."
    exit 1
  fi
  ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"
  DOCKER_CMD=(docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -e GOMODCACHE=/tmp/go-cache -v "$ABS_WORKDIR":/work -w /work)
  if [[ -n "${HOME:-}" ]]; then
    HOST_GOMODCACHE="${HOME}/.cache/go"
    mkdir -p "$HOST_GOMODCACHE"
    DOCKER_CMD+=(-v "$HOST_GOMODCACHE":/tmp/go-cache)
  fi
  DOCKER_CMD+=("$IMAGE" bash -lc)
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
  if ! command -v go >/dev/null 2>&1; then
    log_error "go is required on PATH."
    exit 1
  fi
  pushd "$WORKDIR" >/dev/null
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
