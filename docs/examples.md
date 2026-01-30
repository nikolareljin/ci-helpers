# Examples

This file provides extended examples that combine multiple inputs and common
real-world patterns.

Related docs:
- [Reusable workflows](workflows.md)
- [Presets](presets.md)
- [Composite actions](actions.md)

## Monorepo (subdirectory)

```yaml
jobs:
  web:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@production
    with:
      working_directory: "apps/web"
      node_version: "20"
      lint_command: "yarn lint"
      test_command: "yarn test"
      build_command: "yarn build"
```

## Playwright with start-server-and-test (custom port)

```yaml
jobs:
  e2e:
    uses: nikolareljin/ci-helpers/.github/workflows/playwright.yml@production
    with:
      node_version: "20"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:4173 'npx playwright test'"
```

## Cypress with start-server-and-test (custom script)

```yaml
jobs:
  e2e:
    uses: nikolareljin/ci-helpers/.github/workflows/cypress.yml@production
    with:
      node_version: "20"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev:ci' http://localhost:3000 'npx cypress run'"
```

## Docker build + E2E

E2E always runs after Docker when both are set.

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@production
    with:
      node_version: "20"
      docker_command: "docker build -t myapp:ci ."
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
```

## PR gate with release tag check

```yaml
jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/pr-gate.yml@production
    with:
      check_release_tag: true
      release_branch: ${{ github.head_ref }}
      node_version: "20"
      test_command: "yarn test"
```

## Deploy with runtime setup

```yaml
jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/deploy.yml@production
    with:
      node_version: "20"
      deploy_command: "./scripts/deploy.sh"
```

## Flutter Android release (build + Play Store)

```yaml
jobs:
  flutter_release:
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

## RPM build

```yaml
jobs:
  rpm:
    uses: nikolareljin/ci-helpers/.github/workflows/rpm-build.yml@production
    with:
      prebuild_command: "./tools/gen-man.sh"
      spec_path: "packaging/myapp.spec"
      artifact_glob: "dist/*.rpm"
```

## Homebrew build + publish

```yaml
jobs:
  brew:
    uses: nikolareljin/ci-helpers/.github/workflows/homebrew-package.yml@production
    with:
      name: "myapp"
      desc: "My CLI tool"
      homepage: "https://github.com/owner/myapp"
      deps: "curl,jq"
      entrypoint: "bin/myapp"
      man_path: "docs/man/myapp.1"
      use_libexec: "true"
      env_var: "MYAPP_ROOT"
      release_repo: "owner/myapp"
      publish: ${{ vars.HOMEBREW_PUBLISH_ENABLED }}
      tap_repo: ${{ vars.HOMEBREW_TAP_REPO }}
      tap_branch: ${{ vars.HOMEBREW_TAP_BRANCH }}
    secrets:
      tap_token: ${{ secrets.HOMEBREW_TAP_TOKEN }}
```

## Trivy scan + SARIF upload

```yaml
jobs:
  trivy:
    uses: nikolareljin/ci-helpers/.github/workflows/trivy-scan.yml@production
    with:
      scan_path: "."
      fail_on_findings: true
      upload_artifact: true
```

## Gitleaks scan

```yaml
jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run gitleaks scan
        uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@production
        with:
          scan_path: "."
          fail_on_findings: "true"
          upload_artifact: "true"
```

## PHP scan (unit + framework lint + WP-CLI)

```yaml
jobs:
  php_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/php-scan.yml@production
    with:
      php_version: "8.2"
```

## Docker scan (Trivy + Snyk)

```yaml
jobs:
  docker_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/docker-scan.yml@production
    with:
      image_name: "app:ci"
    secrets:
      snyk_token: ${{ secrets.SNYK_TOKEN }}
```

## Composite actions (Gitleaks + Trivy)

```yaml
jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Gitleaks scan
        uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@production
        with:
          scan_path: "."
          fail_on_findings: "true"
          upload_artifact: "true"
      - name: Trivy scan
        uses: nikolareljin/ci-helpers/.github/actions/trivy-scan@production
        with:
          scan_path: "."
          format: "sarif"
          output: "trivy-results.sarif"
          fail_on_findings: "true"
          upload_sarif: "true"
```

## Release tag guard (PR)

```yaml
jobs:
  release_guard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - name: Guard release tag
        id: release_guard
        uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@production
        with:
          release_branch: ${{ github.head_ref }}
          fetch_tags: true
      - name: Use version
        run: echo "Release version: ${{ steps.release_guard.outputs.version }}"
```

## Release tag guard (release)

```yaml
jobs:
  release_guard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - name: Guard release tag
        id: release_guard
        uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@production
        with:
          release_branch: ${{ github.ref_name }}
          fetch_tags: true
      - name: Use version
        run: echo "Release version: ${{ steps.release_guard.outputs.version }}"
```

## Auto-tag release

```yaml
name: Auto Tag Release
on:
  push:
    branches: [ main, master ]

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@production
```

## WordPress plugin check + standalone PHPUnit

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

## PPA publish

```yaml
name: PPA
on:
  push:
    branches: [ main ]

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
```

## Debian package build

```yaml
name: Debian Build
on:
  push:
    branches: [ main ]

jobs:
  deb:
    uses: nikolareljin/ci-helpers/.github/workflows/deb-build.yml@production
    with:
      working_directory: "."
      artifact_glob: "../*.deb"
```
