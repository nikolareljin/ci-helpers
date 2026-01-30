#!/usr/bin/env bash
# SCRIPT: ci_flutter.sh
# DESCRIPTION: Run Flutter CI steps (analyze, test, build) with configurable commands.
# USAGE: scripts/ci_flutter.sh [--workdir <path>] [--skip-analyze] [--skip-test] [--skip-build]
# PARAMETERS:
#   --workdir <path>   Working directory for flutter commands (default: current dir).
#   --skip-analyze     Skip flutter analyze.
#   --skip-test        Skip flutter test.
#   --skip-build       Skip flutter build step.
#   --build-cmd <c>    Override build command (default: flutter build appbundle --release).
#   --version <tag>    Docker image tag (default: from ci_defaults module).
#   --image <img>      Docker image override (default: ghcr.io/cirruslabs/flutter:<version>).
#   --digest <sha256>  Pin image to specific digest for supply-chain security (e.g., sha256:d18e04...).
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
SKIP_ANALYZE=false
SKIP_TEST=false
SKIP_BUILD=false
BUILD_CMD="flutter build appbundle --release"
USE_DOCKER=true
IMAGE_TAG="$CI_DEFAULT_FLUTTER_VERSION"
IMAGE_OVERRIDE=""
DIGEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --skip-analyze) SKIP_ANALYZE=true; shift;;
    --skip-test) SKIP_TEST=true; shift;;
    --skip-build) SKIP_BUILD=true; shift;;
    --build-cmd) BUILD_CMD="$2"; shift 2;;
    --version) IMAGE_TAG="$2"; shift 2;;
    --image) IMAGE_OVERRIDE="$2"; shift 2;;
    --digest) DIGEST="$2"; shift 2;;
    --no-docker) USE_DOCKER=false; shift;;
    -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ -n "$IMAGE_OVERRIDE" ]]; then
  IMAGE="$IMAGE_OVERRIDE"
else
  IMAGE="${CI_DEFAULT_FLUTTER_IMAGE}:${IMAGE_TAG}"
fi

# Apply digest to image if provided
if [[ -n "$DIGEST" ]]; then
  # Validate digest format
  if [[ ! "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    log_error "Invalid digest format. Expected sha256:<64-hex-chars>, got: $DIGEST"
    exit 1
  fi
  # Check if IMAGE already contains a digest
  if [[ "$IMAGE" =~ @sha256: ]]; then
    log_error "Image already contains a digest. Use --image without digest or omit --digest parameter."
    exit 1
  fi
  IMAGE="${IMAGE}@${DIGEST}"
fi

if [[ "$USE_DOCKER" == "true" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is required when running in Docker mode (default). Use --no-docker to run on the host instead."
    exit 1
  fi
  ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"
  DOCKER_CMD=(docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -e PUB_CACHE=/tmp/.pub-cache -v "$ABS_WORKDIR":/work -w /work)
  if [[ -n "${HOME:-}" ]]; then
    mkdir -p "$HOME/.pub-cache"
    DOCKER_CMD+=(-v "$HOME/.pub-cache":/tmp/.pub-cache)
  fi
  DOCKER_CMD+=("$IMAGE" bash -lc)
  if [[ "$SKIP_ANALYZE" == "false" ]]; then
    log_info "flutter analyze"
    "${DOCKER_CMD[@]}" "flutter analyze"
  fi
  if [[ "$SKIP_TEST" == "false" ]]; then
    log_info "flutter test"
    "${DOCKER_CMD[@]}" "flutter test"
  fi
  if [[ "$SKIP_BUILD" == "false" ]]; then
    log_info "$BUILD_CMD"
    "${DOCKER_CMD[@]}" "$BUILD_CMD"
  fi
else
  if ! command -v flutter >/dev/null 2>&1; then
    log_error "flutter is required on PATH."
    exit 1
  fi
  pushd "$WORKDIR" >/dev/null
  if [[ "$SKIP_ANALYZE" == "false" ]]; then
    log_info "flutter analyze"
    flutter analyze
  fi
  if [[ "$SKIP_TEST" == "false" ]]; then
    log_info "flutter test"
    flutter test
  fi
  if [[ "$SKIP_BUILD" == "false" ]]; then
    log_info "$BUILD_CMD"
    bash -lc "$BUILD_CMD"
  fi
  popd >/dev/null
fi
