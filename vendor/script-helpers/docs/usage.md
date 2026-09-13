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
- `DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG` — controls dialog download error popups:
  - default `1`: show dialog on download failure.
  - `0`/`false`/`never`: suppress popup and return non-zero to caller.
- `PORT_DETECTION_ALLOW_SUDO` — allow sudo when probing ports (`ports` module). Default: `false`.
- `FRONTEND_HOST`, `FRONTEND_PORT` — host/port for `browser::open_frontend_when_ready`.

Using as a library in other projects
------------------------------------

- Vendor this folder under `scripts/script-helpers` or similar.
- Source `helpers.sh` from your scripts and import the modules you need.
- Keep examples in `scripts/` handy for quick reference; you can copy/paste and adapt.

Bundled CLIs
------------

- `scripts/adb_tool.sh` — a ready-to-use CLI over the `adb` module for inspecting
  and debugging Android devices (multi-device safe). Subcommands:
  `list`, `status <serial>`, `ip <serial> [iface]`, `install <serial> <apk>`,
  `install-all <apk>`, `push <serial> <local> <remote>`, `pull <serial> <remote> [local]`,
  `shell <serial> <cmd...>`, `logcat <serial> [regex]`, `clear-logcat <serial>`,
  `uninstall <serial> <package>`. Run `scripts/adb_tool.sh --help` for details.
  See [`modules/adb.md`](modules/adb.md).

- `scripts/prune_branches.sh` — removes branches whose work has already landed,
  including the squash and rebase merges `git branch --merged` cannot see, and
  only when the branch gained nothing afterwards. A dry run by default; `--apply`
  to act and `--remote` before a remote branch is considered at all. Options:
  `--repo`, `--base`, `--remote-name`, `--keep <glob>`, `--no-fetch`. Run
  `scripts/prune_branches.sh --help` for details.
  See [`modules/git_branches.md`](modules/git_branches.md).

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

CI helper scripts
-----------------

These scripts help reproduce CI steps locally and default to Docker-based
execution (use `--no-docker` to run on the host). They are intended for local
use only and will refuse to run when `CI=true`.

```bash
./scripts/ci_node.sh --workdir frontend
./scripts/ci_python.sh --workdir backend --requirements requirements.txt --test-cmd "pytest -q"
./scripts/ci_flutter.sh --workdir . --skip-test --build-cmd "flutter build appbundle --release"
./scripts/ci_gradle.sh --workdir . --skip-detekt
./scripts/ci_go.sh --workdir scanner
./scripts/ci_security.sh --workdir backend --python-req requirements.txt
```

Override Docker image versions with `--version` (tag) or `--image` (full reference):

```bash
./scripts/ci_node.sh --version 22-bookworm
./scripts/ci_python.sh --version 3.12-slim
./scripts/ci_go.sh --image golang:1.23-alpine
./scripts/ci_security.sh --gitleaks-version v8.21.2
```

For enhanced supply-chain security, pin images to a specific digest:

```bash
./scripts/ci_flutter.sh --digest sha256:d18e043566d957a358fdfa063e53381a303245b4b68e7c0e2ece82b71183537c
./scripts/ci_security.sh --gitleaks-digest sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
```

Git hook setup and local test runners
-------------------------------------

Install the shared git hooks from your repository root. The command differs
depending on whether you are working inside the script-helpers repo itself or
in a consuming repo that vendors it as a submodule:

```bash
# Inside the script-helpers repo
bash scripts/setup-hooks.sh

# In a consuming repo that has script-helpers as a submodule under scripts/script-helpers
bash scripts/script-helpers/scripts/setup-hooks.sh
```

The installer detects the correct hook directory automatically. It prefers
`.githooks/` when both `pre-commit` and `pre-push` are present there, then
falls back to the submodule path (`scripts/script-helpers/scripts/git-hooks`)
or the local `scripts/git-hooks` directory. Shared hooks still defer to a
matching repo-local `.githooks/pre-commit` or `.githooks/pre-push` when one
is present (same-file recursion guard included).

Run the language-specific local test scripts directly when you want the same
entry points outside a hook. Use `--quick` for the fast test-only path. The
Python runner installs `requirements.txt` when present; projects using only
`pyproject.toml` should prepare their test environment before invoking it.

The command prefix depends on context (same two-variant pattern as `setup-hooks.sh` above):

```bash
# Inside the script-helpers repo
bash scripts/local_test_node.sh --quick
bash scripts/local_test_python.sh --quick --dir backend
bash scripts/local_test_go.sh --quick
bash scripts/local_test_rust.sh --quick
```

By default the Rust gate runs against rustup's `stable` — what CI installs — rather
than whatever `cargo` is first on `PATH`; a distribution cargo shadowing it fails
with a lockfile error that names the wrong thing. `RUST_TOOLCHAIN=1.80.0` pins a
channel or version; `--any-cargo` opts out for a repository that genuinely
targets the system toolchain.

`preflight` runs that same gate, so it needs rustup too, and it has no flag to
forward. Without rustup it reports the Rust project as **skipped**, naming both
remedies, rather than failing the run on advice the reader cannot act on. Set
`PREFLIGHT_RUST_ANY_CARGO=true` to check against `PATH`'s cargo instead of
skipping.

```bash
bash scripts/local_test_flutter.sh --quick --dir app
bash scripts/local_test_php.sh --quick --dir backend

# In a consuming repo (script-helpers as a submodule under scripts/script-helpers)
bash scripts/script-helpers/scripts/local_test_node.sh --quick
bash scripts/script-helpers/scripts/local_test_python.sh --quick --dir backend
bash scripts/script-helpers/scripts/local_test_go.sh --quick
bash scripts/script-helpers/scripts/local_test_rust.sh --quick
bash scripts/script-helpers/scripts/local_test_flutter.sh --quick --dir app
bash scripts/script-helpers/scripts/local_test_php.sh --quick --dir backend
```

The PHP runner targets PHP/Laravel projects: it runs `composer install`
(skipped with `--quick`), checks style with Laravel Pint when
`vendor/bin/pint` is present, then runs the suite via `php artisan test`
(falling back to `vendor/bin/phpunit`). When tests are not skipped and no
runner is found, the script exits non-zero so callers do not treat "no runner"
as a passing suite. Set `SKIP_PHP_TESTS=1` for a style-only run that skips the
(often DB-backed) test suite — handy for a pre-push on a machine without a
local database. In the `pre-push` hook, `composer.json` is authoritative: a
repo that has it runs the PHP suite rather than falling through to the Node
runner, even when a `package.json` is also present for Vite. If PHP or Composer
is not installed, the hook prints a message and skips the PHP checks (the push
still proceeds).

Release branch checks
---------------------

Use this script in local pre-commit hooks or CI pipelines to ensure `VERSION`
matches `release/[v]X.Y.Z[-rcN|-rc.N]` branch naming. Unlike the local-only
`ci_{go,node,python,...}.sh` wrapper scripts that enforce a `CI=true` guard,
`check_release_version.sh` works in both environments:

```bash
./scripts/check_release_version.sh --version-file VERSION --fetch-tags
```

Reuse in other repositories
---------------------------

Add a pre-commit hook in another repo that delegates to the shared script:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$ROOT_DIR/scripts/script-helpers}"

bash "$SCRIPT_HELPERS_DIR/scripts/check_release_version.sh" --version-file VERSION --fetch-tags
```

Notes:
- Set `SCRIPT_HELPERS_DIR` if your submodule lives elsewhere.

Reusable workflow helper scripts
--------------------------------

These scripts are intended to be called from reusable GitHub Actions workflows
or from local CI debugging sessions where you want the same shell entry points.
Unlike the local-only `ci_{go,node,python,...}.sh` wrappers above, the
`ci_gitleaks_report.sh`, `ci_pimcore_bundle_check.sh`, and
`ci_wp_plugin_check.sh` helpers in this section are safe to call with `CI=true`.

Check whether a release tag already exists for a release branch:

```bash
./scripts/check_release_tag.sh --branch release/0.12.2 --repo . --fetch-tags --print-version
```

- The check is a no-op on non-`release/*` branches.
- `--fetch-tags` reads tags from the `origin` remote by default; pass `--remote`
  when the repository uses a different remote name.

Require that the version being released has been written up:

```bash
./scripts/check_changelog_section.sh
./scripts/check_changelog_section.sh --version 1.4.0 --changelog docs/CHANGELOG.md
```

- Like `check_release_version.sh`, a no-op away from a `release/*` branch, so it
  is safe on every pull request. `--changelog` is relative to `--repo`.
- A pre-release section does not count for the final version: `release/0.2.0`
  is not satisfied by `## 2026-09-01 — v0.2.0-rc.1`.
- The section must have entries. A header with nothing under it, or only the
  empty `###` headings `changelog_new_section` writes, fails.
- `changelog_check_header` (run by `make lint-docs`) only inspects the newest
  header. A release branch whose version was never added to the CHANGELOG passed
  that and then published a release body built from commit subjects. This closes
  the gap.

Produce the body of a GitHub Release:

```bash
./scripts/release_notes.sh --version 1.4.0 --output body.md
./scripts/release_notes.sh --version 1.4.0 --tag v1.4.0 --repo ../other-repo
```

- The CHANGELOG section for the version is preferred. With no section, or a
  section with no entries (a warning says so), it falls back to the commit
  subjects since the **previous** tag, and with no previous tag to the whole
  history.
- "Previous tag" means the nearest version-shaped tag (`X.Y.Z` or `vX.Y.Z`, or
  the same prefix as `--tag`) other than this version. Floating tags such as
  `production` are ignored; they sit on the release commit and would empty the
  range. For a final release, pre-release tags are skipped too, so `0.2.0` is
  described from `0.1.0`, not from `0.2.0-rc.1`; a pre-release is described
  from the nearest version tag of either kind.
- A clone with no tags other than the release tag gets the whole history and a
  warning, because from inside the clone a first release and tags that were
  never fetched look the same.
- Without `--tag`, whichever of `X.Y.Z` and `vX.Y.Z` exists is used.
- The commit fallback needs full history. In a shallow clone it exits 1 and
  says so; use `fetch-depth: 0` with `actions/checkout`. A CHANGELOG section
  needs no history.
- `--changelog` is relative to `--repo`; `--output` is relative to the current
  directory.
- It says on stderr which of those it used, and when there is genuinely nothing
  to report it names the version and the source rather than printing a bare
  placeholder. `* No changes listed.` was indistinguishable from a range computed
  wrongly, and for years it was always the latter.
- Prefer `--output`: a release body should reach `gh` or an action through a file
  (`body_path:`), not through an interpolated string.

Normalize and evaluate a Gitleaks SARIF report:

```bash
./scripts/ci_gitleaks_report.sh \
  --output results.sarif \
  --requested-output test/tmp/results.sarif \
  --fail-on-findings true
```

Run the Pimcore bundle CI helper locally:

Use a compose file from the consuming repository; `test/docker-compose.yml` below is a caller-side placeholder.

```bash
./scripts/ci_pimcore_bundle_check.sh \
  --compose-file test/docker-compose.yml \
  --bundle-src . \
  --db-service db \
  --php-service php \
  --out-dir test/tmp
```

Run the WordPress plugin CI helper locally:

Use a compose file from the consuming repository; `test/docker-compose.yml` below is a caller-side placeholder.

```bash
./scripts/ci_wp_plugin_check.sh \
  --compose-file test/docker-compose.yml \
  --plugin-slug my-plugin \
  --plugin-src . \
  --wpcli-service wpcli \
  --wordpress-service wordpress \
  --db-service db \
  --out-dir test/tmp
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

macOS, iOS and bash 3.2
-----------------------

Stock macOS runs bash 3.2 as `/bin/bash`. Every module here works on it; see the
README for the exceptions and for how `./dev` selects a newer bash when one is
installed.

### Verifying portability without a Mac

```bash
make test-bash32                 # whole suite under a real bash 3.2 (Docker)
bash scripts/local_test_bash32.sh --test tests/help_test.sh
bash scripts/local_test_bash32.sh --shell   # poke around in bash 3.2
bash tests/portability_test.sh   # static scan; also runs as part of `make test`
```

`tests/portability_test.sh` fails the build on GNU-only utilities and bash-4-only
syntax. The failures it prevents are the silent kind: BSD `grep` does not reject
`\s`, it just never matches, and an associative array on bash 3.2 becomes an
indexed one and returns plausible nonsense.

### The `ios` preflight stack

`preflight` detects an `ios` stack for a Flutter project that has an `ios/`
directory or a `Podfile`, and runs `scripts/ci_ios.sh` against it. The stack
directory is the Flutter project root, not `ios/`.

```bash
./dev preflight                  # includes the ios stack on macOS
bash scripts/preflight.sh --list # show detected "<stack><TAB><dir>" pairs
bash scripts/preflight.sh --stack ios
```

Off macOS, or without Xcode, the iOS checks report `SKIP` with a reason rather
than failing — a skip is reported separately so it cannot be mistaken for a
pass. The Flutter stack no longer builds an APK unconditionally either: without
an `android/` directory or an Android SDK it skips that step, so a Mac set up
only for iOS work is not asked for the Android toolchain.

`--quick` skips the iOS stack entirely, and says so. Its analyze and test steps
belong to the flutter stack for the same directory, so the build is the whole
of what the iOS step does — and `--quick` is defined as skipping builds. The
old behaviour ran `ci_ios.sh` with every step disabled and still reported a
passed "ios build", which is a claim about a build that never happened.

### Deploying to an iOS simulator

```bash
./dev deploy ios                   # build for the simulator, install, launch
./dev deploy ios --device <udid>   # when more than one simulator is booted
./dev run ios                      # flutter run against a booted simulator
./dev build ios --release          # signed IPA when IOS_EXPORT_OPTIONS_PLIST is
                                   # set, an unsigned .app when it is not
```

A debug `deploy ios` builds with `flutter build ios --simulator`; a plain
`flutter build ios` targets a physical device and produces an `.app` that
`simctl install` cannot use. With no simulator booted, or with more than one and
no `--device`, it fails with a message naming the fix rather than guessing.

The two modes are not interchangeable. `--release` builds a signed `.ipa` and
installs it through `devicectl` onto an **attached device**, so it resolves an
attached device rather than a simulator, and stops at installed — `simctl
launch` has no devicectl equivalent that works without a debug session. A debug
deploy targets a booted **simulator**.

`build` and `deploy` differ on the plist deliberately. `build ios --release`
without one is fine: `ios_build_release` falls back to `flutter build ios
--release --no-codesign`, and an unsigned `.app` is a legitimate build output.
Installing one is not, so `IOS_EXPORT_OPTIONS_PLIST` is **required** for
`deploy ios --release`, and is checked before the build starts. Without that
check the same fallback runs, writing an unsigned `.app` and nothing under
`build/ios/ipa` -- so the install step picked up an `.ipa` left by an earlier
signed build and pushed that stale binary to the device, with every step
reporting success.

Set `IOS_EXPORT_OPTIONS_PLIST` for a signed release build, and `IOS_DEVICE` to
pin a simulator without passing `--device` each time.
