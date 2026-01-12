# Usage

In your script
--------------

```bash
#!/usr/bin/env bash
set -euo pipefail

# Adjust the path to where you vendored this repo
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(dirname "$0")/script-helpers}"

# 1) Load the loader
source "$SCRIPT_HELPERS_DIR/helpers.sh"

# 2) Import the modules you need
shlib_import logging docker dialog file json env ports browser traps certs hosts clipboard ollama os

# 3) Call functions
print_info "Project root: $(get_project_root)"
docker_status
```

Version bumping and comparison
```bash
shlib_import logging env version

# Bump patch version in VERSION at the project root (or pass -f to override)
version_bump patch

# Compare semantic versions (ignores leading v/V and suffixes)
version_compare "v1.10.0-rc1" "1.9.9"
case $? in
  0) echo "Same version";;
  1) echo "Left is newer";;
  255) echo "Left is older";; # 255 represents -1 from version_compare
  2) echo "Missing args";;
  3) echo "Invalid input";;
esac
```

Import patterns
---------------

- `shlib_import name [name ...]` sources the given modules from `lib/*.sh`.
- Logging is auto-imported first if not explicitly requested to ensure logs are available.
- `shlib_import_all` is available when you want everything (handy for interactive sessions).

Environment variables
---------------------

- `SCRIPT_HELPERS_DIR` — absolute or relative path to this repository. The loader auto-detects; set explicitly when needed.
- `DEBUG=true` — enables `log_debug` output in logging.
- `DOWNLOAD_USE_DIALOG` — download UI preference for `file::download_file`:
  - `auto` (default): use dialog gauge if `dialog` is installed.
  - `true`/`1`: force dialog if available.
  - `false`/`0`/`never`: disable dialog UI.
- `PORT_DETECTION_ALLOW_SUDO` — allow sudo when probing ports (`ports` module). Default: `false`.
- `FRONTEND_HOST`, `FRONTEND_PORT` — host/port for `browser::open_frontend_when_ready`.

Using as a library in other projects
------------------------------------

- Vendor this folder under `scripts/script-helpers` or similar.
- Source `helpers.sh` from your scripts and import the modules you need.
- Keep examples in `scripts/` handy for quick reference; you can copy/paste and adapt.

Shared include and dependency check
-----------------------------------

Recommended layout in the consuming repo (supports direct calls and symlinks):
```text
./
  scripts/
    include.sh
    update.sh
    script-helpers/    # git submodule
    build.sh
  update -> scripts/update.sh
  build -> scripts/build.sh
```

How to create scripts/include.sh
--------------------------------

1) Create `scripts/include.sh` with the loader below.
2) Source it from every script: `source "$SCRIPT_DIR/include.sh"`.
3) Call `require_script_helpers <modules...>` at the top of each script.

scripts/include.sh (loader for all scripts):
```bash
#!/usr/bin/env bash
set -euo pipefail

INCLUDE_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$INCLUDE_SOURCE" ]; do
  INCLUDE_DIR="$(cd "$(dirname "$INCLUDE_SOURCE")" && pwd)"
  INCLUDE_SOURCE="$(readlink "$INCLUDE_SOURCE")"
  if [[ "$INCLUDE_SOURCE" != /* ]]; then
    INCLUDE_SOURCE="$INCLUDE_DIR/$INCLUDE_SOURCE"
  fi
done

SCRIPT_DIR="$(cd "$(dirname "$INCLUDE_SOURCE")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$ROOT_DIR/scripts/script-helpers}"
HELPERS_PATH="$SCRIPT_HELPERS_DIR/helpers.sh"

script_helpers_hint() {
  printf "ERROR: script-helpers dependency not found.\n" >&2
  printf "Run: git submodule update --init --recursive\n" >&2
  printf "Or:  git clone <repo-url> scripts/script-helpers\n" >&2
  printf "Or:  ./update\n" >&2
}

load_script_helpers() {
  # Shared loader so both call sites stay in sync.
  if [[ ! -f "$HELPERS_PATH" ]]; then
    script_helpers_hint
    return 1
  fi
  # shellcheck source=/dev/null
  source "$HELPERS_PATH"
  if [[ "$#" -gt 0 ]]; then
    shlib_import "$@"
  fi
}

require_script_helpers() {
  # Fail fast with a friendly prompt instead of sourcing a missing file.
  load_script_helpers "$@" || return 1
}

load_script_helpers_if_available() {
  # Soft guard; prints a hint but returns success when missing.
  if [[ ! -f "$HELPERS_PATH" ]]; then
    script_helpers_hint
    return 0
  fi
  load_script_helpers "$@"
}
```

If `script-helpers` is missing, the loader prevents a hard error and tells the user to install it or run `./update`.
Use `require_script_helpers` for scripts that must stop when helpers are missing, and `load_script_helpers_if_available`
for bootstrap scripts that should continue (like `./update`).

scripts/build.sh (safe source for direct call or symlink):
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  if [[ "$SCRIPT_SOURCE" != /* ]]; then
    SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
  fi
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/include.sh"
require_script_helpers logging help

print_info "script-helpers is available"
```

scripts/update.sh (submodule bootstrap):
```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/include.sh"
load_script_helpers_if_available help

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is not installed."
  exit 1
fi

cd "$ROOT_DIR"
git submodule sync --recursive
git submodule update --init --recursive --remote
```

Create root symlinks:
```bash
ln -s ./scripts/update.sh ./update
ln -s ./scripts/build.sh ./build
```

Common snippets
---------------

Minimal logging
```bash
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging
print_success "It works!"
```

Load .env and require variables
```bash
shlib_import logging env
load_env .env
require_env DATABASE_URL SECRET_KEY
```

Download with a progress gauge
```bash
shlib_import dialog file logging
dialog_download_file "https://example.com/file.iso" "/tmp/file.iso" auto
# or via file::download_file which uses the gauge automatically when available
download_file "https://example.com/file.iso" "/tmp/file.iso"
```

Docker compose detection and status
```bash
shlib_import logging docker
compose_cmd=$(get_docker_compose_cmd)
log_info "Compose: $compose_cmd"
docker_status
```

Packaging scaffolding and builds
--------------------------------

Generate packaging files (debian/, RPM spec, PKGBUILD, Homebrew formula):

```bash
./vendor/script-helpers/scripts/packaging_init.sh --repo .
```

Build packages (expects packaging files to exist):

```bash
./vendor/script-helpers/scripts/build_deb_artifacts.sh --repo .
./vendor/script-helpers/scripts/build_rpm_artifacts.sh --repo .
./vendor/script-helpers/scripts/build_arch_artifacts.sh --repo .
```

Render a Homebrew formula with a release tarball SHA:

```bash
./vendor/script-helpers/scripts/render_brew_formula.sh --repo . --url <tarball_url> --sha256 <sha256>
```
