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

# An installed docker whose daemon is not running fails every command below,
# including the pull -- so ask the daemon first. Otherwise a stopped Docker
# Desktop is reported as an image that could not be fetched, and the reader goes
# looking at the network.
if ! docker info >/dev/null 2>&1; then
  log_error "local_test_bash32: the docker daemon is not reachable — start Docker and retry"
  exit 3
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if ! docker pull "$IMAGE" >/dev/null 2>&1; then
    log_error "local_test_bash32: $IMAGE is not present locally and could not be pulled"
    log_error "local_test_bash32: with a network, run: docker pull $IMAGE"
    exit 3
  fi
fi

if [[ "$INTERACTIVE" == "true" ]]; then
  exec docker run --rm -it -v "$SCRIPT_HELPERS_DIR:/repo" -w /repo "$IMAGE" bash
fi

# The image is minimal: no git, no python3. Several tests drive real library
# code through those, so they are installed when the network allows. When it
# does not, the affected tests are reported as SKIPPED -- a test that failed for
# want of git says nothing about bash 3.2, and a gate that cries wolf is a gate
# people learn to ignore.
BOOTSTRAP='apk add --no-cache git python3 curl >/dev/null 2>&1 || true'

# Offline, `docker run` on an image that was never pulled fails with a registry
# error that reads like the gate is broken. Say what actually happened, and use
# the same "docker is unavailable" exit code, so a machine with no network is
# told to pull the image once rather than left debugging the suite.
# One runner for both paths. The single-test path used to bypass this and run
# the file directly, so `--test tests/git_branches_test.sh` on an image without
# git -- which is every image when the bootstrap cannot reach the network --
# failed for want of git and blamed bash 3.2. Whatever is skipped in the suite
# is skipped the same way for one file.
RUNNER='
  set -u
  bash --version | head -n1
  case "${BASH_VERSINFO[0]}" in
    3) ;;
    *) echo "expected bash 3.x in this image, got ${BASH_VERSION}" >&2; exit 1 ;;
  esac

  # Tests whose subject is a tool rather than the shell. Each names what it
  # needs, so a missing tool reads as SKIP and only a real 3.2 defect fails.
  # Derived from the test file rather than kept by hand: a hand-kept map named
  # one test as needing git while three others also ran it, so offline those
  # three failed for a missing tool and blamed bash 3.2. A test that invokes a
  # tool needs it; the scan is the source of truth, and the case below adds
  # only what a scan cannot see.
  needs_for() {
    need=""
    # Comment lines dropped first. Scanning raw text made a tool mentioned in
    # prose a dependency, so tests that only *talk* about git were skipped
    # offline instead of run -- lost coverage, the failure this runner exists
    # to avoid, pointed the other way. Whole-line comments only, and with no
    # single quote anywhere: this function is carried inside a single-quoted
    # RUNNER string, and one quote here ends it and breaks the embedded script.
    body="$(grep -v "^[[:space:]]*#" "$1" 2>/dev/null)"
    printf "%s" "$body" | grep -qE "(^|[^[:alnum:]_-])git " && need="$need git"
    printf "%s" "$body" | grep -qE "(^|[^[:alnum:]_])python3?( |$)" && need="$need python3"
    printf "%s" "$body" | grep -qE "(^|[^[:alnum:]_])curl( |$)" && need="$need curl"
    case "$1" in
      # docker_install supports apt/dnf/pacman, not apk, so on this Alpine-based
      # image the installer correctly refuses and the test correctly fails.
      # That is a statement about Alpine, not about bash 3.2.
      tests/docker_install_test.sh) need="$need apt-get" ;;
      # Runs git when it is there and falls back to find when it is not, on
      # purpose and with a comment saying so. Skipping it for a missing git
      # would drop the portability gate itself from the 3.2 run, which is the
      # one thing this image exists to exercise.
      tests/portability_test.sh) need="" ;;
    esac
    echo "${need# }"
  }

  have_all() {
    for _t in $1; do
      command -v "$_t" >/dev/null 2>&1 || { echo "$_t"; return 1; }
    done
    return 0
  }

  # No arguments means the whole suite.
  if [ "$#" -eq 0 ]; then
    set -- tests/*_test.sh
  fi

  failed=0
  skipped=0
  for f in "$@"; do
    [ -f "$f" ] || { echo "no such test: $f" >&2; failed=1; continue; }
    # needs_for keys on the canonical tests/... spelling; a caller may say
    # ./tests/... and would otherwise skip the skip, failing for a missing tool
    # under exactly the name this runner exists to avoid.
    key="${f#./}"
    need="$(needs_for "$key")"
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

if [[ -n "$SINGLE_TEST" ]]; then
  log_info "local_test_bash32: $SINGLE_TEST under $IMAGE"
  exec docker run --rm -v "$SCRIPT_HELPERS_DIR:/repo" -w /repo "$IMAGE" \
    bash -c "$BOOTSTRAP; $RUNNER" _ "$SINGLE_TEST"
fi

log_info "local_test_bash32: full suite under $IMAGE"
exec docker run --rm -v "$SCRIPT_HELPERS_DIR:/repo" -w /repo "$IMAGE" \
  bash -c "$BOOTSTRAP; $RUNNER" _
