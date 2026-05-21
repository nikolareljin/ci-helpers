#!/usr/bin/env bash
# SCRIPT: local_test_python.sh
# DESCRIPTION: Use a local virtualenv when available and run pytest.
# USAGE: bash scripts/local_test_python.sh [--quick] [--dir <path>]
#
# PARAMETERS:
#   --quick   Skip install; run tests against the current environment.
#   --dir     Subdirectory containing pyproject.toml/requirements.txt (default: .).
# ----------------------------------------------------
set -euo pipefail

QUICK=false
TEST_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-python] --dir requires a path." >&2
        exit 1
      fi
      TEST_DIR="$2"
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ ! -d "$repo_root/$TEST_DIR" ]]; then
  echo "[local-test-python] Directory not found: $repo_root/$TEST_DIR" >&2
  exit 1
fi
cd "$repo_root/$TEST_DIR"

# Resolve one Python interpreter for both dependency installs and test runs.
PYTHON=""
if [[ -x venv/bin/python ]]; then PYTHON="venv/bin/python"
elif [[ -x .venv/bin/python ]]; then PYTHON=".venv/bin/python"
elif [[ -x "$repo_root/venv/bin/python" ]]; then PYTHON="$repo_root/venv/bin/python"
elif [[ -x "$repo_root/.venv/bin/python" ]]; then PYTHON="$repo_root/.venv/bin/python"
elif command -v python3 &>/dev/null; then PYTHON="python3"
elif command -v python &>/dev/null; then PYTHON="python"; fi

if [[ -z "$PYTHON" ]]; then
  echo "[local-test-python] Python not found. Activate a venv or install Python first." >&2
  exit 1
fi

if [[ "$QUICK" == "false" ]]; then
  if [[ -f requirements.txt ]]; then
    if ! "$PYTHON" -m pip --version &>/dev/null; then
      echo "[local-test-python] pip not found for $PYTHON. Install pip in the selected Python environment." >&2
      exit 1
    fi

    echo "[local-test-python] $PYTHON -m pip install -r requirements.txt"
    "$PYTHON" -m pip install -r requirements.txt --quiet
  elif [[ -f pyproject.toml ]]; then
    echo "[local-test-python] pyproject.toml found without requirements.txt; using the selected Python environment."
  fi
fi

if ! "$PYTHON" -m pytest --version &>/dev/null; then
  echo "[local-test-python] pytest not found for $PYTHON. Install it in the selected Python environment." >&2
  exit 1
fi

echo "[local-test-python] $PYTHON -m pytest --tb=short -q"
"$PYTHON" -m pytest --tb=short -q
echo "[local-test-python] Done."
