# Changelog
## 2026-09-10 — 0.24.1

### Changed

- **Three Dependabot action bumps, in one release.** `actions/deploy-pages`
  5.0.0 → 5.0.1 (#157), `softprops/action-gh-release` 3.0.2 → 3.0.3 (#158),
  `docker/setup-qemu-action` 4.2.0 → 4.3.0 (#159). One of them needed a
  hand: Dependabot moved `setup-qemu-action`'s SHA to 4.3.0 but left the
  inline comment saying `v4.2.0 @ 2026-07-01`, and the SHA pin audit resolves
  the *annotated* ref — merged as written, the release gate that 0.24.0 added
  would have failed on the next merge to `main`. The comment now names the
  version the SHA is.

## 2026-09-09 — 0.24.0

### Changed

- **The Tauri workflows default to `ubuntu-24.04`.** All three named
  `ubuntu-22.04`, and the reason recorded next to them was backwards:

  > Runner label — ubuntu-22.04 required for Tauri v2 WebKit ABI

  and, in `docs/workflows.md`, *"required for Tauri v2 WebKit2GTK ABI
  compatibility — ubuntu-24.04 breaks it"*. It is **v1** that needs
  `webkit2gtk-4.0`, which Ubuntu removed in 24.04. **v2** links `4.1` — which
  is what these workflows' own apt step already installs, and what 24.04
  ships. The pin was holding jobs on an older image so they could install
  libraries the newer image has.

  Verified before changing it, by compiling a Tauri v2 app on a 24.04 machine
  rather than by reading the docs that were wrong.

  The 22.04 runner image has a finite life, and nothing in the fleet was
  tracking that.

- **`build-linux` sets `APPIMAGE_EXTRACT_AND_RUN=1`.** This is the one place
  the two images actually differ for a Tauri build. The 22.04 image shipped
  `libfuse2`; 24.04 does not (it became `libfuse2t64`) and additionally sets
  `kernel.apparmor_restrict_unprivileged_userns=1` — either alone stops an
  AppImage mounting itself, which is what `linuxdeploy` and `appimagetool` do
  by default. With the variable set they extract and run instead, needing
  neither FUSE nor a package whose name 26.04 will change again. Tauri's
  bundler sets this itself today (`tauri-bundler 2.9.4`,
  `linuxdeploy.rs:191`) — measured: a Tauri v2 app bundled on a 24.04 machine
  with `apparmor_restrict_unprivileged_userns=1` both with and without the
  variable. So this is a guarantee, not a fix: it pins in the workflow what a
  dependency currently chooses to do, and nothing in this repository ever runs
  a Tauri workflow to notice if that choice changed. The consumer that would
  notice publishes AppImages to a public dist repo.

- **`rust-cache` on `build-linux` keys on the runner label.** `-sys` crates
  compile against the image's C libraries; a cache built on one Ubuntu and
  restored on the next is a successful restore followed by a link error.

- **Docs stop calling it a matrix.** `tauri-release.yml` runs three independent
  jobs; there is no `matrix.os` to override, and the Linux runner is the
  `runner` input. Two input descriptions that repeated "Runner label." are
  fixed — they render verbatim in GitHub's workflow UI. `README.md` gains a
  *Runner floor* note, the only top-level statement of what this repository
  assumes about Ubuntu.

- **Known and left alone:** `ppa-deb.yml` falls through to the vendored
  script-helpers' `DEB_SERIES="jammy"` when `series` is empty, so a 22.04
  codename survives in the PPA path. Changing that default silently changes
  *what distro consumers publish for*, which is a decision to make upstream
  on purpose and re-vendor — not a side effect of a runner bump.

### Fixed

- **`security-weekly` had failed every Monday since 2026-08-17.** The SHA Pin
  Audit found twenty pins behind the ref they annotate and exited 1, and
  nothing else on the release path runs that check. Refreshed with
  `update_pinned_actions.sh`; `--check` reports 46 up-to-date, 0 stale. (#152)

- **The security gate never ran on the automated release path.**
  `production-branch.yml` triggers on a tag push, but the tag is pushed by
  `GITHUB_TOKEN`, which does not fire workflows — so `production` has advanced
  without a stale-pin or floating-ref check since the automation landed.
  `auto-tag-release-push.yml` now runs both checks in a `gate` job before the
  tag is cut. `docs/usage.md` also stopped claiming `create_production.sh` does
  not move the `production` branch; it does, unless `--no-branch`.

- **`tauri-release.yml` referenced its own `winget-submit.yml` at
  `@production`.** A consumer pinned to a tag was getting whatever `production`
  pointed at for that one job. Relative now, so it resolves at the consumer's
  pinned ref.

- **`[ -f src/*Bundle.php ]` in `php-scan.yml` only worked with exactly one
  bundle** — with none the glob stays literal, with several `-f` gets more
  than one argument and errors out, so Pimcore detection by that route was
  unreliable at both ends. A loop sees each match. Found by actionlint
  (below); with it, five
  more shellcheck warnings: three `local x=$(…)` masking exit codes under
  `set -e`, a `trap` expanding at definition rather than on signal, and
  `export GPG_TTY="$(tty)"` in `ppa-deb.yml` — which, split as shellcheck
  asks, would have aborted every run (no terminal, `tty` exits 1), and with
  `|| true` would have exported the literal string `not a tty`. The block is
  **removed**: the export could not reach the build step anyway, and signing
  uses loopback pinentry, which never asks a terminal.

- **`APPLE_PASSWORD` is accepted as an alias of `APPLE_APP_PASSWORD`** in
  `tauri-release.yml`, since it is the name most consumers already hold. (#97)

- **`pnpm-pages.yml` used a bare `pages-<ref>` concurrency group**, the obvious
  name a caller would also use — leaving these jobs queued behind the run that
  started them. Prefixed, as `pages.yml` already was. (#133)

- **Two changelog entries named private repositories.** Cited by code now, per
  the convention for anything that lands in a public repository.

### Added

- **actionlint runs on every PR**, pinned by image digest so nothing new enters
  the SHA pin audit, with shellcheck at warning and above — an error or a
  warning in a `run:` block is a bug; a style note is a review comment.
  `check_workflow_yaml.py` proves a file parses; it does not know a runner
  label from a typo or an expression from a string, which is how a
  startup-failure bug shipped through a green PR. `.github/actionlint.yaml`
  teaches it `macos-15-intel`, a real label its list lags behind. (#134)

- **Every job that runs on a runner has a `timeout-minutes`.** Fifty-seven had
  none, so a hung job billed to GitHub's six-hour default. By workload: 120
  for release, build, deploy and packaging jobs (the Tauri, Flutter, Rust,
  Go, FPC, Docker, deb/rpm/PPA/Homebrew builders); 30 for scans, checks,
  lints and tagging; 60 for the rest; and two set by hand — the YAML and
  actionlint checks at 10, the new release gate at 15. Six workflows already
  took a caller-owned `timeout_minutes` input and keep it. Jobs that call a
  reusable workflow cannot carry one and are unchanged. (#132)

- **`tauri-release.yml` takes a `runner` input**, as `tauri.yml` and
  `tauri-scan.yml` already did. It was the one Tauri workflow a consumer could
  not override — and the wrong one to hardcode, being the workflow that
  produces release artefacts. Consumers pinned to an older image now have a
  way out that is not a fork.

## 2026-09-06 — 0.23.0

### Changed

- **`vendor/script-helpers` updated from 0.14.0 to 0.24.0.** The vendored tree now matches script-helpers at tag `0.24.0` (`1bb1977`), which is where the `production` branch points, except for the excluded paths below.

  The three scripts these workflows actually invoke — `build_deb_artifacts.sh`, `build_rpm_artifacts.sh` and `ppa_upload.sh` — are **unchanged across the whole 0.14.0 → 0.24.0 span**, so no packaging behaviour moves with this bump. What arrives is the rest of the library: new modules (`adb`, `android`, `changelog`, `flutter`, `git_branches`, `gradle`, `hub`, `ios`, `manifest`, `screencap`, `serve`, `svg`, `docker_install`) and their docs, available to future work rather than used today.

- **`sync_script_helpers.sh` no longer vendors upstream's `.github/`.** GitHub only runs workflows at the repository root, so a copy under `vendor/` could never execute — but it *did* reference this repository's own reusable workflows back:

  ```
  vendor/script-helpers/.github/workflows/release.yml:
    uses: nikolareljin/ci-helpers/.github/workflows/create-github-release.yml@production
  ```

  A vendored, stale, non-executing second definition of our own CI is worse than nothing: it reads as authoritative and it inflates every sync diff. Four files removed, and the exclusion list is now explicit in the sync script so re-syncs stay clean.

  The drift check in `security-weekly.yml` compares the recorded upstream SHA, not file content, so excluding a path does not make it report drift.

- **`pr-gate.yml` and `release-tag-gate.yml` now check out `check_release_tag.sh` at `1bb1977` (0.24.0)** instead of `3d70d24`, a commit from 2026-04-11. This picks up a real fix: the old revision swallowed a failed tag fetch with `|| true`, so the release-tag gate could evaluate against stale tags and pass when it should not. The new revision fails loudly instead, and adds an optional `--remote`. Both call sites pass only `--branch`, `--repo`, `--fetch-tags` and `--print-version`, all still accepted.

- **`scripts/verify_vendor.sh` proves the vendored copy still works, and runs on every pull request** (`vendor-check.yml`). Syncing is a file copy: it cannot tell you that a module `scripts/` imports went away upstream, or that an excluded path crept back in. The check derives the required module list from the `shlib_import` lines in `scripts/` rather than hard-coding it, imports them the way a real caller does, and runs `--help` on every script that depends on the vendored tree.

  Currency is checked too, but the pull-request job passes `--offline`: an upstream release should not turn every open pull request red for a reason unrelated to the change under review. `security-weekly.yml` already fails once a week when the copy falls behind, which is the right cadence for that.

  Each guard was verified to fail when it should — a reintroduced `.github`, a missing imported module, and a stale recorded SHA each make it exit 1.

- **`version_bump.sh` accepts `--help`, not only `-h`.** Every other script here takes both; this one fell through to the argument error and exited 1 while printing correct help.

### Known issues

- **The vendored tree carries an upstream data-loss bug in `scripts/install_dev_cli.sh`.** Its `--shims` backup is an unconditional `mv "$dest" "$dest.pre-dev-cli"`; on a second run `$dest` is the shim the previous run wrote, so re-running replaces the caller's original script with the generated shim. Reproduced, and fixed upstream in nikolareljin/script-helpers#58 — this repository will pick the fix up on the next vendor sync.

  Deliberately **not** patched here. `vendor/script-helpers` tracks upstream verbatim apart from a declared exclusion list; a local edit to a vendored file is a different thing entirely — it would be silently reverted the next time `sync_script_helpers.sh` runs, and would leave the recorded SHA claiming content that is not there. ci-helpers does not invoke this script, so the defect is dormant here.

### Notes

- **`wp-plugin-check.yml` and `pimcore-bundle-check.yml` deliberately stay pinned at `3d70d24`.** `ci_wp_plugin_check.sh` and `ci_pimcore_bundle_check.sh` **dropped `--php-version`** after that commit, and both scripts exit 2 on an unknown argument. Since both workflows pass `--php-version "${{ inputs.php_version }}"`, moving those pins would hard-fail every caller. Rewiring the `php_version` input belongs in its own change, not in a vendor sync.

## 2026-09-03 — 0.22.1

### Fixed

- **`rpm-build.yml` builds again.** `rpmbuild`'s `_topdir` has to be absolute, and the workflow passed `working_directory` into it unchanged. On the default `"."` that made `_topdir` relative, `%prep` resolved `_builddir` to an absolute `/packaging/rpm/build/BUILD` that does not exist, and the build died:

  ```
  error: Bad exit status from /var/tmp/rpm-tmp.r7Qq1N (%prep)
  ```

  A caller cannot fix this from the outside, which is worth showing rather than asserting. Passing `${{ github.workspace }}` as `working_directory` produced:

  ```
  [ERROR] Spec file not found (use --spec): /packaging/isoforge.spec
  ```

  That is `repo=""` with `packaging/isoforge.spec` appended, so the expression reached the workflow as an empty string. The explanation is that a reusable workflow's `with:` block is evaluated in the caller's workflow context, where no runner and therefore no workspace exists yet. Note this is specific to `jobs.<id>.with` on a `uses:` call — `${{ github.workspace }}` in a step, as `release-tag-check.yml` uses it, runs on a runner and resolves normally.

  The step already runs in the requested directory, so it now takes the path from `pwd`. Callers keep passing `working_directory` as before, absolute or relative, and both work. Nothing about the input's meaning changes.

### Known issues

- **`deb-build.yml`'s default `artifact_glob` cannot be uploaded.** It is `../*.deb`, matching where `dpkg-buildpackage` puts its output, but `upload-artifact` rejects the path outright:

  ```
  ##[error]Invalid pattern '../*.deb'. Relative pathing '.' and '..' is not allowed.
  ```

  Every caller that does not override it builds a package and then fails on the upload. Until the default moves the artifacts into the workspace, a caller works around it with:

  ```yaml
  build_command: "dpkg-buildpackage -us -uc && mkdir -p dist && mv ../*.deb dist/"
  artifact_glob: "dist/*.deb"
  ```

  Fixing the default belongs in `build_deb_artifacts.sh`, which is where the output location is decided, so it is left for a change that can move both together.

## 2026-09-02 — 0.22.0

### Added

- **`pimcore.yml` tests several PHP versions, and which ones is up to the caller.** It now defaults to `["8.3", "8.4"]` and accepts any JSON array — versions are not checked against an allow-list, so a bundle on an older or newer PHP line uses the same preset:

  ```yaml
  with:
    php_versions: '["8.1", "8.2", "8.3", "8.4"]'
  ```

  Each version runs as its own matrix leg. The input is a JSON array because a reusable workflow's inputs are strings and cannot be used as a matrix directly; it is resolved into one in a small preceding job, which also fails loudly if the value is not a non-empty array — an empty matrix expands to a skipped job, which reads like a pass.
- **`php_version` (singular) still works and now overrides `php_versions`**, so a caller wanting exactly one version does not have to write a one-element array. Its default changed from `"8.4"` to `""`, meaning "not overridden"; callers who relied on the old default now get 8.3 and 8.4 instead of 8.4 alone.
- **The selected PHP version now reaches the Docker stack.** `php_version` previously configured only the optional standalone (host) PHP; the containers were built from the compose file, which could not see it, so every leg of a would-be matrix would have tested the same PHP. `pimcore-bundle-check.yml` now publishes the version to the environment as `PHP_VERSION` — the variable name is the new `php_version_env` input, and setting it to `""` exports nothing — so a compose file can interpolate it as a build argument.

- **`scripts/check_workflow_yaml.py` and a `workflow-yaml-check` workflow.** Everything under `.github/workflows` and `.github/actions` is consumed by other repositories, so a file that does not parse is a broken release for everyone pinned to it — and nothing checked. This repository's own PR gate is a release-tag check and a secret scan, neither of which reads the files it ships, which is how the `wp-plugin-check` breakage above went unnoticed. The script parses all 78 workflow and action files and annotates failures with `::error file=`; it fails on the pre-fix `wp-plugin-check` and passes on the fix. It also runs in the tracked `.githooks/pre-commit` hook, alongside `check_release_version.sh`, so the failure is caught at commit time rather than in CI. It also covers `.github/dependabot.yml`, where a malformed file fails nothing visibly — GitHub simply stops opening update pull requests, which looks the same as having nothing to update. It treats an unreadable or non-UTF-8 file as a failure rather than dying on it, and collapses the parser's message to one line — workflow commands are line-based, so a multi-line message truncates the `::error` annotation and spills the rest into the log.
- The new `resolve-versions` job carries `timeout-minutes`, so a hung resolve cannot bill to GitHub's six-hour default (the reason `release-tag-check` sets one).

### Changed

- **The `pimcore-bundle-check` composite action gained `php_version_env` too**, so the action and the reusable workflow behave the same way. Previously only the workflow exported the version, and a repository calling the action directly would have had `php_version` affect the standalone steps while the Compose stack silently built its own default. Its description no longer says "Pimcore 11" — it is not version-specific.

- `pimcore.yml` calls `pimcore-bundle-check.yml` through a **relative** `uses:`, so the child comes from this repository at whatever ref the consumer pinned. It previously pinned the child to `@production`, which would have handed a consumer testing a release branch the previous version of the child — and with this change that means a version input the child does not yet understand.
- The preset's header no longer says "Pimcore 11"; it is not version-specific.
- **An explicitly empty `php_versions` now fails instead of falling back.** The input defaults to a non-empty array, so an empty value means the caller passed one — usually an unset variable — and substituting the default quietly would hide that. It falls through to validation and fails with a message naming the expected shape. This also keeps the default in one place, the input declaration, rather than repeating it in the resolver.

### Fixed

- **`wp-plugin-check/action.yml` was not valid YAML and had shipped that way.** Its two heredoc bodies — the `wp-cli.yml` config and the `python3 - <<'PY'` findings check — were written at column 0 inside an indented `run: |` block. A block scalar ends as soon as indentation drops below its own, so the document was malformed from the `WPCLI` line onward; PyYAML and Ruby's Psych both refuse it. `docs/actions.md` and `docs/usage.md` point consumers at this action. Fixed by re-indenting both bodies to their step's indentation, which YAML strips straight back off — the emitted shell and Python are byte-identical, and the diff is provably whitespace-only.

- **`$GITHUB_ENV` writes are validated before they happen.** `php_version_env` and `php_version` are both caller-controlled, and were written as a bare `NAME=VALUE` line. A name containing `=` or whitespace, or a value containing a newline, would have appended extra entries — a value of `8.4\nSECRET_INJECTED=yes` set a second variable. The name is now checked against `^[A-Za-z_][A-Za-z0-9_]*$`, newlines in the value are rejected outright, and the write uses the heredoc form with a unique delimiter. This matches how `ci.yml` already validates `db_env`.
- **The matrix value is JSON-safe and always single-line.** `php_version` was interpolated into `["${PHP_VERSION}"]` without escaping, so a value containing a quote produced malformed JSON; it is now built with `jq --arg`. A pretty-printed `php_versions` array passed the old check but wrote a multi-line `$GITHUB_OUTPUT` value that `fromJSON` could not read, so the value is now compacted with `jq -c`. The check also requires every element to be a non-blank string, rather than only that the array is non-empty.

### Documentation

- **The Pimcore preset is documented for the first time.** It shipped undocumented: `docs/presets.md`, `docs/workflows.md` and `docs/examples.md` had no mention of `pimcore.yml` at all. Added a preset section covering how to choose PHP versions (`php_versions` for a list, `php_version` for exactly one, and that any versions may be passed), reference entries for `pimcore.yml` and `pimcore-bundle-check.yml`, and a worked multi-version example.
- **`docs/actions.md` now documents the `pimcore-bundle-check` composite action.** It was the only action in `.github/actions/` missing from that reference.
- The docs spell out the part that is easy to get wrong: setting a version is only half of it. The checks run inside the caller's compose stack, so the version is exported as `PHP_VERSION` (configurable via `php_version_env`) and **the compose file must consume it as a build argument** — otherwise every matrix leg builds the same image and the run reports version coverage it does not have. Both the compose and Dockerfile snippets are given.

### Dependencies

- `actions/setup-java` 5.7.0 → 6.0.0 (6 call sites), `securego/gosec` 2.28.0 → 2.29.0, and `github/codeql-action/upload-sarif` 4.37.8 → 4.37.9 (2 call sites) — folding in the open Dependabot pull requests so this release does not ship behind them. `gosec`'s trailing version comment is corrected to `v2.29.0`; Dependabot's own patch bumped the pinned commit but left the comment reading `v2.28.0`.


## 2026-09-01 — 0.21.3

### Changed

- **The Homebrew example names the renamed IsoForge repository.** `nikolareljin/burn-iso` is now `nikolareljin/iso-forge`, so the `homepage` and `release_repo` inputs in the `homebrew-package.yml` example in `docs/workflows.md` would have sent a reader to a redirect and named a repository that no longer exists under that name.

## 2026-08-24 — 0.21.2

### Fixed

- **RPM and Homebrew packaging helper scripts no longer require executable bits.** The reusable workflows invoke the helper scripts through Bash, so a caller whose script-helpers checkout retains non-executable file modes no longer fails with exit 126, and subdirectory callers resolve helpers from their configured working directory.


## 2026-08-24 — 0.21.1

### Fixed

- **Refreshed the audited GitHub Action pins.** `actions/checkout` advances to
  v7.0.1, `github/codeql-action/upload-sarif` to v4.37.8, and
  `docker/setup-buildx-action` to v4.3.0. The moving `master` ref for Trivy
  advances to its verified current commit, and gosec to its current stable
  v2.28.0 release. The Trivy composite-action pin is refreshed
  alongside its workflow callers, so
  the SHA-pin gate again reports no stale references. No workflow interface or
  caller configuration changes.

## 2026-08-09 — 0.21.0

### Added

- **`pages-build.yml` and `pages-deploy.yml` — the Pages preset in two callable
  halves (#137).** `pages.yml` contains both a build and a deploy, and GitHub
  validates a called workflow's declared permissions when the run starts, before
  any job-level `if:` is evaluated. Every caller therefore had to grant
  `pages: write` and `id-token: write` on *every* event it handled, including
  pull requests, where `deploy: false` means nothing is published — so the build
  ran pip, npm postinstall and generator plugins with deploy-capable scopes live
  and nothing to deploy.

  A caller can now build with `pages-build.yml` and deploy with
  `pages-deploy.yml` as two jobs, granting write only on the second. On a pull
  request the deploy job is skipped, its token is never minted, and the run holds
  no write scope anywhere. `pages-deploy.yml` checks out nothing and builds
  nothing, so those scopes are only ever live in a job that runs no third-party
  code.

  Measured against real runs rather than inferred: `pages-build.yml` succeeds on
  `contents: read` + `pages: read`, and `startup_failure`s on `contents: read`
  alone — `pages: read` is genuinely required, because Configure Pages reads the
  repository's Pages configuration.

  `pages-build.yml` adds two inputs of its own, `upload` and `configure_pages`,
  which `pages.yml` drives from its `deploy` input to keep its own behaviour
  identical.

### Changed

- **`pages.yml` now calls those two workflows instead of carrying the steps.**
  Its inputs, defaults, concurrency group and permission requirements are
  unchanged, and it gains a `page_url` output. Nothing calling it needs to
  change. Verified from a consuming repository at this branch: the single-call
  path builds through two levels of nesting and skips the deploy on
  `deploy: false`, exactly as before.

  A relative `uses:` inside a reusable workflow resolves against *its own*
  repository at the ref the consumer pinned, not against the consumer's
  repository — so `pages.yml@production` gets `pages-build.yml@production` with
  no coordination on the caller's side. Measured, because the alternative
  reading would have made this refactor impossible.

- **`pages-deploy.yml` serialises on `ci-helpers-pages-deploy-<key>`,** not the
  `ci-helpers-pages-<key>` group `pages.yml` uses. A called workflow's group is
  evaluated alongside its caller's, so sharing the name would leave the deploy
  queued behind the run that started it.

## 2026-08-08 — 0.20.1

### Fixed

- **`pages.yml` upgraded pip from PyPI on every run.** The requirements-file
  install path ran `python -m pip install --upgrade pip` before installing
  anything, pulling whatever PyPI served at that moment into the job that builds
  and uploads the published site. Every `uses:` in the preset is pinned to a SHA;
  this one line was the exception, and the only part of the workflow that could
  behave differently between two runs of the same commit. With `python_version`
  set, `actions/setup-python` has already provided a current pip and the upgrade
  bought nothing; without it, the upgrade was mutating the runner image's own
  Python. A caller who needs a particular pip can install it through
  `install_command`, where the version is theirs to pin.

  No input changed and no caller needs to do anything.

- **A `requirements_file` without a `python_version` installed into an
  unspecified Python.** `Setup Python` only runs when `python_version` is set, so
  that combination quietly used whichever interpreter the runner image ships — a
  version nobody chose, and one that moves when the image does. It now says so
  with a `::warning::`. Not a failure: it works today, and refusing it would
  break callers already relying on it.

### Changed

- **Refreshed every floating-ref action pin.** The third-party actions tracked at
  a moving ref — `dtolnay/rust-toolchain` (`stable`), `swatinem/rust-cache`
  (`v2`), `aquasecurity/trivy-action` (`master`), `snyk/actions/docker`
  (`master`), `securego/gosec` (`master`) — were pinned to SHAs between two and
  five weeks old across 14 workflow and action files. All are advanced to the
  current head of the ref each one names, and each new SHA was verified against
  the upstream ref rather than taken on the updater's word. `scripts/update_pinned_actions.sh --check`
  reports 47 up to date, 0 stale.

## 2026-08-08 — 0.20.0

### Fixed

- **`release-tag-check.yml` ran on every branch and tag creation.** It carried a
  `branches:` filter on the `create` event. GitHub does not support one there
  and ignores it silently rather than rejecting it, so the filter did nothing
  and the check started on every branch and tag created in a consuming
  repository. The `create` trigger is kept — a branch made through the web UI or
  the API fires `create` and no `push`, so dropping it would stop checking
  exactly the release branches nobody made from a terminal — and is now filtered
  in the job, where an expression works. The job also gained a
  `timeout-minutes`.

### Added

- **`pages.yml` — a stack-agnostic GitHub Pages preset.** Builds a static site
  with whatever generator a repository uses and deploys it: MkDocs, Sphinx,
  Hugo, Astro, or a plain `cp -r`. Until now the only Pages publisher was
  `pnpm-pages.yml`, which carries pnpm-workspace and Playwright capture
  behaviour that does not generalise, so every non-pnpm repository hand-rolled
  its own build-and-deploy pair.

  Inputs: `python_version`, `node_version`, `requirements_file`,
  `install_command`, `build_command`, `pages_path`, `deploy`,
  `working_directory`, `concurrency_key`, `fetch_depth`, `runner`,
  `require_entry_file`, `artifact_retention_days`, `timeout_minutes`.

  `build_command` is optional: leaving it empty publishes a directory already
  committed to the repository, so a plain HTML site needs no toolchain and no
  placeholder command. Closes #127.

  The concurrency group is namespaced `ci-helpers-pages-<key>`. A called
  workflow's group is evaluated alongside the caller's, so a caller using the
  obvious bare `pages-<ref>` name — which most hand-rolled Pages workflows
  already do — would leave the called jobs queued behind the run that started
  them.

  Two failure modes are handled deliberately, because both produce a green run
  that publishes nothing useful:

  - `pages_path` must be relative and must not climb above
    `working_directory`. The value is normalised first, so `.`, `./`, `./.`,
    `.//` and `a/./b` are all judged as what they resolve to. Publishing the
    root of `working_directory` is allowed and warns.
  - The build fails if `pages_path` is missing, or contains no files, so a
    generator that silently produces nothing cannot replace a working site with
    an empty one. The check looks for a file rather than any entry, because a
    tree of empty directories is not a site.
  - It also fails when there is no `index.html` or `index.htm` at the root of
    `pages_path`, because such a site deploys successfully and then serves 404
    at its own address. `require_entry_file: false` opts out.
  - `working_directory` is held to the same rules as `pages_path` — relative, no
    climbing out of the checkout, must exist — rather than failing several steps
    later with a message about whichever command ran first.

  `deploy: false` builds without publishing — pass
  `${{ github.event_name != 'pull_request' }}` to validate a site on every pull
  request and publish only from the default branch. Note that the caller must
  grant `pages: write` and `id-token: write` **even when `deploy` is false**:
  GitHub validates a reusable workflow's declared permissions at run start,
  before any job-level `if:` is evaluated.

  `actions/configure-pages` runs before the build on deploying runs and exports
  `PAGES_BASE_URL`, `PAGES_ORIGIN` and `PAGES_HOST` to `build_command`, for
  generators that need the site's own address. It is skipped when `deploy` is
  false, so a repository validating its site on pull requests before enabling
  Pages fails on its own site rather than on the Pages API.

  All third-party actions are pinned to commit SHAs, matching the rest of the
  repository.

## 2026-08-04 — 0.19.2

### Security

- **Every third-party action is pinned to a commit SHA (supply chain):**
  42 workflow and action files referenced actions by moving tag —
  `actions/checkout@v7`, `actions/setup-java@v5`, `dorny/test-reporter@v3`,
  `github/codeql-action/upload-sarif@v4`, `subosito/flutter-action@v2`,
  `shivammathur/setup-php@v2`, `ruby/setup-ruby@v1` and others. A tag is
  mutable: whoever controls the upstream repository, or anyone who compromises
  it, can move `@v7` to different code and every consumer picks it up on the
  next run without a diff anywhere.

  All 30 external references now pin a 40-character commit SHA with the
  resolved version in a trailing comment, so upgrades are explicit and
  reviewable:

  ```yaml
  uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  ```

  `nikolareljin/ci-helpers/...@production` references are deliberately left on
  the floating tag: that is this repository's own release channel, and pinning
  it would defeat how consumers receive updates.

### Fixed

- **`flutter-release.yml` — a channel name was passed where a version belongs (found in R-588):**
  `flutter_version` defaulted to `stable` and was forwarded verbatim to
  `subosito/flutter-action` as `flutter-version`, which expects a version
  number. Every caller relying on the default failed in seconds with:

  ```
  Unable to determine Flutter version for channel: stable version: stable
  ```

  The job died before checkout finished, so it read as an infrastructure
  failure rather than a workflow defect. `ci.yml`, `pr-gate.yml` and
  `release-build.yml` already defaulted to `""`; only this workflow did not,
  which is why the problem stayed hidden.

  The default is now `""`, and the Flutter setup is split into the same
  version-or-channel pair those workflows already use. Callers that explicitly
  pass a channel name as `flutter_version` — which the old default actively
  encouraged — are now treated as "no version pin" instead of failing, and the
  channel they named is honoured as the channel. The guard covers every Flutter
  channel (`stable`, `beta`, `dev`, `master`, `main`) via a list, so it cannot
  miss one.

  To pin an exact SDK, pass a version number: `flutter_version: "3.44.7"`.
  To track a channel, leave `flutter_version` unset and use `flutter_channel`.

## 2026-08-03 — 0.19.1

### Fixed

- **`ci.yml` — parallel callers no longer cancel each other (#125):**
  The concurrency group was `ci-helpers-ci-${{ github.workflow }}-${{ github.ref }}`.
  A caller invoking this workflow from more than one job at once — backend and
  frontend, or one job per module — put every such job in the *same* group,
  and `cancel-in-progress: true` made whichever started second destroy the
  first. The victim reported `cancelled` after 0 seconds with no steps, so it
  read as an infrastructure hiccup rather than lost coverage, and cancelled
  runs are grey rather than red so nothing alerted.

  Introduced in 0.19.0 (ff0fd2d) and inherited by all thirteen presets that
  delegate here: `csharp`, `cypress`, `docker`, `go`, `java`, `java-gradle`,
  `kotlin`, `node`, `php`, `playwright`, `python`, `react`, `rust`. Observed
  in R-185, whose `main` had no complete CI run for three days:
  the `python` and `node` legs killed each other on every push.

  The group now includes the working directory, which already distinguishes
  the common case of one job per component and needs no change from callers.
  A new optional `concurrency_key` input overrides it for callers whose jobs
  share a directory — matrix legs, most often — and is forwarded by all
  thirteen presets.

- **`pr-gate.yml` — the same collision, found in review (#125):**
  `pr-gate.yml` does not delegate to `ci.yml`; it carries its own
  concurrency block, keyed the same wrong way. Four repositories in the
  fleet call it twice from a single workflow file and were losing half
  their gate on every pull request. Fixed identically, and it now accepts
  `concurrency_key` too.

### Changed

- **`docker-multiarch.yml` — `docker/login-action` 4.5.1 → 4.6.0 (#124):**
  Folded in from the Dependabot branch. Its version comment still read
  `v4.5.1` after the SHA moved, which is the one thing a pinned-SHA comment
  exists to tell you; corrected to `v4.6.0`.

## 2026-07-31 — 0.19.0

### Added

- **`timeout_minutes` input on `ci.yml`, `pr-gate.yml`, `release-build.yml`, `kotlin.yml`,
  `java-gradle.yml` and `flutter-release.yml`.** Before this, `timeout-minutes` appeared
  **nowhere** across the reusable workflows, so a hung job billed until GitHub's six-hour
  cap. Defaults are 20 minutes for the CI and gate workflows, 30 for `release-build.yml`,
  and 60 for `flutter-release.yml` — higher there because a cold Flutter plus fastlane
  build is slow and because that workflow can run on a macOS runner at a 10x minute
  multiplier, which is exactly where an unbounded hang is expensive. Every value is an
  optional input with a default. Callers whose jobs fit that default need no change; longer
  jobs must pass a higher `timeout_minutes`. `kotlin.yml` and
  `java-gradle.yml` pass theirs through to `ci.yml`.
- **`concurrency` with `cancel-in-progress: true` on `ci.yml` and `pr-gate.yml`.**
  Previously `concurrency` appeared in exactly one workflow (`pnpm-pages.yml`) and was set
  to `false`, so a rapid series of pushes each ran to completion. The group is keyed on the
  caller workflow and ref so unrelated workflows and branches within a repository never
  cancel each other.
- `docs/presets.md`: an Android note on the Kotlin preset. `./gradlew test` may be a
  no-op or run broader variant tests depending on the project; `testDebugUnitTest` runs
  debug unit tests explicitly.

### Changed

- **`docs/private-repo-ci-strategy.md` rewritten around a release-only floor.** The
  document already prescribed the right three-layer model and already identified nine
  consuming repos running 2x CI per push; it was prose and nothing changed. It now leads
  with Layer 0 — stack-specific local CI commands and a blocking pre-push hook from
  `script-helpers` — and
  recommends that a single-maintainer private repo keep only tagging and release workflows
  on the server, with the three-layer model documented as what to return to when a repo
  gains a second contributor. Adds the macOS 10x and Windows 2x multipliers as explicit
  rules, an Android (Gradle) section, and the `gh api` one-liner for measuring where a
  repo's minutes actually go.

### Security

- `docs/private-repo-ci-strategy.md` no longer names specific consuming repositories. This
  repository is public, and the table of repos needing the double-trigger fix disclosed the
  names, stacks and CI weaknesses of private ones. Replaced with the commands to detect the
  same condition in any repo.

## 2026-07-27 — 0.18.0

### Added

- **`auto-tag.yml` — a tag-only, least-privilege release workflow.** It does exactly
  what `auto-tag-release.yml` does for tagging (detect the merged `release/X.Y.Z` PR,
  create+push the tag, move the floating `production` tag) but omits the dispatch job,
  so it needs only `contents: write` + `pull-requests: read` — **no `actions: write`**.
  Consumers that do not use the `release_workflow` auto-dispatch feature should switch to
  it to avoid granting `actions: write`.

### Changed

- **`auto-tag-release.yml` now delegates tagging to `auto-tag.yml`** (single source of
  truth) and keeps only the dispatch job. Its `workflow_call` inputs and `version` output
  are unchanged, so existing callers — including the six that set `release_workflow` — are
  unaffected.

### Security

- **`docker-multiarch.yml`: bump `docker/login-action` v4.4.0 → v4.5.1** (SHA-pinned
  `abd2ef45e78c5afb21d64d4ca52ee8550d9572c7`). Folds in Dependabot PR #120 with a corrected
  pin annotation so the SHA-pin audit stays consistent.

### Fixed

- **Docs/README no longer show the tag-only setup calling `auto-tag-release.yml` without
  `actions: write`.** That example failed at startup with *"requesting 'actions: write',
  but is only allowed 'actions: none'"* (the dispatch job's declared permission is
  validated even though it never runs). Tag-only examples now use `auto-tag.yml`, and the
  `auto-tag-release.yml` docs state plainly that all its callers must grant `actions: write`.

## 2026-07-26 — 0.17.0

### Added

- **`flutter-release.yml`: fastlane `match` support for iOS signing.** New optional
  secrets `match_git_url`, `match_password`, and `match_git_basic_authorization` are
  exposed as `MATCH_GIT_URL` / `MATCH_PASSWORD` / `MATCH_GIT_BASIC_AUTHORIZATION` only on the
  macOS-gated App Store steps (secret masking + the Fastlane upload), never job-wide, so a
  consumer's `ios_release` Fastlane lane
  can sync certificates and provisioning profiles from a private storage repo. This closes the
  gap where iOS deploys had no in-workflow signing path (Android already handled
  keystore signing in-workflow). All three secrets are optional and resolve to empty
  strings when omitted, so existing callers are unaffected.

### Fixed

- **README production-tag drift.** The README hard-coded `Current production tag: 0.14.2`,
  which lagged `VERSION`. It now points to Releases / `VERSION` instead of naming a
  version that goes stale on every release.

## 2026-07-21 — 0.16.2

### Changed

- **Consolidated the two open Dependabot GitHub Actions PRs (#116, #117) into one
  release and fixed the drift Dependabot leaves behind.** #116 bumped the runner
  setup actions and #117 bumped `securego/gosec`; this release applies both and —
  the part Dependabot gets wrong — corrects the human-readable version/date
  trailer on every SHA pin so it matches the commit it annotates:
  - `actions/setup-node` → `v7` (tag-pinned presets) and, in the Tauri workflows,
    the SHA pin advanced to the `v7` tip (`820762786…`) with its trailer corrected
    from a stale `# v6` to `# v7` — Dependabot moved the SHA to the `v7` tip in
    `#116` but left the comment reading `v6`.
  - `actions/setup-dotnet` → `v6`
  - `actions/setup-python` → `v7`
  - `actions/setup-go` → `v7`
  - `securego/gosec` → `master` (`45b083a…`, current tip; supersedes the
    day-older SHA proposed in `#117`)
- **Refreshed every stale SHA pin in one pass via `scripts/update_pinned_actions.sh`,
  fixing the red `security-weekly` workflow.** Its **SHA Pin Audit** job runs that
  same script in `--check` mode and had been failing because pins for
  `dtolnay/rust-toolchain` (`# stable`), `softprops/action-gh-release`, `gosec`,
  and the Tauri `setup-node` had drifted from their annotated refs. All 26 stale
  pins are re-anchored to their current upstream tips (audit: `47 up-to-date,
  0 stale`), so the weekly gate goes green again.

## 2026-07-06 — 0.16.1

### Changed

- **Consolidated Dependabot GitHub Actions bumps (#108–#113):** advanced the
  pinned SHAs for the Docker build stack and the security scanners, and — the
  part Dependabot gets wrong — corrected the human-readable version/date
  trailer on every pin so it matches the SHA it annotates:
  - `docker/setup-qemu-action` → `v4.2.0` (`96fe6ef`)
  - `docker/setup-buildx-action` → `v4.2.0` (`bb05f3f`)
  - `docker/build-push-action` → `v7.3.0` (`53b7df9`)
  - `docker/login-action` → `v4.4.0` (`af1e73f`)
  - `securego/gosec` → `master` (`11023e5`)
  - `aquasecurity/trivy-action` → `master` (`c07df6f`)
- **Fixed a Dependabot pin blind spot:** the `trivy-action` SHA in the
  `trivy-scan` **composite action** (`.github/actions/trivy-scan/action.yml`)
  was left stale by PR #110 — Dependabot only scans `.github/workflows` (its
  `directory: /` scope), not composite actions under `.github/actions`. Updated
  it in lockstep so all four `trivy-action` references share one SHA.

## 2026-06-27 — 0.16.0

### Added

- **`laravel.yml` — new reusable preset for Laravel apps:** builds assets, boots
  a MySQL service, and runs Pint style + the `php artisan test` suite against it.
  Discrete, friendly DB inputs (`db_database`, `db_username`, `db_password`,
  `db_root_password`, `db_port`) are composed into the base DB mechanism for the
  caller; `working_directory` supports apps living in a subdirectory. Use it with
  `uses: nikolareljin/ci-helpers/.github/workflows/laravel.yml@production`.
- **`ci.yml` / `php.yml` — optional, framework-agnostic database service:** new
  `db_image`, `db_env`, `db_ports`, `db_health_cmd`, and `db_wait_seconds` inputs.
  When `db_image` is set, the base job starts the container via `docker run`
  before the command steps (GitHub `services:` blocks can't be conditional in a
  reusable job) and waits on a readiness probe. Leaving `db_image` empty keeps the
  previous DB-less behaviour, so this is backward compatible. Covers general
  PHP + MySQL/Postgres stacks without overloading the Pimcore preset.

## 2026-06-22 — 0.15.0

### Added

- **`fpc-release.yml` — publish the bare Windows `.exe` alongside the `.zip` (#102):**
  The Windows packaging step now also copies the raw `<bin>.exe` to
  `dist/<pkg>.exe` and uploads it as a separate release asset, so consumers
  (PravKal and others) get **both** a clickable standalone `.exe` and the
  `.zip` data bundle, instead of only the zipped exe + data.

### Fixed

- **`fpc-release.yml` — Windows build aborted with `Can't find unit crt` (#102):**
  `FPCDIR` resolution walked up from `fpc.exe` looking only for a Unix-style
  `lib\fpc` landmark, but the Chocolatey `freepascal` package keeps RTL units
  under `<root>\units\<target>`. `FPCDIR` was therefore never set and the
  `fpc.cfg` generation (guarded on it) was skipped, so the driver had no RTL
  search paths. The walk now accepts a `units` directory **or** `lib\fpc` as
  the landmark and widens the search from 5 to 6 directory levels, so `FPCDIR`
  resolves on the Windows package and `fpcmkcfg` produces a working `fpc.cfg`.

### Changed

- **Dependency bumps (Dependabot, #103, #104):**
  - `actions/checkout` `v6` → `v7` across all reusable workflows (and the
    matching SHA pins refreshed).
  - `actions/upload-pages-artifact` `v3` → `v5` and `actions/deploy-pages`
    `v4` → `v5` in `pnpm-pages.yml`.
  - `securego/gosec` pinned SHA advanced to
    `6a008f60b8f7f3d7fae8f126984a9df5d4b7e0cf` in `go-scan.yml`.

## 2026-06-22 — 0.14.7

### Fixed

- **`fpc-release.yml` — Windows `fpc.cfg` generation and Intel macOS coverage (#98):**
  The Chocolatey `freepascal` package ships no `fpc.cfg`, so the `fpc` driver had no RTL
  unit search paths and Windows builds aborted with `Fatal: Can't find unit crt`. After
  resolving `FPCDIR`, the workflow now generates a default `fpc.cfg` with `fpcmkcfg`.
  `fpcmkcfg.exe` is resolved from the discovered FPC directory first (then a PATH fallback
  via the command's full `.Path`, never the possibly-empty `.Source`) so it is found even
  when `fpc.exe` was located by the fallback scan rather than `Get-Command`. The config is
  written only when no `fpc.cfg` already exists, so a customized config from a different
  package or a preinstalled FPC is never overwritten. The unschedulable `macos-13` Intel
  matrix entry is replaced with `macos-15-intel` (label `macos-x86_64`), the current
  schedulable hosted Intel runner, keeping the documented `macos-x86_64` release asset
  building instead of silently dropping it.

- **`auto-tag-release.yml` — expose the detected release version as a `workflow_call` output (#99):**
  Added a `version` output (`value: ${{ jobs.tag.outputs.version }}`) so callers can gate
  follow-up jobs — creating a GitHub Release, moving a production branch — on
  `needs.<caller-job-id>.outputs.version`. The output description clarifies that
  `<caller-job-id>` is the caller's own job that `uses:` this workflow, not the internal
  `tag` job.

## 2026-06-17 — 0.14.6

### Added

- **`pnpm-pages.yml` — reusable GitHub Pages deployment workflow for pnpm monorepos:**
  New `preset-pnpm-pages` reusable workflow (`workflow_call`) that builds a pnpm monorepo,
  optionally runs a Playwright-based capture script to generate screenshots and videos, runs
  a static-site generator, and deploys the result to GitHub Pages. Inputs: `runner`,
  `working_directory`, `fetch_depth`, `node_version`, `pnpm_version`, `build_command`,
  `capture_command`, `generate_command`, `pages_path`, `install_playwright`,
  `playwright_browser`. The `playwright_browser` input is validated against known browser
  names (`chromium`, `firefox`, `webkit`, `chrome`, `msedge`) before install and passed via
  `PW_BROWSER` to avoid shell injection. `pages: write` and `id-token: write` are scoped to
  the `deploy` job only; the `build` job requires only `contents: read`. Jobs: `build`
  (checkout → pnpm → optional Playwright → generate → upload artifact) and `deploy` (Pages
  deployment with `github-pages` environment).

## 2026-06-15 — 0.14.5

### Fixed

- **`fpc-release.yml` — Windows `FPCDIR` not set (Chocolatey ZIP install):** The Chocolatey
  `freepascal` package ships a ZIP archive without `fpc.cfg`, so the previous walk-up that
  searched for `etc\fpc.cfg` never succeeded. Changed the landmark to `lib\fpc` (always
  present in the FPC install tree) and increased the depth limit from 3 to 5 levels. With
  `FPCDIR` correctly set, the `fpc` driver resolves RTL unit paths and passes them to
  `ppc386.exe`, fixing `Fatal: Can't find unit crt`.

## 2026-06-15 — 0.14.4

### Fixed

- **`fpc-release.yml` — AppImage download `wget -O` flag placement:** The output-file flag
  `-O /tmp/appimagetool` was placed after `--`, causing `wget` to treat it as a second URL
  to download (network failure) rather than as the output path. Moved `-O` before `--` so
  `wget` correctly saves to `/tmp/appimagetool`.

- **`security-weekly` — `aquasecurity/trivy-action` SHA stale:** Bumped the pinned SHA
  from `bfa4b33a` (2026-06-04) to `476e4fdc` (2026-06-15) in all four locations:
  `.github/actions/trivy-scan/action.yml`, `.github/workflows/docker-scan.yml`,
  `.github/workflows/docker-multiarch.yml`, and `.github/workflows/trivy-scan.yml`.

## 2026-06-15 — 0.14.3

### Fixed

- **`fpc-release.yml` — Windows `FPCDIR` not set:** `ppc386.exe` searches for `fpc.cfg`
  relative to its own binary, but the choco install places `fpc.cfg` in `<root>\etc\` which
  is not on that search path. The workflow now walks up from `fpc.exe`'s directory to locate
  `etc\fpc.cfg` and exports `FPCDIR` to `GITHUB_ENV` so the `fpc` driver can find the config
  and pass it (with unit search paths) to the sub-compiler. Without this, compilation fails
  with `Fatal: Can't find unit crt`.

- **`fpc-release.yml` — AppImage download `curl` fallback:** `wget` exits with code 4
  (hard network/DNS failure) on some CI runners, and `--tries` does not retry on exit-code-4
  errors. Added a `curl` fallback so a transient DNS failure on the runner does not abort the
  AppImage build entirely.

### Changed

- **`vendor/script-helpers`:** Updated from 0.13.0 to 0.14.0
  (`ba2ad9f`). Picks up the full PowerShell companion library (`ps/`) plus
  numerous bug-fixes across `ps/lib/` modules (logging, env, file, traps,
  ports, docker, help, certs, hosts) and the PS CI runner scripts.

- **`scripts/sync_script_helpers.sh`:** Enhanced to auto-detect the latest
  semver release tag via `git ls-remote` when no `--ref` is given; added
  `--ref` and `--repo-url` CLI flags; switched to shallow clone + temp-dir
  for speed and atomicity; added an "already up to date" short-circuit.
  SHA refs now handled correctly (clone then checkout rather than `--branch`).

## 2026-06-15 — 0.14.2

### Fixed

- **`fpc-release.yml` — Windows PATH after choco:** Chocolatey installs FPC but the new
  PATH is not inherited by subsequent bash steps. After `choco install freepascal` the
  workflow now scans `C:\fpc` for `fpc.exe` and writes its directory to `GITHUB_PATH` so
  the `Build` step can invoke the compiler.

- **`fpc-release.yml` — AppImage download retry:** `wget` was failing with exit code 4
  (network failure) on CI runners when downloading `appimagetool`. Added
  `--tries=3 --waitretry=5` for resilience against transient network issues.

- **`fpc-release.yml` — `overwrite_files`:** `softprops/action-gh-release` renamed the
  `update_existing` input to `overwrite_files`. The old name was silently ignored, meaning
  duplicate uploads to an existing release would fail. Updated all three upload steps.

### Dependencies

- `pnpm/action-setup`: v4 → v6 (`pnpm.yml`, `pnpm-cypress.yml`, `pnpm-scan.yml`, `pnpm-playwright.yml`)
- `dorny/test-reporter`: v2 → v3 (`pnpm.yml`, `pnpm-cypress.yml`, `pnpm-playwright.yml`)

## 2026-06-13 — 0.14.0

### Added

- **`pnpm-playwright.yml`:** New `preset-pnpm-playwright` workflow for pnpm monorepos
  running Playwright E2E tests. Sets up pnpm + Node, runs test/build (lint is optional —
  skipped when `lint_command` is empty), then installs Playwright browsers and runs E2E via
  `start-server-and-test`. Uploads `playwright-report/`
  as an artifact on every run (configurable via `upload_playwright_report` and
  `playwright_report_path`). Supports optional JUnit test result upload via
  `upload_test_results`/`test_results_path`.

- **`pnpm-cypress.yml`:** New `preset-pnpm-cypress` workflow for pnpm monorepos running
  Cypress tests. Defaults to component test mode (`cypress run --component`) — no running
  server required. Override `e2e_command` for full E2E against a preview server. Uploads
  Cypress videos and screenshots as artifacts on failure (configurable via
  `upload_cypress_artifacts`). Supports optional JUnit test result upload.

- **`pnpm.yml` — `upload_test_results` + `test_results_path` inputs:** Optional JUnit
  test result reporting via `dorny/test-reporter`. Set `upload_test_results: true` and
  configure your test runner to emit JUnit XML to `test-results/**/*.xml` (or override
  `test_results_path`). Results appear as GitHub check annotations on PRs.

- **`docs/presets.md`:** Added pnpm, pnpm-playwright, and pnpm-cypress sections.
  Renamed existing Playwright and Cypress sections to clarify they are yarn-based,
  with a cross-reference to the pnpm variants.

## 2026-06-12 — 0.13.0

### Added

- **`pnpm.yml`:** New `preset-pnpm` workflow for pnpm monorepos. Sets up pnpm via
  `pnpm/action-setup@v4`, enables Node.js cache keyed on `pnpm-lock.yaml`, runs
  `pnpm install --frozen-lockfile`, then lint/test/build/e2e/extra steps with
  fully configurable commands. Inputs: `pnpm_version`, `node_version`, `lint_command`,
  `test_command`, `build_command`, `e2e_command`, `extra_command`.

- **`pnpm-scan.yml`:** Security scan variant for pnpm monorepos. Adds per-package
  audit support via `audit_filters` (space-separated list of workspace package names)
  and `audit_level` inputs. When `audit_filters` is set, audits each package
  individually with `pnpm --filter`; otherwise runs a workspace-wide audit.
  Audit inputs are passed through `env:` variables to prevent shell injection.

## 2026-06-12 — 0.12.1

### Added

- **`auto-tag-release.yml`:** New `release_workflow` input (default `""`). When set to a workflow
  filename (e.g. `"release.yml"`), the workflow is dispatched via `workflow_dispatch` after the
  version tag is pushed, with `release_tag` set to the detected version. This bypasses the GitHub
  restriction that prevents `GITHUB_TOKEN`-created tags from firing tag-push triggered workflows.
  Callers must also grant `actions: write` permission. The workflow filename is validated against
  a safe-characters regex before use.

### Fixed

- **`auto-tag-release.yml`:** Restored `actions: write` to the workflow-level `permissions:` block.
  GitHub requires job-level permissions to be a strict subset of the workflow-level block; omitting
  `actions: write` from the top-level while the `dispatch` job requested it at job-level caused a
  `startup_failure` on every invocation of the workflow.

### Changed

- **`create_production.sh`:** Post-push verification now hard-fails when either the `production`
  tag or branch on the remote is missing or points to a different commit than expected. Previously
  the script would exit on push failure (via `set -euo pipefail`) but did not explicitly confirm
  that both remote refs converged to the same SHA. Annotated release tags are handled correctly
  via the peeled `^{}` entry from `git ls-remote`.

## 2026-06-09 — 0.12.0

### Added

- **`fpc-release.yml`:** New reusable workflow for Free Pascal (FPC) projects. Builds a binary
  natively on Linux (`ubuntu-latest`), macOS ARM64 (`macos-latest`), macOS x86_64 (`macos-13`),
  and Windows (`windows-latest`) using the platform FPC package manager (apt / Homebrew /
  Chocolatey), packages each into a release archive (`.tar.gz` on Linux/macOS, `.zip` on
  Windows), and optionally uploads all four to a GitHub release. Supports bundling runtime data
  files (`data_glob`) and extra docs (`extra_files`) alongside the binary.
  Additional Linux package formats (`linux_packages: "deb,rpm,appimage"`) and macOS DMG
  (`macos_dmg: "true"`) can be enabled with package metadata inputs (`package_maintainer`,
  `package_description`, `package_url`, `app_icon`).

## 2026-06-04 — 0.11.0

### Added

- **`php.yml`:** New `node_version` input (default `""`) — set to e.g. `"22"` to install Node.js for npm-based build steps alongside PHP.

### Changed

- **Runtime defaults bumped to current supported versions:**
  - PHP: `8.2` → `8.4` (`php.yml`, `php-scan.yml`, `pimcore.yml`)
  - Go: `1.22` → `1.24` (`go.yml`, `go-scan.yml`, `go-release.yml`, `go-deploy.yml`)
  - Python: `3.12` → `3.13` (`python.yml`, `python-scan.yml`)
  - Node.js: `20` → `22` (`node.yml`, `react.yml`, `node-scan.yml`, `react-scan.yml`, `vue-scan.yml`, `playwright.yml`, `cypress.yml`)
- **Security tool SHA updates** (resolves dependabot PRs #69–#73):
  - `aquasecurity/trivy-action`: `314ff8b` → `bfa4b33` (all reusable workflows + composite action)
  - `snyk/actions/docker`: `9cf6ca7` → `8e119fb`
  - `securego/gosec`: `6351b0c` → `92ed8df`
  - `docker/setup-qemu-action`: `ce36039` (v4.0.0) → `06116385` (v4.1.0)
  - `actions/upload-artifact`: v4 → v7
  - `actions/download-artifact`: v4 → v8

## 2026-05-29 — 0.10.6

### Fixed

- **`deb-build.yml`:** `extra_packages` is now split into an array before being passed to `apt-get`, preventing shell metacharacter injection from crafted values.
- **`deb-build.yml`:** `upload_to_release` input is now validated early; any value other than `auto`, `true`, or `false` fails with a clear error instead of silently publishing.
- **`deb-build.yml`:** `release_tag` newlines/CR stripped before writing to `$GITHUB_OUTPUT` to prevent output injection.
- **`deb-build.yml`:** SHA-pinned `softprops/action-gh-release` ref now includes the required `# v3 @ YYYY-MM-DD` annotation so `update_pinned_actions.sh` can track and refresh it.
- **`rust-release-tarballs.yml`:** Both tag-resolve steps now strip newlines/CR from `release_tag` before writing to `$GITHUB_OUTPUT` (injection hardening) and now accept `vX.Y.Z` tags in addition to `X.Y.Z`.
- **`rust-release-tarballs.yml`:** Homebrew formula `test` block now correctly produces `#{bin}/…` Ruby interpolation (was `\#{bin}/…` which rendered as a literal string and broke `brew test`).
- **`rust-release-tarballs.yml`:** SHA-pinned `softprops/action-gh-release` refs now include the required `# v3 @ YYYY-MM-DD` annotation.
- **`rust-release-tarballs.yml`:** `homepage` input description clarified — must be a GitHub repo URL; used as the base for release download URLs.

## 2026-05-29 — 0.10.5

### Added

- **`deb-build.yml`:** New `upload_to_release` input (`auto` / `true` / `false`, default: `auto`) — when `auto`, uploads the built `.deb` to the GitHub release whenever triggered by a version tag or when `release_tag` is provided.
- **`deb-build.yml`:** New `release_tag` input for manual backfill via `workflow_dispatch` (e.g. re-running a release after a tag was created without triggering CI).

### Fixed

- **`deb-build.yml`:** `extra_packages`, `prebuild_command`, and `build_command` inputs are now passed via env vars in `run:` steps rather than inline `${{ }}` interpolation, eliminating potential shell injection risk.

## 2026-05-26 — 0.10.4

### Fixed

- **`flutter-release.yml`:** Android signing secrets are no longer required when
  `build_android: true` without `deploy_google_play: true`. Missing secrets now emit
  a workflow warning and skip `key.properties` setup, allowing projects that use their
  own default signing config (e.g. debug signing) to run CI builds without providing
  keystore credentials. Signing secrets remain mandatory when `deploy_google_play: true`.

## 2026-05-25 — 0.10.3

### Changed

- **`docker-multiarch.yml`:** Bump `docker/setup-qemu-action` v3 → v4.0.0,
  `docker/setup-buildx-action` v3 → v4.1.0, `docker/login-action` v3 → v4.2.0,
  `docker/build-push-action` v6 → v7.2.0 (all SHA-pinned).
- **`tauri-release.yml`:** Bump `azure/trusted-signing-action` v0 → v2.0.0 and
  `actions/download-artifact` v4 → v8.0.1 (SHA-pinned).
- **`go-release.yml`:** Bump `softprops/action-gh-release` v1 → v3 (SHA-pinned).

## 2026-05-23 — 0.10.2

### Fixed

- **`reusable workflows`:** Replace all `./` relative action refs with full repo
  paths to fix resolution in caller repositories (#52).
- **`ci.yml` / misc:** Pin `actions/github-script` to SHA `3a2844b7` (v9) (#51).

## 2026-05-23 — 0.10.1

### Fixed

- **`reusable workflows`:** Use full repo ref for gitleaks composite action call
  inside reusable workflows (#50).

## 2026-05-23 — 0.10.0

### Added

- **`tauri-scan.yml`:** Fast Tauri CI check for Linux (ubuntu-22.04). Installs
  WebKit2GTK 4.1 system dependencies, sets up Rust via `dtolnay/rust-toolchain`,
  runs `cargo fmt -- --check`, `cargo clippy -- -D warnings`, and `cargo check`
  (no full build — keeps the gate fast). Optional Node + frontend install for
  front-end type-checking. All commands routed through `env:` variables to prevent
  expression injection from workflow inputs (protects against crafted ref names
  or other GitHub context values being interpolated directly into `run:` scripts).

- **`tauri.yml`:** Standalone Tauri CI preset (does not wrap `ci.yml` — `ci.yml`
  has no `apt` step). Runs full `cargo test` + `cargo build` on ubuntu-22.04 with
  WebKit2GTK dependencies. Optional Node setup and frontend build before Cargo steps.

- **`tauri-release.yml`:** Cross-platform Tauri desktop release workflow. Builds on
  a 3-job matrix: `macos-latest` (universal binary via `aarch64 + x86_64`, requires
  both rustup targets), `windows-latest` (MSI + NSIS), `ubuntu-22.04` (AppImage +
  deb + rpm). macOS job uses the new `actions/macos-sign` composite action for
  keychain import and optional `xcrun notarytool submit --wait` + `xcrun stapler
  staple` notarization. Windows job uses the new `actions/windows-sign` composite
  action in one of three modes (see below). Release job downloads all artifacts and
  uploads via `softprops/action-gh-release`. Optional dist-repo cross-publish and
  WinGet submission job via `winget-submit.yml`.

- **`winget-submit.yml`:** Standalone reusable workflow for submitting Windows
  Package Manager manifests to a fork of `microsoft/winget-pkgs`. Installs
  `wingetcreate` via `dotnet tool install --global Microsoft.WingetCreator` and runs
  `wingetcreate update --submit`. URL format: `<installer_url>|<arch>|<type>`
  (e.g. `...setup.exe|x64|nullsoft`). Inputs: `package_id`, `version`,
  `installer_url`, `installer_arch`, `installer_type`, `release_notes_url`,
  `winget_fork_owner`. Secret: `WINGET_PKGS_TOKEN`.

- **`docker-multiarch.yml`:** Multi-architecture Docker buildx workflow (build +
  push). Sets up QEMU and buildx, logs in to a configurable registry (default
  `ghcr.io`), pushes versioned tag plus optional `:latest`. Optional post-build
  Trivy image scan. Inputs: `image_name`, `tag`, `platforms`, `dockerfile`,
  `context`, `build_args`, `push_latest`, `registry`, `registry_username`,
  `scan_after_build`, `trivy_severity`, `fail_on_scan_findings`.
  Secret: `registry_token`. Outputs: `image_digest`, `image_ref`.

- **`manifest-version.yml`:** Generic manifest version reader, git tagger, and
  workflow dispatcher. Extracts version from `package.json`, `Cargo.toml`,
  `pubspec.yaml`, `pyproject.toml`, a plain `VERSION` file, or a custom shell
  command. Validates semver format, optionally skips if tag already exists, creates
  a lightweight git tag, and dispatches named workflows via `gh workflow run` with
  support for extra inputs via `dispatch_inputs_json`. Outputs: `version`, `tag`,
  `skipped`.

- **`actions/macos-sign`:** Composite action for macOS codesigning setup. Imports
  an Apple p12 certificate into a temporary keychain (`ci-build.keychain-db`), sets
  the keychain search list and `apple-tool:,apple:,codesign:` partition access, and
  exports all Apple env vars (`APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_PASSWORD`) to
  `$GITHUB_ENV` for Tauri. Keychain cleanup is the caller's responsibility —
  composite actions have no post-run hook; `tauri-release.yml` includes the
  required `if: always()` cleanup step; custom callers must add their own.

- **`actions/windows-sign`:** Composite action for Windows codesigning with three
  modes:
  - `tauri_updater` (free): exports `TAURI_SIGNING_PRIVATE_KEY` and
    `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` for Tauri's ED25519 updater bundle signing.
    Signs `.sig` files only — does not sign the MSI/EXE binary.
  - `pfx` (paid OV/EV): decodes a base64 PFX, imports it to `Cert:\CurrentUser\My`,
    extracts the thumbprint, and sets `TAURI_WINDOWS_SIGN_COMMAND` (signtool with
    RFC 3161 timestamp via Sectigo) and `WINDOWS_CERT_THUMBPRINT`. Signs MSI + EXE
    with Authenticode. PFX/cert cleanup is the caller's responsibility (same
    composite-action post-run limitation); `tauri-release.yml` includes the step.
  - `azure` (paid Azure Trusted Signing): exports Azure credentials to `$GITHUB_ENV`
    for consumption by `azure/trusted-signing-action` in a subsequent post-build
    step. Uses `azuresigntool` internally — not compatible with
    `TAURI_WINDOWS_SIGN_COMMAND`.

## 2026-05-23 — 0.9.3

### Fixed
- **`auto-tag-release.yml` squash-merge detection:** Added a second commit-subject
  fallback that extracts `(#N)` from squash-merge subjects and validates the PR
  directly via `pulls.get`. The association-index path (`listPullRequestsAssociatedWithCommit`)
  is eventually-consistent and could silently miss a release merge fired seconds after
  the push; `pulls.get` is not subject to that delay. Re-runnable warning emitted
  when `merge_commit_sha` mismatch is detected (delayed indexing edge case).
- **`create_production.sh` branch drift:** Script now also force-pushes the
  production BRANCH to the same commit as the production TAG after every release.
  Previously only the tag was moved, leaving `refs/heads/production` stale and
  causing GitHub Actions to resolve `@production` to the old branch commit instead
  of the new tag commit. Pass `--no-branch` to opt out of the branch update.

## 2026-05-22 — 0.9.2

### Changed
- Refreshed stale pinned GitHub Action SHAs required by the production-tag
  security gate.

## 2026-05-22 — 0.9.0

### Added
- **`data-safety-scan` composite action:** Centralized JSON data scanning that
  rejects sensitive-key fields before application data is shipped.

## 2026-05-21 — 0.8.0

### Added
- **`install_command` input for `pr-gate.yml`:** New optional input that runs a
  dedicated Install step before Lint/Test/Build. Allows callers to install
  dependencies once and reuse them across subsequent steps, eliminating
  redundant `npm ci` / `pip install` calls that previously appeared in both
  `lint_command` and `test_command`.
- **`docs/private-repo-ci-strategy.md`:** Full 3-layer CI model documentation
  (Local hooks → PR gate → Main gate) with per-stack workflow examples for
  Node/TypeScript, Python, Go, Rust, Flutter, Java/Gradle, and PHP. Includes
  a table of repos that need the duplicate-trigger fix and a reference to the
  script-helpers local test scripts.

## 2026-05-14 — 0.7.3

### Changed
- **Node.js 24 opt-in:** Added `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` workflow-level
  env to all workflows that invoke third-party actions still on Node 20 runtime
  (`auto-tag-release.yml`, `gitleaks-scan.yml`, `release-rc-pr.yml`,
  `release-tag-gate.yml`, `flutter-release.yml`, `go-release.yml`,
  `rust-release.yml`, `release-build.yml`, `pr-gate.yml`, `ci.yml`).
  Silences Node 20 deprecation warnings ahead of the forced migration on
  June 2, 2026 (Node 20 removed from runners September 16, 2026).

## 2026-04-13 — 0.7.2

### Changed
- **Node.js runtime:** Upgraded `actions/setup-node` from `v4` to `v5` across all
  Node-using workflows (`ci.yml`, `deploy.yml`, `pr-gate.yml`, `react-scan.yml`,
  `release-build.yml`, `node-scan.yml`, `vue-scan.yml`). Default `node_version`
  updated from `"20"` to `"22"` (Active LTS) in `node.yml`, `node-scan.yml`,
  `react.yml`, `react-scan.yml`, `vue-scan.yml`, `cypress.yml`, and
  `playwright.yml`. Node.js 20 GitHub Actions runtime is deprecated; forced
  migration to Node.js 24 begins June 2, 2026.

### Added
- **`scripts/update_pinned_actions.sh`:** Local helper script that scans `.github/` for
  SHA-pinned action refs annotated with `# <ref> @ <date>`, fetches the current HEAD SHA
  from the GitHub API (with caching for repeated repo+ref queries), and updates stale pins
  in place. Supports `--check` (dry-run / CI gate) and `--dir <path>` override. Run with
  `gh` CLI authenticated.

### Security
- **Supply chain:** Pinned three floating `@master` action refs to reviewed commit SHAs:
  `securego/gosec` in `go-scan.yml`, `aquasecurity/trivy-action` and `snyk/actions/docker` in `docker-scan.yml`.
  Floating refs allow upstream changes to silently alter CI behaviour.
- **Pinned** `softprops/action-gh-release@v1` to its SHA in `go-release.yml`.
- **Expression injection (defence in depth):** Moved non-command workflow inputs
  (`ldflags`, paths, names, WP-CLI args) from direct `${{ inputs.* }}` interpolation
  in `run:` blocks to `env:` variables in `go-deploy.yml`, `go-release.yml`, and
  `php-scan.yml`. Prevents shell-level injection if a caller ever passes user-controlled
  content as a non-command input.
- **SSH_OPTS quoting:** Changed `SSH_OPTS` in `go-deploy.yml` from an unquoted string
  (used in `ssh $SSH_OPTS`) to a proper bash array (`SSH_OPTS=(...)`, `"${SSH_OPTS[@]}"`)
  to prevent word-splitting on the key path.
- **Explicit permissions:** Added `permissions: contents: read` to `gitleaks-check.yml`
  and `release-tag-check.yml`; added `pull-requests: read` to `gitleaks-check.yml`.
  These non-reusable workflows previously relied on the repo's `GITHUB_TOKEN` default.
- **`version_bump.sh`:** Switched to `rg -F` for literal match discovery and Perl
  literal replacements so version strings containing `/` and other special characters
  are handled safely during in-place updates.
- **`rust_release_build.sh`:** Added allowlist validation for the `--apt-packages`
  argument before passing it to `apt-get install` to prevent command injection via
  crafted package name strings.

## 2026-04-11

### Fixed
- Reworked reusable workflows that previously depended on caller-local `.github/actions/*` paths to use shared `script-helpers` scripts or direct third-party actions instead, so downstream callers can use them safely.

### Changed
- `gitleaks-scan.yml`: `scan_path`, `report_format`, and `config_path` inputs now fail fast with a clear error when provided with non-default values. Previously the workflow delegated to the local composite action which would warn and proceed; the new direct `gitleaks-action` integration cannot honour these overrides, so non-default values are rejected explicitly. Input descriptions document this contract.
- `auto-tag-release.yml`: added `update_production_tag` boolean input (default `true`). When set to `false`, the Bootstrap script-helpers and Update production tag steps are skipped, allowing external callers that do not carry a floating `production` tag to use this reusable workflow safely.

## 2026-04-07

### Added
- Added `pimcore-bundle-check.yml` reusable workflow and matching composite action
  `.github/actions/pimcore-bundle-check/action.yml` for Docker-based Pimcore 11
  bundle testing (PHPUnit, PHPCS PSR-12, PHPStan, coverage). Mirrors the existing
  `wp-plugin-check` pattern: Docker Compose orchestrates a `php` + `db` (MySQL 8)
  stack; tests run inside the container via `docker compose exec`.
- Added `pimcore.yml` preset that wraps `pimcore-bundle-check.yml` with Pimcore 11
  defaults (PHP 8.1, PSR-12 PHPCS, PHPUnit). Minimal one-liner usage:
  `uses: nikolareljin/ci-helpers/.github/workflows/pimcore.yml@production`
- Added Pimcore framework detection to `php-scan.yml`: auto-detects bundles via
  `"type": "pimcore-bundle"` in `composer.json` or a `pimcore/pimcore` dependency,
  and conditionally runs `lint_pimcore_command` (default: PSR-12 PHPCS on `src/`).

## 2026-03-30

### Fixed
- Updated `scripts/create_production.sh` to push the movable `production` tag with `--force` because Git rejects `--force-with-lease` for existing tag refs even after a fresh tag fetch.

## 2026-03-26

### Added
- Added `scripts/check_release_version.sh` plus a tracked `.githooks/pre-commit` hook to enforce that `VERSION` matches `release/[v]X.Y.Z[-rcN]` or `release/[v]X.Y.Z[-rc.N]` branch names during local commits.

### Changed
- `release-tag-check.yml` now runs on both branch creation and pushes for `release/*` branches and validates `VERSION` before checking tag availability.

## 2026-03-24

### Fixed
- Hardened `auto-tag-release.yml` so merged release branches still tag correctly when GitHub has not yet associated the merge commit with its PR, using a merge-subject fallback that validates the referenced PR plus default-branch and `merge_commit_sha` guards.

## 2026-03-20

### Changed
- Reverted repo-internal reusable workflow and composite action wrappers back to local `./.github/...` references so `ci-helpers` validates the current branch instead of self-referencing `@production`.
- Updated reusable and preset GitHub workflows from `actions/checkout@v4` to `actions/checkout@v5` and from `actions/setup-python@v5` to `actions/setup-python@v6` to stay aligned with GitHub's Node 24 runtime transition.
- Restored local `./.github/...` references inside ci-helpers' own reusable workflows and composite-action callers so the repo no longer imports itself via `nikolareljin/ci-helpers@production`.

## 2026-03-19

### Changed
- Added `flutter_version` and `flutter_channel` inputs to the generic reusable `ci.yml` and `release-build.yml` workflows.
- Added `lint_command` and `test_command` support to `release-build.yml` so release artifact jobs can reuse the same validation flow before publishing.
- Updated workflow and usage docs with Flutter APK and pre-build validation examples.

## 2026-01-29

### Changed
- Added a macOS runner guard for App Store deploy preparation in the Flutter release workflow.
- Updated App Store Connect key encoding instructions with Linux-friendly examples.
- Documented a macOS runner example for iOS/App Store deployments in flutter-release workflow docs.

## 2026-01-28

### Added
- Added a reusable `go-deploy.yml` workflow for building and deploying Go binaries to remote servers via SSH/rsync.
- Documented go-deploy workflow inputs, secrets, and usage examples.

## 2026-01-19

### Added
- Added a reusable Flutter release workflow for building Android/iOS and deploying via Fastlane.
- Documented Flutter release workflow inputs and added an example.
- Added a `release-rc-pr.yml` workflow to automatically open pull requests for release-candidate branches.
- Added `SECURITY.md` with security reporting and support policy details.
- Added `APPLE_FASTLANE_PUBLISH.md` and `GOOGLE_PLAY_PUBLISH.md` guides documenting app store publishing via Fastlane.

## 2026-01-07 (0.4.0)

### Changed
- Vendored new script-helpers package publishing helpers and updated workflows to use them.
- Added reusable RPM build and Homebrew packaging workflows with optional publish support.

## 2026-01-06

### Changed
- Moved PPA upload helper to vendored script-helpers and updated workflows to use it.

## 2026-01-05

### Added
- Added a reusable Debian package build workflow that uploads artifacts.

## 2026-01-04

### Added
- Added a reusable workflow to build and publish Debian source packages to Launchpad PPAs.
- Documented PPA publish inputs and required secrets.

## 2026-01-03 (0.3.0)

### Changed
- Updated docs to consistently point reusable workflow/action references at @production.
- Bumped production tag references to 0.3.0 in documentation.

## 2025-12-31 (0.2.0)

### Added
- Added a release-notes composite action with optional binary links.
- Added a generic release-build reusable workflow for publishing release artifacts.
- Added a Rust multi-target release workflow and rust release build helper script.
- Added a Go multi-target release workflow.
- Added a production branch update script and repo-local workflow.

### Changed
- Updated docs with release workflows, release notes usage, and install-from-git examples.

## 2025-12-27 (0.1.2)

### Added
- Added lint defaults across language presets and scan workflows (Python, C#, Java, Go, Rust, PHP, Node, React).
- Added release tag PR gate workflow and an auto-tag push wrapper for repo-local usage.
- Documented release tag gate + auto-tag setup for external repos.

### Changed
- Python defaults now install pytest before running tests and support pyproject-only installs (with pyinstaller).
- Node/React/C#/Go/Rust defaults now fetch dependencies before running tests.
- Auto-tag release workflow is now reusable, default-branch aware, and hard-fails if the tag already exists.
- Release branch tag guard now accepts `release/X.Y.Z-rcN` branches.
- Updated docs and references to version 0.1.2.

## 2025-12-26 (0.1.1)

### Added
- Documented VERSION as the source of truth for the production tag in README, docs, and AGENTS.
- Added `scripts/version_bump.sh` to bump VERSION and update @vX.Y.Z references.

### Changed
- Moved preset workflows to the top-level `.github/workflows/` directory to satisfy reusable workflow requirements.
- Updated the Gitleaks composite action defaults to SARIF (`results.sarif`) to match `gitleaks-action` output and avoid missing report files.
- Added optional artifact upload support to the Gitleaks composite action and updated docs/examples.
- Standardized script headers and help output for all scripts in `scripts/`.

### Added
- Added a release-branch guard workflow that checks for existing tags when `release/*` branches are created.

## 2025-12-25

### Added
- Gitleaks-based leak scanning workflow, composite action, and PR/cron check.
- Reusable scan workflows for PHP, Python, Go, Rust, Java, C#, Node, React, Vue, and Docker.
- Usage guide plus expanded examples for workflows and composite actions.

### Changed
- Replaced NoseyParker scan docs and references with Gitleaks.
- Gitleaks reports now include Leak-Lock extension links when leaks are found.
- PR and auto-tag examples now include `master` alongside `main`.

## 2025-12-23 (0.1.0)

### Added
- Initial reusable workflows, presets, and composite actions for CI and scans.
- Playwright/Cypress/E2E support with Yarn and start-server-and-test defaults.
- Vendored script-helpers with sync automation.

### Changed
- README and docs expanded with quick start, examples, and links.
- License and repository naming updates.
