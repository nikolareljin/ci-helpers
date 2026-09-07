#!/usr/bin/env bash
# SCRIPT: local_test_node.sh
# DESCRIPTION: Install dependencies and run tests for Node/npm projects.
# USAGE: bash scripts/local_test_node.sh [--quick] [--workspace <name>]
#
# PARAMETERS:
#   --dir     Project directory, relative to the repository root (default: .).
#   --quick       Skip install; run tests against existing node_modules.
#   --workspace   Run tests only for a specific npm workspace.
# ----------------------------------------------------
set -euo pipefail

QUICK=false
TEST_DIR="."
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-node] --dir requires a path." >&2
        exit 1
      fi
      TEST_DIR="$2"
      shift
      ;;
    --workspace)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-node] --workspace requires a workspace name." >&2
        exit 1
      fi
      WORKSPACE="$2"
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ ! -d "$repo_root/$TEST_DIR" ]]; then
  echo "[local-test-node] Directory not found: $repo_root/$TEST_DIR" >&2
  exit 1
fi
cd "$repo_root/$TEST_DIR"

if [[ ! -f package.json ]]; then
  echo "[local-test-node] No package.json found at repo root." >&2; exit 1
fi

if ! command -v npm &>/dev/null; then
  echo "[local-test-node] npm not found in PATH. Install Node.js/npm before running this script." >&2
  exit 1
fi

if [[ "$QUICK" == "false" ]]; then
  echo "[local-test-node] Installing dependencies..."
  if [[ -f package-lock.json ]] || [[ -f npm-shrinkwrap.json ]]; then
    npm ci
  else
    echo "[local-test-node] No lockfile found; using npm install (consider committing package-lock.json)."
    npm install
  fi
fi

if [[ -n "$WORKSPACE" ]]; then
  echo "[local-test-node] Testing workspace: $WORKSPACE"
  npm test --workspace "$WORKSPACE"
else
  echo "[local-test-node] Running tests..."
  npm test
fi

echo "[local-test-node] Done."
