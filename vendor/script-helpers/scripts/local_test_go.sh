#!/usr/bin/env bash
# SCRIPT: local_test_go.sh
# DESCRIPTION: Vet and test all Go modules in the repository.
# USAGE: bash scripts/local_test_go.sh [--quick] [--module <path>]
#
# PARAMETERS:
#   --dir     Project directory, relative to the repository root (default: .).
#   --quick     Skip vet; run tests only.
#   --module    Path to a specific module directory (default: all go.mod roots).
# EXIT_CODES:
#   0  Every check that ran passed.
#   1  A check failed, or bad arguments.
#   3  Nothing could be checked: no module has Go packages. preflight reports it as SKIP.
# ----------------------------------------------------
set -euo pipefail

# skip_exit <reason>; nothing could be checked. Exit 3, which preflight reports as
# SKIP with this reason (written to $PREFLIGHT_SKIP_FILE when preflight sets it).
skip_exit() {
  echo "[local-test-go] $1" >&2
  if [[ -n "${PREFLIGHT_SKIP_FILE:-}" ]]; then printf '%s\n' "$1" > "$PREFLIGHT_SKIP_FILE"; fi
  exit 3
}

QUICK=false
TEST_DIR="."
MODULE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-go] --dir requires a path." >&2
        exit 1
      fi
      TEST_DIR="$2"
      shift
      ;;
    --module)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-go] --module requires a path." >&2
        exit 1
      fi
      MODULE="$2"
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# --dir is documented as relative to the repository root. preflight, which may
# be pointed at a subdirectory of a repository with --dir, resolves it to an
# absolute path first; an absolute value is honoured as given. Without this,
# `preflight --dir sub` in a git repository looked for sub/<stack> under the
# git root instead of under sub/, and reported the stack's directory missing.
if [[ "$TEST_DIR" == /* ]]; then
  target="$TEST_DIR"
else
  target="$repo_root/$TEST_DIR"
fi
if [[ ! -d "$target" ]]; then
  echo "[local-test-go] Directory not found: $target" >&2
  exit 1
fi
cd "$target"

if ! command -v go &>/dev/null; then
  echo "[local-test-go] go not found in PATH." >&2; exit 1
fi

modules=0
empty_modules=0

run_module() {
  local dir="$1"
  modules=$((modules + 1))
  echo "[local-test-go] Module: $dir"
  pushd "$dir" > /dev/null
  # A module with no packages (a root go.mod for tooling, say) has nothing to vet
  # or test, and `go test ./...` fails on it with "matched no packages". Only a
  # successful, empty listing means that: a broken go.mod also lists nothing,
  # but go list fails, and go test below reports it. A package that does not
  # compile is still listed, so it is still tested.
  local listed list_rc=0
  listed="$(go list ./... 2>/dev/null)" || list_rc=$?
  if [[ $list_rc -eq 0 && -z "$listed" ]]; then
    echo "  no Go packages in this module; nothing to test"
    empty_modules=$((empty_modules + 1))
    popd > /dev/null
    return 0
  fi
  if [[ "$QUICK" == "false" ]]; then
    echo "  go vet ./..."
    go vet ./...
  fi
  echo "  go test ./..."
  go test ./...
  popd > /dev/null
}

if [[ -n "$MODULE" ]]; then
  run_module "$MODULE"
else
  # Find all go.mod files while skipping large generated or vendored trees.
  while IFS= read -r gomod; do
    run_module "$(dirname "$gomod")"
  done < <(
    find . \
      \( -name .git -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
      -o -type f -name go.mod -print | sort
  )
fi

if [[ $modules -gt 0 && $empty_modules -eq $modules ]]; then
  skip_exit "no module here has Go packages; nothing to test"
fi
echo "[local-test-go] Done."
