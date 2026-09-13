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

# A destination this installer is about to write must be a regular file or
# absent. A symlink -- dangling or live -- would be written through to wherever
# it points (-f and -e are both false for a dangling one, so the write reaches
# cp and cp follows it); a directory would be replaced by a file. Used once
# over every managed destination before the first write, and again at each
# write for the window in between.
refuse_bad_dest() {
  local dest="$1" rel="${1#"$REPO"/}"
  # Parents first. Checking only the final component leaves the path itself
  # unexamined: with `scripts` a symlink to somewhere outside,
  # $REPO/scripts/cli.sh is neither a symlink nor a directory, so the check
  # passed and the mkdir -p and cp below followed the parent link out of the
  # repository. Walk what this installer would create or traverse.
  local rest="$rel" part probe="$REPO"
  while [[ "$rest" == */* ]]; do
    part="${rest%%/*}"; rest="${rest#*/}"; probe="$probe/$part"
    if [[ -L "$probe" ]]; then
      log_error "${probe#"$REPO"/} is a symlink ($(readlink "$probe")); refusing to write beneath it"
      exit 2
    fi
  done
  if [[ -L "$dest" ]]; then
    log_error "$rel is a symlink ($(readlink "$dest")); refusing to write through it"
    exit 2
  fi
  if [[ -d "$dest" ]]; then
    log_error "$rel is a directory; refusing to replace it with a file"
    exit 2
  fi
}

install_file() {
  local src="$1" dest="$2" mode="${3:-644}"
  local rel="${dest#"$REPO"/}"
  refuse_bad_dest "$dest"
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
  mkdir -p -- "$(dirname "$dest")"
  cp -- "$src" "$dest"
  chmod -- "$mode" "$dest"
}

# --- refuse bad input before the first write --------------------------------
#
# Everything below writes files. Every destination -- the entry point's own
# files and the --shims list -- is checked here, in full, so a rejected
# invocation leaves the repository exactly as it found it: validating the shim
# list after the entry point had been installed meant exit 2 could still have
# rewritten dev, scripts/cli.sh and scripts/_bootstrap.sh on the way out, and a
# dangling symlink at one of those core paths was never checked at all.
for core in dev dev.ps1 scripts/_bootstrap.sh scripts/cli.sh scripts/cli.ps1 scripts/_bootstrap.ps1 scripts/project.sh.example; do
  refuse_bad_dest "$REPO/$core"
done
shim_list=()
if [[ -n "$SHIMS" ]]; then
  IFS=',' read -r -a shim_list <<< "$SHIMS"
  # Two things are refused. A name with a path
  # separator, or `.`/`..`, would write outside the repository root or over a
  # directory. And `dev` -- the entry point every shim delegates to -- would be
  # moved to dev.pre-dev-cli and replaced by a shim that runs `./dev dev`, which
  # is itself: an exec loop, with the real entry point already moved aside.
  # The same goes for the files this installer itself writes.
  for name in "${shim_list[@]}"; do
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    [[ -n "$name" ]] || continue
    case "$name" in
      dev|dev.ps1|scripts|*/*|.|..)
        log_error "--shims: '$name' cannot be a shim -- it is the entry point the shims delegate to, or a path"
        exit 2 ;;
    esac
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
      log_error "--shims: '$name' is not a plain file name (letters, digits, . _ - only)"
      exit 2
    }
    # *.pre-dev-cli is where this installer keeps the caller's original. A shim
    # by that name would move the real backup to x.pre-dev-cli.pre-dev-cli and
    # put a generated file where the restore path expects the original.
    case "$name" in *.pre-dev-cli)
      log_error "--shims: '$name' uses the backup suffix this installer reserves"
      exit 2 ;;
    esac
    # What is at the destination matters as much as the name. A directory --
    # .git, scripts, docs -- would be moved aside and replaced by a file; a
    # symlink, dangling or live, would be written through to wherever it
    # points. Both are checked here, before any write, so a bad entry anywhere
    # in the list leaves the repository untouched; the per-shim check below
    # remains for the window between this pass and the write.
    refuse_bad_dest "$REPO/$name"
  done
fi

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
  for name in "${shim_list[@]}"; do
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    [[ -n "$name" ]] || continue
    dest="$REPO/$name"
    refuse_bad_dest "$dest"
    if [[ -e "$dest" && "$FORCE" == "false" ]]; then
      # On a re-run $dest is the shim written last time. Moving that over an
      # existing backup would replace the caller's original script with our
      # own generated one -- the only copy of it, gone. Keep the first backup.
      if [[ -e "$dest.pre-dev-cli" ]]; then
        # Only a shim we wrote is safe to discard. If $dest is anything else
        # the backup slot that would have saved it is already occupied, so
        # there is no move that does not lose a file: leave both untouched.
        if grep -q '^# Compatibility shim\. Use \./dev ' "$dest" 2>/dev/null; then
          say "keep backup: $name.pre-dev-cli already exists"
          [[ "$DRY_RUN" == "true" ]] || rm -f -- "$dest"
        else
          log_warn "skip $name: $name.pre-dev-cli exists and ./$name is not a shim we wrote"
          continue
        fi
      else
        say "back up: $name -> $name.pre-dev-cli"
        [[ "$DRY_RUN" == "true" ]] || mv -- "$dest" "$dest.pre-dev-cli"
      fi
    fi
    say "shim: ./$name -> ./dev $name"
    [[ "$DRY_RUN" == "true" ]] && continue
    # Delegates to ./dev rather than re-running scripts/cli.sh directly: ./dev
    # is what picks a usable bash, and duplicating that resolver into every
    # consumer repo is how it would drift out of step with this library.
    cat > "$dest" <<EOF
#!/usr/bin/env bash
# Compatibility shim. Use ./dev $name — this is removed one minor version on.
exec "\$(dirname "\$0")/dev" "$name" "\$@"
EOF
    chmod -- 755 "$dest"
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
