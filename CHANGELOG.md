# Changelog

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
  - The build fails if `pages_path` is missing or empty afterwards, so a
    generator that silently produces nothing cannot replace a working site with
    an empty one.
  - It also fails when there is no `index.html` or `index.htm` at the root of
    `pages_path`, because such a site deploys successfully and then serves 404
    at its own address. `require_entry_file: false` opts out.
  - `working_directory` is validated up front rather than failing several steps
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

- **`flutter-release.yml` — a channel name was passed where a version belongs (found in `anchor`):**
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
  in document-tracker, whose `main` had no complete CI run for three days:
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
