script-helpers
================

Reusable Bash helpers extracted from projects in this workspace. Source modules you need (docker, logging, dialog, file, json, ports, etc.) and reuse them across scripts.

Windows / PowerShell support
-----------------------------

`ps/helpers.ps1` is a parallel PowerShell companion library that mirrors all core Bash modules. It works natively on Windows without WSL or Git Bash.

Quick start (PowerShell):

```powershell
# Add script-helpers as a submodule or copy it into your project.
# Then in your .ps1 script:
$env:SCRIPT_HELPERS_DIR = "$PSScriptRoot\script-helpers"  # or wherever you placed it
. "$env:SCRIPT_HELPERS_DIR\ps\helpers.ps1"
Import-ScriptHelpers logging env docker version

print_info  "Hello from Windows!"
log_info    "Project root: $(get_project_root)"
load_env    ".env"
require_env "MY_API_KEY"
```

PowerShell modules (mirrors each Bash lib/*.sh):

| Module | Functions |
|--------|-----------|
| `logging.ps1`    | `print_info`, `print_error`, `print_success`, `print_warning`, `log_info`, `log_warn`, `log_error`, `log_debug`, `print_color` |
| `os.ps1`         | `get_os`, `is_wsl`, `is_admin`, `run_with_optional_sudo` |
| `env.ps1`        | `load_env`, `require_env`, `get_project_root`, `resolve_env_value` |
| `file.ps1`       | `file_exists`, `directory_exists`, `create_directory`, `download_file`, `verify_checksum`, `command_exists` |
| `deps.ps1`       | `install_package`, `install_dependencies`, `require_command` — uses `winget` > `choco` > `scoop` |
| `version.ps1`    | `version_bump`, `version_compare` |
| `docker.ps1`     | `get_docker_compose_cmd`, `docker_compose`, `check_docker`, `wait_for_service` |
| `ports.ps1`      | `port_in_use`, `list_port_usage_details`, `get_port_conflicts_json` — uses `Get-NetTCPConnection` |
| `json.ps1`       | `json_escape`, `format_json`, `json_get`, `jq_query` |
| `browser.ps1`    | `open_url`, `wait_for_port`, `check_port_open` |
| `traps.ps1`      | `setup_exit_trap`, `cleanup_on_exit`, `enable_strict_mode` |
| `python.ps1`     | `python_resolve_3`, `python_ensure_venv`, `activate_venv`, `python_has_min_version` |
| `clipboard.ps1`  | `copy_to_clipboard`, `get_from_clipboard` |
| `dialog.ps1`     | `dialog_input`, `dialog_yesno`, `dialog_menu`, `dialog_password` — Read-Host based (no ncurses) |
| `help.ps1`       | `display_help`, `print_help`, `show_help`, `get_script_metadata`, `parse_common_args` |
| `certs.ps1`      | `generate_self_signed_cert`, `trust_cert` — Windows Certificate Store |
| `hosts.ps1`      | `add_hosts_entry`, `remove_hosts_entry` — Windows hosts file (requires admin) |
| `ci_defaults.ps1` | Docker image version pins (current stable; see module for divergence note vs Bash `ci_defaults.sh`) |
| `packaging.ps1`  | `pkg_load_metadata`, `pkg_require_vars`, `pkg_trim`, `pkg_join_list`, `pkg_quote_list`, `pkg_render_lines`, `pkg_classify_name`, `pkg_guess_version` + PS helpers: `join_by`, `quote_args`, `load_packaging_metadata`, `get_package_version` |

PowerShell CI scripts (`ps/scripts/`):

```powershell
# Run Node.js CI natively on Windows (no Docker required)
.\ps\scripts\ci_node.ps1 -Workdir frontend -SkipBuild

# Run Python CI natively
.\ps\scripts\ci_python.ps1 -Workdir . -Quick

# Python CI — quick mode also works in Docker
.\ps\scripts\ci_python.ps1 -Workdir . -Quick -UseDocker
.\ps\scripts\ci_python.ps1 -Workdir . -SkipTest -UseDocker

# Go and Rust CI
.\ps\scripts\ci_go.ps1 -Workdir .
.\ps\scripts\ci_rust.ps1 -Workdir . -Quick

# Bump version
.\ps\scripts\bump_version.ps1 minor

# Tag and push release
.\ps\scripts\tag_release.ps1
```

All CI scripts also accept `-UseDocker` to run inside Docker Desktop (Linux containers) instead of natively.
`-Quick` and `-SkipTest` flags are honoured in both native and Docker modes.
`*Cmd` override parameters (e.g. `-TestCmd`) accept token arrays for commands with spaces or quotes: `-TestCmd "pytest","-k","my test"`.

> **Note:** All `ci_*.ps1` scripts are for **local developer use only**. They exit immediately with an error when `CI=true` is set (as it would be in GitHub Actions or any standard CI environment), preventing accidental execution inside automated pipelines.

Scripts auto-detect `SCRIPT_HELPERS_DIR` from `$PSScriptRoot`; you can override it by setting the env var before invoking the script.

Notes:
- PS 5.1 (Windows built-in) and PS 7+ are both supported. ANSI colour applies to both stdout (`print_*`) and stderr (`log_*`) on PS 7+ and on any terminal advertising ANSI support via `$env:TERM`.
- `certs.ps1` and `hosts.ps1` require administrator elevation.
- `dialog.ps1` uses `Read-Host` prompts instead of the Linux `dialog` ncurses widget.
- `ollama.ps1` is not included; use the Ollama Windows installer directly.
- Package installation via `deps.ps1` uses `winget` (Windows 11) → `choco` → `scoop`, in that order.
- `hosts.ps1` matches domains as complete tokens; `example.com` will not match `myexample.com`.

Quick start
-----------

- Add as a subfolder (recommended for local repo):
  - Copy or symlink `script-helpers` into your project (e.g., `scripts/script-helpers`).
  - Source the loader and import modules in your script:

    ```bash
    #!/usr/bin/env bash
    set -euo pipefail
    SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(dirname "$0")/script-helpers}"
    # Load the loader
    # shellcheck source=/dev/null
    source "$SCRIPT_HELPERS_DIR/helpers.sh"
    # Import only what you need
    shlib_import logging docker dialog file json env ports browser traps certs hosts clipboard
    ```

- Git submodule (once this repo is hosted remotely):
  
  ```bash
  git submodule add -b production git@github.com:nikolareljin/script-helpers.git scripts/script-helpers
  ```
  
  - The `production` branch is fast-forwarded to a specific release tag to enable quick rollback.
  - Source as shown above.

Pinning the production branch
-----------------------------

To manually move `production` to a specific tag:

```bash
scripts/pin_production.sh 0.10.0
```

Loader and modules
------------------

- `helpers.sh`: resolves library path and provides `shlib_import` to source modules by name.
- Modules live in `lib/*.sh` and are small, dependency-light files:
  - `logging.sh` — color constants and logging helpers (`print_info`, `log_info`, etc.).
  - `dialog.sh` — dialog sizing helpers and `get_value`.
  - `os.sh` — OS detection (`get_os`, `getos`, `is_wsl`) and conditional sudo helper.
  - `deps.sh` — install utilities (`install_dependencies`) where applicable.
  - `docker.sh` — docker compose detection/wrapper (`docker_compose`, `run_docker_compose_command`), status utility (`docker_status`).
  - `file.sh` — file/dir helpers, checksum verification.
  - `json.sh` — json utilities (`json_escape`, `format_response`, `format_md_response`).
- `env.sh` — `.env` loading, `require_env`, project-root detection.
- `python.sh` — resolve Python 3 executables and ensure local virtualenvs.
- `version.sh` — semantic version helpers (`version_bump`, `version_compare`).
- `ports.sh` — port usage/availability helpers.
- `browser.sh` — `open_url`, `open_frontend_when_ready`.
- `traps.sh` — cleanup and signal traps.
- `certs.sh` — self-signed cert creation and trust-store helpers.
- `hosts.sh` — `/etc/hosts` helpers.
- `clipboard.sh` — `copy_to_clipboard`.
- `ollama.sh` — Ollama helpers (`ollama_install_cli`, prepare models index from webfarmer/ollama-get-models, dialog selection, `ollama_pull_model`, `ollama_run_model`) and runtime helpers for local/docker (`ollama_runtime_*`).

Notes for Ollama model indexing:
- Requires Python 3 (`python3` preferred; falls back to `python` if it is 3.x).
- Installs `beautifulsoup4`/`requests` via `apt` when available; otherwise uses `pip` (requires `python3-pip`).

Download dialog gauge
---------------------

- `dialog_download_file URL [output_path] [tool]`
  - Shows a real-time `dialog` gauge with percent, downloaded vs total size, speed, and ETA.
  - `tool` can be `auto` (default), `curl`, or `wget`.
  - On errors, displays a `dialog` error message with the exit code and the last lines from the underlying tool (curl/wget) describing the cause.
  - Example:

    ```bash
    source ./helpers.sh
    shlib_import dialog logging
    dialog_download_file "https://example.com/big.iso" "/tmp/big.iso" auto
    ```

Notes:
- Requires `dialog` to be installed. Uses `curl` (preferred) or `wget` for downloading.
- If server does not provide Content-Length, the gauge will show downloaded bytes and speed with a rolling progress bar and no ETA.

Compatibility notes
-------------------

- Function names from existing projects are preserved where possible. Where multiple variants existed, this library accepts both styles (e.g., `print_color` accepts either ANSI code constants or color names like `red`, `green`).
- Some functions (e.g., `download_iso`) expect data like `DISTROS` associative array to be supplied by the caller project.
- `install_dependencies` may run `sudo` and perform network installs; use cautiously in CI or locked-down environments.

Example usage
-------------

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$SCRIPT_DIR/script-helpers}"
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging docker env file json

print_info "Project root: $(get_project_root)"
compose_cmd=$(get_docker_compose_cmd)
log_info "Compose cmd: $compose_cmd"

# Show running containers and compose services status (if docker-compose.yml exists)
docker_status
```

CI helper scripts
-----------------

Use these to run common CI steps locally (Docker by default; pass `--no-docker` to run on the host):

```bash
./scripts/ci_node.sh --workdir frontend
./scripts/ci_python.sh --workdir backend --requirements requirements.txt --test-cmd "pytest -q"
./scripts/ci_flutter.sh --workdir . --skip-test --build-cmd "flutter build appbundle --release"
./scripts/ci_gradle.sh --workdir . --skip-detekt
./scripts/ci_go.sh --workdir scanner
./scripts/ci_security.sh --workdir backend --python-req requirements.txt
```

Docker status utility
---------------------

- `docker_status` prints:
  - A table of running containers from `docker ps` (name, image, status, since, ports).
  - If a `docker-compose.yml` exists in the current directory, it checks each defined service and marks:
    - `✅` running (shows "since" time when available)
    - `💥` failed (e.g., exited/restarting)
    - `✖️` not running
- If no `docker-compose.yml` is found in the current directory, it prints a tip to `cd` into a directory that contains it.
- Requirements: Docker CLI and either `docker compose` (v2) or `docker-compose` (v1).

Example:

```bash
source ./helpers.sh
shlib_import logging docker
docker_status
```

Testing locally
---------------

- Source `helpers.sh` from a shell and import modules to try functions interactively:

```bash
source ./helpers.sh
shlib_import logging json
print_success "It works!"
```

Conventions
-----------

Download behavior
-----------------

- `file.sh::download_file URL [output]`
  - Automatically uses the dialog gauge (`dialog_download_file`) when `dialog` is installed.
  - Control via env var `DOWNLOAD_USE_DIALOG`:
    - `auto` (default): use dialog if available.
    - `true`/`1`: force dialog if available, otherwise fallback.
    - `false`/`0`/`never`: disable dialog and use plain `curl`/`wget`.
  - `DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG=0` suppresses dialog popup errors while preserving non-zero exit codes.
  - Falls back to plain `curl` or `wget` with no interactive gauge if dialog is unavailable or fails. When a dialog download fails, an error message is shown with details before falling back.

Examples
--------

- `scripts/example_download.sh` — Download a URL with the dialog progress gauge.
- `scripts/example_dialog_input.sh` — Prompt for a value using `dialog`.
- `scripts/example_logging.sh` — Showcase logging helpers (`print_*`, `log_*`).
- `scripts/example_env.sh` — Use env helpers (`get_project_root`, `resolve_env_value`, `require_env`).
- `scripts/example_docker_compose_cmd.sh` — Detect the Docker Compose command.
- `scripts/example_docker_status.sh` — Show Docker/Compose status with glyphs.
- `scripts/example_json.sh` — JSON helpers demo (`json_escape`, `format_response`).
- `scripts/example_package_publish.sh` — Package publishing helpers demo.

Packaging helpers
-----------------

- `scripts/build_deb_artifacts.sh` — Build Debian packages and emit artifacts.
- `scripts/ppa_upload.sh` — Build and upload a Debian source package to a Launchpad PPA.
- `scripts/build_rpm_artifacts.sh` — Build RPM packages and emit artifacts.
- `scripts/build_brew_tarball.sh` — Build a Homebrew tarball from a repo checkout.
- `scripts/gen_brew_formula.sh` — Generate a Homebrew formula from a tarball.
- `scripts/publish_homebrew.sh` — Publish a formula to a Homebrew tap repository.

Library helpers:
- `lib/package_publish.sh` — Shared helpers for Debian builds and PPA publishing.

Run examples with Makefile
--------------------------

- `make examples` runs safe, non-interactive demos.
- Opt-in flags:
  - `RUN_INTERACTIVE=1` to include `dialog` input demo.
  - `RUN_NETWORK=1` to include the download demo.
  
Example:

```bash
make examples RUN_INTERACTIVE=1 RUN_NETWORK=1
```

- Shell: POSIX-friendly where possible; scripts should set `set -euo pipefail` in the caller.
- Filenames are `snake_case`. Functions are preserved from original includes for compatibility.

Versioning and releases
-----------------------

- `VERSION` file holds the current semantic version.
- Tags use plain semver (`X.Y.Z`) without a `v` prefix. Use `scripts/tag_release.sh` to create and push an annotated tag for the current commit.
- Use `scripts/bump_version.sh` or `version_bump` (from `lib/version.sh`) to increment the version file.
- GitHub Actions:
  - Auto-tag (`.github/workflows/auto-tag.yml`): manually triggered via `workflow_dispatch` to bump `VERSION` from conventional commits and create a semver tag.
  - Production pinning: when a semver tag is created by release automation from `main`, the same workflow run fast-forwards `production` to that tag commit.
  - Release: publishes a GitHub Release when a `*.*.*` tag is pushed.


---

## Clone traffic

![Clone traffic](https://raw.githubusercontent.com/nikolareljin/stats/main/charts/script-helpers.svg)

_Updated daily. Total and unique cloners over the last 14 days._
