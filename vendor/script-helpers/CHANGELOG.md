Changelog

This project uses Keep a Changelog style and aims to follow Semantic Versioning for tagged releases.

## [Unreleased]

## 2026-09-02 — v0.24.0

### Added
- `lib/git_branches.sh` and `scripts/prune_branches.sh`: branch maintenance that
  any repository vendoring these helpers can run. `git branch --merged` only sees
  merges that produced a merge commit, so a repository that squash-merges
  accumulates branches it will never list and people delete by hand. The
  squash case is detected by rebuilding the commit a squash merge would have
  produced and asking `git cherry` whether that patch is already upstream.

  The costly mistake is the other one: a branch whose work landed and which
  then received new commits still has something to lose. Both tests look at
  the branch tip as it stands, so a commit added after the merge fails both —
  the protection falls out of the check rather than being a rule to remember.
  It is a dry run by default, refuses the base branch, the current branch, a
  branch checked out in another worktree, protected names including
  `release/*`, and anything holding commits its upstream does not. `--base`
  accepts `main`, `origin/main` or a full ref and normalises before comparing,
  because an un-normalised base matches no local branch and stops being
  recognised as the base. The squash probe carries its own throwaway identity:
  `git commit-tree` refuses to run without one, and where there is none the
  probe would fail silently and report every squash-merged branch as unmerged.
  A probe that cannot run now reports `unknown` rather than `unmerged` — both
  keep the branch, but only one of them means the question was answered.
- `tests/git_branches_test.sh`: a fixture repository covering merge-commit,
  squash, never-merged and unrelated histories — and the case the file exists
  for, a branch squash-merged and then committed to again, which must survive.

### Changed
- `scripts/git-hooks/pre-push` returns immediately when a push contains only
  ref deletions. There are no new commits for a test suite to have an opinion
  about, and running one is the kind of latency that teaches people to reach
  for `--no-verify` — pruning three merged branches otherwise ran the full
  gate three times. Skipped only when every ref in the push is a deletion.
- Comments and module docs name `iso-forge` rather than `burn-iso`, following the
  rename of the repository these helpers were first written for. No behavior changed.


## 2026-08-22 — v0.23.0

- Added: `lib/hub.sh`, corpus-hub setup for capture clients. Every client of
  the corpus hub was told to reach it at a typed `HUB_URL` and nothing
  checked the key, told anyone the hub was behind, or made a hub exist on a
  fresh machine beyond printing "clone the other repository". One module
  both clients import: `hub_setup_dialog` asks whether the hub is **local**
  (clone it when absent and run the hub's own `./start --configure-superuser`
  and `./install-service` -- never compose) or **remote** (URL and key),
  proves the answer (`hub_probe` on `/v1/service`; `hub_check_key` on an
  authenticated read, where a 401 is reported as a wrong key and not as a
  missing hub), and writes `HUB_MODE`, `HUB_URL`, `HUB_API_KEY` and the hub's
  `HUB_INSTANCE_ID` with an in-place, symlink-safe `hub_write_env`.
  `hub_offer_update` compares the running version with the newest tag and,
  to a person and in local mode only, offers to exec the hub's own
  `./update`. Three renderers behind one set of prompts: `dialog` when
  installed on a terminal, plain `read -p` otherwise, and no prompt at all
  without a terminal -- a systemd unit or CI run fails naming the variable it
  wanted instead of waiting on a read forever. The clone URL is an argument;
  the library names no repository. `tests/hub_test.sh` runs it against a
  fake hub and stubbed hub scripts.

## 2026-08-09 — v0.22.0

- Added: wireless-adb helpers in `lib/adb.sh`. A phone on the desk is not always
  a phone on a cable, and `adb connect` has three sharp edges that every project
  rediscovers separately — tcpip mode is lost on reboot and the failure looks
  identical to a wrong address; Android 11+ "Wireless debugging" allocates a
  random port per session so a hard-coded 5555 quietly stops working; and
  `adb connect` exits 0 on a bare TCP handshake, so success is not evidence a
  device is usable.
  The address comes from `DEV_DEVICE` — the existing dev-cli convention for
  which device, and what `--device` sets, so one variable covers both which
  device and where to connect; a USB serial there has no colon and is correctly
  not treated as an address. `ANDROID_DEVICE_IP` / `_PORT` stay supported as an
  explicit split form.
  `adb_wireless_addr`, `adb_wireless_attached`, `adb_wireless_connect`,
  `adb_wireless_disconnect`, `adb_wireless_enable`, `adb_wireless_setup`,
  `adb_wireless_write_env` and `adb_wireless_recovery_hint`.
  `adb_wireless_connect` confirms against `adb devices` rather than trusting the
  exit status, and treats `offline` / `unauthorized` as not attached.
  `adb_wireless_setup` does the whole cable-to-wireless handover in one call and
  prints the address for a caller to store; `adb_wireless_write_env` upserts it
  into a gitignored env file as `DEV_DEVICE` without disturbing anything else
  in that file.
- Security: `adb_wireless_write_env` validates the host and port before writing.
  An env file is SOURCED by the shell that reads it, so whatever lands in it is
  executed. A newline in the value injected an extra line —
  `adb_wireless_write_env .env "$(printf '203.0.113.1\nFOO=$(id)')"` wrote a
  literal `FOO=$(id)` line, and sourcing ran it. The value is not always
  hand-typed: `adb_wireless_setup` takes it from `adb shell ip ...`, i.e. from
  whatever the attached device prints. Validation is at the sink, so every
  caller is covered. `adb_wireless_valid_host` / `adb_wireless_valid_port` are
  exported for callers that want to check earlier.
- Added: `scripts/check_no_private_ips.sh`. Wireless adb makes a device's LAN
  address part of daily work, and it then wants to end up in a README, a test
  fixture or a CI file. This fails on any RFC 1918 literal in a **tracked** file.
  Boundaries are spelled `(^|[^0-9.])` rather than `\b`, which is a GNU/PCRE
  extension and not POSIX ERE — under BSD grep the pattern would quietly match
  nothing and the gate would report success while checking for nothing at all.
  It scans tracked files and ignores untracked and gitignored files, so the env
  file the address is supposed to live in is never flagged — a gate that fired
  there would only teach people to skip it. RFC 5737 documentation ranges,
  loopback and `.local` names are allowed, because those are what a tracked
  example should use.

## 2026-08-09 — v0.21.0

- Fixed: `CHANGELOG.md`'s release headers did not match the format this library
  itself defines and checks. `lib/changelog.sh` exists because `ci-helpers`
  extracts release notes by finding a `## YYYY-MM-DD — vX.Y.Z` heading and
  silently falls back to an auto-generated commit list when it cannot — and
  every heading in this file was `## [X.Y.Z] - YYYY-MM-DD`, so every release
  published here has been getting the fallback. The twenty existing headings
  are converted and `make lint-docs` now runs `changelog_check_header`, since
  nothing ran it, which is how a checker shipped by this repository came to be
  failing on this repository.

- Changed: comments and examples now describe what a helper does rather than
  naming the project a convention was taken from. Several compatibility
  shims were labelled with the name of the codebase whose call shape they
  match, and one example invocation and one changelog line named specific
  projects. None of it was load-bearing — no code read those names — and a
  reader of this repository learns more from "takes a single combined command
  string" than from the name of a codebase they cannot see. This library is
  meant to be self-contained and readable on its own terms.

## 2026-07-31 — v0.20.0
- Fixed: `local_test_python.sh` ran only pytest, while `preflight` labelled the step "lint + test". A repo that moved its CI local therefore lost its Python lint gate without a word about it — the shape of failure this family exists to prevent. It now runs `ruff check .` whenever the project configures ruff (`[tool.ruff]` in `pyproject.toml`, or `ruff.toml`/`.ruff.toml`), and treats configured-but-not-installed as a failure rather than a skip: a gate the project declared and that never ran must not report green. A full (non-`--quick`) run installs ruff first.
- Fixed: `templates/dev-cli/cli.sh` `verb_install` did not configure git hooks. In a repo that has deleted its build workflows the `pre-push` hook is the only remaining gate, and `core.hooksPath` lives in the untracked `.git/config` — so every clone but the one the migration was done on had no gate at all. `install` now runs `setup-hooks.sh`, in both shells.
- Fixed: `templates/dev-cli/cli.sh` `verb_install` ran `python3 -m pip install -r requirements.txt` against the system interpreter, which a PEP 668 host refuses outright, aborting `./dev install`. It now resolves the same project-local `.venv` that `local_test_python.sh` uses, and installs the `dev` extra so preflight's tools are present.
- Fixed: `dev_stack_dir` returned success with empty output when a stack was absent — awk exits 0 when it matches nothing — so the `|| echo .` fallback at every call site was dead code and an empty directory reached `android_build`/`flutter_build`. It now returns 1.
- Fixed: `--device` / `--user` as the final argument killed `./dev` silently. `shift 2` with one argument left returns non-zero and `set -e` ended the process before the validation below could name the missing value. Both options now check for an operand first.
- Fixed: `templates/dev-cli/cli.ps1` could throw before doing anything. `[string[]]$Rest` is `$null` rather than an empty array when nothing follows the verb, and `Set-StrictMode -Version Latest` makes `$Rest.Count` a terminating error. Also `Verb-Devices` referenced `$IsMacOS`, which does not exist in Windows PowerShell 5.1 (same StrictMode rule), and imported an `ios` module that has no PowerShell implementation — a hard error on macOS instead of the "no simulators" notice it intended. All three are guarded, and PowerShell `Verb-Install` gained the python/node parity the Bash verb already had.
- Added: PowerShell parity for the Windows story. `ps/lib/docker_install.ps1` mirrors the Bash module function-for-function (`install_docker`, `ensure_docker`, `docker_ready`, `docker_install_status`, `docker_report_state`, `docker_start_daemon`, `wait_for_docker_daemon`), with switch parameters (`-Yes`, `-DryRun`, `-NoStart`, `-TimeoutSec`) in place of the flags and identical exit codes. Plus `ps/scripts/install_docker.ps1`, the counterpart to `bin/install-docker`. Windows is the primary target — Docker Desktop is the mechanism there, not a convenience — so it gets full support (`winget` → Chocolatey → official installer, TLS 1.2 forced for Windows PowerShell 5.1, `$ProgressPreference` silenced so the download is not ~10× slower, and a non-elevated warning rather than an opaque UAC failure). macOS is Homebrew-cask only and Linux defers to the Bash module by design, rather than maintaining two implementations of package-manager detection and the `docker` group.
- Added: `ps/lib/serve.ps1` and `ps/lib/svg.ps1` — PowerShell counterparts for the modules added in 0.17.0 and 0.18.0, which shipped Bash-only. `serve_static_site` uses `TcpClient` for the free-port probe (`Get-NetTCPConnection` is Windows-only) and keeps the same python3 → python → `npx http-server` preference and return codes. `svg_rasterizer` prefers `magick` over the legacy `convert` on Windows and refuses to match `convert.exe` from the system directory — that is the FAT-to-NTFS conversion utility, not ImageMagick.
- Fixed: `ps/scripts/tag_release.ps1` could not be parsed, so the script was unusable. `"Invalid version in $File: $version"` parses `$File:` as a scoped variable reference (the `$env:PATH` form); it needs `${File}`. Pre-existing on `main`.
- Added: a `powershell` CI job that parses every `ps/**/*.ps1` and imports every module. PowerShell had never been built or linted in CI, which is how the `tag_release.ps1` syntax error shipped unnoticed. The Bash `lint-and-examples` job now also runs `make test`, which it previously did not.
- Note: `ios` remains Bash-only on purpose. It drives Xcode, `xcrun` and `simctl`, which exist only on macOS; the Bash module already no-ops elsewhere via its `ios_available` gate, so a PowerShell mirror would be a file full of stubs. `ollama` and `package_publish` are also still Bash-only, but predate this change and were left alone.

- Added: `docker_install` module (`lib/docker_install.sh`) — gets Docker onto a bare machine, so a project bootstrap can go from nothing to a working `docker compose` without sending the operator off to read platform-specific install docs. Companion to `docker`, which assumes Docker already exists. Installs Docker Engine + the compose v2 plugin on Linux (Docker's official `apt`/`dnf`/`yum` repositories; distribution packages on openSUSE and Arch), Docker Desktop on macOS (Homebrew cask, else the official `.dmg` for the detected CPU) and on Windows (`winget` → Chocolatey → official silent installer, from Git Bash/MSYS2), and detects WSL explicitly, explaining Docker Desktop-with-integration versus Engine-in-distro before installing either. Detection helpers (`docker_cli_installed`, `docker_daemon_running`, `docker_compose_v2_available`, `docker_ready`, `docker_install_status`, `docker_report_state`), the installer (`install_docker`, `ensure_docker`), and the reusable pieces (`docker_start_daemon`, `docker_add_user_to_group`, `wait_for_docker_daemon`). Plus a CLI wrapper `bin/install-docker` (adds `--check`) and `tests/docker_install_test.sh`, which is detection- and dry-run-only so `make test` never installs anything.

  Behaviour worth knowing: `install_docker` is **idempotent** — a working Docker returns 0 having changed nothing. When the CLI exists but the daemon does not answer it **starts what is already installed** before considering an install, because a closed Docker Desktop is the common case and reinstalling is the wrong fix. It prints its plan and asks before modifying the system (`--yes` skips, `--dry-run` shows without doing, `--no-start` and `--no-group` narrow the scope). Exit `3` means installed-but-daemon-not-up, which on Linux is almost always the `docker` group change not applying to the current shell — the module says so rather than leaving the caller guessing. Apt derivatives are mapped onto their upstream (Mint/Pop!_OS/neon/Zorin/elementary → `ubuntu`, Raspbian/Kali/Parrot → `debian`) and the repository line prefers `UBUNTU_CODENAME` over `VERSION_CODENAME`, since the latter is the derivative's own release name and 404s against Docker's repository.
- Added: `android` module (`lib/android.sh`) — the build side of Android, counterpart to `adb`, which owns everything that happens on an already-running device. SDK discovery (`android_sdk_root`, `android_available`, `android_sdk_tool`, searching the SDK's several layouts and versioned `build-tools` newest-first), bootstrap (`android_ensure_sdk` accepting licenses and installing platform-tools/platform/build-tools), building (`android_gradlew`, `android_build` — one spelling of the debug/release toggle where consuming repos had four, and `android_artifact`, which distinguishes "not built yet" from "built and here it is"), signing (`android_sign` via `apksigner` or `jarsigner`, with the keystore from a file or base64-decoded out of an environment variable, and an opt-in `--allow-unsigned` debug-signed fallback so a local build proceeds without release credentials), and emulators (`android_avd_list`, `android_avd_create`, `android_emulator_start` waiting on boot completion, `android_emulator_stop`). Loads the `gradle` and `adb` modules itself, so `shlib_import android` is sufficient.
- Added: `flutter` module (`lib/flutter.sh`) — `flutter_resolve_sdk` finds Flutter in the places a non-interactive shell's PATH misses (a snap, a tarball under `$HOME`, fvm), which consuming repos had solved by pasting the same candidate-path loop into every script that needed it. Plus `flutter_available`, `flutter_run_cmd` (the single point where SDK resolution lives), `flutter_pub_get`, `flutter_analyze`, `flutter_format_check`, `flutter_test`, `flutter_build` (defaulting to `--release`, since a mode-less Flutter build is a debug build and that is rarely what a build function's caller means), `flutter_devices` (with a `jq`-free fallback), and `flutter_resolve_device`, which refuses to guess between two connected devices.
- Added: `gradle` module (`lib/gradle.sh`) — `gradle_available`, `gradle_wrapper`, `gradle_run`, `gradle_lint`, `gradle_test`, `gradle_assemble`, `gradle_clean`. Prefers the project's `./gradlew` over a system `gradle`, because the wrapper pins the version and a system `gradle` does not. Kept separate from `android` so a plain JVM host component need not import an Android toolchain to run `test`.
- Added: `screencap` module (`lib/screencap.sh`) — screenshots and screen video from a device, emulator or simulator, for README media, store listings and bug reports. `screencap_available`, `screencap_shot`, `screencap_record`, `screencap_record_stop`, `screencap_frame` and `screencap_gif` (two-pass with a generated palette, because a single-pass GIF from video is visibly dithered). Two device limits are reported rather than hidden: `screenrecord` caps a clip at 180 seconds, so longer requests are chunked and concatenated instead of silently truncated; and a physical iOS device cannot be recorded without Xcode driving it, which returns 3 with an explanation rather than appearing to succeed. Generated names land in `docs/screenshots/`, overridable with `SCREENCAP_DIR`.
- Added: `manifest` module (`lib/manifest.sh`) — `manifest_kind`, `manifest_detect`, `manifest_read_version`, `manifest_write_version`, `manifest_android_version_code` and `manifest_sync_version`, across `pubspec.yaml`, `build.gradle[.kts]`, `VERSION`, `package.json` and `pyproject.toml`. A phone app states its version in three places at once and they drift; `manifest_sync_version` is the "one release, one number" operation. A pubspec's `+build` counter is preserved and the Play Store `versionCode` is recomputed from semver; a non-semver input returns 2 rather than emitting a wrong `versionCode`, which the Play Store rejects only after the upload.
- Added: `changelog` module (`lib/changelog.sh`) — `changelog_check_header`, `changelog_extract` and `changelog_new_section`. The `## YYYY-MM-DD — vX.Y.Z` header is load-bearing: `ci-helpers` extracts release notes by finding that section, and any other shape silently falls back to an auto-generated commit list. The checker calls out an ASCII hyphen where the em-dash belongs, which is the common near-miss.
- Added: `scripts/preflight.sh` — one command that runs every check CI would have run: lint, format, tests, build and a secret scan. It detects `(stack, directory)` pairs rather than a single stack at the repo root, which is what lets it replace a multi-job workflow in a repo with an app in `android/` and a host in `host/`; a repo can pin the list with a `.preflight` file when autodetection picks up a directory CI never built. A skipped check is reported separately from a passing one, so an absent toolchain cannot look green. Carries the same local-only guard as the other `ci_*.sh` runners.
- Added: `scripts/local_test_gradle.sh` — the missing member of the `local_test_*` family, autodetecting Android task names from the applied Gradle plugin.
- Added: `scripts/install_dev_cli.sh` and `templates/dev-cli/` — one `./dev` verb set for every consuming repo: `install build run test preflight deploy devices screenshot record logs clean update release`. A verb a repo cannot honour prints why and exits 0 rather than being absent, because a missing verb is indistinguishable from a typo. `_bootstrap.sh` is copied rather than sourced from the library, since locating the library is the thing it does, and it self-heals an uninitialized submodule. Repo-specific behaviour goes in `scripts/project.sh`, so `cli.sh` stays refreshable from the template. The installer leaves old root scripts as thin shims.
- Added: `adb_install` takes `--user <id>`, defaulting to `0` (the device owner), and passes it through to `adb`. Plus `adb_installed_for_user` and `adb_install_verified`. An unqualified `adb install` can land a package in a profile the shell cannot subsequently read: on a device with a work profile or Samsung Secure Folder the install prints `Success` and exits 0, `pm list packages` fails with `SecurityException: Shell does not have permission to access user <id>`, and the app is absent from the launcher and unstartable by `am start`. Every signal says the install worked, so the symptom reads as an app fault rather than a deploy fault. Pinning the user prevents the common case; `adb_install_verified` prevents the class, because an installer's exit code asserts that adb accepted the command, not that the app is usable. Note that `adb shell` exits 0 even when the command inside it failed, so the check reads the output rather than the status. `android_package_name` supplies the package name to verify, preferring `aapt` on the built artifact since that is the only source accounting for `applicationIdSuffix` and flavors.
- Changed: `scripts/git-hooks/pre-push` now detects Gradle and Android projects — whose absence previously produced "No test runner detected" and a green push — and delegates to `preflight --quick` when it is available. It distinguishes "preflight is not installed" from "preflight failed", so a failing check can never fall through to a weaker one and let the push pass.
- Added: PowerShell companions for every new module (`ps/lib/{android,flutter,gradle,screencap,manifest,changelog}.ps1`) plus `ps/scripts/preflight.ps1` and `ps/scripts/local_test_gradle.ps1`. The PowerShell preflight is native rather than shelling out, so the same verbs work in Windows PowerShell with no Git Bash present.

## 2026-07-26 — v0.19.0
- Added: `ios` module (`lib/ios.sh`) — an iOS device/simulator toolkit, the counterpart to `adb`. Discover hardware and simulators (`ios_list_devices`, `ios_list_simulators`, `ios_booted_simulators`), control simulators (`ios_boot_simulator`, `ios_shutdown_simulators`), install and launch builds (`ios_install` for `.app`/`.ipa`, `ios_launch`), and build a Flutter release (`ios_build_release`: a signed IPA with an ExportOptions plist, otherwise an unsigned iOS app). macOS-only: every function no-ops on other hosts (`ios_available` gate) so callers degrade cleanly. Plus `scripts/ci_ios.sh`, a host-based analyze/test/build runner (Apple's toolchain runs only on macOS, so unlike the Docker-based `ci_*.sh` helpers it has no image and exits early elsewhere).

## 2026-07-25 — v0.18.0
- Added: `svg` module (`lib/svg.sh`) to rasterize SVG art to PNG for app logos and launcher icons. `svg_rasterize <in.svg> <out.png> [size]` renders a square PNG (default 1024px), preferring Inkscape and falling back to ImageMagick (`magick`/`convert`); `svg_rasterize_sizes` emits one PNG per size for icon sets; `svg_rasterizer` reports the available tool. Plus a CLI wrapper `bin/svg-rasterize` and a `tests/svg_test.sh` smoke test (auto-picked up by `make test`). Extracted from an application's icon-generation flow so the rasterizing step is defined once here rather than per project.

## 2026-07-21 — v0.17.0
- Added: `serve` module (`lib/serve.sh`) with `serve_static_site <dir> [port]` to preview a static/GitHub-Pages directory locally — auto-picks a free port (default `8000`), prefers `python3 -m http.server`, falls back to `python` (`http.server` on Python 3 or `SimpleHTTPServer` on Python 2) then `npx http-server`. Plus a CLI wrapper `bin/serve-pages` and a `tests/serve_test.sh` smoke test (also runnable via new `make test` target).
- Added: PHP/Laravel support for the local test runner and `pre-push` hook. New `scripts/local_test_php.sh` runs `composer install` (skipped with `--quick`), Laravel Pint style checks when available, and the suite via `php artisan test` (falling back to `vendor/bin/phpunit`); `SKIP_PHP_TESTS=1` gives a style-only run for pre-push without a local database. In the `pre-push` hook, `composer.json` is authoritative so Laravel apps that also ship a `package.json` for Vite run their PHP suite instead of falling through to the Node runner.
- Changed: release automation now reuses the shared ci-helpers reusable workflows instead of hand-rolled logic. `auto-tag-release.yml` (on merge of a `release/X.Y.Z` PR to `main`) calls `ci-helpers/auto-tag-release.yml@production` to detect+tag the version, `create-github-release.yml@production` to publish the Release in the same run, and moves the `production` branch. Removes the bespoke `release-tag.yml` and `auto-tag.yml`.
- Added: `adb` module — a multi-device-safe Android Debug Bridge toolkit (Bash `lib/adb.sh` + PowerShell `ps/lib/adb.ps1`). Inspect devices (`adb_list_devices` table of serial/model/Android OS/API level/IP; `adb_device_status`, `adb_device_api`, `adb_android_version`, `adb_device_ip`), install apps (`adb_install`, `adb_install_all`, `adb_uninstall`), copy files (`adb_push`, `adb_pull`), and debug (`adb_shell`, `adb_logcat`, `adb_clear_logcat`, `adb_battery_level`, `adb_screen_on`). Every command targets `adb -s <serial>` so it works with more than one device attached. Plus a reusable CLI wrapper `scripts/adb_tool.sh`.
- Added: CI helper scripts for Node, Python, Flutter, Gradle, Go, and basic security checks.
- Added: `scripts/pin_production.sh` to fast-forward the production branch to a release tag.
- Added: `scripts/check_release_version.sh` to verify release versions before tagging or publishing.
- Added: `--version` and `--image` parameters to all `ci_*.sh` scripts for Docker image tag and full image override.

## 2026-06-12 — v0.14.0
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

## 2026-05-21 — v0.13.0
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

## 2026-04-11 — v0.12.2
- Added: `scripts/check_release_tag.sh` so reusable workflows can perform release-tag checks via shared shell logic.
- Added: `scripts/ci_pimcore_bundle_check.sh` for reusable Pimcore bundle CI orchestration.
- Added: `scripts/ci_wp_plugin_check.sh` for reusable WordPress plugin-check CI orchestration.
- Added: `scripts/ci_gitleaks_report.sh` to normalize and evaluate Gitleaks SARIF output in reusable workflows.

## 2026-03-20 — v0.12.1
- Changed: Ollama model selection now uses a `dialog --menu` browser instead of the older radiolist/manual-entry flow.
- Changed: Ollama model browsers now default to official un-namespaced library models, sorted alphabetically, with a reusable parsed menu cache valid for 30 minutes.
- Changed: `ollama_dialog_select_size` now returns a distinct cancel status so callers can return to model selection instead of implicitly reusing an old size.
- Fixed: Ollama selector cache generation can be reused safely across repeated opens within the same session and across launches while the cache is still fresh.
- Fixed: Ollama selector cache refreshes now write atomically and ignore empty/stale cache files instead of reusing corrupted menu data.
- Fixed: Ollama size-selection warnings now go to stderr so stdout-only callers do not corrupt captured values.
- Added: dialog-based Ollama pull progress UI for runtime pulls, including model/layer/progress/speed/ETA parsing.
- Fixed: Dialog pull progress now cleans up background pulls on cancel and bounds progress-log parsing to the recent tail of the log file.

## 2026-02-13 — v0.12.0
- Added: Ollama runtime helpers in `lib/ollama.sh` for local/docker execution (`ollama_runtime_*`) and shared model ref builder (`ollama_model_ref`).
- Added: `is_wsl` helper in `lib/os.sh` for reusable WSL/WSL2 detection.
- Added: `DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG` support in `lib/dialog.sh` to optionally suppress popup error dialogs from `dialog_download_file`.
- Docs: Updated README and module docs for Ollama runtime helpers, WSL detection, and dialog error-popup controls.
- Docs: Added missing `ollama_model_ref_safe` API entry in `docs/modules/ollama.md` to match exported helper aliases.

## 2026-02-01 — v0.11.1
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

## 2026-01-11 — v0.10.0
- Added: Cross-distro packaging scaffolds (Debian, RPM, Arch, Homebrew) with shared metadata templates.
- Added: Packaging helper module and scripts to render templates and build RPM/Arch artifacts.
- Added: Packaging docs covering structure, build commands, signing notes, and install commands.
- Changed: Auto-tag workflow now opens a PR for VERSION bumps instead of pushing directly to protected `main`.
- Changed: Tag existence checks now verify exact refs to avoid false matches (e.g., `0.10.0` vs `0.1.0`).

## 2026-01-08 — v0.9.1
- Added: `lib/package_publish.sh` for shared Debian/PPA publishing helpers.
- Added: package publish example script.
- Changed: packaging scripts now use shared helpers via `shlib_import`.
- Changed: download dialog gauge uses fixed sizing and no-shadow to avoid visual artifacts.
- Added: Debian packaging helpers (`scripts/build_deb_artifacts.sh`, `scripts/ppa_upload.sh`).
- Added: Homebrew packaging helpers (`scripts/build_brew_tarball.sh`, `scripts/gen_brew_formula.sh`, `scripts/publish_homebrew.sh`).

## 2025-12-26 — v0.9.0
- Changed: Unified script help rendering across `display_help`, `print_help`, and `show_help` with a shared renderer.
- Changed: `-h/--help` now prefers script-level header help when the caller script is known.
- Fixed: Header parsing now only reads the top comment block and captures parameter lines reliably without pulling unrelated script comments.

## 2025-12-20 — v0.8.0
- Added: `version` module (`version_bump`, `version_compare`) with support for optional version file paths and preserving prefixes/suffixes.
- Changed: `scripts/bump_version.sh` now delegates to `version_bump` and accepts `-f/--file`.
- Changed: `version_compare` now returns -1/0/1 (surfaced as 255/0/1 in shells) and keeps higher codes for errors (2 missing args, 3 invalid format).
- Docs: Added module docs and usage examples for version helpers.

## 2025-12-16 — v0.7.0
- Changed: Docker checks now distinguish missing CLI, stopped daemon, and permission errors for clearer guidance (2025-12-16).

## 2025-12-16 — v0.6.0
- Changed: `init_include` now finds the caller project root reliably and keeps debug logging safe under `set -e` (2025-12-16).

## 2025-11-27 — v0.5.0
- Added: `docker_status` in `lib/docker.sh` to show running containers and cross-check services from the current directory's `docker-compose.yml`, marking statuses with glyphs (✅ running, 💥 failed, ✖️ not running). Includes example `scripts/example_docker_status.sh` and updates to README/Makefile (2025-11-27).
- Changed: Tweak download notification messages for clarity in the dialog gauge (2025-11-05).

## 2025-11-03 — v0.3.0
- Added: Dialog-based download progress gauge via `dialog_download_file`, showing percent, size, speed, and ETA. Integrated into `file.sh::download_file` with automatic fallback to `curl`/`wget` when needed (2025-11-03).
- Added: Example scripts for downloads, dialog input, logging, env, Docker Compose, and JSON helpers; `make examples` target to run demos (2025-11-03).
- Changed: On download failures, display a `dialog` error with exit code and recent output before falling back to non-interactive download (2025-11-03).
- Docs: Expanded README with usage, compatibility notes, and `DOWNLOAD_USE_DIALOG` behavior (2025-11-03).

## 2025-10-22 — v0.2.0
- Added: Ollama helpers (`lib/ollama.sh`) and model installer script (`scripts/install_ollama_model.sh`) to install and manage models via dialog selection or CLI (2025-10-18).
- Added: `CHANGELOG.md` to document notable changes (2025-10-17).
- Added: `scripts/bump_version.sh` to bump semantic version string in `VERSION` (2025-10-22).
- Changed: README install instructions and guidance for using this repo as a Git submodule (2025-10-18, 2025-10-22).
- Maintenance: Purged `RELEASE_CHECKLIST.md` from history; updated version metadata (2025-10-17, 2025-10-22).
- Docs: Unified script help headers across `scripts/*` for consistent usage output (2025-10-22).

## 2025-10-17 — v0.1.0
- Initial release: Bootstrapped reusable Bash helpers with loader `helpers.sh` and core modules: `logging.sh`, `dialog.sh`, `os.sh`, `deps.sh`, `docker.sh`, `file.sh`, `json.sh`, `env.sh`, `ports.sh`, `browser.sh`, `traps.sh`, `certs.sh`, `hosts.sh`, `clipboard.sh`, and `help.sh` (2025-10-17).
- Added: Tag and release automation (`scripts/tag_release.sh`) (2025-10-17).

---

Historical notes prior to this changelog may be incomplete or summarized retroactively.
