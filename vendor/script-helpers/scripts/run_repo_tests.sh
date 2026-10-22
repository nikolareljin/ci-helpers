#!/usr/bin/env bash
# SCRIPT: run_repo_tests.sh
# DESCRIPTION: Run a repository's test suite, detecting the stack (preflight --quick first, else PHP, Node, Python, Go, Gradle, Rust, Flutter, make test, bats, tests/*_test.sh).
# USAGE: bash scripts/run_repo_tests.sh [--require]
# PARAMETERS:
#   --require  Exit 4 when no test runner is found, instead of 0. The push
#              uses it, so an opted-in repository with no tests is not "passed".
#   -h, --help Show this help message.
#   Runs in the repository containing the current directory.
# EXIT_CODES:
#   0  tests passed, or none found without --require
#   1  tests failed (the runner's own exit code is in the message)
#   2  usage error
#   4  no tests found, with --require
# EXAMPLE: bash scripts/script-helpers/scripts/run_repo_tests.sh
# ----------------------------------------------------
# This was the test stage of the pre-push hook. A push no longer runs tests
# (it blocks on security, hygiene and lint of the changed files only); the full
# suite is `make test` or `./dev test`, and this is the same runner for a
# repository that has neither.
set -euo pipefail

_require=false
case "${1:-}" in
  "") ;;
  --require) _require=true ;;
  -h|--help) sed -n '2,/^# ----/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "[tests] unknown option: $1 (usage: run_repo_tests.sh [--require])" >&2; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

# Tests must not inherit the global hooks' script directory.
unset SCRIPT_HELPERS_SECURITY_DIR

# Resolve local_test_*.sh scripts directory; submodule path takes priority.
_scripts_dir=""
if [[ -d "$repo_root/scripts/script-helpers/scripts" ]]; then
  _scripts_dir="$repo_root/scripts/script-helpers/scripts"
elif [[ -d "$repo_root/scripts" ]]; then
  _scripts_dir="$repo_root/scripts"
fi

_ran_tests=false

# preflight.sh, when the submodule is new enough, runs every check the repo's CI
# would have run and knows about stacks this hook's own chain does not - Gradle
# and Android among them. In a repo that has deleted its build workflows this
# hook is the only remaining gate, so prefer the thorough runner and fall back
# to the per-language chain below only when it is absent.
# "Not available" is said in _preflight_absent, not in the exit code: preflight
# can itself exit 127 (a command it runs is missing), and reading that as "not
# installed" would let a failing push through.
_preflight_absent=false
run_preflight() {
  local preflight="" rc=0
  if [[ -n "$_scripts_dir" ]] && [[ -f "$_scripts_dir/preflight.sh" ]]; then
    preflight="$_scripts_dir/preflight.sh"
  else
    _preflight_absent=true
    return 0
  fi
  echo "[tests] preflight --quick"
  bash "$preflight" --quick || rc=$?
  # 3 = no stack detected. Not a failure; let the chain below try instead.
  [[ "$rc" -eq 3 ]] && { _preflight_absent=true; return 0; }
  return "$rc"
}

# Inline Go runner used when local_test_go.sh is not available.
run_go_tests_inline() {
  local gomod module_dir
  while IFS= read -r gomod; do
    module_dir="$(dirname "$gomod")"
    echo "[tests] go test ./... ($module_dir)"
    (cd "$module_dir" && go test ./...) || return $?
  done < <(
    find . \
      \( -name .git -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
      -o -type f -name go.mod -print | sort
  )
}

run_tests() {
  # PHP / Laravel - composer.json is authoritative: Laravel apps also ship a
  # package.json for Vite, so once composer.json is present we run the PHP suite
  # (or skip with a clear message) and never fall through to the Node runner.
  if [[ -f composer.json ]]; then
    if ! command -v php &>/dev/null || ! command -v composer &>/dev/null; then
      echo "[tests] composer.json found but php/composer are not installed - skipping PHP checks; push proceeds." >&2
      echo "[tests] Install PHP and Composer to run these checks before pushing." >&2
      return 0
    fi
    if [[ -n "$_scripts_dir" ]] && [[ -f "$_scripts_dir/local_test_php.sh" ]]; then
      echo "[tests] local_test_php.sh --quick"
      bash "$_scripts_dir/local_test_php.sh" --quick || return $?
      _ran_tests=true
    else
      # Track whether any PHP check actually ran so _ran_tests stays honest.
      local _php_checked=false
      if [[ -x vendor/bin/pint ]]; then
        echo "[tests] vendor/bin/pint --test"
        vendor/bin/pint --test || return $?
        _php_checked=true
      fi
      if [[ "${SKIP_PHP_TESTS:-}" != "1" ]]; then
        if [[ -f artisan ]]; then
          echo "[tests] php artisan test"
          php artisan test || return $?
          _php_checked=true
        elif [[ -x vendor/bin/phpunit ]]; then
          echo "[tests] vendor/bin/phpunit"
          vendor/bin/phpunit || return $?
          _php_checked=true
        fi
      fi
      if [[ "$_php_checked" == "true" ]]; then
        _ran_tests=true
      else
        echo "[tests] composer.json found but no PHP checks ran (no pint/artisan/phpunit, or tests skipped)." >&2
      fi
    fi
    return 0
  fi

  # Node / npm workspaces - only return when tests actually ran; otherwise fall through.
  if [[ -f package.json ]] && command -v npm &>/dev/null; then
    if [[ -n "$_scripts_dir" ]] && [[ -f "$_scripts_dir/local_test_node.sh" ]]; then
      echo "[tests] local_test_node.sh --quick"
      bash "$_scripts_dir/local_test_node.sh" --quick || return $?
      _ran_tests=true
      return 0
    elif command -v node &>/dev/null; then
      local test_script
      test_script="$(
        node -pe '
          var pkg = require("./package.json");
          var test = (pkg.scripts && pkg.scripts.test) || "";
          test === "echo \"Error: no test specified\" && exit 1" ? "" : test;
        ' 2>/dev/null || echo ""
      )"
      if [[ -n "$test_script" ]]; then
        echo "[tests] npm test"
        npm test || return $?
        _ran_tests=true
        return 0
      fi
    fi
    # package.json present but no runnable test command - fall through to other runners.
  fi

  # Python - only return when tests actually ran; otherwise fall through.
  if [[ -f pyproject.toml ]] || [[ -f setup.py ]] || [[ -f requirements.txt ]]; then
    if [[ -n "$_scripts_dir" ]] && [[ -f "$_scripts_dir/local_test_python.sh" ]]; then
      echo "[tests] local_test_python.sh --quick"
      bash "$_scripts_dir/local_test_python.sh" --quick || return $?
      _ran_tests=true
      return 0
    else
      local python_bin=""
      if [[ -x venv/bin/python ]]; then python_bin="venv/bin/python"
      elif [[ -x .venv/bin/python ]]; then python_bin=".venv/bin/python"
      elif command -v python3 &>/dev/null; then python_bin="python3"
      elif command -v python &>/dev/null; then python_bin="python"; fi

      if [[ -n "$python_bin" ]] && "$python_bin" -m pytest --version &>/dev/null; then
        echo "[tests] $python_bin -m pytest"
        "$python_bin" -m pytest --tb=short -q || return $?
        _ran_tests=true
        return 0
      fi
    fi
    # Python files present but pytest not available - fall through to other runners.
  fi

  # Go - detect go.mod first so non-Go repos fall through to Rust/Flutter.
  if command -v go &>/dev/null; then
    local first_gomod
    first_gomod="$(find . \( -name .git -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
      -o -type f -name go.mod -print -quit)"
    if [[ -n "$first_gomod" ]]; then
      if [[ -n "$_scripts_dir" ]] && [[ -f "$_scripts_dir/local_test_go.sh" ]]; then
        echo "[tests] local_test_go.sh --quick"
        bash "$_scripts_dir/local_test_go.sh" --quick || return $?
      else
        run_go_tests_inline || return $?
      fi
      _ran_tests=true
      return 0
    fi
  fi

  # Gradle / Android - checked before Flutter, because a Flutter repo's android/
  # subdirectory is built by `flutter build` and must not match here, while a
  # native Android or plain JVM repo has no pubspec.yaml to fall through to.
  if [[ ! -f pubspec.yaml ]] && { [[ -x ./gradlew ]] || [[ -f settings.gradle ]] || [[ -f settings.gradle.kts ]]; }; then
    if [[ -n "$_scripts_dir" ]] && [[ -f "$_scripts_dir/local_test_gradle.sh" ]]; then
      echo "[tests] local_test_gradle.sh --quick"
      bash "$_scripts_dir/local_test_gradle.sh" --quick || return $?
      _ran_tests=true
      return 0
    elif [[ -x ./gradlew ]]; then
      echo "[tests] ./gradlew test"
      ./gradlew --no-daemon test || return $?
      _ran_tests=true
      return 0
    fi
    # settings.gradle but no wrapper - fall through rather than invoking a
    # system gradle at a version the project did not pin.
  fi

  # Rust
  if [[ -f Cargo.toml ]] && command -v cargo &>/dev/null; then
    if [[ -n "$_scripts_dir" ]] && [[ -f "$_scripts_dir/local_test_rust.sh" ]]; then
      echo "[tests] local_test_rust.sh --quick"
      bash "$_scripts_dir/local_test_rust.sh" --quick || return $?
    else
      echo "[tests] cargo test"
      cargo test || return $?
    fi
    _ran_tests=true
    return 0
  fi

  # Flutter / Dart
  if [[ -f pubspec.yaml ]] && command -v flutter &>/dev/null; then
    if [[ -n "$_scripts_dir" ]] && [[ -f "$_scripts_dir/local_test_flutter.sh" ]]; then
      echo "[tests] local_test_flutter.sh --quick"
      bash "$_scripts_dir/local_test_flutter.sh" --quick || return $?
    else
      echo "[tests] flutter test"
      flutter test || return $?
    fi
    _ran_tests=true
    return 0
  fi

  # Shell repositories. Nothing above matches a repo with no manifest file, so
  # this hook used to print "No test runner detected" and exit 0 for them -- and
  # both shared libraries here are shell repos. A broken push reported success.
  local candidate mk=""
  for candidate in Makefile makefile GNUmakefile; do
    [[ -f "$candidate" ]] && { mk="$candidate"; break; }
  done
  if [[ -n "$mk" ]] && grep -qE '^test[[:space:]]*:' "$mk"; then
    echo "[tests] make test"
    make test || return $?
    _ran_tests=true
    return 0
  fi

  local bats_files=()
  while IFS= read -r candidate; do bats_files+=("$candidate"); done \
    < <(find tests -maxdepth 1 -name '*.bats' 2>/dev/null | sort)
  if [[ ${#bats_files[@]} -gt 0 ]] && command -v bats >/dev/null 2>&1; then
    echo "[tests] bats tests"
    bats tests || return $?
    _ran_tests=true
    return 0
  fi

  # tests/*_test.sh, the convention this library uses for itself.
  local sh_tests=()
  while IFS= read -r candidate; do sh_tests+=("$candidate"); done \
    < <(find tests -maxdepth 1 -name '*_test.sh' 2>/dev/null | sort)
  if [[ ${#sh_tests[@]} -gt 0 ]]; then
    echo "[tests] ${#sh_tests[@]} shell test file(s) under tests/"
    for candidate in "${sh_tests[@]}"; do
      echo "[tests]   $candidate"
      bash "$candidate" || return $?
    done
    _ran_tests=true
    return 0
  fi

  if [[ ${#bats_files[@]} -gt 0 ]]; then
    echo "[tests] tests/*.bats present but bats is not installed - nothing ran." >&2
    return 1
  fi

  echo "[tests] No test runner detected - skipping. Nothing to run."
}

# Unset git's hook variables before running the repository's tests.
#
# Why: git sets GIT_DIR (and similar variables) for a hook, pointing at the
# repository being pushed. The checks above need them. Tests must not see
# them: GIT_DIR beats the current directory, so a test that makes its own
# temporary repository would use the pushed one instead. In a linked worktree
# GIT_DIR is an absolute path, and there such tests failed only inside the
# hook, and the push was refused.
#
# Exception: the variables are kept if git, without them, would find no
# repository here, a different repository, or a different work tree. That is
# `git --git-dir=... --work-tree=... push`, where the variables are the only
# way to find the right place.
#
# What is unset: the names `git rev-parse --local-env-vars` prints, plus the
# six a hook always gets, written out in case that command is missing.
_drop_git_hook_env() {
  local names with without
  names="$(git rev-parse --local-env-vars 2>/dev/null || true) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY"
  # Where git looks now, and where it would look without the variables.
  with="$(git rev-parse --absolute-git-dir --show-toplevel 2>/dev/null)" || return 0
  # shellcheck disable=SC2086  # $names is a list: one variable name per word
  without="$(unset $names; git rev-parse --absolute-git-dir --show-toplevel 2>/dev/null)" || return 0
  [[ -n "$with" && "$with" == "$without" ]] || return 0
  # shellcheck disable=SC2086
  unset $names
}
_drop_git_hook_env

# A failure is always exit 1, with the runner's code in the message. Passing
# the runner's code through made `make test` (exit 2) read as a usage error and
# a runner that exits 4 read as "no tests found".
_preflight_rc=0
run_preflight || _preflight_rc=$?
if [[ "$_preflight_rc" -ne 0 ]]; then
  echo "[tests] preflight failed (exit $_preflight_rc)." >&2
  exit 1
elif [[ "$_preflight_absent" != true ]]; then
  echo "[tests] All checks passed."
  exit 0
fi

# Captured, not left to `set -e`. Calling run_tests in a `||` context disables
# -e INSIDE it, so every runner needs its own `|| return $?` -- without them a
# failing `make test` or `npm test` fell through to `return 0` and the push was
# allowed. Checked by driving a repo whose tests exit 1.
_tests_rc=0
run_tests || _tests_rc=$?
if [[ "$_tests_rc" -ne 0 ]]; then
  echo "[tests] tests failed (exit $_tests_rc)." >&2
  exit 1
fi
if [[ "$_ran_tests" == "true" ]]; then
  echo "[tests] All checks passed."
elif [[ "$_require" == true ]]; then
  echo "[tests] no tests found to run (add make test, or a stack the runner detects)." >&2
  exit 4
fi
