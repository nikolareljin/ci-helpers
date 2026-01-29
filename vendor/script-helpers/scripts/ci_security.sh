#!/usr/bin/env bash
# SCRIPT: ci_security.sh
# DESCRIPTION: Run basic security checks (pip-audit/safety/bandit, npm audit, gitleaks).
# USAGE: scripts/ci_security.sh [--workdir <path>] [--install] [--skip-python] [--skip-node] [--skip-gitleaks]
# PARAMETERS:
#   --workdir <path>       Working directory (default: current dir).
#   --install              Install required tools into current environment.
#   --skip-python          Skip Python dependency checks.
#   --skip-node            Skip Node.js audit.
#   --skip-gitleaks        Skip gitleaks scan.
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
#   -h, --help             Show this help message.
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
shlib_import help logging ci_defaults

WORKDIR="."
INSTALL_TOOLS=false
SKIP_PYTHON=false
SKIP_NODE=false
SKIP_GITLEAKS=false
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

if [[ "$USE_DOCKER" == "true" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is required when running in Docker mode (default). Use --no-docker to run on the host instead."
    exit 1
  fi
  ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"
  if [[ "$SKIP_PYTHON" == "false" ]]; then
    if [[ -z "$PYTHON_REQ" && -f "$ABS_WORKDIR/requirements.txt" ]]; then
      PYTHON_REQ="requirements.txt"
    fi
    if [[ -n "$PYTHON_REQ" ]]; then
      docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$ABS_WORKDIR":/work -w /work "$PY_IMAGE" \
        bash -lc "python -m pip install --user --upgrade pip pip-audit safety bandit && export PATH=\"/tmp/.local/bin:\$PATH\" && pip-audit -r \"$PYTHON_REQ\" || true && safety check -r \"$PYTHON_REQ\" --full-report || true && bandit -r . -ll || true"
    else
      log_warn "No requirements file found; skipping python audit."
    fi
  fi
  if [[ "$SKIP_NODE" == "false" ]]; then
    docker run --pull=always --rm -t -u "$(id -u):$(id -g)" -e NPM_CONFIG_CACHE=/tmp/.npm -v "$ABS_WORKDIR":/work -w /work "$NODE_IMAGE" \
      bash -lc "$NODE_CMD" || true
  fi
  if [[ "$SKIP_GITLEAKS" == "false" ]]; then
    docker run --pull=always --rm -t -v "$ABS_WORKDIR":/work -w /work "$GITLEAKS_IMAGE" \
      detect --source . --no-git || true
  fi
else
  pushd "$WORKDIR" >/dev/null
  if [[ "$INSTALL_TOOLS" == "true" ]]; then
    if command -v python >/dev/null 2>&1; then
      python -m pip install --upgrade pip pip-audit safety bandit
    fi
  fi
  if [[ "$SKIP_PYTHON" == "false" ]]; then
    if [[ -z "$PYTHON_REQ" && -f "requirements.txt" ]]; then
      PYTHON_REQ="requirements.txt"
    fi
    if [[ -n "$PYTHON_REQ" ]]; then
      if command -v pip-audit >/dev/null 2>&1; then
        pip-audit -r "$PYTHON_REQ" || true
      else
        log_warn "pip-audit not found; skipping."
      fi
      if command -v safety >/dev/null 2>&1; then
        safety check -r "$PYTHON_REQ" --full-report || true
      else
        log_warn "safety not found; skipping."
      fi
      if command -v bandit >/dev/null 2>&1; then
        bandit -r . -ll || true
      else
        log_warn "bandit not found; skipping."
      fi
    fi
  fi
  if [[ "$SKIP_NODE" == "false" ]]; then
    if command -v npm >/dev/null 2>&1; then
      bash -lc "$NODE_CMD" || true
    else
      log_warn "npm not found; skipping."
    fi
  fi
  if [[ "$SKIP_GITLEAKS" == "false" ]]; then
    if command -v gitleaks >/dev/null 2>&1; then
      gitleaks detect --source . --no-git || true
    else
      log_warn "gitleaks not found; skipping."
    fi
  fi
  popd >/dev/null
fi
