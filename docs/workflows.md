# Reusable Workflows

This repo exposes reusable workflows via `workflow_call`. You consume them from
your own repo by referencing this repo path and a tag or commit SHA.

Related docs:
- [Presets](presets.md)
- [Composite actions](actions.md)
- [Examples](examples.md)

All workflows use Bash with `set -euo pipefail` for the commands you pass in.
All commands run inside `inputs.working_directory` (default `"."`).

## ci.yml

Workflow: `.github/workflows/ci.yml`

Purpose: Run lint, test, build, optional Docker, and optional E2E commands.

Execution order:
1) Lint
2) Test
3) Build
4) Docker
5) E2E
6) Extra

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `node_version` (string, default `""`)
- `java_version` (string, default `""`)
- `dotnet_version` (string, default `""`)
- `python_version` (string, default `""`)
- `go_version` (string, default `""`)
- `php_version` (string, default `""`)
- `rust_toolchain` (string, default `""`)
- `rust_components` (string, default `""`)
- `lint_command` (string, default `""`)
- `test_command` (string, default `""`)
- `build_command` (string, default `""`)
- `docker_command` (string, default `""`)
- `e2e_command` (string, default `""`)
- `extra_command` (string, default `""`)

Example (Node + E2E with Playwright):

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@production
    with:
      node_version: "20"
      lint_command: "yarn lint"
      test_command: "yarn test"
      build_command: "yarn build"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx playwright test'"
```

Example (Docker build + E2E):

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@production
    with:
      node_version: "20"
      docker_command: "docker build -t myapp:ci ."
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
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
- All CI inputs (same as `ci.yml`)
- `check_release_tag` (boolean, default `false`)
- `release_branch` (string, default `""`)

Example (PR gate with release tag check + E2E):

```yaml
jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/pr-gate.yml@production
    with:
      node_version: "20"
      lint_command: "yarn lint"
      test_command: "yarn test"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
      check_release_tag: true
      release_branch: ${{ github.head_ref }}
```

## deploy.yml

Workflow: `.github/workflows/deploy.yml`

Purpose: Run a deployment command with optional runtime setup.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `node_version` (string, default `""`)
- `java_version` (string, default `""`)
- `dotnet_version` (string, default `""`)
- `python_version` (string, default `""`)
- `go_version` (string, default `""`)
- `php_version` (string, default `""`)
- `deploy_command` (string, required)

Example:

```yaml
jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/deploy.yml@production
    with:
      node_version: "20"
      deploy_command: "./scripts/deploy.sh"
```

## flutter-release.yml

Workflow: `.github/workflows/flutter-release.yml`

Purpose: Build Flutter Android/iOS artifacts and optionally deploy to Google Play and Apple App Store via Fastlane.

Notes:
- iOS builds/uploads require a macOS runner.
- For store deploys, a Fastlane lane is expected in the app repo (Gemfile optional).

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `flutter_version` (string, default `stable`)
- `flutter_channel` (string, default `stable`)
- `java_version` (string, default `"17"`)
- `ruby_version` (string, default `"3.2"`)
- `build_android` (boolean, default `true`)
- `build_ios` (boolean, default `false`)
- `deploy_google_play` (boolean, default `false`)
- `deploy_app_store` (boolean, default `false`)
- `android_build_command` (string, default `flutter build appbundle --release`)
- `ios_build_command` (string, default `flutter build ios --release --no-codesign`)
- `android_artifact_path` (string, default `build/app/outputs/bundle/release/*.aab`)
- `ios_artifact_path` (string, default `build/ios/ipa/*.ipa`)
- `upload_artifacts` (boolean, default `true`)
- `android_artifact_name` (string, default `flutter-android`)
- `ios_artifact_name` (string, default `flutter-ios`)
- `fastlane_android_lane` (string, default `android_release`)
- `fastlane_ios_lane` (string, default `ios_release`)

Secrets:
- `android_keystore_base64` (optional)
- `android_keystore_password` (optional)
- `android_key_alias` (optional)
- `android_key_password` (optional)
- `google_play_service_account_json` (optional, for deploy)
- `app_store_connect_api_key_base64` (optional, for deploy)
- `app_store_connect_key_id` (optional, for deploy)
- `app_store_connect_issuer_id` (optional, for deploy)

Example (Android build + Play Store deploy):

```yaml
jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/flutter-release.yml@production
    with:
      working_directory: "apps/mobile"
      build_android: true
      deploy_google_play: true
      fastlane_android_lane: "android_release"
    secrets:
      android_keystore_base64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
      android_keystore_password: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
      android_key_alias: ${{ secrets.ANDROID_KEY_ALIAS }}
      android_key_password: ${{ secrets.ANDROID_KEY_PASSWORD }}
      google_play_service_account_json: ${{ secrets.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON }}
```

## trivy-scan.yml

Workflow: `.github/workflows/trivy-scan.yml`

Purpose: Run Trivy filesystem scan with optional SARIF upload.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `scan_path` (string, default `"."`)
- `format` (string, default `sarif`)
- `output` (string, default `trivy-results.sarif`)
- `severity` (string, default `CRITICAL,HIGH`)
- `ignore_unfixed` (string, default `"true"`)
- `vuln_type` (string, default `os,library`)
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

## gitleaks-scan.yml

Workflow: `.github/workflows/gitleaks-scan.yml`

Purpose: Run Gitleaks and emit a report.

Note: When findings are detected, the workflow prints Leak-Lock links for help
removing leaked credentials.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `scan_path` (string, default `"."`)
- `report_format` (string, default `sarif`)
- `output` (string, default `results.sarif`)
- `config_path` (string, default `""`)
- `fail_on_findings` (boolean, default `false`)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `gitleaks-report`)

Note: `gitleaks-action` emits SARIF only; other `report_format` values are ignored, and `scan_path`/`config_path` are not honored (it auto-detects `.gitleaks.toml`).

Example:

```yaml
jobs:
  gitleaks:
    uses: nikolareljin/ci-helpers/.github/workflows/gitleaks-scan.yml@production
    with:
      scan_path: "."
      fail_on_findings: true
      upload_artifact: true
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
- `deb_fullname` (string, default `""`)
- `deb_email` (string, default `""`)
- `signing_key_id` (string, required, GPG key ID or fingerprint)
- `extra_packages` (string, default `""`)

Secrets:
- `gpg_private_key` (armored private key)
- `gpg_passphrase` (GPG key passphrase)
- `launchpad_ssh_private_key` (SSH key registered with Launchpad)

Note: The workflow disables shell xtrace (`set +x`) in secret-handling steps to avoid leaking credentials.

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
      launchpad_ssh_private_key: ${{ secrets.PPA_SSH_PRIVATE_KEY }}

## rpm-build.yml

Workflow: `.github/workflows/rpm-build.yml`

Purpose: Build RPM artifacts and upload them.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `prebuild_command` (string, default `""`)
- `spec_path` (string, default `""`, path to `.spec`)
- `artifact_dir` (string, default `"dist"`)
- `extra_packages` (string, default `""`)
- `artifact_name` (string, default `"rpm-packages"`)
- `artifact_glob` (string, default `"dist/*.rpm"`)

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

## homebrew-package.yml

Workflow: `.github/workflows/homebrew-package.yml`

Purpose: Build a Homebrew tarball, generate a formula, upload artifacts, and optionally publish to a tap repo.

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

Secrets:
- `tap_token` (GitHub token with write access to the tap repo)

Example:

```yaml
jobs:
  brew:
    uses: nikolareljin/ci-helpers/.github/workflows/homebrew-package.yml@production
    with:
      name: "isoforge"
      desc: "TUI tool for downloading and flashing ISO images to USB"
      homepage: "https://github.com/nikolareljin/burn-iso"
      deps: "dialog,jq,curl"
      entrypoint: "inc/isoforge.sh"
      man_path: "docs/man/isoforge.1"
      use_libexec: "true"
      env_var: "ISOFORGE_ROOT"
      release_repo: "nikolareljin/burn-iso"
      publish: ${{ vars.HOMEBREW_PUBLISH_ENABLED }}
      tap_repo: ${{ vars.HOMEBREW_TAP_REPO }}
      tap_branch: ${{ vars.HOMEBREW_TAP_BRANCH }}
    secrets:
      tap_token: ${{ secrets.HOMEBREW_TAP_TOKEN }}
```
```

## deb-build.yml

Workflow: `.github/workflows/deb-build.yml`

Purpose: Build Debian packages and upload artifacts.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `prebuild_command` (string, default `"make man"`)
- `build_command` (string, default `""`)
- `extra_packages` (string, default `""`)
- `artifact_name` (string, default `"deb-packages"`)
- `artifact_glob` (string, default `"../*.deb"`)

Example:

```yaml
jobs:
  deb:
    uses: nikolareljin/ci-helpers/.github/workflows/deb-build.yml@production
    with:
      working_directory: "."
      artifact_glob: "../*.deb"
```

## php-scan.yml

Workflow: `.github/workflows/php-scan.yml`

Purpose: Run PHP unit tests, framework linting, and a WP-CLI scan with demo content when detected.

Inputs (selected):
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `php_version` (string, default `8.2`)
- `composer_command` (string, default `composer install --no-interaction --prefer-dist`)
- `unit_command` (string, default `vendor/bin/phpunit`)
- `lint_wp_command` (string, default `vendor/bin/phpcs --standard=WordPress --extensions=php`, only runs when WordPress is detected)
- `lint_drupal_command` (string, default `vendor/bin/phpcs --standard=Drupal --extensions=php`, only runs when Drupal is detected)
- `lint_laravel_command` (string, default `vendor/bin/pint`)
- `wp_cli_scan` (boolean, default `true`, only runs when WordPress is detected)
- `wp_root` (string, default `wp-cli-site`)

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
- `python_version` (string, default `3.12`)
- `install_command` (string, default `if [ -f requirements.txt ]; then python -m pip install -r requirements.txt; elif [ -f pyproject.toml ]; then python -m pip install pyinstaller && python -m pip install .; fi`)
- `lint_command` (string, default `python -m pip install ruff && ruff check .`)
- `unit_command` (string, default `python -m pip install pytest && python -m pytest`)
- `django_command` (string, default `if [ -f manage.py ]; then python manage.py test; fi`, only runs when Django is detected)

Example:

```yaml
jobs:
  python_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/python-scan.yml@production
```

## go-scan.yml

Workflow: `.github/workflows/go-scan.yml`

Purpose: Run Go lint, tests, and gosec scanning.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `go_version` (string, default `1.22`)
- `lint_command` (string, default `test -z "$(gofmt -l .)" && go vet ./...`)
- `test_command` (string, default `go mod download && go test ./...`)
- `gosec_args` (string, default `./...`)

Example:

```yaml
jobs:
  go_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/go-scan.yml@production
```

## rust-scan.yml

Workflow: `.github/workflows/rust-scan.yml`

Purpose: Run Rust lint, tests, and cargo-audit.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `rust_toolchain` (string, default `stable`)
- `rust_components` (string, default `rustfmt, clippy`)
- `lint_command` (string, default `cargo fmt -- --check && cargo clippy -- -D warnings`)
- `test_command` (string, default `cargo fetch && cargo test`)
- `audit_command` (string, default `cargo audit`)

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
- `lint_command` (string, default `mvn -B -DskipTests checkstyle:check`)
- `test_command` (string, default `mvn -B test`)
- `dependency_check_command` (string, default `mvn -B org.owasp:dependency-check-maven:check`)

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
- `lint_command` (string, default `dotnet tool install -g dotnet-format && export PATH="$PATH:$HOME/.dotnet/tools" && dotnet-format --verify-no-changes`)
- `test_command` (string, default `dotnet restore && dotnet test`)
- `vuln_command` (string, default `dotnet list package --vulnerable --include-transitive`)

Example:

```yaml
jobs:
  csharp_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/csharp-scan.yml@production
```

## node-scan.yml

Workflow: `.github/workflows/node-scan.yml`

Purpose: Run Node.js lint/test/audit and optional build.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `node_version` (string, default `20`)
- `install_command` (string, default `npm ci`)
- `lint_command` (string, default `npm run lint`)
- `test_command` (string, default `npm test`)
- `audit_command` (string, default `npm audit --audit-level=high`)
- `build_command` (string, default `""`)

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
- `node_version` (string, default `20`)
- `install_command` (string, default `npm ci`)
- `lint_command` (string, default `npm run lint`)
- `test_command` (string, default `npm test -- --watchAll=false`)
- `audit_command` (string, default `npm audit --audit-level=high`)
- `build_command` (string, default `npm run build`)

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
- `node_version` (string, default `20`)
- `install_command` (string, default `npm ci`)
- `lint_command` (string, default `npm run lint`)
- `test_command` (string, default `npm test`)
- `audit_command` (string, default `npm audit --audit-level=high`)
- `build_command` (string, default `npm run build`)

Example:

```yaml
jobs:
  vue_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/vue-scan.yml@production
```

## docker-scan.yml

Workflow: `.github/workflows/docker-scan.yml`

Purpose: Build a Docker image and scan with Trivy and Snyk.

Note: Snyk requires a `SNYK_TOKEN` secret.

Inputs (selected):
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `image_name` (string, default `ci-image:latest`)
- `dockerfile` (string, default `Dockerfile`)
- `context` (string, default `"."`)
- `trivy_severity` (string, default `CRITICAL,HIGH`)
- `fail_on_findings` (boolean, default `true`)
- `run_snyk` (boolean, default `true`)

Example:

```yaml
jobs:
  docker_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/docker-scan.yml@production
    secrets:
      snyk_token: ${{ secrets.SNYK_TOKEN }}
```

## auto-tag-release.yml

Workflow: `.github/workflows/auto-tag-release.yml`

Purpose: Auto-tag releases when a `release/X.Y.Z` or `release/X.Y.Z-rcN` PR is merged into the default branch.

Notes:
- Detects the repo default branch; falls back to `main` if missing.
- Fails the workflow if the tag already exists (prevents merge from appearing successful).

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `fetch_depth` (number, default `0`)
- `default_branch` (string, default `""`, uses repo default)

Example:

```yaml
name: Auto Tag Release
on:
  push:
    branches: [ main, master ]

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@production
```

## release-tag-gate.yml

Workflow: `.github/workflows/release-tag-gate.yml`

Purpose: Block PRs if a `release/X.Y.Z` or `release/X.Y.Z-rcN` branch targets the default branch and the tag already exists.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `fetch_depth` (number, default `0`)
- `release_branch` (string, default `""`, uses PR head/ref)
- `base_branch` (string, default `""`, uses PR base)
- `default_branch` (string, default `""`, uses repo default)

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

Inputs (selected):
- `runner` (string, default `ubuntu-latest`)
- `working_directory` (string, default `"."`)
- `fetch_depth` (number, default `0`)
- `node_version`, `java_version`, `dotnet_version`, `python_version`, `go_version`, `php_version` (optional toolchain setup)
- `build_command` (string, default `""`)
- `artifact_paths` (string, default `""`, supports globs)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `release-artifacts`)
- `release_tag` (string, default `""`)
- `release_name` (string, default `""`)
- `release_notes` (string, default `""`)
- `generate_release_notes` (boolean, default `true`)
- `binary_links` (string, default `""`, `label|filename` per line)
- `binary_base_url` (string, default `""`)

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
      build_command: "npm ci && npm run build"
      artifact_paths: "dist/*"
      binary_links: |
        Linux|myapp-linux
        macOS|myapp-mac
```

## rust-release.yml

Workflow: `.github/workflows/rust-release.yml`

Purpose: Build multi-target Rust release binaries and publish a GitHub Release.

Inputs (selected):
- `bin_name` (string, required)
- `artifact_dir` (string, default `artifacts`)
- `rust_toolchain` (string, default `stable`)
- `install_deps` (boolean, default `true`)
- `apt_packages` (string, default `build-essential mingw-w64 musl-tools`)
- `build_windows`, `build_linux_gnu`, `build_linux_musl`, `build_macos` (booleans, default `true`)
- `linux_gnu_aliases` (string, default `""`, comma-delimited)
- `release_tag`, `release_name`, `release_notes` (string, optional)
- `generate_release_notes` (boolean, default `true`)
- `binary_links` (string, default `""`, `label|filename` per line)
- `binary_base_url` (string, default `""`)

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

Inputs (selected):
- `bin_name` (string, required)
- `main_path` (string, default `"."`)
- `artifact_dir` (string, default `artifacts`)
- `go_version` (string, default `1.22`)
- `build_targets` (string, default `linux/amd64,windows/amd64,darwin/amd64`)
- `ldflags` (string, default `""`)
- `release_tag`, `release_name`, `release_notes` (string, optional)
- `generate_release_notes` (boolean, default `true`)
- `binary_links` (string, default `""`, `label|filename` per line)
- `binary_base_url` (string, default `""`)

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

## wp-plugin-check.yml

Workflow: `.github/workflows/wp-plugin-check.yml`

Purpose: Run WordPress plugin-check via Docker, with optional PHPUnit/lint.

Note: Requires Docker on the runner and a compose file that mounts the plugin.

Inputs:
- `runner` (string, default `ubuntu-latest`)
- `compose_file` (string, default `test/docker-compose.yml`)
- `plugin_slug` (string, required)
- `plugin_src` (string, default `"."`)
- `plugin_src_env` (string, default `PLUGIN_SRC`)
- `out_dir` (string, default `test/tmp`)
- `php_version` (string, default `""`)
- `php_lint_command` (string, default `""`)
- `phpcs_warning_command` (string, default `""`)
- `phpunit_command` (string, default `""`)
- `fail_on_findings` (boolean, default `false`)
- `upload_artifact` (boolean, default `false`)
- `artifact_name` (string, default `plugin-check-results`)

Example:

```yaml
jobs:
  plugin-check:
    uses: nikolareljin/ci-helpers/.github/workflows/wp-plugin-check.yml@production
    with:
      plugin_slug: my-plugin
      plugin_src_env: MY_PLUGIN_SRC
      plugin_src: "."
      php_version: "8.2"
      phpunit_command: "vendor/bin/phpunit"
      phpcs_warning_command: "vendor/bin/phpcs -p -s --warning-severity=1 --error-severity=0 ."
      fail_on_findings: true
      upload_artifact: true
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
  node_version: "20"
  test_command: "yarn test"
```
