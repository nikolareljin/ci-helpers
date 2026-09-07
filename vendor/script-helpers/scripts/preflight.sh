#!/usr/bin/env bash
# SCRIPT: preflight.sh
# DESCRIPTION: Run every check CI would have run, locally, before pushing.
# USAGE: bash scripts/preflight.sh [--quick] [--stack <name>] [--docker] [--skip-security] [--list]
#
# PARAMETERS:
#   --quick           Skip build/assemble steps. Tests and lint still run.
#                     This is what the pre-push hook uses.
#   --stack <name>    Check one stack only, instead of every stack detected.
#                     Repeatable. One of: flutter gradle node python go rust php.
#   --docker          Reproduce CI in containers via the ci_*.sh runners, using
#                     the images pinned in lib/ci_defaults.sh. Slower and closer
#                     to CI. The default runs on the host, which is what makes
#                     this fast enough to sit in a git hook.
#   --skip-security   Skip the secret / dependency scan.
#   --list            Print the stacks detected and exit without running them.
#   --dir <path>      Project directory (default: the repository root).
#   -h, --help        Show this help message.
#
#   A repo may pin exactly what runs with a `.preflight` file at its root:
#   one "<stack> <dir>" per line, # comments allowed. When present it replaces
#   autodetection, which is how a repo excludes a helper directory that merely
#   happens to contain a package.json.
#
# EXIT_CODES:
#   0  Every check that ran passed.
#   1  At least one check failed.
#   2  Bad arguments, or an unknown --stack.
#   3  No stack could be detected in this directory.
#
# EXAMPLE:
#   bash scripts/preflight.sh                  # everything, on the host
#   bash scripts/preflight.sh --quick          # what pre-push runs
#   bash scripts/preflight.sh --stack flutter --docker
# ----------------------------------------------------
set -uo pipefail

# Deliberately not `set -e`: preflight runs every check and reports all the
# failures, rather than stopping at the first one. A developer fixing three
# things wants to see three things.

if [[ "${CI:-}" == "true" ]]; then
  echo "This script is intended for local use only." >&2
  echo "In CI, run the checks directly — preflight exists to replace CI, not to run inside it." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging

QUICK=false
USE_DOCKER=false
SKIP_SECURITY=false
LIST_ONLY=false
PROJECT_DIR=""
declare -a WANTED_STACKS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    --docker) USE_DOCKER=true; shift ;;
    --no-docker) USE_DOCKER=false; shift ;;   # accepted for symmetry with ci_*.sh
    --skip-security) SKIP_SECURITY=true; shift ;;
    --list) LIST_ONLY=true; shift ;;
    --stack) WANTED_STACKS+=("${2:-}"); shift 2 ;;
    --dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
[[ -d "$PROJECT_DIR" ]] || { log_error "preflight: not a directory: $PROJECT_DIR"; exit 2; }
cd "$PROJECT_DIR" || exit 2

KNOWN_STACKS="flutter gradle node python go rust php"
for s in "${WANTED_STACKS[@]}"; do
  [[ " $KNOWN_STACKS " == *" $s "* ]] || {
    log_error "preflight: unknown stack '$s'. Known: $KNOWN_STACKS"
    exit 2
  }
done

# ---------------------------------------------------------------------------
# Detection
#
# A repo can be more than one stack at once, and in this fleet several are: an
# Android app under android/ plus a Python host under host/, a Flutter app under
# mobile/ plus a Go CLI. Detecting a list of (stack, directory) pairs rather
# than one winner at the root is exactly what lets this replace a multi-job CI
# workflow with one command.
#
# Emits "<stack>\t<dir>" lines, <dir> relative to the project root.
# ---------------------------------------------------------------------------

# Directories that hold someone else's code or this build's output.
_is_pruned() {
  case "$1" in
    */node_modules/*|*/build/*|*/.git/*|*/vendor/*|*/.dart_tool/*|*/.gradle/*|*/target/*|*/venv/*|*/.venv/*) return 0 ;;
  esac
  return 1
}

detect_stacks() {
  local marker dir
  local -a pairs=() flutter_dirs=()

  while IFS= read -r marker; do
    _is_pruned "$marker" && continue
    dir="$(dirname "$marker")"; dir="${dir#./}"; [[ -n "$dir" ]] || dir="."
    case "$(basename "$marker")" in
      pubspec.yaml)                       pairs+=("flutter	$dir"); flutter_dirs+=("$dir") ;;
      gradlew|settings.gradle|settings.gradle.kts) pairs+=("gradle	$dir") ;;
      package.json)                       pairs+=("node	$dir") ;;
      pyproject.toml|setup.py|requirements.txt) pairs+=("python	$dir") ;;
      go.mod)                             pairs+=("go	$dir") ;;
      Cargo.toml)                         pairs+=("rust	$dir") ;;
      composer.json)                      pairs+=("php	$dir") ;;
    esac
  done < <(find . -maxdepth 3 -type f \
             \( -name pubspec.yaml -o -name gradlew -o -name 'settings.gradle' \
                -o -name 'settings.gradle.kts' -o -name package.json \
                -o -name pyproject.toml -o -name setup.py -o -name requirements.txt \
                -o -name go.mod -o -name Cargo.toml -o -name composer.json \) 2>/dev/null | sort)

  # Deduplicate, then drop two kinds of redundant project:
  #
  #  * A Gradle project inside a Flutter app. A Flutter repo's android/ tree is
  #    built by `flutter build`, not by a second Gradle pass; running both
  #    doubles the slowest step for no extra coverage.
  #  * A same-stack project nested inside another. A Cargo workspace member, or
  #    a package inside an npm workspace, is built by its root — checking both
  #    runs the same tests twice.
  local pair stack pdir other odir ostack skip
  local -a seen=() kept=()
  for pair in "${pairs[@]}"; do
    case " ${seen[*]-} " in *" $pair "*) continue ;; esac
    seen+=("$pair")
    stack="${pair%%	*}"; pdir="${pair#*	}"
    skip=0
    if [[ "$stack" == "gradle" ]]; then
      for other in "${flutter_dirs[@]-}"; do
        [[ -n "$other" ]] || continue
        [[ "$other" == "." || "$pdir" == "$other" || "$pdir" == "$other"/* ]] && { skip=1; break; }
      done
    fi
    [[ "$skip" -eq 1 ]] && continue
    kept+=("$pair")
  done

  for pair in "${kept[@]-}"; do
    [[ -n "$pair" ]] || continue
    stack="${pair%%	*}"; pdir="${pair#*	}"
    skip=0
    for other in "${kept[@]}"; do
      ostack="${other%%	*}"; odir="${other#*	}"
      [[ "$ostack" == "$stack" && "$odir" != "$pdir" ]] || continue
      # $pdir sits inside $odir — the outer project owns it.
      if [[ "$odir" == "." || "$pdir" == "$odir"/* ]]; then skip=1; break; fi
    done
    [[ "$skip" -eq 1 ]] && continue
    printf '%s\n' "$pair"
  done
}

# A repo may pin exactly what preflight checks with a `.preflight` file at its
# root: one "<stack> <dir>" per line, blank lines and # comments ignored. When
# present it is authoritative, because autodetection cannot tell a project that
# CI built from a helper directory that merely contains a package.json.
read_preflight_config() {
  local file="$PROJECT_DIR/.preflight" stack dir
  [[ -f "$file" ]] || return 1
  while read -r stack dir _; do
    [[ -n "$stack" ]] || continue
    [[ "$stack" == \#* ]] && continue
    [[ " $KNOWN_STACKS " == *" $stack "* ]] || {
      log_error ".preflight: unknown stack '$stack'"
      return 2
    }
    printf '%s\t%s\n' "$stack" "${dir:-.}"
  done < "$file"
}

DETECTED=()
CONFIGURED=false
if [[ -f "$PROJECT_DIR/.preflight" ]]; then
  while IFS= read -r line; do [[ -n "$line" ]] && DETECTED+=("$line"); done < <(read_preflight_config)
  [[ ${#DETECTED[@]} -gt 0 ]] || { log_error "preflight: .preflight is present but lists no usable projects"; exit 2; }
  CONFIGURED=true
else
  while IFS= read -r line; do [[ -n "$line" ]] && DETECTED+=("$line"); done < <(detect_stacks)
fi

# --stack filters the detected pairs rather than replacing them, so the
# directory a stack lives in is still discovered rather than assumed to be root.
PAIRS=()
if [[ ${#WANTED_STACKS[@]} -gt 0 ]]; then
  for pair in "${DETECTED[@]-}"; do
    [[ -n "$pair" ]] || continue
    for s in "${WANTED_STACKS[@]}"; do
      [[ "${pair%%	*}" == "$s" ]] && { PAIRS+=("$pair"); break; }
    done
  done
  if [[ ${#PAIRS[@]} -eq 0 ]]; then
    log_error "preflight: --stack ${WANTED_STACKS[*]} requested, but none was detected in $PROJECT_DIR"
    exit 3
  fi
else
  PAIRS=("${DETECTED[@]-}")
fi

if [[ "$LIST_ONLY" == "true" ]]; then
  if [[ ${#DETECTED[@]} -eq 0 ]]; then
    echo "No stack detected in $PROJECT_DIR"
    exit 3
  fi
  printf '%s\n' "${DETECTED[@]}"
  exit 0
fi

if [[ ${#PAIRS[@]} -eq 0 || -z "${PAIRS[0]}" ]]; then
  log_error "preflight: no stack detected in $PROJECT_DIR"
  log_error "Looked for: pubspec.yaml, gradlew, package.json, pyproject.toml, go.mod, Cargo.toml, composer.json"
  log_error "Pass --stack <name> to force one."
  exit 3
fi

# ---------------------------------------------------------------------------
# Step runner
# ---------------------------------------------------------------------------

declare -a RESULTS=()
FAILED=0

# run_step <label> <command...>; run a check, record pass/fail, never abort.
run_step() {
  local label="$1"; shift
  print_line 2>/dev/null || true
  log_info "preflight: $label"
  if "$@"; then
    RESULTS+=("PASS  $label")
    return 0
  fi
  RESULTS+=("FAIL  $label")
  FAILED=1
  log_error "preflight: $label FAILED"
  return 1
}

# skip_step <label> <reason>; record a check that could not run. A skip is not a
# pass — it is reported separately so an absent toolchain cannot look green.
skip_step() {
  RESULTS+=("SKIP  $1 — $2")
  log_warn "preflight: skipping $1 — $2"
}

helper_script() { printf '%s/scripts/%s\n' "$SCRIPT_HELPERS_DIR" "$1"; }

# in_dir <dir> <command...>; run a command from inside its project directory.
# Used only for tools invoked directly (a raw `flutter build`); the
# local_test_*.sh runners take --dir instead, because each of them resolves its
# directory against the repository root rather than the current one — cd alone
# silently ran them against the wrong tree, and a runner that finds nothing
# reports success.
# Invoked indirectly, as the command argument to run_step.
# shellcheck disable=SC2329
in_dir() {
  local dir="$1"; shift
  ( cd "$PROJECT_DIR/$dir" && "$@" )
}

# label <stack> <dir>; "gradle" at the root, "gradle (android/)" in a subdir.
label() {
  [[ "$2" == "." ]] && { printf '%s\n' "$1"; return; }
  printf '%s (%s/)\n' "$1" "$2"
}

# ---------------------------------------------------------------------------
# Per-stack checks. Each takes the directory its project lives in.
# ---------------------------------------------------------------------------

check_flutter() {
  local dir="$1" name; name="$(label flutter "$dir")"
  if [[ "$USE_DOCKER" == "true" ]]; then
    local args=(--workdir "$dir")
    [[ "$QUICK" == "true" ]] && args+=(--skip-build)
    run_step "$name (docker)" bash "$(helper_script ci_flutter.sh)" "${args[@]}"
    return
  fi
  if ! command -v flutter >/dev/null 2>&1 && [[ ! -x "${FLUTTER_ROOT:-}/bin/flutter" ]]; then
    skip_step "$name" "flutter is not installed (try --docker, or set FLUTTER_ROOT)"
    return
  fi
  local args=()
  [[ "$QUICK" == "true" ]] && args+=(--quick)
  local what="analyze + test"; [[ "$QUICK" == "true" ]] && what="test"
  run_step "$name $what" bash "$(helper_script local_test_flutter.sh)" --dir "$dir" "${args[@]}"
  if [[ "$QUICK" == "false" ]]; then
    run_step "$name build apk --debug" in_dir "$dir" flutter build apk --debug
  fi
}

check_gradle() {
  local dir="$1" name; name="$(label gradle "$dir")"
  if [[ "$USE_DOCKER" == "true" ]]; then
    local args=(--workdir "$dir" --skip-detekt)
    [[ "$QUICK" == "true" ]] && args+=(--skip-build)
    run_step "$name (docker)" bash "$(helper_script ci_gradle.sh)" "${args[@]}"
    return
  fi
  if [[ ! -x "$PROJECT_DIR/$dir/gradlew" ]]; then
    skip_step "$name" "no executable ./gradlew (try --docker)"
    return
  fi
  local args=()
  [[ "$QUICK" == "true" ]] && args+=(--quick)
  local what="lint + test + assemble"; [[ "$QUICK" == "true" ]] && what="test"
  run_step "$name $what" bash "$(helper_script local_test_gradle.sh)" --dir "$dir" "${args[@]}"
}

check_node() {
  local dir="$1" name; name="$(label node "$dir")"
  if ! command -v npm >/dev/null 2>&1; then
    skip_step "$name" "npm is not installed"
    return
  fi
  local args=()
  [[ "$QUICK" == "true" ]] && args+=(--quick)
  run_step "$name lint + test" bash "$(helper_script local_test_node.sh)" --dir "$dir" "${args[@]}"
}

check_python() {
  local dir="$1" name; name="$(label python "$dir")"
  if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    skip_step "$name" "no python interpreter found"
    return
  fi
  local args=()
  [[ "$QUICK" == "true" ]] && args+=(--quick)
  run_step "$name lint + test" bash "$(helper_script local_test_python.sh)" --dir "$dir" "${args[@]}"
}

check_go() {
  local dir="$1" name; name="$(label go "$dir")"
  if ! command -v go >/dev/null 2>&1; then
    skip_step "$name" "go is not installed"
    return
  fi
  local args=()
  [[ "$QUICK" == "true" ]] && args+=(--quick)
  run_step "$name vet + test" bash "$(helper_script local_test_go.sh)" --dir "$dir" "${args[@]}"
}

check_rust() {
  local dir="$1" name; name="$(label rust "$dir")"
  if ! command -v cargo >/dev/null 2>&1; then
    skip_step "$name" "cargo is not installed"
    return
  fi
  local args=()
  [[ "$QUICK" == "true" ]] && args+=(--quick)
  run_step "$name clippy + test" bash "$(helper_script local_test_rust.sh)" --dir "$dir" "${args[@]}"
}

check_php() {
  local dir="$1" name; name="$(label php "$dir")"
  if ! command -v php >/dev/null 2>&1; then
    skip_step "$name" "php is not installed"
    return
  fi
  local args=()
  [[ "$QUICK" == "true" ]] && args+=(--quick)
  run_step "$name lint + test" bash "$(helper_script local_test_php.sh)" --dir "$dir" "${args[@]}"
}

check_security() {
  local scanner
  scanner="$(helper_script ci_security.sh)"
  [[ -f "$scanner" ]] || { skip_step "security" "ci_security.sh not found"; return; }
  local args=(--workdir .)
  [[ "$USE_DOCKER" == "true" ]] || args+=(--no-docker)
  # gitleaks on the host needs the binary; in Docker mode it comes from the image.
  if [[ "$USE_DOCKER" == "false" ]] && ! command -v gitleaks >/dev/null 2>&1; then
    args+=(--skip-gitleaks)
    log_warn "preflight: gitleaks is not installed — secret scanning is being skipped."
    log_warn "This is the one check the weekly scheduled sweep exists to backstop. Install gitleaks, or run with --docker."
  fi
  run_step "security scan" bash "$scanner" "${args[@]}"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

log_info "preflight: $PROJECT_DIR"
log_info "preflight: ${#PAIRS[@]} project(s)$([[ "$CONFIGURED" == "true" ]] && echo ' from .preflight')$([[ "$QUICK" == "true" ]] && echo ' (quick)')$([[ "$USE_DOCKER" == "true" ]] && echo ' (docker)')"
for pair in "${PAIRS[@]}"; do
  log_info "  - $(label "${pair%%	*}" "${pair#*	}")"
done

for pair in "${PAIRS[@]}"; do
  stack="${pair%%	*}"; stack_dir="${pair#*	}"
  case "$stack" in
    flutter) check_flutter "$stack_dir" ;;
    gradle)  check_gradle  "$stack_dir" ;;
    node)    check_node    "$stack_dir" ;;
    python)  check_python  "$stack_dir" ;;
    go)      check_go      "$stack_dir" ;;
    rust)    check_rust    "$stack_dir" ;;
    php)     check_php     "$stack_dir" ;;
  esac
done

[[ "$SKIP_SECURITY" == "true" ]] || check_security

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "preflight summary"
echo "-----------------"
printf '%s\n' "${RESULTS[@]}"
echo

if [[ "$FAILED" -eq 0 ]]; then
  log_info "preflight: all checks passed."
  exit 0
fi
log_error "preflight: one or more checks failed. Fix them, or push with --no-verify if you know why."
exit 1
