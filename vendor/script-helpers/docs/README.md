# Script Helpers — Documentation

Reusable Bash helpers extracted from projects in this workspace. Source the loader, import only the modules you need, and call the functions in your own scripts.

- Installation: see ./docs/installation.md
- Usage: see ./docs/usage.md
- Packaging: see ./docs/packaging.md
- Full API: see ./docs/api.md
- CI helper scripts: see ./docs/usage.md#ci-helper-scripts
- CI default versions: see ./docs/ci_defaults.md

Quick start
-----------

```bash
#!/usr/bin/env bash
set -euo pipefail

# Point to the script-helpers folder in your repo
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(dirname "$0")/script-helpers}"

# Load loader and import modules you need
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging docker dialog file json env ports browser traps certs hosts clipboard ollama os

print_success "script-helpers is ready"
```

Modules overview
----------------

- helpers — loader and import utilities.
- logging — color and log utilities for both stdout and stderr.
- help — print help/usage from script header comments and common arg parsing.
- os — OS detection and conditional sudo runner.
- env — project root detection, .env loading, require envs.
- file — file/dir checks, download with optional dialog gauge, ISO/checksum helpers.
- dialog — `dialog` sizing, input, and a rich download progress gauge.
- docker — docker compose detection/wrapper, service wait, status inspection.
- docker_install — install Docker Engine (Linux) / Docker Desktop (macOS, Windows); idempotent `ensure_docker` guard. Bash + PowerShell + `bin/install-docker` / `ps/scripts/install_docker.ps1`.
- deps — install utilities and AI Runner tooling profile.
- json — escape strings, extract fields, markdown-friendly formatting.
- svg — rasterize SVG artwork to square PNGs and icon-size sets.
- python — resolve Python 3 executables and ensure local virtualenvs.
- ports — list port listeners, detect conflicts from env variables.
- version — semantic version helpers for bumping and comparing.
- browser — open URLs and wait+open a frontend when ready.
- certs — self‑signed certs and trust store installation.
- hosts — /etc/hosts helpers.
- clipboard — copy text to clipboard (Linux/macOS).
- traps — simple EXIT/INT/TERM traps with error reporting.
- ollama — install CLI, prepare models index, select/pull/run models.
- package_publish — Debian package builds and PPA upload helpers.
- packaging — packaging metadata helpers and template formatting.
- ci_defaults — centralized Docker image version defaults for CI helper scripts.
- adb — Android Debug Bridge toolkit: list/inspect devices (model, Android OS, API level, IP), install apps, copy files to/from, and debug (shell/logcat/status); multi-device safe; Bash + PowerShell + `scripts/adb_tool.sh` CLI.
- ios — iOS device and simulator toolkit: discover, boot, install, launch, and build Flutter release apps or signed IPAs; macOS/Xcode only.
- serve — serve a static site directory locally for preview (auto-picks a free port; prefers `python3 -m http.server`); CLI wrapper `bin/serve-pages`.
- gradle — wrapper resolution and task invocation; prefers the project's `./gradlew` over a system `gradle`; Bash + PowerShell.
- android — Android build side: SDK resolution and bootstrap, one debug/release build toggle, artifact lookup, APK/AAB signing with a base64-keystore path and a debug-signed fallback, AVDs, emulator start/stop; Bash + PowerShell.
- flutter — Flutter SDK resolution across the install locations a non-interactive shell misses, analyze/format/test/build, device listing and resolution; Bash + PowerShell.
- git_branches — Whether a branch has already landed, including the squash and rebase merges `git branch --merged` cannot see, and whether it gained commits afterwards; backs scripts/prune_branches.sh.
- screencap — screenshots and screen video from a device, emulator or simulator, plus ffmpeg frame extraction and GIF conversion; chunks past `screenrecord`'s 180s cap; Bash + PowerShell.
- manifest — read and write the project version across pubspec, Gradle, VERSION, package.json and pyproject, with the Play Store versionCode derived from semver; Bash + PowerShell.
- changelog — check, extract and generate the CHANGELOG release-header format that `ci-helpers` builds release notes from; Bash + PowerShell.
- hub — corpus-hub setup for capture clients: local-vs-remote dialog, probe, API-key check, symlink-safe `.env` writing, bootstrap through the hub's own scripts, and an update offer.

If you add a new module or function, update ./docs/api.md and the relevant ./docs/modules/*.md file. See AGENTS.md for the process and checklist.
