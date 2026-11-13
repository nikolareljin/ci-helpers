# Reusable Workflows

This repo exposes reusable workflows via `workflow_call`. You consume them from
your own repo by referencing this repo path and a tag or commit SHA.

Related docs:

- [Presets](presets.md)
- [Composite actions](actions.md)
- [Examples](examples.md)

All workflows use Bash with `set -euo pipefail` for the commands you pass in.
All commands run inside `inputs.working_directory` (default `"."`).

### Runners on pull requests

Every `runner` input accepts any label, a self-hosted one included. On a
`pull_request` event the job runs the PR's code, so a self-hosted runner that
outlives the job keeps whatever that code left behind: caches, docker images
and volumes, files outside the workspace. The next job on that machine, a
release included, starts from that state. For workflows a pull request
triggers, pass a GitHub-hosted label (`ubuntu-*`, `macos-*`, `windows-*`) or
an ephemeral self-hosted runner, one that is destroyed after each job.

## ci.yml

Workflow: `.github/workflows/ci.yml`

Purpose: Run install, lint, test, build, optional Docker, and optional E2E commands.

Execution order:
1) Install
2) Lint
3) Test
4) Build
5) Docker
6) E2E
7) Extra

`install_command` runs first so a caller can override `lint_command` without
losing its dependencies. An install inside a lint default is dropped as soon
as a caller overrides that default.

Inputs:

- `runner` (string, default `ubuntu-latest`; with `php_version` set, `ubuntu-latest` runs on `ubuntu-24.04`, as the ondrej/php PPA has no 26.04 suite yet)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `submodules` (string, default `"false"`) — `false`, `true` or `recursive`, passed to `actions/checkout`. Any other value is **refused**: checkout reads anything that is not `true`/`recursive` as false, so a typo would otherwise check out no submodule and report success. **Public submodules only** — checkout authenticates with a header scoped to the calling repository, so one in a private repository fails with a 403. Note the engine already checks out with `fetch-depth: 0` and `fetch-tags: true`, so `recursive` against a large submodule tree can want more than the default `timeout_minutes`.
- `cache` (boolean, default `true`) — restore dependency caches through each `setup-*` action's own cache option. Which toolchains are enabled is **detected from the tree**, not assumed: `setup-node` and `setup-dotnet` fail the job when told to cache with no lockfile present, so a blanket "cache everything" would be a new class of red build. The mapping is `package-lock.json`/`npm-shrinkwrap.json` → npm, `yarn.lock` → yarn (npm wins when both are present, and the summary says so), `requirements*.txt` → pip, `go.sum`, `pom.xml` → maven, a root `*.gradle`/`*.gradle.kts` → gradle, `packages.lock.json` → NuGet. Each run writes one line per toolchain to the job summary saying what was cached and whether it hit.

  Not cached, deliberately: **poetry and pipenv**, because `setup-python` resolves their cache directories by running those binaries and the setup step runs *before* `install_command`, so neither is on PATH yet; **pnpm**, which must be on PATH before `setup-node` can probe its store (the `pnpm.yml` presets put it there with corepack and do not call this engine); and **Rust and PHP**, whose setup steps have no cache option here (the Tauri CI workflows cache the cargo registry with `actions/cache/restore` and `actions/cache/save`). **Flutter and Godot** cache the downloaded release archive only, never the extracted SDK or editor: `actions/cache/restore` before the setup step (the Flutter key carries OS, channel, version, architecture and the archive's expected sha256; the Godot key carries OS, architecture, version, the .NET flag and a hash of the library's `toolchain-pins.env`), and `actions/cache/save` directly after it, before any step runs the caller's code, so an entry holds what the setup step verified and nothing a later step wrote. On every run the script checks the archive's sha256 against the pin or the manifest, deletes and downloads it again on a mismatch, and extracts it fresh; a cache entry written by another job cannot put a different SDK on PATH. `tests/toolchain_cache_save_test.sh` holds the step order.

  One caveat worth knowing before enabling it on a matrix: `setup-java`'s cache key does not carry the JDK version, so a `java_version` matrix over one `pom.xml` shares a single cache. Pass `cache: false` if that matters.
- `node_version` (string, default `""`)
- `java_version` (string, default `""`)
- `dotnet_version` (string, default `""`)
- `python_version` (string, default `""`)
- `go_version` (string, default `""`: no Go; `go.mod` reads `<working_directory>/go.mod`)
- `flutter_version` (string, default `""`; an exact release such as `3.47.9`, or `3.47` / `3.47.x` for the newest of that line)
- `flutter_channel` (string, default `""`; `stable`, `beta` or `dev`. Set it alone to install Flutter on that channel without a version: on `stable` that is the release pinned in the library's `toolchain-pins.env`, on `beta` or `dev` the newest release of the channel. `master` and `main` are refused, they are git clones with no release digest)

  Flutter comes from the official release archive through `scripts/setup_flutter.sh`, which the job checks out from this library at the workflow's own commit; no third-party action. The release is chosen from `releases_<os>.json` as `subosito/flutter-action` chose it (channel, the runner's architecture, exact version or `X.Y` prefix, newest first), the archive is checked against the manifest's sha256 before it is extracted, and the pinned default must also match the pin in `toolchain-pins.env`. `FLUTTER_ROOT` and `PUB_CACHE` are exported; `flutter`, `dart` and the pub cache's `bin` go on PATH. The manifest and the archive come from `storage.googleapis.com` only: a `FLUTTER_STORAGE_BASE_URL` naming another host refuses, no redirect is followed, the manifest is capped at 8 MiB, and an archive path other than `<channel>/<os>/flutter_<name>.zip` or `.tar.xz` refuses.
- `php_version` (string, default `""`)
- `rust_toolchain` (string, default `""`)
- `rust_components` (string, default `""`)
- `godot_version` (string, default `""`; a full three-part version — `4.3.0`, never `4.3`, which is refused with the fix before any download; `4.4.0-beta1` for a pre-release)

  Godot comes from the official release archive on `github.com/godotengine/godot-builds` through `scripts/setup_godot.sh`, from the same library checkout; no third-party action. Only a release whose sha256 is pinned in the library's `toolchain-pins.env` installs (`4.3.0` and `4.7.2`, both variants, on Linux x86_64, macOS and Windows x64), checked before the archive is extracted; any other release fails naming the pinned ones. The editor is linked as `godot` under `~/bin`, which goes on PATH, and `GODOT` and `GODOT4` name it, as the action set them; on Windows `godot.exe` is the editor and `GODOT` names `godot_console.exe`, the release's console wrapper, since the editor prints nothing to a console. No export templates are installed (no caller had them).
- `godot_use_dotnet` (boolean, default `false`; Godot's .NET build, for a C# project)
- `install_command` (string, default `""`)
- `lint_command` (string, default `""`)
- `test_command` (string, default `""`)
- `build_command` (string, default `""`)
- `docker_command` (string, default `""`)
- `e2e_command` (string, default `""`)
- `extra_command` (string, default `""`)
- `extra_env` (string, default `""`) — extra environment for the command steps, one `KEY=VALUE` per line. Written to `$GITHUB_ENV` without the shell re-quoting the value, so a credential containing quotes survives intact; a line that is not `KEY=VALUE` fails the step with the value redacted.
- `db_image` (string, default `""`) - optional database image. When set, the container is started with `docker run` before the command steps, because a `services:` block cannot be made conditional inside a reusable job. Prefer the digest form `postgres:16@sha256:<digest>`: a bare tag is re-resolved on every run.
- `db_env` (string, default `""`) — container environment, one `KEY=VALUE` per line. A bare key is refused: `docker run -e KEY` would copy that variable off the runner and into the container.
- `db_ports` (string, default `""`) — one published port mapping per line.
- `db_health_cmd` (string, default `""`) — readiness probe, run **inside** the container, so it must address a local socket or port rather than a host URL.
- `db_wait_seconds` (number, default `60`) — how long to wait for that probe before failing and printing the container's last 50 log lines.
- `timeout_minutes` (number, default `20`) — job timeout. Without one, a hung job bills until GitHub's six-hour cap.

This workflow declares a `concurrency` group keyed on the caller workflow, the
**working directory**, the runner and toolchain version inputs, and the ref,
with `cancel-in-progress: true`, so a superseding push cancels the run it
replaces.

The working directory is in the key because a caller may invoke this workflow
from several jobs at once — backend and frontend, or one job per module. Those
jobs share `github.workflow` and `github.ref`. Keyed on those alone they
would share one group, and `cancel-in-progress` would cancel whichever started
first. The cancelled job reports `cancelled` after 0 seconds with no steps,
which reads as an infrastructure hiccup rather than lost coverage.

The runner and the toolchain versions (`node_version`, `java_version`,
`dotnet_version`, `python_version`, `go_version`, `flutter_version` with
`flutter_channel`, `php_version`, `rust_toolchain`, `godot_version`) are in the default key for
the same reason: a matrix over versions or runners reaches this workflow with a
single working directory, and its legs would cancel each other too.

- `concurrency_key` (string, default `""`) — replaces the working directory,
  runner and toolchain versions in that key. Set it when two concurrent calls
  still share all of those, such as matrix legs over something else. Leave it
  empty otherwise. A caller that sets it gets exactly that group.

Example (Flutter mobile CI):

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@production
    with:
      flutter_version: "3.38.7"
      java_version: "17"
      working_directory: "mobile"
      lint_command: "dart format --output=none --set-exit-if-changed lib test && flutter analyze"
      test_command: "flutter test"
      build_command: "flutter build apk --debug"
```

Example (Node + E2E with Playwright):

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@production
    with:
      node_version: "22"
      lint_command: "yarn lint"
      test_command: "yarn test"
      build_command: "yarn build"
      e2e_command: "npx start-server-and-test 'yarn dev' http://localhost:3000 'npx playwright test'"
```

Example (Docker build + E2E):

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@production
    with:
      node_version: "22"
      docker_command: "docker build -t myapp:ci ."
      e2e_command: "npx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
```

## pr-gate.yml

Workflow: `.github/workflows/pr-gate.yml`

Purpose: Run a PR gate that can include release tag checks plus CI steps.

Execution order:
1) Release tag check (optional)
2) Lint
3) Test
4) Build
5) Docker
6) E2E
7) Extra

Inputs:

- The `ci.yml` inputs, with the same defaults, except the database and
  environment inputs (`db_image`, `db_env`, `db_ports`, `db_health_cmd`,
  `db_wait_seconds`, `extra_env`), which it does not take: `runner`,
  `working_directory`, `concurrency_key`, `fetch_depth`, `submodules`, `cache`,
  `node_version`, `java_version`, `dotnet_version`, `python_version`,
  `go_version`, `flutter_version`, `flutter_channel`, `php_version`,
  `rust_toolchain`, `rust_components`, `godot_version`, `godot_use_dotnet`,
  `install_command`, `lint_command`, `test_command`, `build_command`,
  `docker_command`, `e2e_command`, `extra_command`
- `check_release_tag` (boolean, default `false`)
- `release_branch` (string, default `""`)
- `timeout_minutes` (number, default `20`) — job timeout.

This workflow uses a concurrency group keyed on the caller workflow, the
working directory, and the ref, with `cancel-in-progress: true`. It accepts
`concurrency_key` to override the directory component; see the `ci.yml` section
above for when that is needed.

Example (PR gate with release tag check + E2E):

```yaml
jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/pr-gate.yml@production
    with:
      node_version: "22"
      lint_command: "yarn lint"
      test_command: "yarn test"
      e2e_command: "npx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
      check_release_tag: true
      release_branch: ${{ github.head_ref }}
```

## deploy.yml

Workflow: `.github/workflows/deploy.yml`

Purpose: Run a deployment command with optional runtime setup.

Inputs:

- `runner` (string, default `ubuntu-latest`; with `php_version` set, `ubuntu-latest` runs on `ubuntu-24.04`, as the ondrej/php PPA has no 26.04 suite yet)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `node_version` (string, default `""`)
- `java_version` (string, default `""`)
- `dotnet_version` (string, default `""`)
- `python_version` (string, default `""`)
- `go_version` (string, default `""`: no Go; `go.mod` reads `<working_directory>/go.mod`)
- `php_version` (string, default `""`)
- `deploy_command` (string, required)

The job token is `contents: read` and the checkout keeps no credentials, so a `deploy_command` that pushes to a branch must bring its own credentials (a deploy key or token passed as a secret).

Example:

```yaml
jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/deploy.yml@production
    with:
      node_version: "22"
      deploy_command: "./scripts/deploy.sh"
```

## cloudflare-deploy.yml

Workflow: `.github/workflows/cloudflare-deploy.yml`

Purpose: Deploy to Cloudflare with wrangler, behind a kill switch and a GitHub Environment.

**Disabled by default.** Nothing deploys until the kill switch reads the string `true` — either the `enabled` input, or the repository variable `CLOUDFLARE_DEPLOY_ENABLED` when that input is empty. While it is off, a `disabled-notice` job writes a job summary explaining how to arm it, so a switched-off repository does not look like a broken workflow.

Two jobs do the work. `build` (`contents: read`, no Cloudflare secret, no Environment) checks out the caller, runs `install_command` and `build_command`, bundles the Worker with the library's pinned wrangler (`wrangler deploy --dry-run --outdir`) or takes the Pages directory, and uploads the result with a sha256 manifest. `deploy` holds the token and the Environment, checks out nothing of the caller's, checks every file against the manifest, and runs the pinned wrangler (`WRANGLER_VERSION` in `toolchain-pins.env`, installed with `npm ci --ignore-scripts` from `scripts/wrangler/package-lock.json`) with arguments built from checked inputs only (`scripts/cloudflare_wrangler.py`). The Workers lane deploys the bundle with `--no-bundle` and a checked copy of the config: `build` is dropped (the build job ran it), and every key must be on an allowlist of wrangler keys that name data (`ALLOWED_KEYS` in `scripts/cloudflare_wrangler.py`; `unsafe` may hold only `bindings` and `metadata`). `containers`, `site`, `wasm_modules`, `text_blobs`, `data_blobs`, `base_dir`, `tsconfig`, `alias`, `python_modules`, `rules`, `find_additional_modules` (the deploy uploads the single-file bundle), any key not on the list, an assets directory outside the artifact, any `.env` or `.dev.vars` file and a source map comment naming a file outside the bundle are refused. A TOML config needs Python 3.11 or later on `deploy_runner`. `build_command` sees repository variables only, not the Environment's.

**The caller must use `secrets: inherit`** when the token lives on an Environment. A job that calls a reusable workflow cannot declare `environment:`, and `on.workflow_call` has no `environment` keyword, so an environment-scoped secret cannot be passed explicitly. It is resolved by the `environment:` declared on this workflow's deploy job, and `secrets: inherit` is what makes that possible. An explicit `secrets:` block still works for a repository-level secret.

Inputs:
- `command` (string, default `deploy`) — one of `deploy`, `versions upload`, `pages deploy`; checked against that allowlist before wrangler runs
- `environment` (string, default `""`) — required, except on a bare-SemVer tag push
- `wrangler_env` (string, default `""`) — overrides the wrangler `--env` name; the literal `none` omits `--env` entirely
- `ref` (string, default `""`)
- `production_environment` (string, default `production`)
- `enabled` (string, default `""`) — the kill switch
- `runner` (string, default `ubuntu-latest`) runs `resolve` and `build`; `deploy_runner` (string, default `ubuntu-latest`) runs `deploy` and needs `/usr/bin/python3` 3.11 or later
- `timeout_minutes` (number, default `30`), `fetch_depth` (number, default `1`), `working_directory` (string, default `"."`)
- `node_version` (string, default `""`), `package_manager` (string, default `npm`), `install_command` (string, default `""`), `build_command` (string, default `""`)
- `config_path` (string, default `""`), `config_glob` (string, default `""`) - Workers lane only; empty uses `wrangler.json`, `wrangler.jsonc` or `wrangler.toml` in `working_directory`
- `version` (string, default `""`), `version_file` (string, default `VERSION`), `version_suffix` (string, default `sha7`), `version_var` (string, default `VERSION`)
- `deploy_args` (string, default `""`) - checked word by word. Pages lane: the directory to upload first, then `--project-name`, `--branch`, `--commit-hash`, `--commit-dirty`, `--skip-caching`. Workers lane: `--name`, `--compatibility-date`, `--compatibility-flag(s)`, `--keep-vars`, `--dispatch-namespace`, `--tag`, `--message`. Any other word fails the run.
- `wrangler_version` (string, default `""`) - empty or the pinned version; any other value fails the run
- `deploy_command`, `wrangler_command` (string, default `""`) - removed. Setting either fails the `resolve` job with an error naming the replacement: `build_command` for the build, `command` and `deploy_args` for the wrangler call.
- `base_url` (string, default `""`), `smoke_path` (string, default `/health`), `smoke_version_path` (string, default `""`), `smoke_version_field` (string, default `version`)
- `concurrency_key` (string, default `""`)

Secrets:
- `CLOUDFLARE_API_TOKEN` (optional) — Account > Workers Scripts > Edit for the Workers lane; Account > Cloudflare Pages > Edit for the Pages lane. Declared optional so a disabled run does not require one; a run that reaches the deploy step without it fails at an explicit preflight.
- `CLOUDFLARE_ACCOUNT_ID` (optional) — only if you would rather not keep the account id in a variable.

Outputs: `deployed`, `environment`, `version`, `url`.

### Two rules worth stating once

**A job output is a string.** `deployed` is `"true"`, `"false"`, or **empty** — empty when the kill switch is off, because the deploy job is skipped and a skipped job has no outputs. `if: needs.deploy.outputs.deployed` is truthy for `"false"` too, since every non-empty string is. Compare it as `== 'true'`, and use `!= 'true'` for "did not deploy" — `== 'false'` misses the disabled case. This workflow avoids the trap internally by having its `resolve` job emit an enum (`deploy` / `disabled`) rather than a boolean, so no output value can be a fake boolean.

**An empty account id is not an error to wrangler.** It resolves the account from the token instead, which is correct for a token scoped to one account and a coin toss otherwise — so a deploy that lands on the wrong account looks exactly like one that worked. The account id is read from `vars` first and `secrets` second, and a preflight step fails loudly when both are empty.

The concurrency group is `ci-helpers-cloudflare-deploy-<environment>`. Do not name your own group the same thing: a caller's group is evaluated alongside the called workflow's, and a shared name leaves the deploy job queued behind the run that started it, permanently.

Example:

```yaml
jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/cloudflare-deploy.yml@production
    secrets: inherit
    permissions:
      contents: read
    with:
      enabled: ${{ vars.CLOUDFLARE_DEPLOY_ENABLED }}
      environment: staging
      node_version: "22"
      build_command: "npm run build"
      config_glob: "dist/*/wrangler.json"
      smoke_version_path: /api/status
```

## cloudflare-build.yml

Workflow: `.github/workflows/cloudflare-build.yml`

Purpose: Build a Worker and validate it with `wrangler deploy --dry-run`, deploying nothing.

It declares **no secrets** and no write scope, so a caller that checks its Worker on pull requests never writes `secrets: inherit` and no deploy credential is in scope while build code runs. That is the reason it is a separate file: GitHub validates a called workflow's declared permissions and secrets at run start, before any job-level `if:`.

What the dry run proves: the configuration is valid and the Worker bundles. What it does **not** prove: bindings, routes, or that the token can reach the account — none of that is reachable without calling the API. A green build means "this would compile", not "this would deploy".

Inputs: `runner`, `timeout_minutes`, `fetch_depth`, `working_directory`, `node_version`, `package_manager`, `install_command`, `build_command`, `config_path`, `config_glob`, `version_file`, `version_suffix`, `wrangler_version` (empty or the pinned version), `dry_run` (boolean, default `true`). `wrangler_command` is removed: setting it fails the run. The dry run uses the same pinned wrangler as `cloudflare-deploy.yml`.

Outputs: `version`, `config_path`.

Example:

```yaml
jobs:
  build:
    if: ${{ github.event_name == 'pull_request' }}
    uses: nikolareljin/ci-helpers/.github/workflows/cloudflare-build.yml@production
    permissions:
      contents: read
    with:
      node_version: "22"
      build_command: "npm run build"
      config_glob: "dist/*/wrangler.json"
```

## Release Build Overview

Workflow: `.github/workflows/release-build.yml`

Purpose: Build release artifacts, optionally upload workflow artifacts, and publish a GitHub release on tag-driven flows.

See the detailed `release-build.yml` section later in this document for the full input list and examples, including Flutter APK releases.

## flutter-release.yml

Workflow: `.github/workflows/flutter-release.yml`

Purpose: Build Flutter Android/iOS artifacts and optionally upload to Google
Play and App Store Connect with fastlane.

Jobs:

| Job | Runs | Holds |
|-----|------|-------|
| `build` | the caller's build (`runner`) | nothing: `contents: read`, no secret |
| `sign-android` | when `build_android`; on `android_sign_runner` | the upload key and, with `deploy_google_play`, the Play service account |
| `upload-app-store` | when `deploy_app_store`; on `app_store_runner` | the `match_*` and App Store Connect secrets |

- `build` runs `android_build_command`, `ios_build_command` (when
  `build_ios` and not `deploy_app_store`) and `ios_archive_command` (when
  `deploy_app_store`), stages the files matching `android_artifact_path`
  (`.aab` or `.apk`, a plain name) and the archive at `ios_archive_path` (as
  one tarball), and uploads them with a sha256 manifest under
  `flutter-release-build-<run id>-<attempt>-<random>`, kept one day. It gets
  no keystore: `android/key.properties` is not written, so Gradle signs with
  the project's own release config (the Flutter template's is the debug key).
- `sign-android` and `upload-app-store` check out nothing of the caller's,
  check the artifact name, then check every file against the manifest
  (`scripts/artifact_parts.sh verify`) before they use it. They run only
  library scripts, the pinned Java (`actions/setup-java`), Ruby from the
  runner's tool cache (`scripts/setup_ruby.sh`) and fastlane installed by
  `scripts/install_fastlane.sh` from the library's
  `scripts/fastlane/Gemfile.lock`: frozen, rubygems.org only, every gem
  checked against the lockfile's sha256 by Bundler (`BUNDLER_VERSION`,
  itself checked against `BUNDLER_GEM_SHA256` in `toolchain-pins.env`), all
  installed before a secret is read.
- `sign-android` removes the build's signature from each `.aab`
  (`scripts/zip_strip_signature.py`), signs it with `jarsigner` and the
  upload key, verifies it, and uploads `android_artifact_name` (when
  `upload_artifacts`). Without the four keystore secrets the bundle is passed
  on as built, with a warning; with `deploy_google_play` that fails. With
  the four secrets set, an `.apk` fails the job (it needs `apksigner`):
  build an app bundle.
- With `deploy_google_play`, `sign-android` runs `fastlane supply` with the
  one signed `.aab`, `android_package_name`, `google_play_track` and
  `google_play_release_status`; metadata, images and changelogs are not
  uploaded.
- `upload-app-store` unpacks the archive (`scripts/safe_untar.py`: one
  `<name>.xcarchive`, no `..`, no absolute path, no link target with `..`), checks
  that its one app's `CFBundleIdentifier` is `ios_bundle_id`, fetches the
  App Store certificate and profile with `fastlane match appstore --readonly`
  into a keychain of its own (deleted on exit), writes `exportOptions.plist`
  (`app-store-connect`, manual signing, profile `match AppStore
  <ios_bundle_id>`, `ios_team_id`) and runs `xcodebuild -exportArchive`. It
  then uploads the IPA with `fastlane pilot upload` (`app_store_destination:
  testflight`) or `fastlane deliver` without metadata, screenshots or a
  review submission (`app_store`).
- fastlane runs from an empty directory with `FASTLANE_SKIP_UPDATE_CHECK`,
  `FASTLANE_OPT_OUT_USAGE` and `FASTLANE_HIDE_CHANGELOG` set and no
  `BUNDLE_GEMFILE` (`scripts/fastlane_run.sh`): no `Fastfile`, `Appfile`,
  `Matchfile`, `Pluginfile` or `Gemfile` of the caller is read, and no lane
  runs. Every value it gets is a checked input or a secret.
- The key files (keystore, Play JSON, App Store Connect key) are written
  under a 0700 directory the script removes on exit.
- Ruby: `ruby_version` is matched as `ruby/setup-ruby` matched it (`3` is
  the newest 3.y.z the tool cache holds, `3.4` the newest 3.4.z). The hosted
  images cache Ruby 3.2, 3.3, 3.4 and 4.0.
- Flutter comes from the official release archive through
  `scripts/setup_flutter.sh` from the library checkout, on every run; no
  third-party action. An empty `flutter_version` on the `stable` channel
  installs the release pinned in `toolchain-pins.env` (`FLUTTER_VERSION`),
  checked against both the pin and the manifest's sha256; an exact version
  or an `X.Y` prefix is checked against the manifest's sha256; `beta` or
  `dev` without a version is the newest of the channel. A channel name in
  `flutter_version` is read as the channel; `master` and `main` are refused.
  Nothing is cached (see [Cache trust](SECURITY.md#cache-trust)).

Inputs:

- `runner` (string, default `ubuntu-latest`; the `build` job. `macos-latest` for iOS)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `flutter_version` (string, default `""`; empty is the pinned release on `stable`, the newest on another channel; `3.47.9`, or `3.47` for the newest of that line)
- `flutter_channel` (string, default `stable`; `stable`, `beta` or `dev`)
- `java_version` (string, default `"17"`)
- `ruby_version` (string, default `"3.4"`; the upload jobs' Ruby for fastlane)
- `build_android` (boolean, default `true`)
- `build_ios` (boolean, default `false`)
- `deploy_google_play` (boolean, default `false`; needs `build_android: true`)
- `deploy_app_store` (boolean, default `false`; needs a macOS `runner`)
- `android_build_command` (string, default `flutter build appbundle --release`; shell code, run as written)
- `ios_build_command` (string, default `flutter build ipa --release`; shell code, run as written; not run when `deploy_app_store`)
- `ios_archive_command` (string, default `flutter build ipa --release --no-codesign`; shell code, run when `deploy_app_store`; must leave an unsigned archive at `ios_archive_path`)
- `ios_archive_path` (string, default `build/ios/archive/Runner.xcarchive`; relative to `working_directory`)
- `android_artifact_path` (string, default `build/app/outputs/bundle/release/*.aab`)
- `ios_artifact_path` (string, default `build/ios/ipa/*.ipa`)
- `upload_artifacts` (boolean, default `true`)
- `android_artifact_name` (string, default `flutter-android`; uploaded by `sign-android`)
- `ios_artifact_name` (string, default `flutter-ios`)
- `android_package_name` (string, default `""`; the application id, such as `com.example.app`; required by `deploy_google_play`)
- `google_play_track` (string, default `internal`; `internal`, `alpha`, `beta`, `production` or a custom track of `[a-z0-9_:-]`)
- `google_play_release_status` (string, default `completed`; `completed`, `draft`, `halted` or `inProgress`)
- `android_sign_runner` (string, default `ubuntu-latest`; the `sign-android` job)
- `ios_bundle_id` (string, default `""`; required by `deploy_app_store`)
- `ios_team_id` (string, default `""`; the 10-character Apple team id; required by `deploy_app_store`)
- `app_store_destination` (string, default `testflight`; `testflight` runs `pilot upload`, `app_store` runs `deliver`)
- `app_store_runner` (string, default `macos-latest`; the `upload-app-store` job)
- `timeout_minutes` (number, default `60`) - the `build` job's timeout; the
  default covers a cold Flutter build on a macOS runner.

Secrets:

- `android_keystore_base64`, `android_keystore_password`, `android_key_alias`, `android_key_password` (the upload key; all four or none; required by `deploy_google_play`)
- `google_play_service_account_json` (required by `deploy_google_play`)
- `app_store_connect_api_key_base64`, `app_store_connect_key_id`, `app_store_connect_issuer_id` (required by `deploy_app_store`)
- `match_git_url`, `match_password` (required by `deploy_app_store`: the `match` storage repository and its passphrase)
- `match_git_basic_authorization` (optional, base64 `user:token` for a private `match` repository)

Example (Android build + Play Store deploy):

```yaml
jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/flutter-release.yml@production
    with:
      working_directory: "apps/mobile"
      build_android: true
      deploy_google_play: true
      android_package_name: com.example.app
      google_play_track: internal
    secrets:
      android_keystore_base64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
      android_keystore_password: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
      android_key_alias: ${{ secrets.ANDROID_KEY_ALIAS }}
      android_key_password: ${{ secrets.ANDROID_KEY_PASSWORD }}
      google_play_service_account_json: ${{ secrets.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON }}
```

Example (iOS build + TestFlight upload, macOS runner):

```yaml
jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/flutter-release.yml@production
    with:
      runner: macos-latest
      working_directory: "apps/mobile"
      build_android: false
      deploy_app_store: true
      ios_bundle_id: com.example.app
      ios_team_id: ABCDE12345
    secrets:
      app_store_connect_api_key_base64: ${{ secrets.APP_STORE_CONNECT_API_KEY_BASE64 }}
      app_store_connect_key_id: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
      app_store_connect_issuer_id: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
      match_git_url: ${{ secrets.MATCH_GIT_URL }}
      match_password: ${{ secrets.MATCH_PASSWORD }}
      match_git_basic_authorization: ${{ secrets.MATCH_GIT_BASIC_AUTHORIZATION }}
```

## trivy-scan.yml

Workflow: `.github/workflows/trivy-scan.yml`

Purpose: Run Trivy filesystem scan with optional SARIF upload.

Trivy is the release binary pinned by version and sha256 in the library's
`scanner-pins.env`, downloaded and verified in the job; no third-party action.
The vulnerability database is fetched in its own step and the scan runs with
`--skip-db-update --skip-check-update --offline-scan`, and every Trivy call
passes `--disable-telemetry --skip-version-check`, so nothing is reported to
Aqua. The report holds the requested `severity` only.

Inputs:

- `runner` (string, default `ubuntu-latest`)
- `scan_path` (string, default `"."`)
- `format` (string, default `sarif`)
- `output` (string, default `trivy-results.sarif`)
- `severity` (string, default `CRITICAL,HIGH`)
- `ignore_unfixed` (string, default `"true"`)
- `vuln_type` (string, default `os,library`)
- `scanners` (string, default `vuln`) -- comma-separated Trivy scanners.
  `misconfig` reads Dockerfiles, compose files, Kubernetes manifests and
  Terraform; `secret` is Trivy's own secret scanner, which `gitleaks-scan.yml`
  already covers. The rulesets ship with the binary, so this costs a flag and
  not a tool:

  ```yaml
  with:
    scanners: vuln,misconfig
  ```
- `skip_dirs` (string, default `""`) -- comma-separated directories to leave
  out. Use it for fixtures that are wrong on purpose: a Security tab full of
  findings nobody is going to act on is one people stop reading.

**The caller must grant `security-events: write`, even with
`upload_sarif: false`.** This workflow declares that permission, and GitHub
compares a called workflow's declared permissions against the caller's when it
resolves the call -- before any job runs, and regardless of which steps would
have used it. A caller granting only `contents: read` is refused, and the
refusal arrives as a `startup_failure` with no annotation while every other
check stays green:

```yaml
jobs:
  trivy:
    permissions:
      contents: read
      security-events: write
    uses: nikolareljin/ci-helpers/.github/workflows/trivy-scan.yml@production
```
- `fail_on_findings` (boolean, default `false`)
- `upload_sarif` (boolean, default `true`)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `trivy-results`)

Example:

```yaml
jobs:
  trivy:
    uses: nikolareljin/ci-helpers/.github/workflows/trivy-scan.yml@production
    with:
      scan_path: "."
      fail_on_findings: true
      upload_artifact: true
```

## codeql-scan.yml

Workflow: `.github/workflows/codeql-scan.yml`

Purpose: Static analysis with CodeQL.

This is the one workflow here that runs CodeQL. `trivy-scan.yml` and
`security-weekly.yml` use `codeql-action` only for `upload-sarif`, to put other
tools' reports into the Security tab.

Inputs:

- `runner` (string, default `ubuntu-latest`)
- `languages` (string, default `""`) -- comma-separated: `actions`, `c-cpp`,
  `csharp`, `go`, `java-kotlin`, `javascript-typescript`, `python`, `ruby`,
  `rust`, `swift`. **Empty is refused.** CodeQL has no sensible default, and an
  analysis that found no source reports no findings, which reads exactly like a
  clean one.
- `build_mode` (string, default `""`) -- `none`, `autobuild` or `manual`. Left
  empty the action picks: `none` where it can, `autobuild` otherwise.
- `build_command` (string, default `""`) -- runs between init and analyse, for
  `build_mode: manual`.
- `config_file` (string, default `""`) -- a CodeQL config, for query selection
  and `paths` / `paths-ignore`.
- `queries` (string, default `""`) -- e.g. `security-extended`,
  `security-and-quality`.
- `diff_informed` (boolean, default `true`) -- **on a pull request CodeQL
  reports only alerts inside the diff.** It logs `Computing PR diff ranges` and
  says nothing about code the pull request did not touch. That is GitHub's
  default and usually what a reviewer wants, but it means a first run on an
  existing repository shows far less than expected, and a gate built on it will
  not fail for anything already in the tree. Set `false` to analyse everything
  on every event.
- `upload` (boolean, default `true`) -- file results in the Security tab. Turn
  it off to run the analysis without filing alerts.
- `fetch_depth` (number, default `0`), `timeout_minutes` (number, default `45`)

Outputs:
- `results` - total results across every report. Tells "no findings" apart from "nothing analysed" together with `rules`.
- `rules` - number of rules the analysis ran.

**The caller must grant three permissions, whether or not it uploads**, for the
reason described under `trivy-scan.yml`: the check is against what the called
workflow *declares*, at call resolution, before any job runs.

```yaml
jobs:
  codeql:
    permissions:
      contents: read
      security-events: write
      actions: read
    uses: nikolareljin/ci-helpers/.github/workflows/codeql-scan.yml@production
    with:
      languages: python
```

The run ends by printing how many results and rules each report carried.
`analyze` is content to produce an empty database, so "no findings" about a
language whose source was never located is the failure this preset is built to
avoid -- the count is there to be read.

## gitleaks-scan.yml

Workflow: `.github/workflows/gitleaks-scan.yml`

Purpose: Enforce Gitleaks checks without exporting scanner results.

Note: When findings are detected, the workflow prints a link to Leak-Lock for help
removing leaked credentials.

Inputs:

- `runner` (string, default `ubuntu-latest`)
- `scan_path` (string, default `"."`)
- `report_format` (string, default `sarif`)
- `output` (string, default `results.sarif`)
- `config_path` (string, default `""`)
- `fail_on_findings` (boolean, default `true`)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `gitleaks-report`)
- `gitleaks_version` (string, default `v8.30.1`) - release tag to download. Pin it for reproducible scans.
- `gitleaks_sha256` (string, default `""`) - sha256 of the release archive for the runner; required with any version other than `v8.30.1`, whose archive digests are pinned in the action; with `v8.30.1` it may only repeat the pinned digest, a different one is refused

Notes:

- `report_format`, `output` and `artifact_name` are deprecated and create no report.
  `upload_artifact: true` and `fail_on_findings: false` are refused.
- Failures identify Gitleaks and the branch and link
  https://nikolareljin.github.io/leak-lock/ for local Scan Repository and test runs.
  Results and report paths never appear in CI output.
- `scan_path` and `config_path` are honored. The scan
  runs a pinned `gitleaks` binary, verified against a sha256 held in
  `scanner-pins.env` (or `gitleaks_sha256`), not one fetched from the same release.
- Rules and `.gitleaksignore` are read from the pull request's base commit.
  gitleaks also reads the `.gitleaksignore` in the scanned tree on its own,
  so one that differs from the base's (added, extended, or a link) fails the
  scan; change the ignore list in its own pull request first.
- **In a git work tree the scan reads the repository's history**, so naming a
  subdirectory in `scan_path` does not narrow it -- every commit is still
  scanned. Outside a work tree the files under `scan_path` are scanned instead.
- A scan that examines nothing fails rather than reporting no findings. Two
  cases: a work tree whose history cannot be read, and a `scan_path` with
  nothing in it. A scan pointed at a generated directory that is empty -- an
  unpacked archive, a build output -- fails instead of reporting clean.

Example:

```yaml
jobs:
  gitleaks:
    uses: nikolareljin/ci-helpers/.github/workflows/gitleaks-scan.yml@production
    with:
      scan_path: "."
      fail_on_findings: true
      upload_artifact: false
```

## foxguard-scan.yml

Workflow: `.github/workflows/foxguard-scan.yml`

Purpose: Enforce Foxguard static-analysis checks without exporting scanner results.

Note: When findings are detected, the workflow prints a link to Leak-Lock for help
reproducing and fixing them locally.

Inputs:

- `runner` (string, default `ubuntu-latest`)
- `scan_path` (string, default `"."`)
- `severity` (string, default `medium`) - lowest severity that fails the scan: `low`, `medium`, `high` or `critical`
- `config_path` (string, default `""`) - foxguard config file, relative to the repository; read from the pull request's base commit
- `foxguard_version` (string, default `v0.14.1`) - release tag to download. Pin it for reproducible scans.
- `foxguard_sha256` (string, default `""`) - sha256 of the release binary for the runner; required with any version other than `v0.14.1`, whose binary digests are pinned in `scanner-pins.env`; with `v0.14.1` it may only repeat the pinned digest, a different one is refused
- `fail_on_findings` (boolean, default `true`) - `false` is refused

Notes:

- Failures identify Foxguard and the branch and link
  https://nikolareljin.github.io/leak-lock/ for local Scan Repository and test runs.
  Results, counts, rule ids, file paths and report paths never appear in CI output.
- The scan runs a pinned `foxguard` binary, verified against a sha256 held in
  the action (or `foxguard_sha256`), not one fetched from the same release.
- The scan reads the files under `scan_path`; `.` is the whole repository.
  The repository is checked out under `repo/` beside the library's own
  checkout, so the library's scripts are never under the scanned path.
- Configuration comes from the base commit of a pull request (`HEAD` on other
  events): `config_path`, or `.foxguard.yml` when present, and otherwise an
  empty config. A `.foxguard.yml` added or changed by the pull request is not
  read, and a config with a `baseline` entry is refused, so a pull request
  cannot silence what it adds. Inline `foxguard: ignore[...]` comments are the
  scanner's own and still apply; they are visible in the diff.
- A scan that reads no file fails rather than reporting no findings: foxguard
  skips files it cannot parse and hidden directories, so a `scan_path` holding
  only those is refused.

Example:

```yaml
jobs:
  foxguard:
    uses: nikolareljin/ci-helpers/.github/workflows/foxguard-scan.yml@production
    with:
      scan_path: "."
      severity: medium
```

## gitleaks-new-findings.yml

Workflow: `.github/workflows/gitleaks-new-findings.yml`

Purpose: Fail a pull request only on secrets the commits it adds contain, without exporting scanner results.

Note: When findings are detected, the workflow prints a link to Leak-Lock for help
removing leaked credentials.

Inputs:

- `runner` (string, default `ubuntu-latest`)
- `base_ref` (string, default `""`) - commit or branch the review starts from; empty reads it from the event (see notes)
- `scan_path` (string, default `"."`) - path inside the repository; the scan reads the commits the review adds, so a subdirectory does not narrow it
- `config_path` (string, default `""`) - `.gitleaks.toml`, relative to the repository, read from the base commit
- `gitleaks_version` (string, default `v8.30.1`) - release tag to download. Pin it for reproducible scans.
- `gitleaks_sha256` (string, default `""`) - sha256 of the release archive for the runner; required with any version other than `v8.30.1`, whose archive digests are pinned in `scanner-pins.env`; with `v8.30.1` it may only repeat the pinned digest, a different one is refused
- `fail_on_findings` (boolean, default `true`) - `false` is refused

Notes:

- The scan is `gitleaks git` over `<merge-base>..HEAD`: the merge base of
  `HEAD` and the base commit, so a secret added in one commit of the review
  and removed in a later one is still found, and a secret already on the base
  is not reported. `gitleaks-scan.yml` scans the whole history and fails on
  it; use that one for a periodic full scan.
- The base, in order: `base_ref`; a pull request's base commit; a push's
  `before`, when it is a commit in the repository and an ancestor of `HEAD`
  (the state the branch was pushed from). Otherwise (a new branch's all-zero
  `before`, a force push whose `before` is gone or rewritten) the push is
  compared with the repository's default branch, so the first push of the
  default branch itself has an empty range. `pull_request_target` is
  refused: its checkout is the base branch, so the range would hold none of
  the pull request's commits. Call the workflow from a `pull_request`
  trigger instead. Any other event needs `base_ref`. A base that is not in the repository, no merge base, or an
  empty range (`HEAD` is the base, or behind it) fails the run: nothing
  passes because the base could not be found.
- `base_ref` is a full commit sha, or a branch of the remote written as
  `main`, `origin/main` or `refs/remotes/origin/main`. A short sha, a tag, a
  local branch or `HEAD` is refused: those are names a pull request can
  create or shadow, so no bare `git rev-parse <name>` is ever run.
- Rules and `.gitleaksignore` are read from the merge base, never from the
  tree under review, so a pull request cannot silence what it adds. gitleaks
  also reads the `.gitleaksignore` in the scanned tree on its own, so one
  that differs from the merge base's (added, extended, or a link) fails the
  run; change the ignore list in its own pull request first.
- Failures identify Gitleaks and the branch and link
  https://nikolareljin.github.io/leak-lock/ for local Scan Repository and test runs.
  Results and report paths never appear in CI output.
- The repository is checked out with full history under `repo/`, beside the
  library's own checkout.

Example:

```yaml
jobs:
  secrets:
    uses: nikolareljin/ci-helpers/.github/workflows/gitleaks-new-findings.yml@production
```

## foxguard-new-findings.yml

Workflow: `.github/workflows/foxguard-new-findings.yml`

Purpose: Fail a pull request only on Foxguard findings its changes add, without exporting scanner results.

Note: When findings are detected, the workflow prints a link to Leak-Lock for help
reproducing and fixing them locally.

Inputs:

- `runner` (string, default `ubuntu-latest`)
- `base_ref` (string, default `""`) - commit or branch the review starts from; empty reads it from the event (see `gitleaks-new-findings.yml`)
- `scan_path` (string, default `"."`)
- `severity` (string, default `medium`) - lowest severity that fails the scan: `low`, `medium`, `high` or `critical`
- `config_path` (string, default `""`) - foxguard config file, relative to the repository; read from the base commit
- `allow_unscanned` (string, default `""`) - glob patterns from the repository root (comma- or newline-separated) naming changed files foxguard may skip (minified, over 1 MiB, not UTF-8, not parseable) without failing; matching files are still scanned and their findings still fail. Set here, in the calling workflow, rather than in the tree under review. Syntax and trade-off: `foxguard-diff` in `docs/actions.md`
- `foxguard_version` (string, default `v0.14.1`) - release tag to download. Pin it for reproducible scans.
- `foxguard_sha256` (string, default `""`) - sha256 of the release binary for the runner; required with any version other than `v0.14.1`, whose binary digests are pinned in `scanner-pins.env`; with `v0.14.1` it may only repeat the pinned digest, a different one is refused
- `fail_on_findings` (boolean, default `true`) - `false` is refused

Notes:

- The scan is `foxguard diff <merge-base>`: findings in the tree under review
  that the merge base's tree does not have. A finding whose lines move is not
  new, and neither is one in a file the review renames without changing it
  (inside `scan_path`, with no config): the base foxguard compares with has
  those renames applied. An edited rename is a new file. `foxguard-scan.yml` reports every finding; use that one for a
  periodic full scan.
- The base is resolved as `gitleaks-new-findings.yml` describes (same
  `base_ref` forms, same push rule), and fails the run the same way when it
  cannot be.
- Configuration comes from the merge base: `config_path`, or `.foxguard.yml`
  when present, and otherwise an empty config. A config the review adds is
  not read, and a config with a `baseline` entry is refused.
- A scan that reads no file fails rather than reporting no findings, unless
  the review adds or changes no file under `scan_path` (a deletion); a
  repository with no file foxguard parses runs `scan-new-findings.yml` with
  `tools: gitleaks` instead.
- Failures identify Foxguard and the branch and link
  https://nikolareljin.github.io/leak-lock/ for local Scan Repository and test runs.
  Results, counts, rule ids, file paths and report paths never appear in CI output.

Example:

```yaml
jobs:
  static-analysis:
    uses: nikolareljin/ci-helpers/.github/workflows/foxguard-new-findings.yml@production
    with:
      severity: medium
```

## scan-new-findings.yml

Workflow: `.github/workflows/scan-new-findings.yml`

Purpose: Fail a pull request only on what it adds: secrets (Gitleaks) and static-analysis findings (Foxguard), as two parallel jobs.

This is the workflow to adopt. `gitleaks-new-findings.yml` and
`foxguard-new-findings.yml` stay for a repository that wants one tool and
nothing else.

Inputs:

- `runner` (string, default `ubuntu-latest`)
- `tools` (string, default `gitleaks,foxguard`) - which scanners run; empty, an unknown name or a repeated name fails the run before anything is checked out or downloaded
- `base_ref` (string, default `""`) - commit or branch the review starts from; empty reads it from the event (see `gitleaks-new-findings.yml`)
- `scan_path` (string, default `"."`)
- `severity` (string, default `medium`) - lowest Foxguard severity that fails the scan
- `gitleaks_config_path` (string, default `""`) - `.gitleaks.toml`, relative to the repository, read from the base commit
- `foxguard_config_path` (string, default `""`) - foxguard config file, relative to the repository, read from the base commit
- `allow_unscanned` (string, default `""`) - as `foxguard-new-findings.yml`: changed files Foxguard may skip without failing
- `gitleaks_version` (string, default `v8.30.1`)
- `gitleaks_sha256` (string, default `""`) - required with any version other than `v8.30.1`; with `v8.30.1` it may only repeat the pinned digest
- `foxguard_version` (string, default `v0.14.1`)
- `foxguard_sha256` (string, default `""`) - required with any version other than `v0.14.1`; with `v0.14.1` it may only repeat the pinned digest
- `fail_on_findings` (boolean, default `true`) - `false` is refused

Notes:

- Three jobs: `tools` reads the input and runs no checkout; `gitleaks` and
  `foxguard` each wait on `tools` only, never on each other, and neither has
  `continue-on-error`, so one failing leaves the other's verdict visible.
- Each scan job behaves as the single-tool workflow of the same name.

Example:

```yaml
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  new-findings:
    uses: nikolareljin/ci-helpers/.github/workflows/scan-new-findings.yml@production
    with:
      tools: gitleaks,foxguard
```

## ppa-deb.yml

Workflow: `.github/workflows/ppa-deb.yml`

Purpose: Build a Debian source package and upload it to a Launchpad PPA.

Inputs:

- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `prebuild_command` (string, default `"make man"`)
- `build_command` (string, default `""`)
- `series` (string, default `""`)
- `ppa_target` (string, required, e.g. `ppa:your-launchpad-id/ppa-name`)
- `publish_runner` (string, default `ubuntu-latest`): runner for the `ppa` job, which holds the keys; not `runner`, since a reused self-hosted machine can carry state left by the build. It needs apt
- `upload_method` (string, default `ftp`): `ftp` uploads anonymously and Launchpad accepts the upload on the GPG signature; `sftp` logs in with the SSH key
- `launchpad_login` (string, default: the owner in `ppa_target`): sftp only; Launchpad user the SSH key belongs to; set it for a team PPA
- `launchpad_known_hosts` (string, default: Launchpad's RSA host key for `ppa.launchpad.net`, fingerprint `SHA256:MGq+4hxD7RduVTcfwlwwboZnsgJC6SL/NltM8ye+gNg`): sftp only; the only host key ssh accepts (`StrictHostKeyChecking yes`). Launchpad publishes its fingerprints at <https://ubuntu.com/docs/launchpad/user/reference/ssh-fingerprints/>; override only if it rotates the key
- `deb_fullname` (string, default `""`)
- `deb_email` (string, default `""`)
- `signing_key_id` (string, required, GPG key ID or fingerprint)
- `extra_packages` (string, default `""`)

Secrets:

- `gpg_private_key` (armored private key)
- `gpg_passphrase` (GPG key passphrase)
- `launchpad_ssh_private_key` (SSH key registered with Launchpad; required for `upload_method: sftp` only)

Note: The workflow disables shell xtrace (`set +x`) in secret-handling steps to avoid leaking credentials.

Two jobs. `build` runs the prebuild and build with no key on the runner and produces an unsigned source package (default build `debuild -S -sa -us -uc`), then uploads every file the `.changes` names as an artifact (kept one day) with a sha256 manifest. `ppa` checks out nothing of the caller's: it downloads the artifact, checks it against the manifest, imports the GPG key into a temporary keyring, signs the `.changes` with `debsign` and deletes the keyring, then runs `dput` (with `sftp`, it writes the Launchpad SSH key first and deletes it after). A custom `build_command` must therefore not sign.

The upload goes to `ppa.launchpad.net` with incoming `~<owner>/<distribution>/<name>/` (distribution `ubuntu` unless `ppa_target` names one). Over `ftp` (the default) it is anonymous. Over `sftp` it logs in as `launchpad_login`, so the key must be registered with that Launchpad account.

The packaging scripts come from script-helpers at a pinned commit, checked out by the workflow and kept outside the source tree; the caller does not vendor them. The caller's `build_command`, if set, must produce a source package (`*_source.changes`).

Example:

```yaml
jobs:
  ppa:
    uses: nikolareljin/ci-helpers/.github/workflows/ppa-deb.yml@production
    with:
      working_directory: "."
      ppa_target: "ppa:your-launchpad-id/distrodeck"
      deb_fullname: "Nikola Reljin"
      deb_email: "nikola.reljin@gmail.com"
      signing_key_id: ${{ secrets.PPA_GPG_KEY_ID }}
    secrets:
      gpg_private_key: ${{ secrets.PPA_GPG_PRIVATE_KEY }}
      gpg_passphrase: ${{ secrets.PPA_GPG_PASSPHRASE }}
```

Over sftp, add `upload_method: "sftp"` under `with:` and
`launchpad_ssh_private_key: ${{ secrets.PPA_SSH_PRIVATE_KEY }}` under `secrets:`.

## rpm-build.yml

Workflow: `.github/workflows/rpm-build.yml`

Purpose: Build RPM artifacts, upload them as a workflow artifact, and optionally attach them to a GitHub release.

script-helpers must be at `vendor/script-helpers` (used first when present) or `scripts/script-helpers` (a submodule). The workflow never creates `vendor/`, which would put a Go module in vendor mode.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `ref` (string, default `""`): git ref to build (tag, branch or commit); empty builds the ref the workflow runs on. Set it to the tag to rebuild an older release.
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `prebuild_command` (string, default `""`)
- `spec_path` (string, default `""`, path to `.spec`)
- `artifact_dir` (string, default `"dist"`)
- `extra_packages` (string, default `""`)
- `artifact_name` (string, default `"rpm-packages"`)
- `artifact_glob` (string, default `"dist/*.rpm"`)
- `upload_to_release` (string, default `"false"`): whether this run's `.rpm` files go to a release: `"true"` always, `"auto"` only on a version tag push or with `release_tag` (or a version-tag `ref`). It sets the `tag` and `skip` outputs; `release-upload.yml` does the upload, so this workflow keeps `contents: read`.
- `release_tag` (string, default `""`): release to attach to; empty takes `ref` when set, else the tag the workflow runs on.

Outputs: `artifact_id`, `tag`, `commit`, `skip` (`"true"` when `upload_to_release` says not to upload, including the default `"false"`).

Example:

```yaml
jobs:
  rpm:
    uses: nikolareljin/ci-helpers/.github/workflows/rpm-build.yml@production
    with:
      prebuild_command: "./tools/gen-man.sh"
      spec_path: "packaging/myapp.spec"
      artifact_glob: "dist/*.rpm"
```

To attach the `.rpm` files to a release, add a job with `contents: write`:

```yaml
jobs:
  rpm:
    uses: nikolareljin/ci-helpers/.github/workflows/rpm-build.yml@production
    with:
      upload_to_release: auto
  rpm-release:
    needs: rpm
    if: needs.rpm.outputs.skip == 'false'
    permissions:
      contents: write
    uses: nikolareljin/ci-helpers/.github/workflows/release-upload.yml@production
    with:
      artifact_id: ${{ needs.rpm.outputs.artifact_id }}
      tag: ${{ needs.rpm.outputs.tag }}
      commit: ${{ needs.rpm.outputs.commit }}
      files: "*.rpm"
```

## release-upload.yml

Workflow: `.github/workflows/release-upload.yml`

Purpose: Attach the files of one workflow artifact to a GitHub release. It adds files and never changes the release notes; a tag that does not exist yet is created at `commit`. It is separate from the build workflows so they keep `contents: read`: a reusable workflow holding a write job fails to start for a caller that grants read, even when that job would be skipped.

Inputs:
- `artifact_id` (string, required): the artifact holding the files, e.g. `rpm-build.yml`'s `artifact_id` output
- `tag` (string, required): release tag; one word
- `commit` (string, default `""`): commit a new tag is created at; empty uses the commit the workflow runs on
- `files` (string, default `"*"`): one glob inside the artifact, matching regular files and not dotfiles; no whitespace, not absolute, no `..` segment. Exactly the files it matches are uploaded; a match that resolves outside the artifact (a symlink) or whose path holds anything but letters, digits, `. _ + @ -` and `/` fails the job.

## homebrew-package.yml

Workflow: `.github/workflows/homebrew-package.yml`

Purpose: Build a Homebrew tarball, generate a formula, upload artifacts, and optionally publish to a tap repo.

script-helpers must be at `vendor/script-helpers` (used first when present) or `scripts/script-helpers` (a submodule). The workflow never creates `vendor/`, which would put a Go module in vendor mode.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `prebuild_command` (string, default `""`)
- `name` (string, required)
- `desc` (string, required)
- `homepage` (string, required)
- `license` (string, default `MIT`)
- `deps` (string, default `""`, comma-separated)
- `entrypoint` (string, default `""`)
- `man_path` (string, default `""`)
- `use_libexec` (string, default `"false"`)
- `env_var` (string, default `""`)
- `tarball_url` (string, default `""`)
- `release_repo` (string, default `""`, used to build a default tarball URL)
- `release_tag` (string, default `""`) -- the release this build belongs to, equal to `VERSION` or `v<VERSION>`. With `publish: "true"` the tarball is uploaded to that release of this repository and the formula points at it. The caller grants `contents: write`; only the `release-asset` job uses it, the build (and `prebuild_command`) runs with `contents: read`. An asset already on the release is never replaced: the same sha256 passes, a different one fails
- `formula_path` (string, default `""`)
- `dist_dir` (string, default `"dist"`)
- `exclude_paths` (string, default `".git,.github,dist"`, comma-separated)
- `artifact_name` (string, default `"homebrew-artifacts"`)
- `artifact_glob` (string, default `""`, optional override)
- `publish` (string, default `"false"`)
- `tap_repo` (string, default `""`)
- `tap_branch` (string, default `"main"`)
- `tap_dir` (string, default `"Formula"`)
- `commit_message` (string, default `""`)

Secrets (publishing goes through [homebrew-tap-publish.yml](#homebrew-tap-publishyml)):
- `tap_deploy_key` (SSH key of a write deploy key on the tap; preferred)
- `tap_token` (token with write access to the tap; used only without `tap_deploy_key`)
- `tap_repo` (the tap as `owner/repo`, when kept as a secret instead of the input)

`publish: "true"` needs `release_tag` and refuses `tarball_url`: the formula's
sha256 is of the tarball this run builds, so it must be the file the url serves.
Without it the job fails, so a push to `main` cannot publish unreleased code.

The build job runs with `contents: read` only, `prebuild_command` included. A
prebuild that needs another scope (`packages: read` for a private registry,
`id-token`) has to get it some other way.

`VERSION` (in `working_directory`) must hold a single version -- letters, digits
and `. + _ -`, e.g. `1.2.3`; a trailing Windows line ending is dropped. Anything
else (a second line, spaces, `=`) fails the job with an error rather than being
exported to later steps.

Example:

```yaml
jobs:
  # release: a job that cuts the release and outputs its tag, or '' when none.
  brew:
    needs: release
    permissions:
      contents: write   # uploads the tarball to the release
    uses: nikolareljin/ci-helpers/.github/workflows/homebrew-package.yml@production
    with:
      name: "myapp"
      desc: "Shell tool packaged for Homebrew"
      homepage: "https://github.com/owner/myapp"
      deps: "dialog,jq,curl"
      entrypoint: "inc/myapp.sh"
      man_path: "docs/man/myapp.1"
      use_libexec: "true"
      env_var: "MYAPP_ROOT"
      # Set only when a release was cut; publishes nothing otherwise.
      release_tag: ${{ needs.release.outputs.tag }}
      publish: ${{ needs.release.outputs.tag != '' }}
    secrets:
      tap_repo: ${{ secrets.HOMEBREW_TAP_REPO }}
      tap_deploy_key: ${{ secrets.HOMEBREW_TAP_DEPLOY_KEY }}
```

## homebrew-tap-publish.yml

Workflow: `.github/workflows/homebrew-tap-publish.yml`

Purpose: Commit one Homebrew formula to a tap repository. Language-agnostic: the
calling job builds the formula and uploads it as an artifact of the same run.
`homebrew-package.yml` and `rust-release-tarballs.yml` publish through it.

Inputs:
- `formula_artifact` (string, required) -- artifact holding the formula
- `formula_file` (string, required) -- file name inside it, e.g. `myapp.rb`
- `tap_repo` (string, default `""`) -- tap as `owner/repo`; or pass the `tap_repo` secret
- `tap_branch` (string, default `"main"`)
- `tap_dir` (string, default `"Formula"`; `.` for the tap root)
- `commit_message` (string, default `""`, which commits `Update <name> formula`)
- `runner` (string, default `ubuntu-latest`)

Secrets:
- `tap_deploy_key` -- SSH private key of a write deploy key on the tap (preferred)
- `tap_token` -- token with `contents:write` on the tap, used only without a deploy key
- `tap_repo` -- the tap as `owner/repo`, when it is a secret rather than a variable

No credential, no tap, or a tap given both ways with different values fails the
job. The push retries twice after `git pull --rebase`, so several apps releasing
into one tap at once all land.

Keeping the tap closed to direct pushes: give the tap's branch ruleset a
`DeployKey` bypass with `bypass_mode: always` and keep every other bypass at
`pull_request`. CI pushes with the deploy key; people and tokens still need a
pull request. Store the private key in each publishing repository (user
accounts have no account-wide secrets).

```yaml
jobs:
  publish-homebrew:
    needs: build
    uses: nikolareljin/ci-helpers/.github/workflows/homebrew-tap-publish.yml@production
    with:
      formula_artifact: homebrew-formula
      formula_file: myapp.rb
      tap_repo: ${{ vars.HOMEBREW_TAP_REPO }}
    secrets:
      tap_deploy_key: ${{ secrets.HOMEBREW_TAP_DEPLOY_KEY }}
```

## rust-release-tarballs.yml

Workflow: `.github/workflows/rust-release-tarballs.yml`

Purpose: Build a Rust binary for macOS arm64, macOS x86_64 and Linux x86_64

The build runs with `contents: read`; a separate `upload-release` job holds `contents: write`, downloads the built files and publishes them. The caller grants `contents: write`.
(on `ubuntu-22.04`: needs glibc 2.34, so Ubuntu 22.04, Debian 12 and newer;
not Ubuntu 20.04), attach the tarballs to
the release, generate a Homebrew formula and publish it through
[homebrew-tap-publish.yml](#homebrew-tap-publishyml).

`bin_name` must be a plain name: letters, digits and `_`, then also `.`, `+` and `-`; no `..`.

The Linux build is pinned to `ubuntu-22.04` on purpose: the binary links against
the build host's glibc, so it runs on that release and every newer one. GitHub
retires runner images on its own schedule, so `security-weekly.yml` runs
`scripts/check_runner_retirement.sh` every Monday. Once `actions/runner-images`
announces that image's deprecation, the job fails and opens or updates the
`security-weekly` tracking issue. That is the signal to move this build, for
example to `ubuntu-latest` with `container: ubuntu:22.04`, which keeps the same
glibc floor.

Required inputs: `bin_name`, `desc`, `homepage`. Optional:
`formula_class` (default derived from `bin_name`), `license` (default `MIT`),
`release_tag` (default: the pushed tag; set it for a backfill run from
`workflow_dispatch`), `rust_toolchain` (default `stable`),
`macos_deployment_target` (default `10.13`, for the x86_64 build).
Tap inputs and secrets as in
`homebrew-tap-publish.yml` (`tap_repo`, `tap_branch`, `tap_dir`;
`tap_deploy_key` or `tap_token`).

## fpc-release.yml

Workflow: `.github/workflows/fpc-release.yml`

Purpose: Build a Free Pascal (FPC) binary natively on Linux (x86_64), macOS (ARM64 + x86_64),

The build runs with `contents: read`; a separate `release` job holds `contents: write`, downloads the built files and publishes them. The caller grants `contents: write`.
and Windows (x86_64); package each into a release archive; optionally produce Linux packages
(DEB, RPM, AppImage) and a macOS DMG; and optionally upload release archives to a GitHub
release (controlled by `upload_to_release`). SHA256 checksum files are uploaded as CI
artifacts only and are not attached to the release.

**Core inputs:**
- `bin_name` (string, **required**) — binary name without extension (e.g. `pravkal`)
- `build_command` (string, default `"bash build.sh"`) — shell command to compile the binary;
  runs on every platform after FPC is installed
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `data_glob` (string, default `""`) — shell glob of runtime data files to bundle with the
  binary (e.g. `"data/_*.KAL data/_*.MOL"`)
- `extra_files` (string, default `"README.md CHANGELOG.md"`) — extra files to include in each
  archive
- `release_tag` (string, default `""`) — tag to build; defaults to the pushed tag
- `upload_to_release` (string, default `"auto"`) — `"auto"` uploads on version-tag pushes or
  when `release_tag` is provided explicitly; `"true"` always, `"false"` never
- `fpc_apt_package` (string, default `"fpc"`) — apt package on Linux runners
- `fpc_brew_formula` (string, default `"fpc"`) — Homebrew formula on macOS runners
- `fpc_choco_package` (string, default `"freepascal"`) — Chocolatey package on Windows runners

**Linux packaging inputs** (optional; require `linux_packages` to be set):
- `linux_packages` (string, default `""`) — comma-separated list of extra Linux package formats
  to build: `deb`, `rpm`, `appimage`. Example: `"deb,rpm,appimage"`. Uses
  [fpm](https://fpm.readthedocs.io/) for DEB/RPM and
  [appimagetool](https://github.com/AppImage/appimagetool) for AppImage. The binary is
  installed to `/usr/share/{bin_name}/` with a thin wrapper in `/usr/bin/` so that runtime data
  files are always found relative to the binary.
- `package_maintainer` (string, default `""`) — DEB/RPM `Maintainer` field
- `package_description` (string, default `""`) — one-line description for DEB/RPM/AppImage
- `package_url` (string, default `""`) — homepage URL for DEB/RPM metadata
- `app_icon` (string, default `""`) — path to a 64×64 PNG icon (relative to
  `working_directory`) for the AppImage; a placeholder is auto-generated when omitted
- `appimagetool_url` (string, default: the appimagetool 1.9.1 x86_64 release) - download URL for
  `appimagetool`. If you override it, set `appimagetool_sha256` to that file's digest too
- `appimagetool_sha256` (string, default: digest of the default URL) - expected SHA256 hex digest
  of the downloaded `appimagetool` binary. Required: the download is always verified, and an
  empty value or a mismatch fails the AppImage build
- `appimagetool_verify` (string) - deprecated and ignored; verification is always on
- `appimage_runtime_url` / `appimage_runtime_sha256` (strings, default: type2-runtime release
  `20251108`, x86_64, and its digest) - the runtime embedded in the AppImage, passed to
  `appimagetool --runtime-file`. Without it appimagetool downloads the rolling `continuous`
  runtime itself. Same rule: an override needs its digest

**macOS packaging inputs:**
- `macos_dmg` (string, default `"false"`) — set to `"true"` to build a `.dmg` disk image on
  each macOS runner (ARM64 + x86_64)

**Output artifacts:**

Archives and optional package extras are uploaded to CI workflow artifacts on every run.
Release upload is controlled by `upload_to_release`: in `"auto"` mode (default) archives are
also uploaded to the GitHub release when triggered by a version-tag push or when `release_tag`
is provided; `"true"` always uploads; `"false"` skips release upload entirely.
Per-platform SHA256 checksum files (`sha256-{label}.txt`) are uploaded as CI workflow
artifacts only — they are not attached to the GitHub release.

| Platform | Archive (CI always / release per `upload_to_release`) | Optional extras (CI always / release per `upload_to_release`) | SHA256 file (CI only) |
|----------|------------------------|--------------------------------|-----------------------|
| Linux x86_64 | `.tar.gz` | `.deb`, `.rpm`, `.AppImage` | `sha256-linux-x86_64.txt` |
| macOS ARM64 | `.tar.gz` | `.dmg` | `sha256-macos-arm64.txt` |
| macOS x86_64 | `.tar.gz` | `.dmg` | `sha256-macos-x86_64.txt` |
| Windows x86_64 | `.zip` | — | `sha256-windows-x86_64.txt` |

Archive naming: `{bin_name}-{tag}-{label}.{ext}`

Example (all formats enabled):

```yaml
on:
  push:
    tags:
      - '[0-9]*.[0-9]*.[0-9]*'
      - 'v[0-9]*.[0-9]*.[0-9]*'

permissions:
  contents: write

jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/fpc-release.yml@production
    with:
      bin_name: pravkal
      data_glob: "data/_*.KAL data/_*.MOL"
      linux_packages: "deb,rpm,appimage"
      macos_dmg: "true"
      package_maintainer: "Full Name <email@example.com>"
      package_description: "Short description of the application"
      package_url: "https://github.com/owner/repo"
```

## deb-build.yml

Workflow: `.github/workflows/deb-build.yml`

Purpose: Build Debian packages, upload artifacts, and optionally attach the `.deb` to a GitHub release.

The build runs with `contents: read`; a separate `release` job holds `contents: write`, downloads the built files and publishes them. The caller grants `contents: write`. It runs on `release_runner` (default `ubuntu-latest`), not `runner`: a reused self-hosted machine can carry state left by the build.

script-helpers must be at `vendor/script-helpers` (used first when present) or `scripts/script-helpers` (a submodule). The workflow never creates `vendor/`, which would put a Go module in vendor mode.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `release_runner` (string, default `ubuntu-latest`): runner for the job that publishes the release; it needs the GitHub CLI (`gh`), which GitHub-hosted runners ship
- `ref` (string, default `""`): git ref to build (tag, branch or commit); empty builds the ref the workflow runs on. Set it to the tag to rebuild an older release. Without `release_tag`, the release is named after `ref`: `auto` uploads only when `ref` is a version tag, and `true` fails for any other `ref`.
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `prebuild_command` (string, default `"make man"`)
- `build_command` (string, default `""`)
- `extra_packages` (string, default `""`)
- `artifact_name` (string, default `"deb-packages"`)
- `artifact_glob` (string, default `"dist/deb/*.deb"`): with this default, the job copies the `.deb` files the build writes next to `working_directory` into `dist/deb/` (older files left on a reused runner are skipped), and fails when there are none. Set it when `build_command` writes elsewhere; nothing is copied then.
- `upload_to_release` (string, default `"auto"`) — must be `"auto"`, `"true"`, or `"false"` (any other value fails with a clear error). `"true"` always uploads, `"false"` never uploads, `"auto"` uploads only when the workflow is triggered by a version tag push (`refs/tags/X.Y.Z`) or when `release_tag` is provided explicitly.
- `release_notes` (boolean, default `true`): write release notes into the release body; `false` uploads the files and leaves the body as it is, for a release another job published with its own notes.
- `release_tag` (string, default `""`) — tag to attach the `.deb` to; defaults to the pushed tag. Set explicitly when triggering a backfill via `workflow_dispatch`.
- `signing_key_id` (string, default `""`): GPG key fingerprint that signs the published files

Secrets (optional):
- `gpg_private_key` (armored private key), `gpg_passphrase`

With a key, a `sign` job between the build and the release signs every file the release gets: `<file>.asc` for each, plus `SHA256SUMS` and `SHA256SUMS.asc`. It runs no caller command and is the only job with the key, which lives in a temporary keyring for one step. Without a key and key id the release is published unsigned and the run shows a notice. With only one of them, or a `signing_key_id` that is not in `gpg_private_key`, the run fails. A release file whose name starts with `-` or has a newline or backslash is refused while signing. GitHub renames an asset whose name has other characters than letters, digits, `.`, `_` and `-`, so the release job publishes such a file with each of those characters as `.` (`app_1.0~rc1+ds_all.deb` as `app_1.0.rc1.ds_all.deb`), the name GitHub stores and the name its `.asc` and `SHA256SUMS` use; the republish check looks the file up under that name, signed or not. Two files that would get the same name, or a name that would start or end with `.`, fail the run. Only release files are signed; the CI artifact (`artifact_name`) is not.

A file already on the release with the same sha256 is kept. A signed package is never replaced: with a different sha256 the run fails. Signed means the release has `<file>.asc`, or has `SHA256SUMS.asc` and its `SHA256SUMS` lists the file. To publish a fix, release a new version, or delete the package, its `.asc`, `SHA256SUMS` and `SHA256SUMS.asc` from the release by hand. An unsigned package with a different sha256 is replaced, with a warning, so a bad unsigned build can be fixed in place; an unsigned `SHA256SUMS` is replaced the same way. A published `.asc` is kept only next to its unchanged file; next to a new file the run fails, because the old signature would not verify. A run that adds a package to a release with a signed `SHA256SUMS` fails until `SHA256SUMS` and `SHA256SUMS.asc` are deleted, since a signed list is not replaced. A release that was unsigned and is rebuilt with signing on gets the new packages, their `.asc` files and a new signed `SHA256SUMS`. With signing on, `artifact_glob` must not match `SHA256SUMS` or `.asc` files: the `sign` job writes them.

Verify a download: `gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS`.

Example (automatic release upload on tag push):

```yaml
jobs:
  deb:
    uses: nikolareljin/ci-helpers/.github/workflows/deb-build.yml@production
    with:
      working_directory: "."
    permissions:
      contents: write
```

Example (manual backfill to an existing release):

```yaml
jobs:
  deb:
    uses: nikolareljin/ci-helpers/.github/workflows/deb-build.yml@production
    with:
      working_directory: "."
      release_tag: "1.2.3"
    permissions:
      contents: write
```

Example (signed release; names from [packaging.md](packaging.md)):

```yaml
jobs:
  deb:
    uses: nikolareljin/ci-helpers/.github/workflows/deb-build.yml@production
    with:
      signing_key_id: ${{ vars.GPG_KEY_ID }}
    secrets:
      gpg_private_key: ${{ secrets.GPG_PRIVATE_KEY }}
      gpg_passphrase: ${{ secrets.GPG_PASSPHRASE }}
    permissions:
      contents: write
```

## php-scan.yml

Workflow: `.github/workflows/php-scan.yml`

Purpose: Run PHP unit tests, framework linting, and a WP-CLI scan with demo content when detected.

Inputs (selected):
- `runner` (string, default `ubuntu-24.04`: the ondrej/php PPA has no suite for `ubuntu-latest` (26.04) yet; it returns to `ubuntu-latest` when the PPA ships one)
- `working_directory` (string, default `"."`)
- `php_version` (string, default `8.4`)
- `composer_command` (string, default `composer install --no-interaction --prefer-dist`)
- `audit_command` (string, default `composer audit --no-interaction`) -- dependency
  advisories from the Packagist security API. **On by default**: it ships with
  Composer 2.4 and later, needs no account and no key. Set to `""` to disable
  the stage.

  Composer 2.9 already refuses to **resolve** a package with a known advisory,
  so this stage is not the first line of defence. It is the second one, and it
  covers the case the block cannot: `composer install` from an existing
  `composer.lock` does not resolve, so a lock written while its packages were
  clean goes on installing after they stop being clean.
- `unit_command` (string, default `vendor/bin/phpunit`)
- `lint_wp_command` (string, default `vendor/bin/phpcs --standard=WordPress --extensions=php`, only runs when WordPress is detected)
- `lint_drupal_command` (string, default `vendor/bin/phpcs --standard=Drupal --extensions=php`, only runs when Drupal is detected)
- `lint_laravel_command` (string, default `vendor/bin/pint --test`; without `--test` pint rewrites files and always succeeds)
- `wp_cli_scan` (boolean, default `true`, only runs when WordPress is detected)
- `wp_root` (string, default `wp-cli-site`) - where the scan installs a throwaway WordPress site
- `wp_site_url` (string, default `http://localhost:8080`), `wp_site_title` (string, default `CI Site`)
- `wp_admin_user` (string, default `admin`), `wp_admin_password` (string, default `""`: a random password per run), `wp_admin_email` (string, default `admin@example.com`) - credentials for that throwaway site only
- `wp_posts_count` (number, default `10`) - demo posts generated before the scan
- `lint_pimcore_command` (string, default `vendor/bin/phpcs --standard=PSR12 --extensions=php src/`, only runs when Pimcore is detected)
- `fetch_depth` (number, default `0`)

PHP is installed by `scripts/setup_php.sh`, which the job checks out from this
library at the workflow's own commit; no third-party action. The version comes
from apt: the image's own packages when they hold it (8.3 on `ubuntu-24.04`),
else the ondrej/php PPA, added under the signing key whose fingerprint is
pinned in `toolchain-pins.env` and refused when the fetched key does not match.
`php_version` must be `X.Y` (`8.4`; not `latest`, `nightly` or `8.4.1`), and
only an Ubuntu or Debian runner is supported (on Debian only a version its
own sources hold, as the PPA builds for Ubuntu only). The script installs the
extension packages the replaced action's builds carried (bcmath, bz2, curl, gd,
gmp, intl, mbstring, mysql, opcache, pgsql, readline, soap, sqlite3, xml, xsl,
zip), Xdebug with `xdebug.mode=coverage`, `date.timezone=UTC` and
`memory_limit=-1` (an ini value setting `extension` or `zend_extension`, or
holding a `;`, is refused), points `php`, `phar`, `php-config`, `phpize` and `phpdbg`
at the version with `update-alternatives`, and checks that `php -v` reports
it. Composer is the release pinned in `toolchain-pins.env` (`COMPOSER_VERSION`,
`COMPOSER_PHAR_SHA256`), downloaded from getcomposer.org and installed only
after its sha256 matches; `COMPOSER_PROCESS_TIMEOUT=0`,
`COMPOSER_NO_INTERACTION=1` and `COMPOSER_NO_AUDIT=1` are exported for the
later steps as before. No GitHub token is written to Composer's `auth.json`;
a job that hits the GitHub API rate limit during `composer install` sets
`COMPOSER_AUTH` itself. Opcache JIT is not switched on (the action wrote
`opcache.jit=1235` into every php.ini).
The PHP jobs run on `ubuntu-24.04` by default (the generic workflows when
`php_version` is set): the ondrej/php PPA has no suite for `ubuntu-latest`
(26.04) yet, and on a 26.04 runner a version its own sources lack fails with a
message naming `ubuntu-24.04`. `runner` still overrides it. Switch the default
back to `ubuntu-latest` when the PPA ships a 26.04 suite;
`scripts/check_php_runner.py` holds the jobs to 24.04 until then.

Example:

```yaml
jobs:
  php_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/php-scan.yml@production
```

## python-scan.yml

Workflow: `.github/workflows/python-scan.yml`

Purpose: Run Python lint, unit tests, and Django tests when a Django project is detected.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `python_version` (string, default `3.13`)
- `install_command` (string, default `if [ -f requirements.txt ]; then python -m pip install -r requirements.txt; elif [ -f pyproject.toml ]; then python -m pip install .; fi`)
- `lint_command` (string, default `python -m pip install ruff && ruff check .`)
- `audit_command` (string, default `""`) -- dependency advisories, off unless set
- `bandit_command` (string, default `""`) -- Python SAST, off unless set

Both are off because turning them on here would change the result of builds
this repository does not own. Measured on 2026-09-29 across the five
repositories that call this preset: two fail `pip-audit` today (`django
4.2.30`, `starlette 0.37.2`) and four fail `bandit`. Turn them on per
repository, where the finding can be looked at:

```yaml
with:
  audit_command: "if [ -f requirements.txt ]; then pipx run pip-audit -r requirements.txt; elif [ -f pyproject.toml ]; then pipx run pip-audit .; else echo "::error::audit_command is set but $(pwd) has neither requirements.txt nor pyproject.toml, so nothing was audited"; exit 1; fi"
  bandit_command: "pipx run bandit -q -r . -ll --exclude ./.venv,./venv,./node_modules,./build,./dist"
```

Two things about those lines, both measured rather than stylistic:

- Bare `pip-audit` audits the **ambient environment**. On a runner that means
  it reports the runner's own `pip` and fails a build over a package the
  project never chose. `-r requirements.txt` and `pip-audit .` audit the
  project.
- Bandit's exclusions are not optional. Without them it walks any local
  virtualenv and reports third-party code as the project's: on three of this
  preset's callers that is 132, 275 and 126 findings, against 1, 12 and 1 in
  code they own.
- Both run through `pipx`, which is preinstalled on GitHub-hosted runners. On a
  self-hosted runner without it the stage fails with `pipx: command not found`,
  which is loud and correct. `pip install` is the thing to avoid: installing
  either tool into the project's environment can upgrade the project's own
  dependencies (`packaging`, `requests`), and these stages run before the lint
  and the tests.
- The audit line ends in an `else` that fails. A working directory with neither
  `requirements.txt` nor `pyproject.toml` would otherwise give a green audit
  stage that audited nothing.
- `unit_command` (string, default `python -m pip install pytest && python -m pytest`)
- `django_command` (string, default `if [ -f manage.py ]; then python manage.py test; fi`, only runs when Django is detected)
- `fetch_depth` (number, default `0`)

Example:

```yaml
jobs:
  python_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/python-scan.yml@production
```

## go-scan.yml

Workflow: `.github/workflows/go-scan.yml`

Purpose: Run Go lint, tests, and gosec scanning.

gosec is built with `go install` at the version pinned in the library's
`scanner-pins.env`, so the Go module checksum database verifies it; no
container action. It runs in `working_directory`, as lint and tests do.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `go_version` (string, default `go.mod`: Go from `<working_directory>/go.mod`, its `toolchain` line when present; a version overrides it)
- `lint_command` (string, default `test -z "$(gofmt -l .)" && go vet ./...`)
- `test_command` (string, default: `go mod download`, then `go test -race ./...` where cgo is on and the platform supports it, else `go test ./...`; see the Go preset in `docs/presets.md`)
- `gosec_args` (string, default `./...`)
- `fetch_depth` (number, default `0`)
- `vulncheck_packages` (string, default `./...`) - the package pattern for `govulncheck`. Not the same as `gosec_args`.

Example:

```yaml
jobs:
  go_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/go-scan.yml@production
```

## rust-scan.yml

Workflow: `.github/workflows/rust-scan.yml`

Purpose: Run Rust lint, tests, and cargo-audit.

The toolchain comes from the rustup the runner ships (`rustup toolchain
install <rust_toolchain> --profile minimal` with each component), through
`scripts/setup_rust.sh`, which the job checks out from this library at the
workflow's own commit; no third-party action. A runner without rustup gets
`rustup-init` at the version and sha256 pinned in the library's
`toolchain-pins.env`, run only after the digest matches. `rust_toolchain` takes
what rustup takes (`stable`, `beta`, `nightly`, `nightly-2026-01-01`, `1.75.0`,
`1.75`) and the relative forms `stable minus 2 releases` and `stable 3 months
ago`. The step exports `CARGO_INCREMENTAL=0` and `CARGO_TERM_COLOR=always` to
the job unless the caller set them. The same step and script serve `rust.yml`,
`ci.yml`, `pr-gate.yml`, `rust-release.yml`, `rust-release-tarballs.yml` and
the three Tauri workflows.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `rust_toolchain` (string, default `stable`)
- `rust_components` (string, default `rustfmt, clippy`)
- `lint_command` (string, default `cargo fmt -- --check && cargo clippy --all-targets -- -D warnings`).
  `--all-targets` because clippy otherwise checks the library and nothing else:
  a warning in test code passes `cargo clippy -- -D warnings` and fails with it.
- `test_command` (string, default `cargo fetch && cargo test`)
- `audit_command` (string, default `cargo audit`)
- `fetch_depth` (number, default `0`)

Example:

```yaml
jobs:
  rust_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/rust-scan.yml@production
```

## java-scan.yml

Workflow: `.github/workflows/java-scan.yml`

Purpose: Run Java lint, tests, and OWASP dependency checks.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `java_version` (string, default `17`)
- `lint_command` (string, default `""`; `mvn -B -DskipTests checkstyle:check` fails on a project with no ruleset)
- `test_command` (string, default `mvn -B test`)
- `fetch_depth` (number, default `0`)
- `dependency_check_command` (string, default `""`). dependency-check 9.0 onward
  needs an NVD API key; without one the data update fails and takes the build
  with it. A repository with a key passes the secret `nvd_api_key` and sets:

  ```yaml
  dependency_check_command: >-
    mvn -B org.owasp:dependency-check-maven:13.0.0:check
    -DfailBuildOnCVSS=7
  ```

  Keep `-DfailBuildOnCVSS`: the plugin's own default threshold of 11 never fails.
  The key never reaches the job that runs this command. A separate `nvd` job
  holds it, runs the dependency-check CLI pinned in `scanner-pins.env`
  (13.0.0) with `--updateonly`, and passes the data to the scan job as an
  artifact with a sha256 manifest. The command gets the data in `DC_DATA_DIR`,
  and `MAVEN_ARGS` carries `-DdataDirectory=$DC_DATA_DIR -DautoUpdate=false`.
  Use plugin 13.x so the data format matches the CLI.
  A data file over 60 MiB travels as `<name>.split-NNN` parts, under the
  64 MiB per-file limit of the artifact check, and is joined again before
  the command runs.
- `nvd_runner` (string, default `ubuntu-latest`): runner for the `nvd` job.

Example:

```yaml
jobs:
  java_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/java-scan.yml@production
```

## csharp-scan.yml

Workflow: `.github/workflows/csharp-scan.yml`

Purpose: Run .NET lint, tests, and list vulnerable packages.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `dotnet_version` (string, default `8.0.x`)
- `project` (string, default `""`) — project or solution to restore, build, test and format. Required whenever the directory does not hold exactly one project or solution; validated, and may not begin with `-`.
- `lint_command` (string, default `dotnet format --verify-no-changes`) - the SDK built-in; with `project` set and this left at the default, the project is passed to it. Use the built-in, not the standalone `dotnet-format` tool: the tool reads `--verify-no-changes` as a file name and exits 1.
- `test_command` (string, default `dotnet restore && dotnet test`) — with `project` set and this left at the default, the project is passed to restore and test. `""` disables the stage.
- `vuln_command` (string, default runs `dotnet list package --vulnerable --include-transitive` and fails when it lists vulnerable packages, since that command exits 0 either way)
- `fetch_depth` (number, default `0`)

Example:

```yaml
jobs:
  csharp_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/csharp-scan.yml@production
```

## validate-dotnet-project.yml

Workflow: `.github/workflows/validate-dotnet-project.yml`

Purpose: Refuse a `project` value that `dotnet` would misread. `csharp.yml` and
`csharp-scan.yml` call it before they build; call it yourself only when you
pass a project path to your own `dotnet` steps.

It fails on a value that starts with `-` (read as an option), has a leading or
trailing space, or holds a character other than letters, digits, `.`, `_`,
`/`, `-` and space. An empty value passes.

Inputs:
- `project` (string, default `""`)
- `runner` (string, default `ubuntu-latest`) - not taken from the caller's runner, since the job is one check

Example:

```yaml
jobs:
  validate:
    uses: nikolareljin/ci-helpers/.github/workflows/validate-dotnet-project.yml@production
    with:
      project: src/App/App.csproj
```

## node-scan.yml

Workflow: `.github/workflows/node-scan.yml`

Purpose: Run Node.js lint/test/audit and optional build.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `node_version` (string, default `22`)
- `install_command` (string, default `npm ci`)
- `lint_command` (string, default `npm run --if-present lint`)
- `test_command` (string, default `npm test`)
- `audit_command` (string, default `npm audit --audit-level=high`)
- `build_command` (string, default `""`)
- `fetch_depth` (number, default `0`)

Example:

```yaml
jobs:
  node_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/node-scan.yml@production
```

## react-scan.yml

Workflow: `.github/workflows/react-scan.yml`

Purpose: Run React lint/test/build with npm audit.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `node_version` (string, default `22`)
- `install_command` (string, default `npm ci`)
- `lint_command` (string, default `npm run --if-present lint`)
- `test_command` (string, default `npm test`)
- `audit_command` (string, default `npm audit --audit-level=high`)
- `build_command` (string, default `npm run build`)
- `fetch_depth` (number, default `0`)

Example:

```yaml
jobs:
  react_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/react-scan.yml@production
```

## vue-scan.yml

Workflow: `.github/workflows/vue-scan.yml`

Purpose: Run Vue lint/test/build with npm audit.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `node_version` (string, default `22`)
- `install_command` (string, default `npm ci`)
- `lint_command` (string, default `npm run --if-present lint`)
- `test_command` (string, default `npm test`)
- `audit_command` (string, default `npm audit --audit-level=high`)
- `build_command` (string, default `npm run build`)
- `fetch_depth` (number, default `0`)

Example:

```yaml
jobs:
  vue_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/vue-scan.yml@production
```

## pnpm-scan.yml

Workflow: `.github/workflows/pnpm-scan.yml`

Purpose: Run pnpm lint/test/build and `pnpm audit`. Installs with
`pnpm install --frozen-lockfile`.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `.`)
- `fetch_depth` (number, default `0`)
- `node_version` (string, default `22`)
- `pnpm_version` (string, default `latest`)
- `lint_command` (string, default `pnpm run --if-present lint`)
- `test_command` (string, default `pnpm run test`)
- `build_command` (string, default `pnpm run build`)
- `audit_filters` (string, default `""`) - space-separated workspace filters, each audited on its own. Empty runs one audit of the whole workspace.
- `audit_level` (string, default `high`)

Example:

```yaml
jobs:
  pnpm_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/pnpm-scan.yml@production
    with:
      audit_filters: "@acme/web @acme/api"
```

## docker-scan.yml

Workflow: `.github/workflows/docker-scan.yml`

Purpose: Build a Docker image and scan it with Trivy.

Trivy is the release binary pinned by version and sha256 in the library's
`scanner-pins.env`, downloaded and verified in the job; no third-party action.
The vulnerability database is fetched in its own step and the scan runs with
`--skip-db-update --offline-scan --disable-telemetry --skip-version-check`.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `image_name` (string, default `ci-image:latest`)
- `dockerfile` (string, default `Dockerfile`)
- `context` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `trivy_ignore_unfixed` (string, default `true`) - skip findings with no fixed version.
- `trivy_severity` (string, default `CRITICAL,HIGH`)
- `fail_on_findings` (boolean, default `true`)
- `run_snyk` (boolean, default `false`). Snyk is disabled: it is a cloud
  service that receives the image's dependency graph and metadata, and a scan
  job here sends code and data to nobody. The input stays so existing callers
  keep parsing. With `run_snyk: true` the job warns and writes a summary line,
  and nothing else happens:

  ```
  Warning: Snyk scan disabled: run_snyk is on, but Snyk is disabled in docker-scan...
  ```

- `snyk_severity_threshold` (string, default `high`) - unused; Snyk is disabled.

Secrets:
- `snyk_token` - unused; Snyk is disabled. Never read. Kept so a caller
  passing it keeps parsing.

Example:

```yaml
jobs:
  docker_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/docker-scan.yml@production
    with:
      image_name: "app:ci"
```

## pimcore.yml

Workflow: `.github/workflows/pimcore.yml`

Purpose: Preset for Pimcore bundle CI. Runs PHPCS and PHPUnit against the
caller's Docker Compose stack, over one or more PHP versions.

Inputs (selected):
- `runner` (string, default `ubuntu-24.04`: the ondrej/php PPA has no suite for `ubuntu-latest` (26.04) yet; it returns to `ubuntu-latest` when the PPA ships one)
- `compose_file` (string, default `test/docker-compose.yml`)
- `bundle_src` (string, default `"."`) and `bundle_src_env` (string, default `BUNDLE_SRC`)
- `php_service` (string, default `php`), `db_service` (string, default `db`), `db_wait_seconds` (string, default `"20"`)
- `php_versions` (string, default `'["8.3", "8.4"]'`) — JSON array; one matrix leg per version. Any versions may be passed; they are not validated against an allow-list
- `php_version` (string, default `""`) — test exactly one version; **overrides** `php_versions`
- `php_version_env` (string, default `PHP_VERSION`) — env var the selected version is exported as, for the compose file to read as a build argument. `""` exports nothing
- `composer_command`, `phpcs_command`, `phpstan_command`, `phpunit_command`, `phpunit_coverage_command`
- `fail_on_findings` (boolean, default `true`), `cleanup` (boolean, default `true`)
- `upload_artifact` (boolean, default `false`), `artifact_name` (string, default `bundle-check-results`)
- `out_dir` (string, default `test/tmp`) - where results are written.

Example:

```yaml
jobs:
  pimcore:
    uses: nikolareljin/ci-helpers/.github/workflows/pimcore.yml@production
    with:
      compose_file: docker-test/docker-compose.yml
      php_versions: '["8.3", "8.4"]'
```

Note: `php_version` alone configures only the optional standalone (host) PHP
used by `php_lint_command` and friends. The containerised checks take their PHP
from your compose file, which is why the version is also exported via
`php_version_env`. See [Presets](presets.md#choosing-php-versions).

## pimcore-bundle-check.yml

Workflow: `.github/workflows/pimcore-bundle-check.yml`

Purpose: The single-version worker behind `pimcore.yml`. Brings up the compose
stack, installs dependencies, and runs lint, static analysis and tests inside
it. Call `pimcore.yml` instead unless you are driving one specific version and
want no matrix.

Inputs: as `pimcore.yml`, minus `php_versions` (it takes one `php_version`),
plus four that run outside the compose stack. In full:

- `runner` (string, default `ubuntu-24.04`: the ondrej/php PPA has no suite for `ubuntu-latest` (26.04) yet; it returns to `ubuntu-latest` when the PPA ships one)
- `compose_file` (string, default `test/docker-compose.yml`)
- `bundle_src` (string, default `.`)
- `bundle_src_env` (string, default `BUNDLE_SRC`) - the variable the compose file reads the bundle path from
- `php_service` (string, default `php`)
- `db_service` (string, default `db`)
- `db_wait_seconds` (string, default `20`)
- `out_dir` (string, default `test/tmp`)
- `php_version` (string, default `""`)
- `php_version_env` (string, default `PHP_VERSION`) - the variable the version is exported as; empty exports nothing
- `composer_command` (string, default `composer install --no-interaction --prefer-dist`)
- `php_lint_command` (string, default `""`) - runs on the runner, before the stack starts
- `phpcs_standalone_command` (string, default `""`) - runs on the runner
- `phpunit_standalone_command` (string, default `""`) - runs on the runner
- `phpunit_working_directory` (string, default `.`) - where the standalone PHPUnit runs
- `phpcs_command` (string, default `vendor/bin/phpcs --standard=PSR12 --extensions=php src/`) - runs inside the stack
- `phpstan_command` (string, default `""`)
- `phpunit_command` (string, default `vendor/bin/phpunit --testdox`)
- `phpunit_coverage_command` (string, default `""`)
- `fail_on_findings` (boolean, default `true`)
- `cleanup` (boolean, default `true`)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `bundle-check-results`)

## auto-tag.yml

Workflow: `.github/workflows/auto-tag.yml`

Purpose: The tag-only, least-privilege version of the release automation. On a push to the default branch that is a merged `release/[v]X.Y.Z[-rc[.]N]` PR, it creates+pushes the version tag. It can also move the floating `production` tag — opt-in via `update_production_tag`, and only for a final `X.Y.Z`. It does **not** dispatch a follow-up workflow.

Permissions: needs only `contents: write` + `pull-requests: read`. **No `actions: write`** — prefer this workflow whenever you do not need the auto-dispatch feature.

Inputs: `runner`, `fetch_depth`, `default_branch`, `update_production_tag` (same meaning as in `auto-tag-release.yml`). Outputs: `version`, and `is_prerelease` (`"true"`/`"false"`) so a caller can gate a follow-up job on whether the release is a candidate without re-deriving the rule from the version string.

Only a release branch in the repository itself counts: a merged PR whose `release/X.Y.Z` head branch lives in a fork is logged and skipped (no tag, `production` untouched, `version` empty).

```yaml
name: Auto Tag
on:
  push:
    branches: [ main, master ]

permissions:
  contents: write
  pull-requests: read

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag.yml@production
```

## auto-tag-release.yml

Workflow: `.github/workflows/auto-tag-release.yml`

Purpose: Auto-tag releases when a `release/[v]X.Y.Z`, `release/[v]X.Y.Z-rcN`, or `release/[v]X.Y.Z-rc.N` PR is merged into the default branch, **plus** optionally dispatch a follow-up workflow. Tagging is delegated to `auto-tag.yml`; this workflow adds the dispatch job.

**Permissions:** callers must grant `actions: write` **in addition to** `contents: write` + `pull-requests: read` — even if they never set `release_workflow`. GitHub validates a reusable workflow's declared permissions at startup regardless of the dispatch job's `if:` gate, so omitting `actions: write` fails the run with *"requesting 'actions: write', but is only allowed 'actions: none'"*. If you do not need auto-dispatch, use [`auto-tag.yml`](#auto-tagyml) instead.

Notes:
- Detects the repo default branch; falls back to `main` if missing.
- Only tags pushes that land on the actual default branch.
- Falls back to parsing only the merge commit subject when GitHub has not yet associated the merge commit with its PR.
- Validates the PR referenced by the merge subject before tagging, instead of trusting the commit message alone.
- Warns and skips tagging when the caller omitted `pull-requests: read`, because both the primary lookup and fallback validation require that permission.
- Fails the workflow if the tag already exists (prevents merge from appearing successful).

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `fetch_depth` (number, default `0`)
- `default_branch` (string, default `""`, uses repo default)
- `update_production_tag` (boolean, default `false`): when `true`, a separate `production` job runs `create_production.sh` after a final version is tagged (concurrency group `ci-helpers-production-move-<owner>/<repo>`, shared with every workflow that moves `production`). Moving a floating `production` ref is opt-in: calling this workflow buys you tagging, and nothing else happens unless you ask. Set it to `true` only in a repository that carries a `production` ref. The job runs this library's `scripts/create_production.sh` from a verified copy; a copy in the calling repository is not run.
- `release_workflow` (string, default `""`) — filename of a local `workflow_dispatch` workflow to trigger after the version tag is pushed (e.g. `"create-github-release.yml"`). The workflow is dispatched with `release_tag` set to the detected version, using `gh workflow run --ref <tag>`. Requires `actions: write` on the caller. Leave empty to skip auto-dispatch.

Outputs:
- `version` - the version tagged; empty when the push was not a `release/*` merge. Gate follow-up jobs on `needs.<job>.outputs.version`.
- `is_prerelease` - `"true"` when that version carries a pre-release suffix.

**`production` moves only for a final `X.Y.Z`.** A merged `release/X.Y.Z-rcN` is tagged so the candidate can be exercised by a pilot consumer, and `production` stays where it is regardless of `update_production_tag`. There is no input for this — a candidate that moved `production` would be live the moment it merged, which is the opposite of cutting one. Promote a candidate by cutting `release/X.Y.Z` (with `CHANGELOG`, `VERSION` and any other reference to the version updated to drop the `-rcN`); merging that tags `X.Y.Z` and moves `production`.

Example (tag only, no production tag, no GitHub Release) — use `auto-tag.yml`, which needs no `actions: write`:

```yaml
name: Auto Tag
on:
  push:
    branches: [ main, master ]

permissions:
  contents: write
  pull-requests: read

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag.yml@production
    with:
      update_production_tag: false
```

Example (tag + auto-create GitHub Release via dispatch):

```yaml
name: Auto Tag Release
on:
  push:
    branches: [ main, master ]

permissions:
  contents: write
  pull-requests: read
  actions: write

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@production
    with:
      update_production_tag: false
      release_workflow: create-github-release.yml
```

See `create-github-release.yml` below for the local wrapper workflow that must exist in the calling repo.

## update-production.yml

Purpose: move a floating ref (`production` by default) onto a tag **you pick, by hand**. Manual and opt-in — nothing calls it on a push, a merge or a schedule, and a repository gets it only by adding a `workflow_dispatch` wrapper of its own.

The two ways `production` can move are **independent**, and a repository may have either, both or neither:

| | how it moves | when |
|---|---|---|
| automatic | `auto-tag.yml` with `update_production_tag: true` | a `release/X.Y.Z` merge, final versions only |
| manual | this workflow | whenever a human runs it and names a tag |

Release candidates are deliberately accepted here. Automatic tagging never moves `production` for a candidate — that is a rule, not an option — so this is how a candidate that has been exercised on a pilot consumer gets promoted without waiting for a final `X.Y.Z`, and how a bad move is rolled back onto an earlier tag.

Runs this library's `scripts/create_production.sh` from a verified copy, the same script `auto-tag.yml` uses; a copy in the calling repository is not run. This workflow passes it `--allow-prerelease --allow-rollback`; the tag must still be on the default branch.

Every workflow that moves `production` (`auto-tag.yml`, `production-branch.yml`, this one) runs in the concurrency group `ci-helpers-production-move-<owner>/<repo>`, so a manual move waits for a release in flight. Do not give a caller workflow the same group name: the inner job would wait on its own caller.

Inputs:

- `tag` (string, **required**) — tag to point the ref at, e.g. `1.2.3` or `1.2.3-rc1`. Must already exist on the remote, on the default branch.
- `ref_name` (string, default `production`) — the floating tag and branch to move. `main`, `master` and `HEAD` are refused.
- `update_branch` (boolean, default `true`) — also move `refs/heads/<ref_name>`, not just the tag.
- `dry_run` (boolean, default `false`) — run every check `create_production.sh` makes (`--dry-run`) and report what would move, push nothing. A tag the real run would refuse fails the dry run too. Worth a first run whenever the target is a candidate or a rollback.
- `runner` (string, default `ubuntu-latest`)

Every run writes a job summary naming the target commit, what the ref points at now (read from the remote, since a moved tag does not update on a plain fetch), and whether the target is a pre-release.

Wrapper to add in a consumer:

```yaml
name: Update production
on:
  workflow_dispatch:
    inputs:
      tag:
        description: "Tag to point production at (e.g. 1.2.3 or 1.2.3-rc1)"
        type: string
        required: true
      dry_run:
        description: "Report what would move, push nothing"
        type: boolean
        default: false

permissions:
  contents: write

jobs:
  update:
    uses: nikolareljin/ci-helpers/.github/workflows/update-production.yml@production
    with:
      tag: ${{ inputs.tag }}
      dry_run: ${{ inputs.dry_run }}
```

To restrict who may run it, point the wrapper's job at a GitHub Environment with required reviewers; the dispatch then waits for an approval before the ref moves.


## create-github-release.yml

Workflow: `.github/workflows/create-github-release.yml`

Purpose: Create a GitHub Release for a version tag. Extracts release notes from `CHANGELOG.md` when a matching `## DATE — VERSION` section exists; falls back to GitHub auto-generated release notes otherwise. Re-runs are safe: `scripts/github_release.sh` (the GitHub CLI, `gh release create`, `edit` and `upload`) updates an existing release when the tag already has one.

Triggers:
- `workflow_dispatch` with `release_tag` input — used by the `release_workflow` dispatch mechanism in `auto-tag-release.yml`.
- `workflow_call` with `release_tag` input — for direct use from other workflows.

Inputs:
- `release_tag` (string, required) — version tag to release (e.g. `1.2.3`).

**Using in external repos**

Create a thin local wrapper at `.github/workflows/create-github-release.yml` in your repo:

```yaml
name: create-github-release
on:
  workflow_dispatch:
    inputs:
      release_tag:
        description: "Version tag to release (e.g. 1.2.3)"
        type: string
        required: true
permissions:
  contents: write
jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/create-github-release.yml@production
    with:
      release_tag: ${{ inputs.release_tag }}
```

Then wire your auto-tag caller to dispatch it:

```yaml
# .github/workflows/auto-tag-release-push.yml
permissions:
  contents: write
  pull-requests: read
  actions: write
jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@production
    with:
      update_production_tag: false
      release_workflow: create-github-release.yml
```

The local wrapper is required because `gh workflow run` dispatches workflows in the current repo, not in ci-helpers. Repos that push tags via a PAT (not `GITHUB_TOKEN`) can use `on: push: tags:` and call `workflow_call` directly instead.

**CHANGELOG format**

Notes are extracted from `CHANGELOG.md` when a line matches `## <date> — <version>`:

```markdown
## 2026-06-12 — 1.2.3

### Added
- New feature X

### Fixed
- Bug in Y
```

Any other format, or no `CHANGELOG.md`, triggers GitHub auto-generated release notes.

## release-tag-gate.yml

Workflow: `.github/workflows/release-tag-gate.yml`

Purpose: Block PRs if a `release/[v]X.Y.Z`, `release/[v]X.Y.Z-rcN`, or `release/[v]X.Y.Z-rc.N` branch targets the default branch and the tag already exists.

The repo-local `release-tag-check.yml` workflow also validates that `VERSION` matches `release/[v]X.Y.Z[-rcN]` or `release/[v]X.Y.Z[-rc.N]` on `create` and `push` events for `release/*` branches.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `fetch_depth` (number, default `0`)
- `release_branch` (string, default `""`, uses PR head/ref)
- `base_branch` (string, default `""`, uses PR base)
- `default_branch` (string, default `""`, uses repo default)

A non-empty input takes precedence over the value read from the event.

Example:

```yaml
name: Release Tag Gate
on:
  pull_request:

jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/release-tag-gate.yml@production
```

## release-build.yml

Workflow: `.github/workflows/release-build.yml`

Purpose: Build release artifacts in any language and publish a GitHub Release.

The build runs with `contents: read`; a separate `release` job holds `contents: write`, downloads the built files and publishes them. The caller grants `contents: write`. It runs on `release_runner` (default `ubuntu-latest`), not `runner`: a reused self-hosted machine can carry state left by the build.

Inputs (selected):
- `runner` (string, default `ubuntu-latest`; with `php_version` set, `ubuntu-latest` runs on `ubuntu-24.04`, as the ondrej/php PPA has no 26.04 suite yet)
- `release_runner` (string, default `ubuntu-latest`): runner for the job that publishes the release; it needs the GitHub CLI (`gh`), which GitHub-hosted runners ship
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `node_version`, `java_version`, `dotnet_version`, `python_version`, `go_version`, `flutter_version`, `flutter_channel`, `php_version` (optional toolchain setup). Flutter is installed by `scripts/setup_flutter.sh` from a checkout of this library at the workflow's commit, as `ci.yml` installs it: the official release archive checked against the manifest's sha256, the `stable` default pinned in `toolchain-pins.env`; `flutter_channel` takes `stable`, `beta` or `dev`.
- `lint_command` (string, default `""`)
- `test_command` (string, default `""`)
- `build_command` (string, default `""`)
- `artifact_paths` (string, default `""`, supports globs)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `release-artifacts`)
- `release_tag` (string, default `""`)
- `release_name` (string, default `""`; empty names the release after its tag)
- `release_notes` (string, default `""`)
- `generate_release_notes` (boolean, default `true`)
- `binary_links` (string, default `""`, `label|filename` per line)
- `binary_base_url` (string, default `""`)
- `timeout_minutes` (number, default `30`) — job timeout. Thirty rather than twenty because a release build does more than a PR gate.

Example:

```yaml
name: Release Build
on:
  push:
    tags: [ "v*.*.*" ]

jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/release-build.yml@production
    with:
      lint_command: "npm ci && npm run --if-present lint"
      test_command: "npm test -- --runInBand"
      build_command: "npm run build"
      artifact_paths: "dist/*"
      binary_links: |
        Linux|myapp-linux
        macOS|myapp-mac
```

Flutter APK example:

```yaml
jobs:
  apk:
    uses: nikolareljin/ci-helpers/.github/workflows/release-build.yml@production
    with:
      working_directory: "."
      java_version: "17"
      flutter_version: "3.38.7"
      lint_command: "./scripts/mobile_lint.sh"
      test_command: "./scripts/mobile_test.sh"
      build_command: "./scripts/mobile_build_release_apk.sh"
      artifact_paths: "mobile/build/app/outputs/flutter-apk/app-release.apk"
      artifact_name: "spank-android-apk"
```

## rust-release.yml

Workflow: `.github/workflows/rust-release.yml`

Purpose: Build multi-target Rust release binaries and publish a GitHub Release.

The build runs with `contents: read`; a separate `release` job holds `contents: write`, downloads the built files and publishes them. The caller grants `contents: write`. It runs on `release_runner` (default `ubuntu-latest`), not `runner`: a reused self-hosted machine can carry state left by the build.

Inputs (selected):
- `bin_name` (string, required): letters, digits and `_`, then also `.`, `+` and `-`; no `..`
- `artifact_dir` (string, default `artifacts`)
- `rust_toolchain` (string, default `stable`)
- `install_deps` (boolean, default `true`)
- `apt_packages` (string, default `build-essential mingw-w64 musl-tools`; package names separated by spaces or newlines, passed to `apt-get install` after `--`, so an apt option here is read as a package name)
- `build_windows`, `build_linux_gnu`, `build_linux_musl`, `build_macos` (booleans, default `true`)
- `linux_gnu_aliases` (string, default `""`, comma-delimited), each name: letters, digits and `_`, then also `.`, `+` and `-`; no `..`
- `release_tag`, `release_name`, `release_notes` (string, optional; an empty `release_name` names the release after its tag)
- `generate_release_notes` (boolean, default `true`)
- `binary_links` (string, default `""`, `label|filename` per line; when empty, the Download Binaries table is generated from the build targets)
- `binary_base_url` (string, default `""`)
- `working_directory` (string, default `.`)
- `fetch_depth` (number, default `0`)

Example:

```yaml
name: Rust Release
on:
  push:
    tags: [ "v*.*.*" ]

jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/rust-release.yml@production
    with:
      bin_name: "image-view"
      linux_gnu_aliases: "deb,pacman,yum,redhat"
```

## go-release.yml

Workflow: `.github/workflows/go-release.yml`

Purpose: Build multi-target Go binaries and publish a GitHub Release.

The build runs with `contents: read`; a separate `release` job holds `contents: write`, downloads the built files and publishes them. The caller grants `contents: write`. It runs on `release_runner` (default `ubuntu-latest`), not `runner`: a reused self-hosted machine can carry state left by the build.

Inputs (selected):
- `bin_name` (string, required)
- `working_directory` (string, default `.`)
- `fetch_depth` (number, default `0`)
- `main_path` (string, default `"."`)
- `artifact_dir` (string, default `artifacts`)
- `go_version` (string, default `go.mod`: Go from `<working_directory>/go.mod`, its `toolchain` line when present; a version overrides it. The `go` line is a minimum: add a `toolchain` line or set a version to build with a newer Go)
- `build_targets` (string, default `linux/amd64,windows/amd64,darwin/amd64`)
- `ldflags` (string, default `""`)
- `release_tag`, `release_name`, `release_notes` (string, optional; an empty `release_name` names the release after its tag)
- `generate_release_notes` (boolean, default `true`)
- `binary_links` (string, default `""`, `label|filename` per line; when empty, the Download Binaries table is generated from the build targets)
- `binary_base_url` (string, default `""`)
- `cgo_enabled` (boolean, default `false`) - a cgo binary links against the build machine's libc, so it stays off unless a build needs it.
- `cgo_packages` (string, default `""`) - apt packages for the headers a cgo build needs. Ignored when `cgo_enabled` is `false`.

Example:

```yaml
name: Go Release
on:
  push:
    tags: [ "v*.*.*" ]

jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/go-release.yml@production
    with:
      bin_name: "myapp"
      main_path: "./cmd/myapp"
      build_targets: "linux/amd64,windows/amd64,darwin/amd64"
```

## go-deploy.yml

Workflow: `.github/workflows/go-deploy.yml`

Purpose: Build a Go binary and deploy it to a remote server via SSH and rsync.

This workflow cross-compiles a Go binary for a target OS/architecture, transfers
it to a remote host over SSH, optionally copies extra files (config templates,
migrations, etc.), and runs a post-deploy command (e.g. restart a systemd
service). Useful for deploying lightweight Go services to VPS or cloud instances.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `deploy_runner` (string, default `ubuntu-latest`) - runner for the `deploy` job, which holds the SSH key; not `runner`, since a reused self-hosted machine can carry state left by the build. It needs `ssh` and `rsync`
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `go_version` (string, default `go.mod`: Go from `<working_directory>/go.mod`, its `toolchain` line when present; a version overrides it. The `go` line is a minimum: add a `toolchain` line or set a version to build with a newer Go)
- `bin_name` (string, required) — output binary name
- `main_path` (string, default `"."`) — Go package path to build
- `build_target` (string, default `linux/amd64`) — `GOOS/GOARCH` pair
- `ldflags` (string, default `""`) — optional linker flags
- `remote_path` (string, required) — destination directory on the remote host
- `remote_bin_name` (string, default `""`) — rename binary on remote (defaults to `bin_name`)
- `extra_files` (string, default `""`) — comma-separated list of files to copy alongside the binary.
  A missing entry fails the deploy before anything is copied.
- `allow_missing_extra_files` (boolean, default `false`) - skip a missing `extra_files` entry
  with a warning instead of failing
- `post_deploy_command` (string, default `""`) — command to run on the remote host after deploy

Two jobs. `build` compiles the binary and stages it with the `extra_files` (a missing entry fails here) as an artifact kept one day, with a sha256 manifest. `deploy` holds the SSH key, checks out nothing of the caller's, checks the artifact against the manifest and copies it.

Secrets:
- `ssh_host` (required) — remote hostname or IP
- `ssh_user` (required) — SSH username
- `ssh_key` (required) — SSH private key
- `ssh_known_hosts` (required at run time) - known_hosts line(s) for `ssh_host`. SSH runs with
  `StrictHostKeyChecking=yes` against only these keys; an empty value fails the job before
  connecting. Produce it with `ssh-keyscan -t ed25519 <host>` and compare the fingerprint
  (`ssh-keygen -lf`) with the one the host prints locally (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`)

Example (deploy a Go service to Oracle Cloud):

```yaml
name: Deploy
on:
  push:
    branches: [ main ]
    paths: [ "server/**" ]

jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/go-deploy.yml@production
    with:
      working_directory: server
      bin_name: my-service
      build_target: linux/amd64
      remote_path: /opt/my-service
      extra_files: ".env.example"
      post_deploy_command: "sudo systemctl restart my-service"
    secrets:
      ssh_host: ${{ secrets.DEPLOY_HOST }}
      ssh_user: ${{ secrets.DEPLOY_USER }}
      ssh_key: ${{ secrets.DEPLOY_SSH_KEY }}
      ssh_known_hosts: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
```

Example (deploy to Arm instance):

```yaml
jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/go-deploy.yml@production
    with:
      working_directory: server
      bin_name: my-service
      build_target: linux/arm64
      remote_path: /opt/my-service
      post_deploy_command: "sudo systemctl restart my-service"
    secrets:
      ssh_host: ${{ secrets.DEPLOY_HOST }}
      ssh_user: ${{ secrets.DEPLOY_USER }}
      ssh_key: ${{ secrets.DEPLOY_SSH_KEY }}
      ssh_known_hosts: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
```

## wp-build.yml

Workflow: `.github/workflows/wp-build.yml`

Purpose: Build the zip a WordPress plugin ships.

It installs production Composer dependencies, runs the front-end build when
there is a `package.json`, copies the plugin without what only develops it, and
zips it as `<slug>-<version>.zip`. Excludes come from `.distignore`; without
one a default list is applied and printed. The build lives in script-helpers'
[`ci_wp_build.sh`](https://nikolareljin.github.io/script-helpers/commands/#scriptsci_wp_buildsh),
so `scripts/ci_wp_build.sh --workdir .` builds the same package locally.

It builds and uploads only. It creates no release and needs no
`contents: write`; attaching the zip is the caller's step (see the
[WordPress preset](presets.md#wordpress)).

Inputs:
- `runner` (string, default `ubuntu-24.04`: the ondrej/php PPA has no suite for `ubuntu-latest` (26.04) yet; it returns to `ubuntu-latest` when the PPA ships one)
- `working_directory` (string, default `.`)
- `fetch_depth` (number, default `0`)
- `submodules` (string, default `false`)
- `php_version` (string, default `8.3`)
- `node_version` (string, default `22`)
- `slug` (string, default `""`) - the plugin directory in the zip, and the name WordPress installs it as. Empty uses the working directory's name.
- `version` (string, default `""`) - empty reads the `Version:` header of the plugin file
- `out_dir` (string, default `build`)
- `composer_command` (string, default `composer install --no-dev --optimize-autoloader --prefer-dist --no-interaction`) - empty skips it
- `asset_command` (string, default `npm ci && npm run build`) - runs only when there is a `package.json`
- `exclude_from` (string, default `""`) - a file of rsync-style excludes. Empty uses `.distignore`.
- `zip` (boolean, default `true`)
- `verify_command` (string, default `""`) - your own check of the staged tree, run with `PACKAGE_DIR` and `PACKAGE_ZIP` set
- `upload_artifact` (boolean, default `true`)
- `artifact_name` (string, default `wp-plugin-package`) - holds the zip, or the staged tree when `zip` is `false`
- `retention_days` (number, default `7`)
- `timeout_minutes` (number, default `20`)

Outputs:
- `package_dir` - the staged tree that ships
- `package_zip` - the archive; empty when `zip` is `false`
- `version` - the version the package was built as

Example:

```yaml
jobs:
  build:
    uses: nikolareljin/ci-helpers/.github/workflows/wp-build.yml@production
    with:
      slug: my-plugin
      verify_command: 'test ! -d "$PACKAGE_DIR/node_modules"'
```

## wp-phpunit.yml

Workflow: `.github/workflows/wp-phpunit.yml`

Purpose: Run a WordPress plugin's own tests against the WordPress test suite.

`wp-plugin-check.yml` checks how a plugin is packaged. This runs what it does.
A plugin's `tests/bootstrap.php` is written against the WordPress test library,
which expects `WP_TESTS_DIR` to hold `includes/functions.php` and a
`wp-tests-config.php` naming a real database. Both are provisioned here, so the
plugin carries no `bin/install-wp-tests.sh`.

The library and core come from one `wordpress-develop` tarball, so they cannot
disagree about the version under test. `wp_version` takes a full `X.Y.Z`, a
minor like `7.1` which resolves to its newest patch, or `latest`; those tags are
always `X.Y.Z`, so a bare minor is resolved rather than requested and 404ing.

The script starts the database and removes it afterwards, so this does not go
through `ci.yml`'s `db_image`: one mechanism rather than two. The provisioning
lives in script-helpers' `ci_wp_phpunit.sh`, so the same code runs on a laptop.

The plugin needs `phpunit/phpunit` and `yoast/phpunit-polyfills` as dev
dependencies; the default `install_command` runs `composer install`.

`extra_command` is threaded through, so a plugin adds its own verifications
without forking this workflow.

Inputs:
- `runner` (string, default `ubuntu-24.04`: the ondrej/php PPA has no suite for `ubuntu-latest` (26.04) yet; it returns to `ubuntu-latest` when the PPA ships one)
- `working_directory` (string, default `.`)
- `fetch_depth` (number, default `0`)
- `submodules` (string, default `false`)
- `php_version` (string, default `8.3`)
- `wp_version` (string, default `latest`)
- `wp_multisite` (string, default `0`)
- `wp_tests_dir` (string, default `/tmp/wordpress-tests-lib`)
- `wp_core_dir` (string, default `/tmp/wordpress`)
- `install_command` (string, default `composer install --no-interaction --prefer-dist`)
- `lint_command` (string, default `""`)
- `test_command` (string, default `./vendor/bin/phpunit`)
- `build_command` (string, default `""`)
- `extra_command` (string, default `""`)
- `db_image` (string, default `mysql:8.0` pinned by digest) - pass `name:tag@sha256:<digest>` to pin your own; a tag alone works but can change under you
- `db_database` (string, default `wordpress_test`)
- `db_username` (string, default `wordpress`)
- `db_password` (string, default `wordpress`)
- `db_port` (string, default `3306`)
- `db_wait_seconds` (number, default `60`)
- `timeout_minutes` (number, default `20`)

Example:

```yaml
jobs:
  tests:
    uses: nikolareljin/ci-helpers/.github/workflows/wp-phpunit.yml@production
    with:
      wp_version: "7.1"
      php_version: "8.3"
```

## wp-plugin-check.yml

Workflow: `.github/workflows/wp-plugin-check.yml`

Purpose: Run WordPress plugin-check via Docker, with optional PHPUnit/lint.

Note: Requires Docker on the runner. Without `wp_version` or `versions`, it
also requires the compose file named by `compose_file`, which mounts the plugin.

Inputs:
- `runner` (string, default `ubuntu-24.04`: the ondrej/php PPA has no suite for `ubuntu-latest` (26.04) yet; it returns to `ubuntu-latest` when the PPA ships one)
- `compose_file` (string, default `test/docker-compose.yml`)
- `plugin_slug` (string, required)
- `plugin_src` (string, default `.`)
- `plugin_src_env` (string, default `PLUGIN_SRC`)
- `wpcli_service` (string, default `wpcli`)
- `db_service` (string, default `db`)
- `wordpress_service` (string, default `wordpress`)
- `host_port` (string, default `8080`)
- `out_dir` (string, default `test/tmp`)
- `db_wait_seconds` (string, default `30`)
- `multisite` (boolean, default `true`)
- `activate_network` (boolean, default `true`)
- `admin_user` (string, default `admin`)
- `admin_password` (string, default `""`: a random password per run)
- `admin_email` (string, default `admin@example.com`)
- `site_title` (string, default `WP Test Site`)
- `meta_check_script` (string, default `""`)
- `php_version` (string, default `""`)
- `php_lint_command` (string, default `""`)
- `phpcs_warning_command` (string, default `""`)
- `phpunit_command` (string, default `""`)
- `phpunit_working_directory` (string, default `.`)
- `wp_version` (string, default `""`)
- `plugin_dir` (string, default `""`)
- `versions` (string, default `""`)
- `exclude_directories` (string, default `vendor,node_modules,.git,.github`)
- `exclude_files` (string, default `.gitignore,.gitattributes,.editorconfig,.distignore`)
- `fail_on_findings` (boolean, default `false`)
- `cleanup` (boolean, default `true`)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `plugin-check-results`)

Set `wp_version` (or `versions`) and the workflow generates the WordPress
stack itself, so a plugin repository carries no compose file. `compose_file` still wins when set, for a
repository that needs services this does not describe.

The generated stack pins `mariadb`, `wordpress:cli` and the default
`wordpress:latest` by digest. An image composed from `wp_version`/`php_version`
(for example `wordpress:6.6-php8.3-apache`) is your choice and is pulled by tag.

`versions` runs one leg per entry:

```yaml
versions: '[{"wp":"6.2","php":"8.0"},{"wp":"7.1","php":"8.4"}]'
```

`php` is optional per entry. Each leg is named from its pair, so a failure says
`check wp6.2-php8.0` rather than a rendered struct. Empty `versions` runs a
single leg from `wp_version` and `php_version`.

`wp plugin check` reports every file it is given, and with `plugin_src: .` that
is the whole repository rather than the plugin. The two exclusion defaults name
what a plugin repository carries but does not ship. A caller pointing
`plugin_src` at an already packaged plugin passes empty strings to turn them
off.

`test` is deliberately not in the default list: a plugin that ships a `test`
directory would have it silently skipped.

Example:

```yaml
jobs:
  plugin-check:
    uses: nikolareljin/ci-helpers/.github/workflows/wp-plugin-check.yml@production
    with:
      plugin_slug: my-plugin
      plugin_src_env: MY_PLUGIN_SRC
      plugin_src: "."
      php_version: "8.4"
      phpunit_command: "vendor/bin/phpunit"
      phpcs_warning_command: "vendor/bin/phpcs -p -s --warning-severity=1 --error-severity=0 ."
      fail_on_findings: true
      upload_artifact: true
```

## tauri-scan.yml

Workflow: `.github/workflows/tauri-scan.yml`

Purpose: Fast Tauri lint + check gate (no full build). Runs on `ubuntu-24.04`.

Tauri **v2** links `webkit2gtk-4.1`, which 24.04 ships and the apt step
installs. Tauri **v1** needs `webkit2gtk-4.0`, which 24.04 does not have, so a
v1 app sets `runner: ubuntu-22.04` and an `apt_packages` list with
`libwebkit2gtk-4.0-dev`.

Inputs:
- `runner` (string, default `ubuntu-24.04`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `rust_toolchain` (string, default `stable`)
- `rust_components` (string, default `rustfmt,clippy`)
- `apt_packages` (string, default: full Tauri v2 WebKit2GTK deps)
- `lint_command` (string, default `cargo fmt -- --check && cargo clippy --all-targets -- -D warnings`).
  `--all-targets` because clippy otherwise checks the library and nothing else:
  a warning in test code passes `cargo clippy -- -D warnings` and fails with it.
- `check_command` (string, default `cargo check`)
- `node_version` (string, default `""`)
- `frontend_dir` (string, default `""` — skip frontend steps when empty)
- `frontend_install_command` (string, default `npm ci`)

Example:

```yaml
jobs:
  tauri-scan:
    uses: nikolareljin/ci-helpers/.github/workflows/tauri-scan.yml@production
    with:
      node_version: "22"
      frontend_dir: "src"
```

## tauri.yml

Workflow: `.github/workflows/tauri.yml`

Purpose: Standalone Tauri CI preset — installs Tauri system deps, runs tests
and a full `cargo build`. Does not wrap `ci.yml` (which has no apt step).
Runs on `ubuntu-24.04` by default; override with `runner`.

Rust comes from the runner's rustup as in [rust-scan.yml](#rust-scanyml).
The cargo registry is cached here and in `tauri-scan.yml`:
`~/.cargo/registry/index`, `~/.cargo/registry/cache` and `~/.cargo/git/db`,
restored with `actions/cache/restore` before `cargo fetch` (`--locked` when
there is a `Cargo.lock`) and saved with `actions/cache/save` right after it,
before any step runs the caller's code. `target/` is not cached and is built
on every run, and the build jobs of `tauri-release.yml` restore nothing (see
[Cache trust](SECURITY.md#cache-trust)). The key is
the runner OS and architecture, the job id, the `runner` label
(the Linux jobs), the rustc commit, and a hash of every `Cargo.lock`,
`Cargo.toml`, `rust-toolchain[.toml]` and `.cargo/config[.toml]` under the
workspace plus build-affecting variables named exactly: `RUSTFLAGS`,
`RUSTDOCFLAGS`, `CARGO_ENCODED_RUSTFLAGS`, `CARGO_INCREMENTAL`, the documented
`CARGO_BUILD_*` keys (`TARGET`, `RUSTFLAGS`, `RUSTDOCFLAGS`, `INCREMENTAL`,
`RUSTC`, `RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`),
`CARGO_PROFILE_<name>[_BUILD_OVERRIDE]_<key>` for cargo's profile keys,
`CARGO_TARGET_<TRIPLE>_LINKER`/`_RUNNER`/`_RUSTFLAGS`, `CC`, `CXX`, `AR`,
`CFLAGS`, `CXXFLAGS`, `LDFLAGS` (bare or with a `_<triple>` suffix),
`TARGET_`/`HOST_` forms of the compiler variables, `CMAKE_GENERATOR`,
`CMAKE_BUILD_TYPE`, `CMAKE_TOOLCHAIN_FILE`, `RUSTC`, `RUSTC_WRAPPER` and
`RUSTUP_TOOLCHAIN`. A triple suffix is matched token by token from closed
sets: an architecture (`x86_64`, `aarch64`, `armv7`, `wasm32`, ...), a vendor
(`unknown`, `apple`, `pc`, `linux`, ...), then OS and environment tokens
(`linux`, `gnu`, `darwin`, `windows`, `msvc`, `android`, `unknown`, ...), so
`CC_x86_64_unknown_linux_gnu` is hashed and `CC_x86_64_db_secretvalue` is not. Names holding `TOKEN`, `SECRET`, `PASS`,
`PW`, `PWD`, `PAT`, `CREDENTIAL`, `AUTH`, `KEY` or `PROXY` are dropped as well
(`scripts/rust_cache_key.sh`). A cargo-specific cache hashes every `CARGO*`,
`CC*`, `CFLAGS*`, `CXX*`, `CMAKE*` and `RUST*` variable; this one does not, so
a registry token or proxy URL is never hashed into a key that anyone with read
access can see. A lockfile change restores the previous entry through a
restore key without the hash. `~/.cargo/bin` (tools from `cargo install`) is
not cached.

Inputs: like `tauri-scan.yml`, but with no `check_command`, no lint and no
components by default, and with test and build steps:
- `runner` (string, default `ubuntu-24.04`) - the one worth overriding
- `working_directory` (string, default `.`) - the Cargo workspace root
- `fetch_depth` (number, default `0`)
- `rust_toolchain` (string, default `stable`)
- `rust_components` (string, default `""`)
- `apt_packages` (string, default: full Tauri v2 WebKit2GTK deps)
- `node_version` (string, default `""`) - empty skips Node setup
- `frontend_dir` (string, default `""`) - empty skips the frontend steps
- `frontend_install_command` (string, default `npm ci`)
- `frontend_build_command` (string, default `""`) - empty skips the build
- `lint_command` (string, default `""`) - empty skips lint
- `test_command` (string, default `cargo test --verbose`)
- `build_command` (string, default `cargo build --verbose`)

Example:

```yaml
jobs:
  tauri-ci:
    uses: nikolareljin/ci-helpers/.github/workflows/tauri.yml@production
    with:
      node_version: "22"
      test_command: "cargo test --workspace"
```

## tauri-release.yml

Workflow: `.github/workflows/tauri-release.yml`

Purpose: Cross-platform Tauri desktop release: three build jobs
(`macos-latest`, `windows-latest`, and the `runner` input, default
`ubuntu-24.04`), two signing jobs, a GitHub release, and optionally a WinGet
submission.

Jobs:

| Job | Runs | Holds |
|-----|------|-------|
| `build-macos` | `cargo tauri build --bundles app`, unsigned | nothing (`contents: read`) |
| `build-signer-macos` | `cargo install tauri-cli --locked` on `macos_sign_runner`, with `macos_updater_sign` | nothing (`contents: read`) |
| `sign-macos` | on `macos_sign_runner` | the Apple secrets, and the updater key with `macos_updater_sign` |
| `build-windows` | `cargo tauri build`, unsigned | nothing (`contents: read`) |
| `build-signer-windows` | `cargo install tauri-cli --locked` on `windows_sign_runner`, with `tauri_updater` | nothing (`contents: read`) |
| `sign-windows` | on `windows_sign_runner` | the PFX, Azure or updater secrets of `windows_sign_mode` |
| `build-linux` | `cargo tauri build` | nothing |
| `release` | uploads `tauri-*-artifacts` | `contents: write`, `DIST_REPO_TOKEN` |

Key design notes:
- macOS builds a **universal binary** (`aarch64 + x86_64`); both rustup targets
  must be added, as `universal-apple-darwin` is a Tauri synthetic target, not
  a native rustup triple.
- The build jobs run the app's own npm and cargo scripts, which can change
  files, `PATH` or `GITHUB_ENV` for the rest of their job, so no secret
  reaches them. They build with `--config` turning off the bundler's own
  signing (`signingIdentity`, `certificateThumbprint`, `signCommand`) and
  updater artifacts, whatever `tauri.conf.json` says, and upload their
  output with a sha256 manifest under
  `tauri-<macos|windows>-build-<run id>-<attempt>-<random>`, kept one day.
- `sign-macos` and `sign-windows` check out nothing of the caller's, check
  the artifact name and every file against the manifest
  (`scripts/artifact_parts.sh verify`; Windows: `.exe` and `.msi` names at
  the top of the artifact only), and run only library scripts, the
  ci-helpers actions at this workflow's commit, system signing tools and
  the updater signer: `tauri-cli` at the version in the library's
  `toolchain-pins.env` (`TAURI_CLI_VERSION`), run as `tauri signer sign`
  from an empty directory (`scripts/tauri_updater_sign.sh`). No bundler
  hook and no cargo runs there.
- `build-signer-macos` and `build-signer-windows` hold no secret. They build
  that `tauri-cli` with `scripts/install_tauri_signer.sh`: `cargo install
  --locked`, a fresh `CARGO_HOME` and an empty directory under
  `RUNNER_TEMP`, no `CARGO_*`, `RUSTC*` or `RUSTFLAGS` from the
  environment, empty `rustc-wrapper`s, `RUSTUP_TOOLCHAIN=stable`, and a
  refusal when a `.cargo/config` or `rust-toolchain` file sits above that
  directory. They upload the binary with a sha256 manifest as
  `tauri-signer-<macos|windows>-<run id>-<attempt>-<random>`; the sign job
  checks the name, verifies the binary against the manifest and runs it.
- `sign-macos` (`scripts/tauri_macos_sign.sh`) unpacks the app
  (`scripts/safe_untar.py`), signs it with the hardened runtime
  (`codesign --deep --options runtime --timestamp`, with
  `macos_entitlements` when set), builds `<Name>_<version>_universal.dmg`
  with `hdiutil` (the app and an `/Applications` link), signs it, notarizes
  and staples it (`notarize_macos`: with `NOTARY_API_KEY`, `NOTARY_KEY_ID`
  and `NOTARY_ISSUER_ID` the key goes to `notarytool --key` as a 0600 file
  in a private directory, removed after; without them the Apple ID and
  app password are used, which `notarytool` takes on its command line, and
  the job warns), staples the app and makes
  `<Name>.app.tar.gz`, plus `.sig` with `macos_updater_sign`. The version
  is the app's `CFBundleShortVersionString`. With `sign_macos: false` the
  DMG and bundle are unsigned.
- Windows signing modes: `none` (default), `tauri_updater` (free ED25519
  `.sig` per installer), `pfx` (Authenticode with a `.pfx`) and `azure`
  (Azure Artifact Signing). Any other value fails the first step of
  `build-windows`. [Windows signing](windows-signing.md) covers certificates
  and setup. `sign-windows` runs in every mode; with `none` it republishes
  the installers as built.
- Both actions (`macos-sign`, `windows-sign`) run with `export_env:
  "false"`, so nothing secret is in `GITHUB_ENV`.
- A published installer is never replaced, on the release or on `dist_repo`:
  one already there with the same sha256 passes (a rerun of the `release` job),
  a different sha256 fails. Delete the asset to republish.

Inputs (selected):

| Input | Default | Description |
|-------|---------|-------------|
| `runner` | `ubuntu-24.04` | Linux runner for `build-linux`. |
| `version` | `""` | Patches `tauri.conf.json` + `Cargo.toml` |
| `rust_toolchain` | `stable` | Rust toolchain |
| `node_version` | `""` | Optional Node.js version |
| `working_directory` | `"."` | Repo-relative project root |
| `tauri_conf_path` | `src-tauri/tauri.conf.json` | Relative to working_directory |
| `frontend_dir` | `"."` | Directory for frontend install/build |
| `frontend_install_command` | `npm ci` | |
| `frontend_build_command` | `""` | Empty = skip explicit build step |
| `sign_macos` | `true` | Gate macOS codesigning |
| `notarize_macos` | `true` | Gate notarization + staple |
| `macos_entitlements` | `""` | Entitlements plist for `codesign`, relative to `working_directory`; the bundler's `bundle.macOS.entitlements` is not read |
| `macos_updater_sign` | `false` | Write `<Name>.app.tar.gz.sig` with `TAURI_SIGNING_PRIVATE_KEY` |
| `macos_sign_runner` | `macos-latest` | Runner for `sign-macos` |
| `windows_sign_runner` | `windows-latest` | Runner for `sign-windows` |
| `windows_sign_mode` | `none` | `none`, `tauri_updater`, `pfx`, `azure` |
| `windows_timestamp_server` | `""` | RFC 3161 URL for `pfx`; empty uses `http://timestamp.digicert.com` |
| `windows_pfx_verify_trust` | `true` | `pfx`: require `signtool verify /pa`; `false` for a private CA or self-signed certificate |
| `upload_release` | `true` | Upload to GitHub Releases |
| `release_tag` | `""` | Defaults to `GITHUB_REF_NAME` |
| `dist_repo` | `""` | Cross-repo artifact push |
| `winget_submit` | `false` | Enable WinGet submission job |
| `winget_package_id` | `""` | e.g. `OrgName.AppName` |
| `winget_installer_url` | `""` | Direct `.exe` URL |
| `winget_installer_arch` | `x64` | Architecture tag |
| `winget_installer_type` | `nullsoft` | `nullsoft`, `msi`, `wix` |
| `winget_fork_owner` | `""` | Owner of the `microsoft/winget-pkgs` fork |
| `release_name` | `""` | Release title; empty is `Release <tag>` |
| `apt_packages` | WebKitGTK, GTK and build tools | Linux system packages |
| `artifact_retention_days` | `3` | Retention of artifacts passed between jobs |
| `fetch_depth` | `0` | |

Secrets:

| Secret | When required |
|--------|---------------|
| `APPLE_CERTIFICATE` | `sign_macos: true` |
| `APPLE_CERTIFICATE_PASSWORD` | `sign_macos: true` |
| `APPLE_SIGNING_IDENTITY` | `sign_macos: true` |
| `APPLE_TEAM_ID` | `sign_macos: true` |
| `APPLE_ID` | `notarize_macos: true` |
| `APPLE_APP_PASSWORD` | `notarize_macos: true` |
| `APPLE_PASSWORD` | accepted as an alias of `APPLE_APP_PASSWORD`, the name most consumers already hold; pass either, not both |
| `NOTARY_API_KEY` | `notarize_macos: true`, preferred: base64 App Store Connect API key (`.p8`) |
| `NOTARY_KEY_ID` | with `NOTARY_API_KEY` |
| `NOTARY_ISSUER_ID` | with `NOTARY_API_KEY` (issuer UUID) |
| `TAURI_SIGNING_PRIVATE_KEY` | `windows_sign_mode: tauri_updater` or `macos_updater_sign: true` |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | `windows_sign_mode: tauri_updater` or `macos_updater_sign: true` |
| `WINDOWS_CERTIFICATE` | `windows_sign_mode: pfx` (base64 `.pfx`) |
| `WINDOWS_CERTIFICATE_PASSWORD` | `windows_sign_mode: pfx` |
| `AZURE_TENANT_ID` | `windows_sign_mode: azure` |
| `AZURE_CLIENT_ID` | `windows_sign_mode: azure` |
| `AZURE_CLIENT_SECRET` | `windows_sign_mode: azure` |
| `AZURE_TRUSTED_SIGNING_ENDPOINT` | `windows_sign_mode: azure` |
| `AZURE_CODE_SIGNING_ACCOUNT` | `windows_sign_mode: azure` |
| `AZURE_CERT_PROFILE` | `windows_sign_mode: azure` |
| `DIST_REPO_TOKEN` | `dist_repo` set |
| `WINGET_PKGS_TOKEN` | `winget_submit: true` |

Example (signed release with WinGet):

```yaml
jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/tauri-release.yml@production
    with:
      version: ${{ github.ref_name }}
      node_version: "22"
      sign_macos: true
      notarize_macos: true
      windows_sign_mode: tauri_updater
      winget_submit: true
      winget_package_id: "MyOrg.MyApp"
      winget_installer_url: "https://github.com/myorg/myapp/releases/download/${{ github.ref_name }}/MyApp-setup.exe"
    secrets:
      APPLE_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE }}
      APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
      APPLE_SIGNING_IDENTITY: ${{ secrets.APPLE_SIGNING_IDENTITY }}
      APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
      APPLE_ID: ${{ secrets.APPLE_ID }}
      APPLE_APP_PASSWORD: ${{ secrets.APPLE_APP_PASSWORD }}
      TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}
      TAURI_SIGNING_PRIVATE_KEY_PASSWORD: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY_PASSWORD }}
      WINGET_PKGS_TOKEN: ${{ secrets.WINGET_PKGS_TOKEN }}
```

## winget-submit.yml

Workflow: `.github/workflows/winget-submit.yml`

Purpose: Submit a Windows Package Manager manifest to a fork of
`microsoft/winget-pkgs`. Installs `wingetcreate` via dotnet, runs
`wingetcreate update`, and submits the generated PR.

Inputs:

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `package_id` | yes | — | e.g. `OrgName.AppName` |
| `version` | yes | — | Package version string |
| `installer_url` | yes | — | Direct URL to the installer binary |
| `installer_arch` | no | `x64` | Architecture tag |
| `installer_type` | no | `nullsoft` | `nullsoft`, `msi`, `wix` |
| `release_notes_url` | no | `""` | Link added to the manifest |
| `winget_fork_owner` | yes | — | GitHub user/org that owns the `winget-pkgs` fork |

Secrets:
- `WINGET_PKGS_TOKEN` (required) — PAT with `repo` scope on the `winget-pkgs` fork

Example (standalone call):

```yaml
jobs:
  winget:
    uses: nikolareljin/ci-helpers/.github/workflows/winget-submit.yml@production
    with:
      package_id: "MyOrg.MyApp"
      version: "1.2.3"
      installer_url: "https://github.com/myorg/myapp/releases/download/1.2.3/MyApp-setup.exe"
      winget_fork_owner: "myorg"
    secrets:
      WINGET_PKGS_TOKEN: ${{ secrets.WINGET_PKGS_TOKEN }}
```

## docker-multiarch.yml

Workflow: `.github/workflows/docker-multiarch.yml`

Purpose: Build and push a multi-architecture Docker image (`linux/amd64` +
`linux/arm64` by default) using QEMU + buildx. Optionally runs a Trivy
vulnerability scan on the pushed image.

Two jobs. `build` (`contents: read`, no secret, on `runner`) builds the
caller's Dockerfile into an OCI image layout (`--output
type=oci,tar=false`, every platform and the provenance attestation),
stores a blob over 60 MiB as `<digest>.split-NNN` parts
(`scripts/artifact_parts.sh split`), and uploads the layout with a sha256
manifest after the publication check. `push` (`packages: write`,
`registry_token`, on `push_runner`) checks out nothing of the caller's: it
downloads the layout, checks it against the manifest and joins the parts
(`scripts/artifact_parts.sh verify`), logs in, and pushes it with
`scripts/docker_push_oci.sh`, which refuses a blob whose name is not its
sha256, a file that is not part of an OCI layout and an index naming other
than one manifest, then runs `skopeo copy --all --preserve-digests` for
each tag and fails when the registry reports another digest. `push_runner`
needs `skopeo` in `/usr/bin` or `/bin` (on GitHub's Ubuntu images). The
login is kept in a 0700 directory under `RUNNER_TEMP`, removed when the job
ends. `image_name` is lowered, then must be a `registry/name`; `image_ref`
holds the lowered name. `tag` must be a valid image tag.

Every step runs the docker CLI the runner ships, through scripts the job
checks out from this library at the workflow's own commit; no third-party
action. `scripts/setup_qemu.sh` registers the emulators by running the binfmt
image pinned by tag and index digest in the library's `toolchain-pins.env`
(`BINFMT_IMAGE`), every platform. `scripts/setup_buildx.sh` creates a
`docker-container` builder on the BuildKit image pinned there
(`BUILDKIT_IMAGE`); a runner without the buildx plugin fails with the message
saying so. `scripts/docker_login.sh` hands `registry_token` to `docker login
--password-stdin`, so the token is in no argument and no log, and logs out in a
final step whatever the build did; an Amazon ECR host is refused (get a login
password with `aws ecr get-login-password` in the caller and pass it as the
token, with `registry_username: AWS`). `scripts/docker_build.sh` runs `docker
buildx build` with the context, Dockerfile, platforms and
build-args to the OCI layout, with no layer cache: the push job publishes these layers, and a
layer restored from the Actions cache would be a layer of the pushed image
(see [Cache trust](SECURITY.md#cache-trust)); provenance is `mode=max` for a public repository and
`mode=min,inline-only=true` for a private one. The printed command masks
build-arg values. No build secret is passed, as before; a caller's own step can
run `scripts/docker_build.sh` with `BUILD_SECRET_ENVS` (`id=VARIABLE` per
line), which mounts `--secret id=<id>,env=<VARIABLE>` and never handles the
value.

Inputs:

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `image_name` | yes | — | Full image name, e.g. `ghcr.io/org/app` |
| `tag` | yes | — | Image tag |
| `platforms` | no | `linux/amd64,linux/arm64` | Comma-separated platform list |
| `dockerfile` | no | `Dockerfile` | Path to Dockerfile |
| `context` | no | `"."` | Build context |
| `build_args` | no | `""` | Newline-separated `KEY=VALUE` build args |
| `push_latest` | no | `false` | Also tag and push `:latest` |
| `registry` | no | `ghcr.io` | Container registry host |
| `registry_username` | no | `""` (falls back to `github.actor`) | Registry login username |
| `scan_after_build` | no | `true` | Run Trivy scan after push |
| `trivy_severity` | no | `CRITICAL,HIGH` | Severities that trigger scan output |
| `fail_on_scan_findings` | no | `false` | Fail the workflow on Trivy findings |
| `fetch_depth` | no | `0` | Checkout depth |
| `runner` | no | `ubuntu-latest` | Runner for the `build` job |
| `push_runner` | no | `ubuntu-latest` | Runner for the `push` job, which holds the token; needs `skopeo` |

Secrets:
- `registry_token` (required) — registry password / token (e.g. `secrets.GITHUB_TOKEN` for GHCR)

Outputs:
- `image_digest` — SHA digest of the pushed manifest
- `image_ref` — `image_name:tag`

Example:

```yaml
jobs:
  docker:
    uses: nikolareljin/ci-helpers/.github/workflows/docker-multiarch.yml@production
    with:
      image_name: ghcr.io/${{ github.repository }}
      tag: ${{ github.ref_name }}
      push_latest: true
      fail_on_scan_findings: true
    secrets:
      registry_token: ${{ secrets.GITHUB_TOKEN }}
```

## manifest-version.yml

Workflow: `.github/workflows/manifest-version.yml`

Purpose: Extract the project version from a manifest file, create a lightweight
git tag, and optionally dispatch downstream release workflows. Supports six
manifest types out of the box.

Inputs:

| Input | Default | Description |
|-------|---------|-------------|
| `manifest_type` | `package_json` | `package_json`, `cargo`, `pubspec`, `pyproject`, `version_file`, `custom` |
| `manifest_path` | auto | Path to manifest; each type has a sensible default |
| `version_command` | `""` | Shell command that prints the version (used with `custom`) |
| `dispatch_workflows` | `""` | Comma-separated workflow filenames to dispatch after tagging |
| `dispatch_inputs_json` | `{}` | Extra JSON inputs passed to each dispatched workflow |
| `publish_latest` | `true` | Forwarded as `publish_latest` to dispatched workflows |
| `tag_prefix` | `""` | Prefix prepended to the version when creating the tag (e.g. `v`) |
| `skip_if_tagged` | `true` | Skip tagging when the tag already exists |
| `runner` | `ubuntu-latest` | Runner for the `version` job |
| `tag_runner` | `ubuntu-latest` | Runner for the `tag-and-dispatch` job, which holds the write token; not `runner`, since a reused self-hosted machine can carry state left by `version_command` |
| `fetch_depth` | `0` | |

Two jobs. `version` reads the version (and runs `version_command`) with `contents: read`. `tag-and-dispatch` checks the version is `X.Y.Z` again, then tags and dispatches; it runs nothing from the caller's tree.

Outputs:
- `version` — extracted version string (no prefix)
- `tag` — git tag that was created
- `skipped` — `true` when the tag already existed and `skip_if_tagged` was set

Supported manifest types:

| Type | Default path | Extraction method |
|------|-------------|-------------------|
| `package_json` | `package.json` | `node` + `fs.readFileSync` + `JSON.parse` (path passed via env var, not interpolated) |
| `cargo` | `Cargo.toml` | `awk` scoped to `[package]` section (avoids matching dependency versions) |
| `pubspec` | `pubspec.yaml` | `grep '^version:'`, strips `+build` suffix |
| `pyproject` | `pyproject.toml` | Python regex scoped to `[project]` or `[tool.poetry]` section |
| `version_file` | `VERSION` | entire file content, whitespace stripped |
| `custom` | — | runs `version_command` and captures stdout |

Example (tag from `package.json`, then dispatch a publish workflow):

```yaml
jobs:
  version:
    uses: nikolareljin/ci-helpers/.github/workflows/manifest-version.yml@production
    with:
      manifest_type: package_json
      tag_prefix: "v"
      dispatch_workflows: "publish.yml"
      dispatch_inputs_json: '{"env":"prod"}'
```

Example (Cargo project, skip if already tagged):

```yaml
jobs:
  version:
    uses: nikolareljin/ci-helpers/.github/workflows/manifest-version.yml@production
    with:
      manifest_type: cargo
      skip_if_tagged: true
```

## release-rc-pr.yml (reusable)

Workflow: `.github/workflows/release-rc-pr.yml`

Purpose: Open a PR from a release branch to the default branch. Can be used
as a reusable `workflow_call` workflow — add a 10-line wrapper in your repo
and get automatic release PRs on every `release/*` push.

See [RELEASE_RC_PR.md](RELEASE_RC_PR.md) for the full setup guide, including
required repository settings, `GH_PAT` secret instructions, and the historical
failure analysis.

Inputs (workflow_call):

| Input | Default | Description |
|-------|---------|-------------|
| `base_branch` | `main` | Branch the PR targets. Any value other than `main` is used as given; `main` (also the default, so indistinguishable from not passing it) uses the repository's default branch from the event payload. |
| `soft_fail` | `false` | When `true`, a known permission `403` (Actions may not open PRs, the token lacks `pull-requests: write`, PRs disabled) warns and the job passes. By default it fails the job. ci-helpers' own run on `create` (no inputs) warns, since its release script opens the PR. |

The caller may trigger it from `create` (filtered to `release/*` branches) or from any other event such as `push` to `release/*`; a ref that is not `release/[v]X.Y.Z[-rcN|-rc.N]` is skipped.

Secrets (workflow_call):

| Secret | Required | Description |
|--------|----------|-------------|
| `GH_PAT` | no | PAT with pull-request write access (classic: `repo` scope; fine-grained: Pull requests Read+write); falls back to `github.token` |

Example (caller repo):

```yaml
# .github/workflows/release-pr.yml
name: Open release PR
on:
  create:
jobs:
  open-pr:
    if: ${{ github.event.ref_type == 'branch' && startsWith(github.event.ref, 'release/') }}
    uses: nikolareljin/ci-helpers/.github/workflows/release-rc-pr.yml@production
    secrets: inherit
```

## Pinning versions

You should pin to a tag or commit SHA:

```yaml
uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@production
```

Using a commit SHA is safest for reproducibility:

```yaml
uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@production
```

## Working directory

If your repository is a monorepo, set `working_directory` so commands run in the
package folder:

```yaml
with:
  working_directory: "apps/web"
  node_version: "22"
  test_command: "yarn test"
```
