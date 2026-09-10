#!/usr/bin/env bash
# SCRIPT: local_test_bash32.sh
# DESCRIPTION: Run the test suite under bash 3.2, the shell macOS ships.
# USAGE: bash scripts/local_test_bash32.sh [--test <file>] [--shell]
#
# PARAMETERS:
#   --test    Run a single test file instead of the whole suite.
#   --shell   Drop into an interactive bash 3.2 shell in the container.
#
# EXIT_CODES:
#   0  every test passed under bash 3.2
#   1  a test failed
#   3  docker is unavailable
# ----------------------------------------------------
#
# macOS ships bash 3.2 as /bin/bash and, for licensing reasons, always will.
# Nothing about that shell is exotic -- it simply lacks mapfile, associative
# arrays and namerefs, and it fails at *runtime* rather than when a file is
# sourced. That is what made the breakage invisible: sourcing looked fine and
# the wrong answer appeared later.
#
# Running the real suite against a real 3.2 is the cheapest honest check, and it
# needs no Mac. The macOS CI job covers what this cannot: the BSD userland.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging ci_defaults

# In line with every other local_test_* runner: this replaces a CI job, it does
# not run inside one.
if [[ "${CI:-}" == "true" ]]; then
  log_error "local_test_bash32: this is a local gate; CI runs the macOS job instead."
  exit 1
fi

SINGLE_TEST=""
INTERACTIVE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)  SINGLE_TEST="${2:-}"; [[ -n "$SINGLE_TEST" ]] || { log_error "--test needs a file"; exit 2; }; shift 2 ;;
    --shell) INTERACTIVE=true; shift ;;
    -h|--help) parse_common_args --help ;;
    *) log_error "local_test_bash32: unknown option $1"; exit 2 ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  log_error "local_test_bash32: docker is required to run a bash 3.2 image"
  exit 3
fi

IMAGE="${CI_DEFAULT_BASH32_IMAGE}:${CI_DEFAULT_BASH32_VERSION}"

if [[ "$INTERACTIVE" == "true" ]]; then
  exec docker run --rm -it -v "$SCRIPT_HELPERS_DIR:/repo" -w /repo "$IMAGE" bash
fi

# The image is minimal: no git, no python3. Several tests drive real library
# code through those, so they are installed when the network allows. When it
# does not, the affected tests are reported as SKIPPED -- a test that failed for
# want of git says nothing about bash 3.2, and a gate that cries wolf is a gate
# people learn to ignore.
BOOTSTRAP='apk add --no-cache git python3 curl >/dev/null 2>&1 || true'
if [[ -n "$SINGLE_TEST" ]]; then
  log_info "local_test_bash32: $SINGLE_TEST under $IMAGE"
  exec docker run --rm -v "$SCRIPT_HELPERS_DIR:/repo" -w /repo "$IMAGE" \
    bash -c "$BOOTSTRAP"'; bash --version | head -n1; bash "$1"' _ "$SINGLE_TEST"
fi

log_info "local_test_bash32: full suite under $IMAGE"
docker run --rm -v "$SCRIPT_HELPERS_DIR:/repo" -w /repo "$IMAGE" bash -c "$BOOTSTRAP"'
  set -u
  bash --version | head -n1
  case "${BASH_VERSINFO[0]}" in
    3) ;;
    *) echo "expected bash 3.x in this image, got ${BASH_VERSION}" >&2; exit 1 ;;
  esac

  # Tests whose subject is a tool rather than the shell. Each names what it
  # needs, so a missing tool reads as SKIP and only a real 3.2 defect fails.
  needs_for() {
    case "$1" in
      tests/git_branches_test.sh)   echo git ;;
      tests/hub_test.sh)            echo "python3 curl" ;;
      # docker_install supports apt/dnf/pacman, not apk, so on this Alpine-based
      # image the installer correctly refuses and the test correctly fails.
      # That is a statement about Alpine, not about bash 3.2.
      tests/docker_install_test.sh) echo "curl apt-get" ;;
      *) echo "" ;;
    esac
  }

  have_all() {
    for _t in $1; do
      command -v "$_t" >/dev/null 2>&1 || { echo "$_t"; return 1; }
    done
    return 0
  }

  failed=0
  skipped=0
  for f in tests/*_test.sh; do
    [ -f "$f" ] || continue
    need="$(needs_for "$f")"
    if [ -n "$need" ] && ! missing="$(have_all "$need")"; then
      printf "\n--- bash 3.2: %s ---\n" "$f"
      echo "SKIP: needs $missing, which is not in this image"
      skipped=$((skipped+1))
      continue
    fi
    printf "\n--- bash 3.2: %s ---\n" "$f"
    if ! bash "$f"; then
      echo "FAILED under bash 3.2: $f" >&2
      failed=1
    fi
  done
  printf "\nbash 3.2 summary: %s skipped for missing tools\n" "$skipped"
  exit $failed
'
