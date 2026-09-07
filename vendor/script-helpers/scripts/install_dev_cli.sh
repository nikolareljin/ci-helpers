#!/usr/bin/env bash
# SCRIPT: install_dev_cli.sh
# DESCRIPTION: Install the shared ./dev entry point into a consumer repository.
# USAGE: bash scripts/install_dev_cli.sh [--repo <path>] [--shims <list>] [--force] [--dry-run]
#
# PARAMETERS:
#   --repo <path>   Target repository (default: current directory).
#   --shims <list>  Comma-separated root scripts to replace with thin shims,
#                   e.g. "build,test,update,start". Each becomes
#                   `exec bash scripts/cli.sh <verb> "$@"`. Existing files are
#                   backed up to <name>.pre-dev-cli unless --force is given.
#   --no-hooks      Do not wire the pre-push hook.
#   --force         Overwrite scripts/cli.sh and _bootstrap.sh if they differ.
#   --dry-run       Print what would change and exit.
#   -h, --help      Show this help message.
#
# EXIT_CODES:
#   0  Installed, or already up to date.
#   1  The target is not a git repository, or a file could not be written.
#   2  Bad arguments.
#
# EXAMPLE:
#   bash scripts/install_dev_cli.sh --repo ../my-project --shims build,test,update
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import help logging

TEMPLATE_DIR="$SCRIPT_HELPERS_DIR/templates/dev-cli"
REPO="."
SHIMS=""
FORCE=false
DRY_RUN=false
WIRE_HOOKS=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --shims) SHIMS="${2:-}"; shift 2 ;;
    --no-hooks) WIRE_HOOKS=false; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$TEMPLATE_DIR" ]] || { log_error "template not found: $TEMPLATE_DIR"; exit 1; }
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { log_error "no such directory"; exit 1; }
git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || {
  log_error "not a git repository: $REPO"
  exit 1
}

say() { if [[ "$DRY_RUN" == "true" ]]; then echo "[dry-run] $*"; else log_info "$*"; fi; }

install_file() {
  local src="$1" dest="$2" mode="${3:-644}"
  local rel="${dest#"$REPO"/}"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    say "unchanged: $rel"
    return 0
  fi
  if [[ -f "$dest" && "$FORCE" == "false" ]]; then
    log_warn "exists and differs: $rel (use --force to overwrite)"
    return 0
  fi
  say "write: $rel"
  [[ "$DRY_RUN" == "true" ]] && return 0
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  chmod "$mode" "$dest"
}

# --- the entry point -------------------------------------------------------

install_file "$TEMPLATE_DIR/_bootstrap.sh" "$REPO/scripts/_bootstrap.sh" 644
install_file "$TEMPLATE_DIR/cli.sh"        "$REPO/scripts/cli.sh"        755
install_file "$TEMPLATE_DIR/dev"           "$REPO/dev"                   755

# project.sh is the repo's own file: seed the example, never overwrite the real one.
if [[ ! -f "$REPO/scripts/project.sh" ]]; then
  install_file "$TEMPLATE_DIR/project.sh.example" "$REPO/scripts/project.sh.example" 644
fi

# PowerShell counterparts, so the same verb works in pwsh and Windows PowerShell.
[[ -f "$TEMPLATE_DIR/cli.ps1" ]] && install_file "$TEMPLATE_DIR/cli.ps1" "$REPO/scripts/cli.ps1" 644
[[ -f "$TEMPLATE_DIR/_bootstrap.ps1" ]] && install_file "$TEMPLATE_DIR/_bootstrap.ps1" "$REPO/scripts/_bootstrap.ps1" 644
[[ -f "$TEMPLATE_DIR/dev.ps1" ]] && install_file "$TEMPLATE_DIR/dev.ps1" "$REPO/dev.ps1" 644

# --- compatibility shims ---------------------------------------------------
#
# Old root scripts stay for one minor version so nothing in muscle memory, a
# systemd unit or a README breaks the day this lands.

if [[ -n "$SHIMS" ]]; then
  IFS=',' read -r -a shim_list <<< "$SHIMS"
  for name in "${shim_list[@]}"; do
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    [[ -n "$name" ]] || continue
    dest="$REPO/$name"
    if [[ -e "$dest" && "$FORCE" == "false" ]]; then
      say "back up: $name -> $name.pre-dev-cli"
      [[ "$DRY_RUN" == "true" ]] || mv "$dest" "$dest.pre-dev-cli"
    fi
    say "shim: ./$name -> ./dev $name"
    [[ "$DRY_RUN" == "true" ]] && continue
    cat > "$dest" <<EOF
#!/usr/bin/env bash
# Compatibility shim. Use ./dev $name — this is removed one minor version on.
exec bash "\$(dirname "\$0")/scripts/cli.sh" $name "\$@"
EOF
    chmod 755 "$dest"
  done
fi

# --- the gate --------------------------------------------------------------

if [[ "$WIRE_HOOKS" == "true" ]]; then
  say "wire: core.hooksPath -> the shared pre-commit/pre-push hooks"
  if [[ "$DRY_RUN" == "false" ]]; then
    ( cd "$REPO" && bash "$SCRIPT_HELPERS_DIR/scripts/setup-hooks.sh" ) || \
      log_warn "setup-hooks.sh failed — wire it by hand before relying on the local gate"
  fi
fi

echo
if [[ "$DRY_RUN" == "true" ]]; then
  log_info "dry run — nothing written."
  exit 0
fi

log_info "Installed. Next:"
echo "  cd $REPO"
echo "  ./dev            # the verb list"
echo "  ./dev preflight  # what the deleted CI jobs used to run"
echo
echo "If autodetection picks up directories your CI never built, pin them with a"
echo ".preflight file at the repo root: one '<stack> <dir>' per line."
