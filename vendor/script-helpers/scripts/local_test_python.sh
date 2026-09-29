#!/usr/bin/env bash
# SCRIPT: local_test_python.sh
# DESCRIPTION: Use a local virtualenv when available, run ruff (when the project
#   configures it) and then pytest.
# USAGE: bash scripts/local_test_python.sh [--quick] [--dir <path>]
#
# PARAMETERS:
#   --quick   Skip install; run lint and tests against the current environment.
#   --dir     Subdirectory containing pyproject.toml/requirements.txt (default: .).
# EXIT_CODES:
#   0  Every check that ran passed.
#   1  A check failed, or bad arguments.
#   3  Nothing could be checked: pytest, or a configured ruff, is not installed, or pytest
#      collected no tests. preflight reports it as SKIP.
# ----------------------------------------------------
set -euo pipefail

# skip_exit <reason>; nothing could be checked. Exit 3, which preflight reports as
# SKIP with this reason (written to $PREFLIGHT_SKIP_FILE when preflight sets it).
skip_exit() {
  echo "[local-test-python] $1" >&2
  if [[ -n "${PREFLIGHT_SKIP_FILE:-}" ]]; then printf '%s\n' "$1" > "$PREFLIGHT_SKIP_FILE"; fi
  exit 3
}

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

# The library root, resolved before any cd. $BASH_SOURCE is whatever the caller
# typed -- "scripts/local_test_x.sh" for the documented invocation -- so
# resolving it after cd-ing into the project looks for the library under the
# project and silently loses the helper it needs.
SH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  echo "[local-test-python] Directory not found: $target" >&2
  exit 1
fi
cd "$target"

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

# A project with no venv falls back to the system interpreter, and on a modern
# Debian or Ubuntu that interpreter is PEP 668 "externally managed": installing
# into it is refused by design. Rather than pass --break-system-packages, which
# is what the error message tempts you into and which can damage the OS Python,
# create a project-local venv and use that. Reuses lib/python.sh's helper rather
# than repeating the logic.
if [[ "$PYTHON" == "python3" || "$PYTHON" == "python" ]] \
   && [[ -f requirements.txt || -f pyproject.toml ]] \
   && "$PYTHON" -c 'import os,sys,sysconfig; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"),"EXTERNALLY-MANAGED")) else 1)' 2>/dev/null; then
  _sh_dir="$SH_ROOT"
  if [[ -f "$_sh_dir/helpers.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_sh_dir/helpers.sh"
    shlib_import python >/dev/null 2>&1 || true
  fi
  echo "[local-test-python] system Python is externally managed (PEP 668); using a project venv at .venv"
  if declare -f python_ensure_venv >/dev/null 2>&1 && python_ensure_venv "$PYTHON" ".venv" >/dev/null 2>&1 \
     && [[ -x .venv/bin/python ]]; then
    PYTHON=".venv/bin/python"
  elif "$PYTHON" -m venv .venv >/dev/null 2>&1 && [[ -x .venv/bin/python ]]; then
    PYTHON=".venv/bin/python"
  else
    echo "[local-test-python] Could not create .venv. Install python3-venv, or create a venv yourself." >&2
    exit 1
  fi
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

  # requirements.txt is runtime dependencies; the test tools usually are not in
  # it. A project that declares a `dev` extra is stating where they live, so
  # honour it rather than making the caller install pytest by hand. This is the
  # same shape ci-helpers' documented install_command uses.
  if [[ -f pyproject.toml ]] && grep -qE '^[[:space:]]*dev[[:space:]]*=' pyproject.toml; then
    echo "[local-test-python] $PYTHON -m pip install -e '.[dev]'"
    "$PYTHON" -m pip install -e '.[dev]' --quiet \
      || echo "[local-test-python] the dev extra did not install; continuing" >&2
  fi
fi

# Lint, when the project configures a linter. preflight labels this step
# "lint + test"; running only pytest made that label a lie, and a repo that had
# moved its CI here would lose the lint gate without a word about it.
ruff_configured() {
  [[ -f ruff.toml || -f .ruff.toml ]] && return 0
  [[ -f pyproject.toml ]] && grep -q '^\[tool\.ruff' pyproject.toml
}

if ruff_configured; then
  declare -a RUFF=()
  if "$PYTHON" -m ruff --version &>/dev/null; then
    RUFF=("$PYTHON" -m ruff)
  elif command -v ruff &>/dev/null; then
    RUFF=(ruff)
  fi
  if [[ ${#RUFF[@]} -eq 0 && "$QUICK" == "false" ]]; then
    echo "[local-test-python] $PYTHON -m pip install ruff"
    "$PYTHON" -m pip install ruff --quiet || true
    "$PYTHON" -m ruff --version &>/dev/null && RUFF=("$PYTHON" -m ruff)
  fi
  if [[ ${#RUFF[@]} -eq 0 ]]; then
    # Configured but absent is a missing gate, not a clean run: say so and stop
    # with exit 3, which preflight reports as SKIP -- listed apart from passes,
    # never counted as one -- like a missing pytest, go or npm.
    skip_exit "ruff is configured but not installed; lint and tests not run. Install: $PYTHON -m pip install ruff"
  fi
  echo "[local-test-python] ${RUFF[*]} check ."
  "${RUFF[@]}" check .
fi

if ! "$PYTHON" -m pytest --version &>/dev/null; then
  # A missing tool is a check that could not run, like a missing go or npm in
  # preflight: exit 3 (a SKIP there) with the fix, not a failure of the code.
  skip_exit "pytest is not installed for $PYTHON; tests not run. Install: $PYTHON -m pip install pytest"
fi

echo "[local-test-python] $PYTHON -m pytest --tb=short -q"
pytest_rc=0
"$PYTHON" -m pytest --tb=short -q || pytest_rc=$?
case "$pytest_rc" in
  0) ;;
  5) skip_exit "pytest collected no tests; nothing to test" ;;
  3) exit 1 ;;   # pytest's internal error; 3 from this runner means skip_exit
  *) exit "$pytest_rc" ;;
esac
echo "[local-test-python] Done."
