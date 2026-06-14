Changelog

This project uses Keep a Changelog style and aims to follow Semantic Versioning for tagged releases.

## [Unreleased]

- Added: CI helper scripts for Node, Python, Flutter, Gradle, Go, and basic security checks.
- Added: `scripts/pin_production.sh` to fast-forward the production branch to a release tag.
- Added: `scripts/check_release_version.sh` to verify release versions before tagging or publishing.
- Added: `--version` and `--image` parameters to all `ci_*.sh` scripts for Docker image tag and full image override.

## [0.14.0] - 2026-06-12

- Fixed: `ps/helpers.ps1` — `Import-ScriptHelpers` now always loads `logging` first unconditionally; previously it skipped the pre-load when `logging` appeared anywhere in the caller's list, leaving other modules without logging if they were listed before it.
- Fixed: `ps/lib/help.ps1` — `get_script_metadata` and `_Help_Render` now guard against empty/null `$ScriptFile` (interactive use with no `SHLIB_CALLER_SCRIPT`) instead of throwing on `Test-Path` and `Path::GetFileName(null)`.
- Fixed: `ps/lib/traps.ps1` — `enable_strict_mode` uses `Set-Variable -Scope 1` to write `ErrorActionPreference` into the immediate caller's scope rather than `$Global:`, so it no longer leaks strict mode into the wider PowerShell session.
- Fixed: `ps/scripts/ci_go.ps1`, `ci_node.ps1`, `ci_python.ps1`, `ci_rust.ps1` — `-UseDocker` mode now calls `check_docker` before invoking Docker; previously a missing/stopped Docker daemon produced a generic "command not found" error instead of the structured diagnostic from the helper.
- Fixed: `ps/lib/traps.ps1` — `setup_exit_trap` now unregisters and re-registers by `SourceIdentifier` instead of storing the `PSEventJob.Id` as a subscription ID; `PSEventJob.Id` is the job ID, not the subscription ID expected by `Unregister-Event -SubscriptionId`, so the previous code could leave duplicate exit handlers on repeated calls.
- Fixed: `ps/lib/logging.ps1` — stderr path in `_Shlib_WriteColor` now guards ANSI codes with `[Console]::IsErrorRedirected`; previously `2>file` or `2>&1` captured raw escape codes even though the stdout path was already guarded.
- Fixed: `ps/lib/logging.ps1` — `_Shlib_WriteColor` now checks `[Console]::IsOutputRedirected` before the ANSI flag; previously the redirect branch was unreachable when ANSI was enabled, so redirected streams (files, pipelines) received raw escape codes instead of plain text.
- Fixed: `ps/lib/traps.ps1` — `setup_exit_trap` now passes the handler via `-MessageData` and reads it as `$event.MessageData` inside the action block; the previous approach stored the handler in a `$script:` variable that is invisible in the separate runspace used by event actions.
- Fixed: `ps/lib/env.ps1` — `resolve_env_value` now mirrors the Bash API: takes a variable *name* and an optional default, returning the env var's value or the default when unset/empty. The internal `$VAR`/`${VAR}` expansion logic used by `load_env` is extracted into `expand_env_refs`.
- Fixed: `ps/lib/version.ps1` — `version_bump` now throws explicitly when `BumpType` is empty and creates the parent directory of `VersionFile` when it does not exist.
- Fixed: `ps/lib/os.ps1` — `run_with_optional_sudo` now throws on an empty `$Cmd`, and uses splatting (`@rest`) to forward arguments so the call works correctly for both native executables and PowerShell functions.
- Fixed: `ps/lib/env.ps1` — `load_env` now uses `foreach`/`continue` instead of `ForEach-Object`/`return`; the old form exited the function on the first blank line or comment instead of skipping only that line.
- Fixed: `ps/lib/packaging.ps1` — `pkg_load_metadata` same fix: `ForEach-Object { return }` was exiting the function early on blank/comment lines.
- Fixed: `ps/lib/docker.ps1` — `check_docker` normalises each element of `docker info 2>&1` output to a string before joining, so ErrorRecord objects in mixed-type arrays do not produce a garbled error message in PS 5.1.
- Fixed: `ps/lib/certs.ps1` — `generate_self_signed_cert` no longer exports a PFX by default. PFX export is now opt-in: pass `-PfxPassword <SecureString>` to write the private-key bundle; the public `.cer` is always written. Prevents accidental unprotected private-key files on disk.
- Fixed: `ps/lib/traps.ps1` — `$_SHLIB_EXIT_SOURCE` now holds the literal string `'PowerShell.Exiting'` instead of `[PsEngineEvent]::Exiting`; the enum stringifies to `"Exiting"` which does not match the engine event's actual `SourceIdentifier`, so the exit handler would never fire (and could not be unregistered).
- Fixed: `ps/lib/env.ps1` — `get_project_root` now checks the filesystem root itself for `.git` after the traversal loop exits; previously the root path was never evaluated, causing incorrect fallback to `$StartDir` on drive-root repos.
- Fixed: `ps/lib/version.ps1` — `version_bump` success message now logs the original version string (including prefix/suffix like `v1.2.0-rc1`) instead of the stripped core after prefix/suffix mutation.
- Fixed: `ps/lib/file.ps1` — `create_directory` now returns `$true` on success and `$false` on failure (via `try/catch` with `-ErrorAction Stop`); previously it returned `$null` on all paths, making success checks unreliable.
- Fixed: `ps/lib/env.ps1` — `expand_env_refs` now expands unset `$VAR`/`${VAR}` references to empty string instead of leaving the literal placeholder, matching Bash `load_env` behaviour.
- Removed: `ps/lib/file.ps1` — `ensure_dir` helper removed; it was undocumented, absent from the Bash `lib/file.sh` API, and fully covered by `create_directory`.
- Fixed: `ps/lib/env.ps1` — `resolve_env_value` now mirrors the full Bash API with an optional third `$EnvFile` parameter; when the process env var is unset it falls back to reading the key from that file (default `.env`), matching the Bash `resolve_env_value(key, default, env_file)` signature.
- Fixed: `ps/helpers.ps1` — `Import-ScriptHelpersAll` now loads `logging` first before iterating `Get-ChildItem` output; filesystem ordering is non-deterministic so the previous code could load other modules before `logging`, breaking any module that logs during import.
- Fixed: `ps/lib/help.ps1` — `show_usage` now uses `Write-Output` instead of `Write-Host` so help text can be redirected or captured by callers.
- Fixed: `ps/lib/file.ps1` — `download_file` now marks `$Url` as mandatory and wraps `Invoke-WebRequest` in `try/catch` returning `$true`/`$false`, consistent with `create_directory` and `verify_checksum`.
- Fixed: `ps/lib/hosts.ps1` — `add_hosts_entry` now checks only active (non-comment) lines when testing whether an entry already exists; previously a commented-out domain (`# 127.0.0.1 example.com`) would falsely prevent adding a real entry. `remove_hosts_entry` likewise now preserves comment lines even when they mention the domain.
- Fixed: `ps/lib/env.ps1` — `resolve_env_value` env-file fallback now uses the same parsing logic as `load_env` (handles `export` prefix, whitespace around `=`, and quote stripping) instead of a bare `StartsWith` that missed all those forms.
- Fixed: `ps/lib/help.ps1` — `_Help_PrintInline` and `_Help_PrintBlock` now use `Write-Output` for the non-colored fallback path so all help output is redirectable, consistent with the earlier `show_usage` fix.
- Fixed: `ps/lib/file.ps1` — `download_file` now pipes `Invoke-WebRequest` to `Out-Null` and suppresses the PS progress bar (`$ProgressPreference = 'SilentlyContinue'`) for the duration of the call; previously the response object leaked into the pipeline and the progress UI was noisier than the Bash equivalent.
- Fixed: `ps/lib/dialog.ps1` — `dialog_download_file` now pipes `Invoke-WebRequest` to `Out-Null`; previously the response object was emitted to the pipeline, potentially interfering with callers.
- Fixed: `ps/lib/ports.ps1` — `get_port_conflicts_json` wraps `$conflicts` in `@()` before `ConvertTo-Json` so a single-conflict result is always a JSON array `[{...}]` instead of a bare object `{...}`; without this PS unwraps a one-element array to a scalar.
- Fixed: `ps/lib/file.ps1` — `verify_checksum` now guards against missing/unreadable files with an explicit `Test-Path` check and `try/catch` around `Get-FileHash`, returning `$false` with a structured error message instead of surfacing raw cmdlet exceptions.
- Fixed: `ps/scripts/ci_rust.ps1` — in `-UseDocker` mode, `-Manifest` paths are now translated to container-relative `/work/<rel>` paths; passing an absolute Windows path or a path outside `-Workdir` now fails with a clear error rather than silently breaking cargo inside the container.

- Added: PowerShell companion library (`ps/`) for native Windows support without WSL.
  - `ps/helpers.ps1` — loader with `Import-ScriptHelpers` function (mirrors `helpers.sh` / `shlib_import`).
  - 19 PowerShell modules in `ps/lib/` mirroring all core Bash lib modules:
    `logging`, `os`, `env`, `file`, `deps`, `help`, `version`, `docker`, `ports`, `json`,
    `browser`, `traps`, `python`, `clipboard`, `dialog`, `certs`, `hosts`, `ci_defaults`, `packaging`.
  - `ps/scripts/ci_node.ps1`, `ci_python.ps1`, `ci_go.ps1`, `ci_rust.ps1` — CI runners that work natively on Windows (no Docker required); pass `-UseDocker` for Docker Desktop mode. `-UseDocker` honours `-Quick` and `-SkipTest` in Python CI.
  - `ps/scripts/bump_version.ps1`, `tag_release.ps1` — version management for Windows.
  - `ps/scripts/example_logging.ps1` — demonstration script.
  - PS 5.1 (Windows built-in) and PS 7+ both supported.
  - `deps.ps1` uses `winget` → `choco` → `scoop` for package installation.
  - `ports.ps1` uses `Get-NetTCPConnection` replacing `lsof`/`ss`/`netstat`.
  - `certs.ps1` uses Windows Certificate Store (`New-SelfSignedCertificate`, `Import-Certificate`).
  - `hosts.ps1` targets `C:\Windows\System32\drivers\etc\hosts` (requires admin elevation).
  - `dialog.ps1` uses `Read-Host`-based prompts (Windows has no ncurses `dialog` binary).
- Fixed: `ps/helpers.ps1` — imported functions now survive into the caller's scope (`New-Module + Import-Module -Global`; previously dot-source inside a function discarded them on return).
- Fixed: `ps/scripts/*.ps1` — `SCRIPT_HELPERS_DIR` auto-detection now resolves to the repo root correctly (scripts live two levels below root, not one).
- Fixed: `ps/scripts/ci_node.ps1` — removed PS 7-only `??` null-coalescing operator; defaults to `node:22-alpine` when `CI_NODE_IMAGE` is unset.
- Fixed: `ps/scripts/ci_rust.ps1` — replaced `Invoke-Expression` with splatted `cargo` args to prevent injection from paths with spaces.
- Fixed: `ps/scripts/tag_release.ps1` — version regex now rejects trailing garbage while accepting pre-release suffixes (e.g. `1.2.3-rc1`).
- Fixed: `ps/lib/docker.ps1` — `docker_compose` now correctly invokes `docker-compose` binary when the plugin form is unavailable; `2>/dev/null` replaced with `2>$null`; CRLF-safe output splitting.
- Fixed: `ps/lib/os.ps1` — `run_with_optional_sudo` no longer passes a null arg when the command is a single token.
- Fixed: `ps/lib/traps.ps1` — `setup_exit_trap` unregisters the previous subscription before registering a new one, preventing duplicate exit handlers.
- Fixed: `ps/lib/file.ps1`, `ps/lib/dialog.ps1` — `-UseBasicParsing` gated to PS 5.1 only (removed deprecation warning on PS 7+).
- Fixed: `ps/lib/python.ps1` — `py` launcher now always passes `-3` when detecting version and creating venvs.
- Fixed: `ps/lib/deps.ps1`, `ps/lib/json.ps1` — replaced `command_exists` calls with `Get-Command` to remove hidden cross-module dependency.
- Fixed: `ps/lib/hosts.ps1` — domain existence checks and removal now use word-boundary regex to avoid false matches on substrings.
- Fixed: `ps/lib/help.ps1` — `show_usage` and `parse_common_args` now recognise `-h`/`--help`, `-v`/`--verbose`, `-d`/`--debug` aliases matching the Bash `help.sh` API; header-separator regex updated from `^#-{3,}` to `^#\s*-{3,}` to match the spaced `# ----` form used by all PS scripts.
- Fixed: `ps/lib/env.ps1` — `load_env` now calls `resolve_env_value` so `FOO=$BAR` references in `.env` files are expanded (the function existed but was never wired up).
- Fixed: `ps/lib/logging.ps1` — `log_info`/`log_warn`/`log_error`/`log_debug` now emit ANSI colour on stderr when the terminal supports it (`$_SHLIB_ANSI`); previously colour was silently dropped on the stderr path.
- Fixed: `ps/lib/dialog.ps1` — `dialog_menu` marks `$Items` as `[Parameter(Mandatory)]` to fail fast instead of infinite-looping when omitted; `dialog_input` return uses `$(if …)` subexpression for PS 5.1 compatibility.
- Fixed: `ps/lib/docker.ps1` — `get_docker_compose_cmd` now pre-checks Docker CLI existence before probing plugin availability.
- Fixed: `ps/lib/packaging.ps1` — `to_camel_case` guards empty parts and single-char segments; `pkg_join_list` uses `-join` operator instead of `Join-String` (PS 5.1 compatible; `Join-String` requires PS 6.2+).
- Fixed: `ps/lib/deps.ps1` — `winget install` uses query form (no `--id`) so generic names like `curl`, `git`, `jq` work without vendor-qualified IDs.
- Fixed: `ps/lib/browser.ps1` — `check_port_open` calls `EndConnect()` after `WaitOne` to surface refused connections; `WaitOne` alone returns `$true` on any completion, including failure.
- Fixed: `ps/lib/version.ps1` — `Set-Content` uses `-Encoding ascii` so the `VERSION` file stays Bash-readable (PS 5.1 default encoding is UTF-16 LE).
- Fixed: `ps/lib/hosts.ps1` — `Add-Content` and `Set-Content` use `-Encoding ascii` to preserve the ANSI format required by the Windows hosts parser.
- Fixed: `ps/scripts/ci_node.ps1`, `ci_python.ps1`, `ci_go.ps1`, `ci_rust.ps1` — Docker mode invokes executables directly (no `sh -c`) eliminating shell injection from user-controlled parameters.
- Fixed: `ps/scripts/ci_node.ps1` — `*Cmd` parameters changed to `string[]` token arrays for correct handling of arguments containing spaces or quotes.
- Fixed: `ps/scripts/ci_python.ps1` — `$TestCmd` changed to `string[]`; Docker pip install now skips when `requirements.txt` is absent, matching native mode behaviour.
- Fixed: `ps/scripts/bump_version.ps1` — missing `BumpType` now exits with code 1 (usage error) instead of 0.
- Added: `ps/lib/packaging.ps1` — `pkg_*` functions mirroring the Bash `packaging.sh` public API: `pkg_load_metadata`, `pkg_require_vars`, `pkg_trim`, `pkg_join_list`, `pkg_quote_list`, `pkg_render_lines`, `pkg_classify_name`, `pkg_guess_version`.

## [0.13.0] - 2026-05-21

- Changed: `scripts/git-hooks/pre-commit` — hardened for universal use across all repos:
  - Blocks accidental `.env` / `.env.*` file commits.
  - Docs lint (`lint_docs.sh`) skipped gracefully when the script is absent.
  - Release version check runs only on `release/*` branches (not on every commit).
- Added: `scripts/git-hooks/pre-push` — language-aware test runner (Node/Python/Go/Rust/Flutter) with auto-detection. Runs before every push; skip with `--no-verify` only when justified.
- Added: `scripts/setup-hooks.sh` — one-liner hook installer. Uses `.githooks/` when both shared hook entry points are overridden, otherwise falls back to `scripts/script-helpers/scripts/git-hooks/`, then `scripts/git-hooks/`.
- Added: `scripts/local_test_node.sh` — install + test for Node/npm projects (`--quick`, `--workspace`).
- Added: `scripts/local_test_python.sh` — venv-aware pytest runner that installs `requirements.txt` when present (`--quick`, `--dir`).
- Added: `scripts/local_test_go.sh` — `go vet` + `go test` across all modules (`--quick`, `--module`).
- Added: `scripts/local_test_rust.sh` — `cargo check` + `cargo clippy` + `cargo test` (`--quick`, `--manifest`).
- Added: `scripts/local_test_flutter.sh` — `flutter analyze` + `flutter test` (`--quick`, `--dir`).

## [0.12.2] - 2026-04-11

- Added: `scripts/check_release_tag.sh` so reusable workflows can perform release-tag checks via shared shell logic.
- Added: `scripts/ci_pimcore_bundle_check.sh` for reusable Pimcore bundle CI orchestration.
- Added: `scripts/ci_wp_plugin_check.sh` for reusable WordPress plugin-check CI orchestration.
- Added: `scripts/ci_gitleaks_report.sh` to normalize and evaluate Gitleaks SARIF output in reusable workflows.

## [0.12.1] - 2026-03-20

- Changed: Ollama model selection now uses a `dialog --menu` browser instead of the older radiolist/manual-entry flow.
- Changed: Ollama model browsers now default to official un-namespaced library models, sorted alphabetically, with a reusable parsed menu cache valid for 30 minutes.
- Changed: `ollama_dialog_select_size` now returns a distinct cancel status so callers can return to model selection instead of implicitly reusing an old size.
- Fixed: Ollama selector cache generation can be reused safely across repeated opens within the same session and across launches while the cache is still fresh.
- Fixed: Ollama selector cache refreshes now write atomically and ignore empty/stale cache files instead of reusing corrupted menu data.
- Fixed: Ollama size-selection warnings now go to stderr so stdout-only callers do not corrupt captured values.
- Added: dialog-based Ollama pull progress UI for runtime pulls, including model/layer/progress/speed/ETA parsing.
- Fixed: Dialog pull progress now cleans up background pulls on cancel and bounds progress-log parsing to the recent tail of the log file.

## [0.12.0] - 2026-02-13

- Added: Ollama runtime helpers in `lib/ollama.sh` for local/docker execution (`ollama_runtime_*`) and shared model ref builder (`ollama_model_ref`).
- Added: `is_wsl` helper in `lib/os.sh` for reusable WSL/WSL2 detection.
- Added: `DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG` support in `lib/dialog.sh` to optionally suppress popup error dialogs from `dialog_download_file`.
- Docs: Updated README and module docs for Ollama runtime helpers, WSL detection, and dialog error-popup controls.
- Docs: Added missing `ollama_model_ref_safe` API entry in `docs/modules/ollama.md` to match exported helper aliases.

## [0.11.1] - 2026-02-01

- Changed: Ollama model index preparation now reuses an existing JSON when present and resolves Python 3 via `python3` or `python` (3.x). Adds apt-based installs for `python3-bs4`/`python3-requests` with a non-fatal `apt-get update` fallback.
- Docs: Updated Ollama module docs and README to cover Python resolution and dependency handling.
- Fixed: Skip `pip` requirement when `apt-get` can install Python deps.
- Fixed: Fail fast if Python deps fail to install and verify deps after install.
- Added: `python` module for resolving Python 3 and ensuring local virtualenvs.
- Added: `OLLAMA_MODELS_REPO_REF` to pin the models repo before executing its scripts.
- Fixed: pip installs for Ollama deps avoid `--user` when running as root.
- Fixed: Validate Ollama model index JSON before falling back after a failed refresh.
- Fixed: Validate venv Python executables before returning from `python_ensure_venv`.
- Added: `--digest` parameter to `ci_flutter.sh` for supply-chain image pinning.
- Added: `--gitleaks-digest` parameter to `ci_security.sh` for supply-chain image pinning.
- Added: `lib/ci_defaults.sh` module — centralized Docker image version defaults for all CI scripts. No more `:latest` tags; all images use pinned versions. Overridable via CLI flags or environment variables.
- Changed: CI helper scripts default to Docker and refuse to run when `CI=true` (local-only).
- Changed: Docker cache mounts in all `ci_*.sh` scripts now target `/tmp/` paths with corresponding env vars (`NPM_CONFIG_CACHE`, `PIP_CACHE_DIR`, `PUB_CACHE`, `GRADLE_USER_HOME`, `GOMODCACHE`) to avoid permission issues with non-root UIDs.
- Changed: `ci_python.sh` Docker mode now chains install and test commands in a single container so pip-installed packages persist for the test step.
- Changed: `ci_security.sh` uses `--python-version`, `--node-version`, `--gitleaks-version` with defaults; `--*-image` overrides take precedence.
- Changed: `ci_security.sh` computes `ABS_WORKDIR` inside Docker/no-Docker branches for consistency with other CI scripts.
- Fixed: `pin_production.sh` now resets local production branch from remote before merge, with fallback for first-run when remote production does not yet exist.
- Fixed: `check_release_version.sh` RC warning message is now clearer about when a pre-existing base tag is expected.
- Fixed: Consistent Docker-not-found error messages across all `ci_*.sh` scripts.
- Docs: Added CI helper usage notes and production-branch release guidance.
- Docs: Clarified that `check_release_version.sh` works in both local hooks and CI pipelines.
- Docs: Added `--version`, `--image`, and `--digest` examples to usage guide.

## [0.10.0] - 2026-01-11

- Added: Cross-distro packaging scaffolds (Debian, RPM, Arch, Homebrew) with shared metadata templates.
- Added: Packaging helper module and scripts to render templates and build RPM/Arch artifacts.
- Added: Packaging docs covering structure, build commands, signing notes, and install commands.
- Changed: Auto-tag workflow now opens a PR for VERSION bumps instead of pushing directly to protected `main`.
- Changed: Tag existence checks now verify exact refs to avoid false matches (e.g., `0.10.0` vs `0.1.0`).

## [0.9.1] - 2026-01-08

- Added: `lib/package_publish.sh` for shared Debian/PPA publishing helpers.
- Added: package publish example script.
- Changed: packaging scripts now use shared helpers via `shlib_import`.
- Changed: download dialog gauge uses fixed sizing and no-shadow to avoid visual artifacts.
- Added: Debian packaging helpers (`scripts/build_deb_artifacts.sh`, `scripts/ppa_upload.sh`).
- Added: Homebrew packaging helpers (`scripts/build_brew_tarball.sh`, `scripts/gen_brew_formula.sh`, `scripts/publish_homebrew.sh`).

## [0.9.0] - 2025-12-26

- Changed: Unified script help rendering across `display_help`, `print_help`, and `show_help` with a shared renderer.
- Changed: `-h/--help` now prefers script-level header help when the caller script is known.
- Fixed: Header parsing now only reads the top comment block and captures parameter lines reliably without pulling unrelated script comments.

## [0.8.0] - 2025-12-20

- Added: `version` module (`version_bump`, `version_compare`) with support for optional version file paths and preserving prefixes/suffixes.
- Changed: `scripts/bump_version.sh` now delegates to `version_bump` and accepts `-f/--file`.
- Changed: `version_compare` now returns -1/0/1 (surfaced as 255/0/1 in shells) and keeps higher codes for errors (2 missing args, 3 invalid format).
- Docs: Added module docs and usage examples for version helpers.

## [0.7.0] - 2025-12-16

- Changed: Docker checks now distinguish missing CLI, stopped daemon, and permission errors for clearer guidance (2025-12-16).

## [0.6.0] - 2025-12-16

- Changed: `init_include` now finds the caller project root reliably and keeps debug logging safe under `set -e` (2025-12-16).

## [0.5.0] - 2025-11-27

- Added: `docker_status` in `lib/docker.sh` to show running containers and cross-check services from the current directory's `docker-compose.yml`, marking statuses with glyphs (✅ running, 💥 failed, ✖️ not running). Includes example `scripts/example_docker_status.sh` and updates to README/Makefile (2025-11-27).
- Changed: Tweak download notification messages for clarity in the dialog gauge (2025-11-05).

## [0.3.0] - 2025-11-03

- Added: Dialog-based download progress gauge via `dialog_download_file`, showing percent, size, speed, and ETA. Integrated into `file.sh::download_file` with automatic fallback to `curl`/`wget` when needed (2025-11-03).
- Added: Example scripts for downloads, dialog input, logging, env, Docker Compose, and JSON helpers; `make examples` target to run demos (2025-11-03).
- Changed: On download failures, display a `dialog` error with exit code and recent output before falling back to non-interactive download (2025-11-03).
- Docs: Expanded README with usage, compatibility notes, and `DOWNLOAD_USE_DIALOG` behavior (2025-11-03).

## [0.2.0] - 2025-10-22

- Added: Ollama helpers (`lib/ollama.sh`) and model installer script (`scripts/install_ollama_model.sh`) to install and manage models via dialog selection or CLI (2025-10-18).
- Added: `CHANGELOG.md` to document notable changes (2025-10-17).
- Added: `scripts/bump_version.sh` to bump semantic version string in `VERSION` (2025-10-22).
- Changed: README install instructions and guidance for using this repo as a Git submodule (2025-10-18, 2025-10-22).
- Maintenance: Purged `RELEASE_CHECKLIST.md` from history; updated version metadata (2025-10-17, 2025-10-22).
- Docs: Unified script help headers across `scripts/*` for consistent usage output (2025-10-22).

## [0.1.0] - 2025-10-17

- Initial release: Bootstrapped reusable Bash helpers with loader `helpers.sh` and core modules: `logging.sh`, `dialog.sh`, `os.sh`, `deps.sh`, `docker.sh`, `file.sh`, `json.sh`, `env.sh`, `ports.sh`, `browser.sh`, `traps.sh`, `certs.sh`, `hosts.sh`, `clipboard.sh`, and `help.sh` (2025-10-17).
- Added: Tag and release automation (`scripts/tag_release.sh`) (2025-10-17).

---

Historical notes prior to this changelog may be incomplete or summarized retroactively.
