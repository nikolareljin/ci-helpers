# Upgrading to 1.0

Release 1.0.0 moves every job that holds a key, a write token or a release
upload away from the caller's code, and drops the third-party installer
actions. Most callers change nothing. This page lists the callers that must
change something, what happens if they do not, and the change.

A "required check" below is a status check named in a branch protection rule
or ruleset. A reusable workflow's check is `<caller job> / <job>`, where
`<caller job>` is the job id in the calling workflow (`docker` in the
examples).

## docker-multiarch.yml

Affected: rulesets that require `docker / build-push`; `image_name` values
without a registry; Amazon ECR registries.

If nothing changes:

- the merge stays blocked: `docker / build-push` never reports, the run
  reports `docker / build` and `docker / push`;
- an `image_name` that is not `registry/name` after lower-casing fails before
  any push;
- an ECR registry fails `Log in to registry` with a message naming
  `aws ecr get-login-password`.

Change: require the two new checks. For ECR, fetch the token in the caller.

```yaml
# before (required checks): docker / build-push
# after  (required checks): docker / build, docker / push
jobs:
  docker:
    uses: nikolareljin/ci-helpers/.github/workflows/docker-multiarch.yml@production
    with:
      image_name: ghcr.io/owner/app      # registry/name
      runner: ubuntu-latest              # build job (new, optional)
      push_runner: ubuntu-latest         # push job, needs skopeo (new, optional)
    secrets:
      registry_token: ${{ secrets.GHCR_TOKEN }}
```

## go-deploy.yml and ppa-deb.yml

Affected: callers on a self-hosted `runner`; rulesets that list the workflow's
checks.

If nothing changes: the build runs on `runner` and the deploy (`go-deploy`) or
PPA (`ppa-deb`) job runs on `ubuntu-latest`, the default of the new input. A
`deploy` or `ppa` job that needs a self-hosted machine (a private network, a
local tool) fails there. A new check `<caller job> / build` reports; add it to
the ruleset to require it.

Change:

```yaml
    with:
      runner: self-hosted          # build job, runs the caller's code
      deploy_runner: self-hosted   # go-deploy.yml only: deploy job
      publish_runner: self-hosted  # ppa-deb.yml only: ppa job
```

`go-deploy.yml` copies the file the build made, `<bin_name>.exe` for a Windows
target. A staged symlink, special file or file larger than 64 MiB fails the
build.

## manifest-version.yml

Affected: callers on a self-hosted `runner`.

If nothing changes: `version_command` runs in the new read-only `version` job
on `runner`; `tag-and-dispatch` runs on `ubuntu-latest`. A new check
`<caller job> / version` reports.

Change: set `tag_runner` when the tag job needs a specific machine.

```yaml
    with:
      runner: self-hosted
      tag_runner: self-hosted
```

## cloudflare-deploy.yml and cloudflare-build.yml

Affected: callers that pass `deploy_command` (`cloudflare-deploy.yml`),
`wrangler_command` or a `wrangler_version` other than the pin (both).

If nothing changes: the run fails with
`deploy_command is removed: the deploy job runs no caller command...` or
`wrangler_command is removed: ...`.

Change: put the build in `build_command`, pick the wrangler call with
`command` (`deploy`, `versions upload` or `pages deploy`) and pass its flags in
`deploy_args`, each checked against an allowlist. The wrangler `--env` name
comes from `environment` (or `wrangler_env`). `wrangler_version` accepts only
empty or the library's pin (`WRANGLER_VERSION` in `toolchain-pins.env`); any
other value fails the run.

```yaml
# before
    with:
      deploy_command: npm run build && npx wrangler deploy --name my-worker
      wrangler_version: "4.42.0"
# after
    with:
      build_command: npm run build
      command: deploy
      deploy_args: --name my-worker
```

## java-scan.yml

Affected: callers that set `dependency_check_command`.

If nothing changes: `NVD_API_KEY` is not set in the scan job, so
`-DnvdApiKey=$NVD_API_KEY` passes an empty key. The NVD data comes from the
new `nvd` job, which holds the key.

Change: drop the key flag and use dependency-check-maven 13.x (Maven 3.9 or
later), which reads `-DdataDirectory=$DC_DATA_DIR -DautoUpdate=false` from
`MAVEN_ARGS`.

```yaml
# before
      dependency_check_command: mvn -B org.owasp:dependency-check-maven:check -DnvdApiKey=$NVD_API_KEY
# after
      dependency_check_command: mvn -B org.owasp:dependency-check-maven:check   # plugin 13.x
      nvd_runner: ubuntu-latest   # optional, the job that holds nvd_api_key
```

## flutter-release.yml

Affected: every caller; rulesets that require `<caller job> / flutter_release`;
callers that pass `fastlane_android_lane` or `fastlane_ios_lane`.

If nothing changes:

- the merge stays blocked: `flutter_release` does not report; the run
  reports `build`, `sign-android` (with `build_android`) and
  `upload-app-store` (with `deploy_app_store`);
- passing a removed input fails the workflow call before any job starts;
- `deploy_google_play` without `android_package_name`, or `deploy_app_store`
  without `ios_bundle_id` and `ios_team_id`, fails.

The app's `Fastfile`, `Appfile`, `Matchfile`, `Pluginfile` and `Gemfile` are
not read. Metadata, images and changelogs are not uploaded to Google Play.

```yaml
# before
    with:
      build_android: true
      deploy_google_play: true
      fastlane_android_lane: deploy
# after
    with:
      build_android: true
      deploy_google_play: true
      android_package_name: com.example.app   # plus the four keystore secrets
      google_play_track: internal          # default
      runner: macos-latest                 # an App Store build needs macOS
      deploy_app_store: true
      ios_bundle_id: com.example.app
      ios_team_id: ABCDE12345
      app_store_destination: testflight    # default; or app_store
```

`ruby_version` resolves only to a Ruby in the runner's tool cache (3.2, 3.3,
3.4 and 4.0 on hosted images); another value fails `Setup Ruby`.

## tauri-release.yml

Affected: every caller that requires the workflow's checks; apps that set
signing in `tauri.conf.json`.

If nothing changes: a new check `<caller job> / sign-macos` reports, and
`<caller job> / sign-windows` reports in every `windows_sign_mode`
(`release` needs both).
`bundle.macOS.signingIdentity`, `bundle.macOS.entitlements`,
`bundle.windows.signCommand` and `certificateThumbprint` have no effect. A
custom DMG background or layout is not applied. App and installer names with
characters other than letters, digits, space and `._+-` fail.

Change: pass entitlements as an input; set the runners if the defaults do not
fit; prefer the API key for notarization.

```yaml
    with:
      macos_entitlements: src-tauri/entitlements.plist
      macos_sign_runner: macos-latest       # default
      windows_sign_runner: windows-latest   # default
    secrets:
      NOTARY_API_KEY: ${{ secrets.NOTARY_API_KEY }}     # base64 .p8, optional
      NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
      NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
```

## auto-tag.yml, auto-tag-release.yml and update-production.yml

Affected: repositories with their own `scripts/create_production.sh`, when
`auto-tag.yml` runs with `update_production_tag: true`, and every caller of
`auto-tag-release.yml` and `update-production.yml`.

If nothing changes: the library's `scripts/create_production.sh` moves the
`production` ref; the repository's copy is not run, so local changes to it
have no effect. `update-production.yml` always passes
`--allow-prerelease --allow-rollback`. The `production` branch moves only if
it already exists on the remote; a repository without one gets the tag only,
and the log says so.

Change: none in the workflow call. Move any behaviour the local script added
into a separate step or job. To keep a `production` branch, create it once
(`git push origin <tag>:refs/heads/production`); nothing needs deleting.

## pnpm.yml, pnpm-cypress.yml and pnpm-playwright.yml

Affected: callers with `upload_test_results: true` whose ruleset requires the
`Tests<suffix>` check run.

If nothing changes: the merge stays blocked; the check run is not created.
Test results are on the job summary page.

Change: remove `Tests<suffix>` from the required checks.

## Toolchain inputs

| Workflows | Input | Fails when |
|---|---|---|
| PHP workflows (`php.yml`, `php-scan.yml`, `laravel.yml`, `pimcore.yml`, `pimcore-bundle-check.yml`, `wp-*.yml`; `ci.yml`, `pr-gate.yml`, `deploy.yml`, `release-build.yml` with `php_version`) | `php_version` | not `X.Y` (`latest`, `nightly`, `8.4.1`) |
| `godot.yml`; `ci.yml`, `pr-gate.yml` with `godot_version` | `godot_version` | not `4.3.0` or `4.7.2` |
| `ci.yml`, `pr-gate.yml`, `release-build.yml`, `flutter-release.yml` | `flutter_channel` | `master` or `main` |
| `unity.yml` | editor version | no `UNITY_EDITOR_IMAGE_<version>` line in `toolchain-pins.env` |

An empty `flutter_version` with `flutter_channel: stable` installs the pinned
Flutter 3.47.9. PHP presets default `runner` to `ubuntu-24.04`. `unity.yml`'s
`cache` input has no effect.

See the [CHANGELOG](https://github.com/nikolareljin/ci-helpers/blob/main/CHANGELOG.md) 1.0.0 section for every change.
