Changelog

This project uses Keep a Changelog style and aims to follow Semantic Versioning for tagged releases.

## [Unreleased]

- Added: CI helper scripts for Node, Python, Flutter, Gradle, Go, and basic security checks.
- Added: `scripts/pin_production.sh` to fast-forward the production branch to a release tag.
- Added: `scripts/check_release_version.sh` to verify release versions before tagging or publishing.
- Added: `--version` and `--image` parameters to all `ci_*.sh` scripts for Docker image tag and full image override.

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
