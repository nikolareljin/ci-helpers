![script-helpers: reusable Bash and PowerShell helpers. 45 Bash modules, 31 PowerShell mirrors, runs on the bash 3.2 macOS ships.](docs/assets/hero.svg)

Reusable Bash and PowerShell helpers. Source modules you need (docker, logging, dialog, file, json, ports, etc.) and reuse them across scripts.

Shell requirements and macOS
----------------------------

**bash 3.2 or newer.** That is deliberate: macOS ships bash 3.2 as `/bin/bash`
and, for licensing reasons, always will. The library is written to run unchanged
on it - no `mapfile`, no associative arrays, no namerefs - so a Mac needs no
setup to use these helpers.

A newer bash is still better, and `./dev` picks one automatically when the
machine has it (`/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, or whatever is
on `PATH`), falling back to `/bin/bash` when it does not. Sourcing `helpers.sh`
on bash 3.x prints a one-time note on stderr - never stdout, and only to a
terminal - naming the remedy for the host: `brew install bash` on macOS, the
package manager elsewhere. Silence it with `SHLIB_NO_BASH_ADVISORY=1`.

Three functions are the exception and require bash 4.0, because they take an
associative array **from the caller**: `select_distro`,
`select_multiple_distros` and `download_iso`. They fail with an actionable
message rather than returning wrong values.

Two gates keep this true:

```bash
make test-bash32   # the suite under a real bash 3.2, in Docker - needs no Mac
bash tests/portability_test.sh   # static scan for GNU-only and bash-4-only constructs
```

CI runs the suite on macOS under `/bin/bash` for every change touching shell
code. See `docs/usage.md` for the iOS verbs (`./dev deploy ios`) and the
preflight `ios` stack.

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
| `deps.ps1`       | `install_package`, `install_dependencies`, `require_command` - uses `winget` > `choco` > `scoop` |
| `version.ps1`    | `version_bump`, `version_compare` |
| `docker.ps1`     | `get_docker_compose_cmd`, `docker_compose`, `check_docker`, `wait_for_service` |
| `docker_install.ps1` | `install_docker`, `ensure_docker`, `docker_ready`, `docker_install_status`, `docker_report_state`, `docker_start_daemon`, `wait_for_docker_daemon` - installs Docker Desktop via `winget` > `choco` > official installer |
| `ports.ps1`      | `port_in_use`, `list_port_usage_details`, `get_port_conflicts_json` - uses `Get-NetTCPConnection` |
| `json.ps1`       | `json_escape`, `format_json`, `json_get`, `jq_query` |
| `browser.ps1`    | `open_url`, `wait_for_port`, `check_port_open` |
| `traps.ps1`      | `setup_exit_trap`, `cleanup_on_exit`, `enable_strict_mode` |
| `python.ps1`     | `python_resolve_3`, `python_ensure_venv`, `activate_venv`, `python_has_min_version` |
| `clipboard.ps1`  | `copy_to_clipboard`, `get_from_clipboard` |
| `dialog.ps1`     | `dialog_input`, `dialog_yesno`, `dialog_menu`, `dialog_password` - Read-Host based (no ncurses) |
| `help.ps1`       | `display_help`, `print_help`, `show_help`, `get_script_metadata`, `parse_common_args` |
| `certs.ps1`      | `generate_self_signed_cert`, `trust_cert` - Windows Certificate Store |
| `hosts.ps1`      | `add_hosts_entry`, `remove_hosts_entry` - Windows hosts file (requires admin) |
| `ci_defaults.ps1` | Docker image version pins (current stable; see module for divergence note vs Bash `ci_defaults.sh`) |
| `packaging.ps1`  | `pkg_load_metadata`, `pkg_require_vars`, `pkg_trim`, `pkg_join_list`, `pkg_quote_list`, `pkg_render_lines`, `pkg_classify_name`, `pkg_guess_version` + PS helpers: `join_by`, `quote_args`, `load_packaging_metadata`, `get_package_version` |
| `adb.ps1`        | `adb_list_devices`, `adb_install`, `adb_push`, `adb_pull`, `adb_shell`, `adb_logcat` - multi-device safe |
| `serve.ps1`      | `serve_static_site` - local static-site preview; python3 > python > `npx http-server` |
| `svg.ps1`        | `svg_rasterizer`, `svg_rasterize`, `svg_rasterize_sizes` - Inkscape > ImageMagick |
| `rust.ps1`       | `rust_toolchain_ci_uses` - resolve rustup's named Cargo before a native Windows gate runs |
| `gradle.ps1`     | `gradle_available`, `gradle_wrapper`, `gradle_run`, `gradle_lint`, `gradle_test`, `gradle_clean`, `gradle_assemble` |
| `android.ps1`    | `android_sdk_root`, `android_ensure_sdk`, `android_build`, `android_artifact`, `android_sign`, `android_generate_keystore`, `android_avd_list`, `android_avd_create`, `android_emulator_start`, `android_emulator_stop` and the rest of `lib/android.sh` |
| `flutter.ps1`    | `flutter_resolve_sdk`, `flutter_available`, `flutter_pub_get`, `flutter_analyze`, `flutter_format_check`, `flutter_test`, `flutter_build`, `flutter_devices`, `flutter_resolve_device` |
| `screencap.ps1`  | `screencap_available`, `screencap_shot`, `screencap_record`, `screencap_record_stop`, `screencap_frame`, `screencap_gif` |
| `manifest.ps1`   | `manifest_detect`, `manifest_kind`, `manifest_read_version`, `manifest_write_version`, `manifest_sync_version`, `manifest_android_version_code` |
| `changelog.ps1`  | `changelog_check_header`, `changelog_extract`, `changelog_has_entries`, `changelog_new_section` |
| `ollama_install.ps1` | `ollama_install`, `ollama_installed_version`, `ollama_install_asset`, `ollama_install_expected_sha256` - the pinned Windows installer, checked against its SHA-256 |

PowerShell CI scripts (`ps/scripts/`):

```powershell
# Run Node.js CI natively on Windows (no Docker required)
.\ps\scripts\ci_node.ps1 -Workdir frontend -SkipBuild

# Run Python CI natively
.\ps\scripts\ci_python.ps1 -Workdir . -Quick

# Python CI - quick mode also works in Docker
.\ps\scripts\ci_python.ps1 -Workdir . -Quick -UseDocker
.\ps\scripts\ci_python.ps1 -Workdir . -SkipTest -UseDocker

# Go and Rust CI
.\ps\scripts\ci_go.ps1 -Workdir .
.\ps\scripts\ci_rust.ps1 -Workdir . -Quick

# Bump version
.\ps\scripts\bump_version.ps1 minor

# Tag and push release
.\ps\scripts\tag_release.ps1

# Lint, unit-test and assemble a Gradle project (-Android for Android task names)
.\ps\scripts\local_test_gradle.ps1 -Dir android -Quick

# See the logging module's output
.\ps\scripts\example_logging.ps1
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
- Package installation via `deps.ps1` uses `winget` (Windows 11) -> `choco` -> `scoop`, in that order.
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
  
  - The `production` branch is moved to a specific release tag. Rolling it back to an earlier tag is
    supported, but it is not a fast-forward, so it must be asked for explicitly - see below.
  - Source as shown above.

Git hooks
---------

Hooks that stop secrets, private repository names and broken files before they
leave your machine. A push checks only what it sends, usually in seconds; tests
run when you ask (`make test`, `./dev test`), or on push in a repository that
opts in (`git config script-helpers.push-tests quick`).

```bash
bash scripts/script-helpers/scripts/setup-hooks.sh        # in each repository
```

Setup finds your GitHub account through `gh`; without `gh`, or to add
organisations you count as your own:
`git config --global script-helpers.owners <user-or-org>[,<another>]`.

What runs on commit and push, the options and settings:
[docs/git-hooks.md](docs/git-hooks.md).

Bringing a repository onto script-helpers, step by step:
[docs/adopt.md](docs/adopt.md). Every script and its options:
[docs/commands.md](docs/commands.md).
That page is generated from the script headers by
`scripts/gen_command_reference.py`; `--check` exits 1 when it is out of date.

Pinning the production branch
-----------------------------

To manually move `production` to a specific tag:

```bash
scripts/pin_production.sh 0.10.0                  # roll forward
scripts/pin_production.sh 0.9.0 --allow-rewind    # roll back, deliberately
scripts/pin_production.sh 0.10.0 --dry-run        # report, push nothing
```

Moving `production` forward needs no flag. Moving it **backward** - a rollback - is not a
fast-forward, so it needs `--allow-rewind`; without the flag the move is refused rather than
attempted. Other options: `--remote <name>`, `--branch <name>` (`main`, `master` and `HEAD` are refused),
`--repo <path>`. The end state is read back from the remote before the script reports success.

It acts on **the repository you are standing in**, not on the one the script lives in, and prints
which repository and remote it is about to touch. That matters when script-helpers is vendored as a
submodule: running `scripts/script-helpers/scripts/pin_production.sh` from your own repository moves
*your* `production`, not the library's. A refused move exits `3`, distinct from `1` for an error.

Loader and modules
------------------

- `helpers.sh`: resolves library path and provides `shlib_import` to source modules by name.
- Modules live in `lib/*.sh` and are small, dependency-light files:
  - `logging.sh` - color constants and logging helpers (`print_info`, `log_info`, etc.).
  - `dialog.sh`: dialog sizing helpers, `get_value`, and boxes that show even when the caller has captured stdout (`dialog_capture`, `dialog_run`, `dialog_gauge`, `dialog_has_tty`, `has_interactive_dialog_session`), and prompts with dialog, plain and no-terminal renderers (`ui_mode`, `ui_menu`, `ui_input`, `ui_secret`, `ui_yesno`, `ui_note`).
  - `os.sh` - OS detection (`get_os`, `getos`, `is_wsl`) and conditional sudo helper.
  - `deps.sh` - install utilities (`install_dependencies`) where applicable.
  - `docker.sh` - docker compose detection/wrapper (`docker_compose`, `run_docker_compose_command`), status utility (`docker_status`).
  - `file.sh` - file/dir helpers, checksum verification.
  - `json.sh` - json utilities (`json_escape`, `format_response`, `format_md_response`, `json_get_field`).
  - `http.sh` - probe a JSON service and prove an API key without putting it in argv (`http_probe_json`, `http_check_key`).
  - `svg.sh` - rasterize SVG art to PNG (`svg_rasterize <in> <out> [size]`, `svg_rasterize_sizes`) for app logos/launcher icons; prefers Inkscape, falls back to ImageMagick. CLI: `bin/svg-rasterize`.
  - `webshot.sh`: screenshots of web pages from a JSON spec (`webshot_capture <spec> <out_dir>`: login profiles, clicks and fills, element clips, hidden elements) and HTML-to-PDF (`webshot_pdf`), with Playwright in a cached venv (`webshot_ensure`). CLI: `bin/webshot`.
- `env.sh` - `.env` loading, `require_env`, project-root detection.
- `python.sh` - resolve Python 3 executables and ensure local virtualenvs.
- `version.sh` - semantic version helpers (`version_bump`, `version_compare`, `version_offer_update`).
- `hub.sh` - corpus-hub setup for capture clients: local-or-remote dialog with a plain and a no-terminal fallback, probe, key check, `.env` writer, bootstrap through the hub's own scripts, and an offer to run the hub's own `./update` (`hub_setup_dialog`, `hub_probe`, `hub_check_key`, `hub_write_env`, `hub_bootstrap`, `hub_offer_update`, `hub_latest_tag`, `hub_ui_mode`).
- `cloudflare.sh` - deploy to Cloudflare with wrangler: credential and account-id resolution, version and deploy-config derivation, a typed confirmation before a protected environment, and a smoke test that asserts the version now live is the one just deployed (`cloudflare_deploy`, `cloudflare_wrangler`, `cloudflare_credentials_ok`, `cloudflare_account_id`, `cloudflare_version_string`, `cloudflare_deploy_config`, `cloudflare_base_url`, `cloudflare_confirm_environment`, `cloudflare_smoke_test`). Backs `./dev deploy cloudflare`, and shares one deploy definition with CI through `CF_DEPLOY_*`.
- `ports.sh` - port usage/availability helpers.
- `browser.sh` - `open_url`, `open_frontend_when_ready`.
- `traps.sh` - cleanup and signal traps.
- `certs.sh` - self-signed cert creation and trust-store helpers.
- `hosts.sh` - `/etc/hosts` helpers.
- `clipboard.sh` - `copy_to_clipboard`.
- `ollama.sh` - Ollama helpers (`ollama_install_cli`, prepare models index from webfarmer/ollama-get-models, dialog selection, `ollama_pull_model`, `ollama_run_model`) and runtime helpers for local/docker (`ollama_runtime_*`).
- `ollama_endpoint.sh`: for a start script. Which models a project needs, as this machine's class of hardware gets them (`ollama_models_required`, `ollama_model_for_class`, `scripts/ollama_models.sh`), which an Ollama has (`ollama_endpoint_models`), a disk and memory check before anything is pulled (`ollama_budget_check`, `ollama_endpoint_ensure_models`), and whether a container can reach this machine's Ollama (`ollama_endpoint_container_reach`).
- `ollama_install.sh`: install Ollama itself from the pinned release, checked against its SHA-256 (`ollama_install`), instead of piping its installer into a shell.
- `help.sh`: print help from a script's header comments, and common argument parsing.
- `adb.sh`: Android Debug Bridge toolkit: list and inspect devices, install apps, copy files, shell, logcat. CLI: `scripts/adb_tool.sh`.
- `android.sh`: Android SDK resolution, debug and release builds, APK/AAB signing, AVDs and the emulator.
- `gradle.sh`: Gradle wrapper resolution and task invocation; prefers the project's `./gradlew`.
- `flutter.sh`: Flutter SDK resolution, analyze, format, test and build, device listing.
- `ios.sh`: iOS devices and simulators: discover, boot, install, launch, and build Flutter apps or signed IPAs (macOS only).
- `screencap.sh`: screenshots and screen video from a device, emulator or simulator; frame extraction and GIFs with ffmpeg.
- `rust.sh`: which Rust toolchain a gate compiles with (rustup's, not the first `cargo` on `PATH`).
- `manifest.sh`: read and write the project version across pubspec, Gradle, `VERSION`, `package.json` and `pyproject.toml`.
- `changelog.sh`: check, extract and generate the CHANGELOG release headers.
- `packaging.sh`: packaging metadata and template rendering.
- `package_publish.sh`: Debian package builds and PPA upload.
- `git_branches.sh`: whether a branch has landed, including squash and rebase merges. Backs `scripts/prune_branches.sh`.
- `ci_defaults.sh`: pinned image versions for the CI runner scripts.
- `ci_stack.sh`: disposable database containers for a CI run: start, wait until ready, remove.
- `docker_install.sh`: install Docker Engine (Linux) or Docker Desktop (macOS, Windows); `ensure_docker`.
- `foxguard.sh`: find, install and verify the pinned foxguard scanner.
- `gitleaks.sh`: install the pinned gitleaks secret scanner.
- `serve.sh`: serve a static site directory for preview. CLI: `bin/serve-pages`.
- `service.sh`: start, stop, status, logs and readiness for a repository's services, through docker compose or as native processes.
- `docs_site.sh`: build, serve, preview and check a repository's documentation site with MkDocs.

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
    - `[ok]` running (shows "since" time when available)
    - `[failed]` failed (e.g., exited/restarting)
    - `[stopped]` not running
- If no `docker-compose.yml` is found in the current directory, it prints a tip to `cd` into a directory that contains it.
- Requirements: Docker CLI and either `docker compose` (v2) or `docker-compose` (v1).

Example:

```bash
source ./helpers.sh
shlib_import logging docker
docker_status
```

Serving a static site locally
------------------------------

- `serve_static_site <dir> [port]` (from `lib/serve.sh`) starts a static HTTP server rooted at `<dir>`, auto-selecting the first free port at/after `[port]` (default `8000`). Prefers `python3 -m http.server`, falling back to `python` (its `http.server` on Python 3 or `SimpleHTTPServer` on Python 2), then `npx http-server`. Prints the URL and serves until Ctrl-C.
- `bin/serve-pages <dir> [port]` - CLI wrapper, handy for previewing a static/GitHub-Pages build output:

```bash
bin/serve-pages ./site 8000
```

```bash
source ./helpers.sh
shlib_import serve
serve_static_site ./public 8080
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

- `scripts/example_download.sh` - Download a URL with the dialog progress gauge.
- `scripts/example_dialog_input.sh` - Prompt for a value using `dialog`.
- `scripts/example_logging.sh` - Showcase logging helpers (`print_*`, `log_*`).
- `scripts/example_env.sh` - Use env helpers (`get_project_root`, `resolve_env_value`, `require_env`).
- `scripts/example_docker_compose_cmd.sh` - Detect the Docker Compose command.
- `scripts/example_docker_status.sh` - Show Docker/Compose status with [ok]/[failed]/[stopped] markers.
- `scripts/example_json.sh` - JSON helpers demo (`json_escape`, `format_response`).
- `scripts/example_package_publish.sh` - Package publishing helpers demo.

Packaging helpers
-----------------

- `scripts/build_deb_artifacts.sh` - Build Debian packages and emit artifacts.
- `scripts/ppa_upload.sh` - Build and upload a Debian source package to a Launchpad PPA.
- `scripts/signing_secrets.sh` - Set or check the package-signing secrets (GPG, PPA, Apple, Windows .pfx) on a list of GitHub repositories.
- `scripts/build_rpm_artifacts.sh` - Build RPM packages and emit artifacts.
- `scripts/build_brew_tarball.sh` - Build a Homebrew tarball from a repo checkout.
- `scripts/gen_brew_formula.sh` - Generate a Homebrew formula from a tarball.
- `scripts/publish_homebrew.sh` - Publish a formula to a Homebrew tap repository.

Library helpers:
- `lib/package_publish.sh` - Shared helpers for Debian builds and PPA publishing.

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
- `scripts/check_changelog_section.sh` refuses a release whose version has no CHANGELOG section, and
  `scripts/release_notes.sh` turns that section into the release body (falling back to the commits since
  the previous tag).
- GitHub Actions:
  - Auto tag + release (`.github/workflows/auto-tag-release.yml`): on merge of a `release/X.Y.Z` PR into `main`, reuses the shared ci-helpers workflows to detect the version, create the semver tag, and publish the GitHub Release.
  - Production pinning: the same workflow run moves the `production` branch to the new tag commit, by
    calling `scripts/pin_production.sh`. The automated path is forward-only - it never passes
    `--allow-rewind`, so release automation cannot roll `production` back on its own.
  - Release (`.github/workflows/release.yml`): fallback that publishes a GitHub Release when a `*.*.*` tag is pushed manually.


---

## Clone traffic

![Clone traffic](https://raw.githubusercontent.com/nikolareljin/stats/main/charts/script-helpers.svg)

_Updated daily. Total and unique cloners over the last 14 days._
