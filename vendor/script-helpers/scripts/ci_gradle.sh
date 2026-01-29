#!/usr/bin/env bash
# SCRIPT: ci_gradle.sh
# DESCRIPTION: Run Gradle CI steps (build, test, lint, detekt) with configurable tasks.
# USAGE: scripts/ci_gradle.sh [--workdir <path>] [--skip-build] [--skip-test] [--skip-lint] [--skip-detekt]
# PARAMETERS:
#   --workdir <path>   Working directory (default: current dir).
#   --skip-build       Skip assembleDebug task.
#   --skip-test        Skip test task.
#   --skip-lint        Skip lint task.
#   --skip-detekt      Skip detekt task.
#   --build-task <t>   Override build task (default: assembleDebug).
#   --test-task <t>    Override test task (default: test).
#   --lint-task <t>    Override lint task (default: lint).
#   --detekt-task <t>  Override detekt task (default: detekt).
#   --no-daemon        Run Gradle with --no-daemon (default: true).
#   --version <tag>    Docker image tag (default: from ci_defaults module).
#   --image <img>      Docker image override (default: gradle:<version>).
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
SKIP_BUILD=false
SKIP_TEST=false
SKIP_LINT=false
SKIP_DETEKT=false
BUILD_TASK="assembleDebug"
TEST_TASK="test"
LINT_TASK="lint"
DETEKT_TASK="detekt"
NO_DAEMON=true
USE_DOCKER=true
IMAGE_TAG="$CI_DEFAULT_GRADLE_VERSION"
IMAGE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --skip-build) SKIP_BUILD=true; shift;;
    --skip-test) SKIP_TEST=true; shift;;
    --skip-lint) SKIP_LINT=true; shift;;
    --skip-detekt) SKIP_DETEKT=true; shift;;
    --build-task) BUILD_TASK="$2"; shift 2;;
    --test-task) TEST_TASK="$2"; shift 2;;
    --lint-task) LINT_TASK="$2"; shift 2;;
    --detekt-task) DETEKT_TASK="$2"; shift 2;;
    --no-daemon) NO_DAEMON=true; shift;;
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
  IMAGE="${CI_DEFAULT_GRADLE_IMAGE}:${IMAGE_TAG}"
fi

GRADLE_FLAGS=()
if [[ "$NO_DAEMON" == "true" ]]; then
  GRADLE_FLAGS+=(--no-daemon)
fi

if [[ "$USE_DOCKER" == "true" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is required when running in Docker mode (default). Use --no-docker to run on the host instead."
    exit 1
  fi
  ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"
  DOCKER_CMD=(docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -e GRADLE_USER_HOME=/tmp/.gradle -v "$ABS_WORKDIR":/work -w /work --entrypoint "")
  if [[ -n "${HOME:-}" ]]; then
    mkdir -p "$HOME/.gradle"
    DOCKER_CMD+=(-v "$HOME/.gradle":/tmp/.gradle)
  fi
  DOCKER_CMD+=("$IMAGE" bash -lc)
  # Docker mode: ${GRADLE_FLAGS[*]} expands into a single string for bash -lc.
  # Non-Docker mode uses "${GRADLE_FLAGS[@]}" to pass flags as separate arguments.
  if [[ "$SKIP_BUILD" == "false" ]]; then
    log_info "./gradlew $BUILD_TASK ${GRADLE_FLAGS[*]}"
    "${DOCKER_CMD[@]}" "./gradlew $BUILD_TASK ${GRADLE_FLAGS[*]}"
  fi
  if [[ "$SKIP_TEST" == "false" ]]; then
    log_info "./gradlew $TEST_TASK ${GRADLE_FLAGS[*]}"
    "${DOCKER_CMD[@]}" "./gradlew $TEST_TASK ${GRADLE_FLAGS[*]}"
  fi
  if [[ "$SKIP_LINT" == "false" ]]; then
    log_info "./gradlew $LINT_TASK ${GRADLE_FLAGS[*]}"
    "${DOCKER_CMD[@]}" "./gradlew $LINT_TASK ${GRADLE_FLAGS[*]}"
  fi
  if [[ "$SKIP_DETEKT" == "false" ]]; then
    log_info "./gradlew $DETEKT_TASK ${GRADLE_FLAGS[*]}"
    "${DOCKER_CMD[@]}" "./gradlew $DETEKT_TASK ${GRADLE_FLAGS[*]}" || true
  fi
else
  if [[ ! -x "$WORKDIR/gradlew" ]]; then
    log_error "gradlew not found in $WORKDIR"
    exit 1
  fi
  pushd "$WORKDIR" >/dev/null
  if [[ "$SKIP_BUILD" == "false" ]]; then
    log_info "./gradlew $BUILD_TASK ${GRADLE_FLAGS[*]}"
    ./gradlew "$BUILD_TASK" "${GRADLE_FLAGS[@]}"
  fi
  if [[ "$SKIP_TEST" == "false" ]]; then
    log_info "./gradlew $TEST_TASK ${GRADLE_FLAGS[*]}"
    ./gradlew "$TEST_TASK" "${GRADLE_FLAGS[@]}"
  fi
  if [[ "$SKIP_LINT" == "false" ]]; then
    log_info "./gradlew $LINT_TASK ${GRADLE_FLAGS[*]}"
    ./gradlew "$LINT_TASK" "${GRADLE_FLAGS[@]}"
  fi
  if [[ "$SKIP_DETEKT" == "false" ]]; then
    log_info "./gradlew $DETEKT_TASK ${GRADLE_FLAGS[*]}"
    ./gradlew "$DETEKT_TASK" "${GRADLE_FLAGS[@]}" || true
  fi
  popd >/dev/null
fi
