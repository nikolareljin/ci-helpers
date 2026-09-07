#!/usr/bin/env bash
# SCRIPT: local_test_go.sh
# DESCRIPTION: Vet and test all Go modules in the repository.
# USAGE: bash scripts/local_test_go.sh [--quick] [--module <path>]
#
# PARAMETERS:
#   --dir     Project directory, relative to the repository root (default: .).
#   --quick     Skip vet; run tests only.
#   --module    Path to a specific module directory (default: all go.mod roots).
# ----------------------------------------------------
set -euo pipefail

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
if [[ ! -d "$repo_root/$TEST_DIR" ]]; then
  echo "[local-test-go] Directory not found: $repo_root/$TEST_DIR" >&2
  exit 1
fi
cd "$repo_root/$TEST_DIR"

if ! command -v go &>/dev/null; then
  echo "[local-test-go] go not found in PATH." >&2; exit 1
fi

run_module() {
  local dir="$1"
  echo "[local-test-go] Module: $dir"
  pushd "$dir" > /dev/null
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

echo "[local-test-go] Done."
