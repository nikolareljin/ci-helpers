#!/usr/bin/env bash
# SCRIPT: ci_security.sh
# DESCRIPTION: Run basic security checks (pip-audit/safety/bandit, npm audit, gitleaks, foxguard).
# USAGE: scripts/ci_security.sh [--workdir <path>] [--install] [--skip-python] [--skip-node] [--skip-gitleaks] [--skip-foxguard] [--check-foxguard] [--install-foxguard] [--fail-on-findings]
# PARAMETERS:
#   --workdir <path>       Working directory (default: current dir).
#   --install              Install required tools into current environment.
#   --skip-python          Skip Python dependency checks.
#   --skip-node            Skip Node.js audit.
#   --skip-gitleaks        Skip gitleaks scan.
#   --skip-foxguard        Skip the foxguard static-analysis scan.
#   --check-foxguard       Exit 0 if foxguard is available, 3 if not (for preflight).
#   --install-foxguard     Download the pinned foxguard release binary, check its
#                          SHA-256 against lib/ci_defaults.sh, cache it, and exit.
#   --python-req <f>       Python requirements file (default: requirements.txt if present).
#   --node-cmd <c>         Override node audit command (default: npm audit --audit-level=high).
#   --python-version <v>   Python Docker image tag (default: from ci_defaults module).
#   --node-version <v>     Node Docker image tag (default: from ci_defaults module).
#   --gitleaks-version <v> Gitleaks Docker image tag (default: from ci_defaults module).
#   --gitleaks-digest <d>  Pin gitleaks image to a specific digest for supply-chain security.
#   --python-image <i>     Docker image override for python checks.
#   --node-image <i>       Docker image override for node checks.
#   --gitleaks-image <i>   Docker image override for gitleaks.
#   --no-docker            Run on the host instead of Docker.
#   --fail-on-findings     Exit 1 when any check reports a finding (default: report
#                          only). gitleaks then scans what git tracks, history
#                          included, instead of every file on disk: ignored files
#                          (.env, .venv, node_modules) are not the repository's
#                          leaks, and failing on them fails every developer machine.
#                          --workdir still limits the audits; git mode reads the
#                          whole repository's history, from any subdirectory.
#                          foxguard findings count only where the repository has
#                          a foxguard config (.foxguard.yml, .foxguard.yaml,
#                          foxguard.yml, foxguard.yaml); elsewhere they are
#                          reported, not counted.
#   -h, --help             Show this help message.
# EXIT CODES: 0 clean (or reported only); 1 findings with --fail-on-findings;
#   3 only under preflight (PREFLIGHT_SKIP_FILE set): nothing it was asked for
#   could run (a missing tool, no manifest, no lockfile), reason in that file.
# ----------------------------------------------------
set -euo pipefail

if [[ "${CI:-}" == "true" ]]; then
  echo "This script is intended for local use only." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging ci_defaults foxguard

WORKDIR="."
INSTALL_TOOLS=false
SKIP_PYTHON=false
SKIP_NODE=false
SKIP_GITLEAKS=false
SKIP_FOXGUARD=false
INSTALL_FOXGUARD=false
FAIL_ON_FINDINGS=false
FINDINGS=0
PYTHON_REQ=""
NODE_CMD="npm audit --audit-level=high"
USE_DOCKER=true
PY_VERSION="$CI_DEFAULT_PYTHON_VERSION"
NODE_VERSION="$CI_DEFAULT_NODE_VERSION"
GITLEAKS_VERSION="$CI_DEFAULT_GITLEAKS_VERSION"
GITLEAKS_DIGEST=""
PY_IMAGE_OVERRIDE=""
NODE_IMAGE_OVERRIDE=""
GITLEAKS_IMAGE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --install) INSTALL_TOOLS=true; shift;;
    --skip-python) SKIP_PYTHON=true; shift;;
    --skip-node) SKIP_NODE=true; shift;;
    --skip-gitleaks) SKIP_GITLEAKS=true; shift;;
    --skip-foxguard) SKIP_FOXGUARD=true; shift;;
    --install-foxguard) INSTALL_FOXGUARD=true; shift;;
    --check-foxguard) foxguard_bin >/dev/null && exit 0; exit 3;;
    --fail-on-findings) FAIL_ON_FINDINGS=true; shift;;
    --python-req) PYTHON_REQ="$2"; shift 2;;
    --node-cmd) NODE_CMD="$2"; shift 2;;
    --no-docker) USE_DOCKER=false; shift;;
    --python-version) PY_VERSION="$2"; shift 2;;
    --node-version) NODE_VERSION="$2"; shift 2;;
    --gitleaks-version) GITLEAKS_VERSION="$2"; shift 2;;
    --gitleaks-digest) GITLEAKS_DIGEST="$2"; shift 2;;
    --python-image) PY_IMAGE_OVERRIDE="$2"; shift 2;;
    --node-image) NODE_IMAGE_OVERRIDE="$2"; shift 2;;
    --gitleaks-image) GITLEAKS_IMAGE_OVERRIDE="$2"; shift 2;;
    -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ "$INSTALL_FOXGUARD" == "true" ]]; then
  foxguard_install
  exit $?
fi

# Resolve images: --*-image overrides take precedence over --*-version defaults.
if [[ -n "$PY_IMAGE_OVERRIDE" ]]; then
  PY_IMAGE="$PY_IMAGE_OVERRIDE"
else
  PY_IMAGE="${CI_DEFAULT_PYTHON_IMAGE}:${PY_VERSION}"
fi

if [[ -n "$NODE_IMAGE_OVERRIDE" ]]; then
  NODE_IMAGE="$NODE_IMAGE_OVERRIDE"
else
  NODE_IMAGE="${CI_DEFAULT_NODE_IMAGE}:${NODE_VERSION}"
fi

if [[ -n "$GITLEAKS_IMAGE_OVERRIDE" ]]; then
  GITLEAKS_IMAGE="$GITLEAKS_IMAGE_OVERRIDE"
else
  GITLEAKS_IMAGE="${CI_DEFAULT_GITLEAKS_IMAGE}:${GITLEAKS_VERSION}"
fi

# Apply digest to gitleaks image if provided (supply-chain pinning).
if [[ -n "$GITLEAKS_DIGEST" ]]; then
  if [[ ! "$GITLEAKS_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    log_error "Invalid digest format. Expected sha256:<64-hex-chars>, got: $GITLEAKS_DIGEST"
    exit 1
  fi
  if [[ "$GITLEAKS_IMAGE" =~ @sha256: ]]; then
    log_error "Gitleaks image already contains a digest. Use --gitleaks-image without digest or omit --gitleaks-digest."
    exit 1
  fi
  GITLEAKS_IMAGE="${GITLEAKS_IMAGE}@${GITLEAKS_DIGEST}"
fi

# finding <tool>; a check exited non-zero: it reported findings, or could not
# run to the end. Counted only with --fail-on-findings.
finding() {
  log_warn "$1 reported findings or failed."
  if [[ "$FAIL_ON_FINDINGS" == "true" ]]; then FINDINGS=$((FINDINGS + 1)); fi
}

# ran / skipped <reason>; what this run actually checked. Under preflight
# (PREFLIGHT_SKIP_FILE set), a run in which nothing it was asked for could run
# exits 3 with the first reason, which preflight reports as SKIP: a missing
# pip-audit or a project without a lockfile used to end in "PASS  security scan"
# after checking nothing. A --skip-* flag is not a skip; the caller chose it.
# bandit is not counted: it is static analysis, and "python audit" means the
# dependency audit.
RAN=0
SKIPPED=()
ran() { RAN=$((RAN + 1)); }
skipped() { log_warn "$1"; SKIPPED+=("$1"); }

# bandit reads every .py under the project, and a local virtualenv holds
# thousands that are not the project's. Measured: `bandit -r .` in a project
# with a .venv failed on a finding inside the venv.
BANDIT_EXCLUDE="./.venv,./venv,./node_modules,./build,./dist"

# gitleaks arguments: git mode (tracked content, history) when findings fail the
# run and this is a git work tree; otherwise every file on disk, as before.
gitleaks_args() {
  if [[ "$FAIL_ON_FINDINGS" == "true" ]] && git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' detect --source .
  else
    printf '%s\n' detect --source . --no-git
  fi
}
# node_auditable <dir>; npm audit needs a package.json and a lockfile. Without
# them it errors, which is not a finding about the project: skip, and say why.
node_auditable() {
  if [[ ! -f "$1/package.json" ]]; then
    skipped "No package.json; npm audit did not run."
    return 1
  fi
  if [[ ! -f "$1/package-lock.json" && ! -f "$1/npm-shrinkwrap.json" ]]; then
    skipped "No package-lock.json; npm audit needs one and did not run."
    return 1
  fi
}

# python_target <dir>; sets PY_TARGET to what pip-audit reads there: "req" for a
# requirements file (PYTHON_REQ, or requirements.txt, which it sets), "project"
# for a pyproject.toml, which pip-audit resolves itself (`pip-audit .`), or "".
# safety reads only a requirements file. Called directly, not in $(...): it
# sets PYTHON_REQ, and a subshell would drop that.
python_target() {
  PY_TARGET=""
  if [[ -z "$PYTHON_REQ" && -f "$1/requirements.txt" ]]; then
    PYTHON_REQ="requirements.txt"
  fi
  if [[ -n "$PYTHON_REQ" ]]; then
    PY_TARGET=req
  elif [[ -f "$1/pyproject.toml" ]]; then
    PY_TARGET=project
  fi
}

# run_foxguard; the static-analysis scan, on the host in both modes (there is no
# image of it). Its findings count only where the repository opted in with a
# foxguard config (.foxguard.yml or another of FOXGUARD_CONFIG_NAMES), found
# from the scan directory upward as foxguard finds it;
# elsewhere they are reported and not counted. Measured 2026-09-29: its bash
# taint rules flagged 93 lines of this library, none exploitable (`rm -f "$tmp"`),
# so a gate on by default would fail every shell repository on correct code.
# Submodules are excluded: their findings belong to the vendored project.
run_foxguard() {
  local bin dir top prefix path sub out n config="" rc=0
  local -a args=()
  if ! bin="$(foxguard_bin)"; then
    skipped "foxguard not found; skipping. Install the pinned version: bash $SCRIPT_DIR/ci_security.sh --install-foxguard"
    return 0
  fi
  ran
  if [[ "$("$bin" --version 2>/dev/null)" != "foxguard $CI_DEFAULT_FOXGUARD_VERSION" ]]; then
    log_warn "foxguard: $bin is not the pinned $CI_DEFAULT_FOXGUARD_VERSION, so results may differ; bash $SCRIPT_DIR/ci_security.sh --install-foxguard"
  fi
  dir="$(cd "$WORKDIR" && pwd -P)"
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top="$dir"
  path="$dir"
  while :; do
    config="$(foxguard_config_in "$path")" && break
    [[ "$path" == "$top" || "$path" == "/" ]] && break
    path="$(dirname "$path")"
  done
  prefix="$(git -C "$dir" rev-parse --show-prefix 2>/dev/null || true)"
  if [[ -f "$top/.gitmodules" ]]; then
    # -z: "key<newline>value<NUL>", so a submodule name with a space survives.
    while IFS= read -r -d '' sub; do
      sub="${sub#*$'\n'}"
      case "$sub" in "$prefix"?*) args+=(--exclude "${sub#"$prefix"}") ;; esac
    done < <(git config -z -f "$top/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
  fi
  # --config always: without it foxguard also reads a config above the
  # repository (measured: a .foxguard.yml in the parent directory disabled rules
  # in the repository below it), so one machine's scan could differ from the
  # next. An explicit config resolves its baseline path the same way.
  if [[ -n "$config" ]]; then
    log_info "foxguard: $config found; findings count."
    ( cd "$dir" && "$bin" --config "$config" "${args[@]+"${args[@]}"}" . ) || finding "foxguard"
    return 0
  fi
  # Report only: the count, not the listing or foxguard's per-file notices
  # (these kept for a failed scan).
  out="$(mktemp)"
  printf '{}\n' > "$out.cfg"
  ( cd "$dir" && "$bin" --quiet --format json --output "$out" --config "$out.cfg" "${args[@]+"${args[@]}"}" . ) 2>"$out.err" || rc=$?
  case "$rc" in
    0) log_info "foxguard: no findings." ;;
    1) n="$(grep -o '"total": *[0-9]*' "$out" | tail -1 | grep -o '[0-9]*$' || true)"
       log_warn "foxguard: $n finding(s), reported, not counted: no foxguard config ($FOXGUARD_CONFIG_NAMES) in this repository. See them: (cd $dir && $bin .). A .foxguard.yml that disables noisy rules or sets a baseline makes them count." ;;
    *) cat "$out.err" >&2
       log_warn "foxguard: could not scan (exit $rc); not counted without a foxguard config." ;;
  esac
  rm -f "$out" "$out.err" "$out.cfg"
}

declare -a GITLEAKS_ARGS=()
while IFS= read -r a; do GITLEAKS_ARGS+=("$a"); done < <(gitleaks_args)

if [[ "$USE_DOCKER" == "true" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is required when running in Docker mode (default). Use --no-docker to run on the host instead."
    exit 1
  fi
  ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"
  if [[ "$SKIP_PYTHON" == "false" ]]; then
    python_target "$ABS_WORKDIR"; py_target="$PY_TARGET"
    if [[ -n "$py_target" ]]; then
      if [[ "$py_target" == "req" ]]; then
        py_audit="{ pip-audit -r \"$PYTHON_REQ\" || rc=1; } && { safety check -r \"$PYTHON_REQ\" --full-report || rc=1; }"
      else
        py_audit="{ pip-audit . || rc=1; }"
      fi
      # bash -c, not -lc: see ci_go.sh. A login shell replaces the image's PATH
      # with /etc/profile's default. Measured 2026-09-22 on python:3.12-slim.
      docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$ABS_WORKDIR":/work -w /work "$PY_IMAGE" \
        bash -c "python -m pip install --user --upgrade pip pip-audit safety bandit && export PATH=\"/tmp/.local/bin:\$PATH\" && rc=0 && $py_audit && { bandit -r . -ll -x \"$BANDIT_EXCLUDE\" || rc=1; } && exit \$rc" \
        || finding "python audit (pip-audit / safety / bandit)"
      ran
    else
      skipped "No requirements.txt or pyproject.toml; the Python dependency audit did not run."
    fi
  fi
  if [[ "$SKIP_NODE" == "false" ]] && node_auditable "$ABS_WORKDIR"; then
    # bash -c, not -lc: see ci_go.sh. Measured 2026-09-22 on node:24-bookworm.
    docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -e NPM_CONFIG_CACHE=/tmp/.npm -v "$ABS_WORKDIR":/work -w /work "$NODE_IMAGE" \
      bash -c "$NODE_CMD" || finding "npm audit"
    ran
  fi
  if [[ "$SKIP_GITLEAKS" == "false" ]]; then
    # In git mode the container needs the repository's .git: mount the top of the
    # work tree and run there. Mounting only a subdirectory left git without a
    # repository, and gitleaks printed "no leaks found" after scanning nothing;
    # starting below the top missed its .gitleaks.toml and .gitleaksignore. git
    # in the image refuses a repository owned by another user unless it is
    # marked safe; the environment does that without a file.
    gl_mount="$ABS_WORKDIR"
    if [[ " ${GITLEAKS_ARGS[*]} " != *" --no-git "* ]]; then
      gl_mount="$(git -C "$ABS_WORKDIR" rev-parse --show-toplevel)"
    fi
    docker run --pull=always --rm -t -v "$gl_mount":/work -w /work \
      -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/work \
      "$GITLEAKS_IMAGE" "${GITLEAKS_ARGS[@]}" || finding "gitleaks"
    ran
  fi
else
  pushd "$WORKDIR" >/dev/null
  if [[ "$INSTALL_TOOLS" == "true" ]]; then
    if command -v python >/dev/null 2>&1; then
      python -m pip install --upgrade pip pip-audit safety bandit
    fi
  fi
  if [[ "$SKIP_PYTHON" == "false" ]]; then
    python_target .; py_target="$PY_TARGET"
    if [[ -n "$py_target" ]]; then
      if command -v pip-audit >/dev/null 2>&1; then
        if [[ "$py_target" == "req" ]]; then
          pip-audit -r "$PYTHON_REQ" || finding "pip-audit"
        else
          pip-audit . || finding "pip-audit"
        fi
        ran
      else
        skipped "pip-audit is not installed; the Python dependency audit did not run."
      fi
      if [[ "$py_target" != "req" ]]; then
        log_info "safety reads only a requirements file; not run for pyproject.toml."
      elif command -v safety >/dev/null 2>&1; then
        safety check -r "$PYTHON_REQ" --full-report || finding "safety"
        ran
      else
        log_warn "safety not found; skipping."
      fi
      if command -v bandit >/dev/null 2>&1; then
        bandit -r . -ll -x "$BANDIT_EXCLUDE" || finding "bandit"
      else
        log_warn "bandit not found; skipping."
      fi
    else
      skipped "No requirements.txt or pyproject.toml; the Python dependency audit did not run."
    fi
  fi
  if [[ "$SKIP_NODE" == "false" ]] && node_auditable .; then
    if command -v npm >/dev/null 2>&1; then
      # bash -c, not -lc: a login shell rereads /etc/profile, which on Alpine sets
      # PATH outright, so the npm found above was "not found" in it and counted as
      # a finding (measured in the bash:3.2 image). See ci_go.sh for the image case.
      bash -c "$NODE_CMD" || finding "npm audit"
      ran
    else
      skipped "npm is not installed; npm audit did not run."
    fi
  fi
  if [[ "$SKIP_GITLEAKS" == "false" ]]; then
    if command -v gitleaks >/dev/null 2>&1; then
      # git mode runs from the repository top: the history is the whole
      # repository's anyway, and gitleaks reads .gitleaks.toml and
      # .gitleaksignore from where it runs.
      if [[ " ${GITLEAKS_ARGS[*]} " != *" --no-git "* ]]; then
        ( cd "$(git rev-parse --show-toplevel)" && gitleaks "${GITLEAKS_ARGS[@]}" ) || finding "gitleaks"
      else
        gitleaks "${GITLEAKS_ARGS[@]}" || finding "gitleaks"
      fi
      ran
    else
      skipped "gitleaks is not installed; the secret scan did not run."
    fi
  fi
  popd >/dev/null
fi

if [[ "$SKIP_FOXGUARD" == "false" ]]; then
  run_foxguard
fi

if [[ "$FINDINGS" -gt 0 ]]; then
  log_error "security scan: $FINDINGS check(s) reported findings."
  exit 1
fi
if [[ "$RAN" -eq 0 && ${#SKIPPED[@]} -gt 0 && -n "${PREFLIGHT_SKIP_FILE:-}" ]]; then
  printf '%s\n' "${SKIPPED[0]}" > "$PREFLIGHT_SKIP_FILE"
  exit 3
fi
