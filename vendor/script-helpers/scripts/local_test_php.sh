#!/usr/bin/env bash
# SCRIPT: local_test_php.sh
# DESCRIPTION: Install dependencies, check style (Pint), and run tests for PHP/Laravel projects.
# USAGE: bash scripts/local_test_php.sh [--quick] [--dir <path>]
#
# PARAMETERS:
#   --quick   Skip composer install; lint and test against existing vendor/.
#   --dir     Subdirectory containing composer.json (default: .).
# ENVIRONMENT:
#   SKIP_PHP_TESTS=1   Run style checks only; skip the (DB-backed) test suite.
#                      Useful for a pre-push without a local database.
# ----------------------------------------------------
set -euo pipefail

QUICK=false
TEST_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-php] --dir requires a path." >&2
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
  echo "[local-test-php] Directory not found: $repo_root/$TEST_DIR" >&2
  exit 1
fi
cd "$repo_root/$TEST_DIR"

if [[ ! -f composer.json ]]; then
  echo "[local-test-php] No composer.json in $TEST_DIR." >&2
  exit 1
fi

if ! command -v php &>/dev/null; then
  echo "[local-test-php] php not found in PATH. Install PHP before running this script." >&2
  exit 1
fi

if ! command -v composer &>/dev/null; then
  echo "[local-test-php] composer not found in PATH. Install Composer before running this script." >&2
  exit 1
fi

if [[ "$QUICK" == "false" ]]; then
  echo "[local-test-php] composer install"
  composer install --no-interaction --prefer-dist
fi

# Style check (Laravel Pint) when available — fast and deterministic.
if [[ -x vendor/bin/pint ]]; then
  echo "[local-test-php] vendor/bin/pint --test"
  vendor/bin/pint --test
fi

if [[ "${SKIP_PHP_TESTS:-}" == "1" ]]; then
  echo "[local-test-php] SKIP_PHP_TESTS=1 — style only; skipping test suite."
  echo "[local-test-php] Done."
  exit 0
fi

# Prefer Laravel's test runner; fall back to PHPUnit.
if [[ -f artisan ]]; then
  echo "[local-test-php] php artisan test"
  php artisan test
elif [[ -x vendor/bin/phpunit ]]; then
  echo "[local-test-php] vendor/bin/phpunit"
  vendor/bin/phpunit
else
  # Exit non-zero so callers (pre-push hooks, CI) do not mistake "no runner" for
  # a passing suite. Use SKIP_PHP_TESTS=1 for an intentional style-only run.
  echo "[local-test-php] No test runner found (artisan/phpunit) and tests were not skipped." >&2
  echo "[local-test-php] Set SKIP_PHP_TESTS=1 for a style-only run, or add a test runner." >&2
  exit 1
fi

echo "[local-test-php] Done."
