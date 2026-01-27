# Usage Guide

This guide shows how to consume reusable workflows and composite actions from
another repository.

## Reusable workflows

Create a workflow in your repo, then call the reusable workflow via `uses`.

Gitleaks on PRs:

```yaml
name: Secrets Scan
on:
  pull_request:
    branches: [ main, master ]

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

PHP scan (unit + framework lint + WP-CLI when detected):

```yaml
name: PHP Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  php_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/php-scan.yml@production
    with:
      php_version: "8.2"
```

Python scan (unit + Django when detected):

```yaml
name: Python Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  python_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/python-scan.yml@production
    with:
      python_version: "3.12"
```

Go scan (tests + gosec):

```yaml
name: Go Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  go_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/go-scan.yml@production
    with:
      go_version: "1.22"
```

Rust scan (tests + cargo-audit):

```yaml
name: Rust Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  rust_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/rust-scan.yml@production
```

Java scan (tests + dependency check):

```yaml
name: Java Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  java_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/java-scan.yml@production
    with:
      java_version: "17"
```

C# scan (tests + vulnerable packages):

```yaml
name: C# Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  csharp_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/csharp-scan.yml@production
    with:
      dotnet_version: "8.0.x"
```

Node.js scan (lint/test/audit):

```yaml
name: Node Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  node_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/node-scan.yml@production
    with:
      node_version: "20"
```

React scan (lint/test/build/audit):

```yaml
name: React Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  react_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/react-scan.yml@production
    with:
      node_version: "20"
```

Vue scan (lint/test/build/audit):

```yaml
name: Vue Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  vue_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/vue-scan.yml@production
    with:
      node_version: "20"
```

Docker scan (Trivy + Snyk):

```yaml
name: Docker Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  docker_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/docker-scan.yml@production
    with:
      image_name: "app:ci"
    secrets:
      snyk_token: ${{ secrets.SNYK_TOKEN }}
```

## Composite actions

Composite actions run inside a normal job. Always include `actions/checkout`.

Gitleaks composite action:

```yaml
name: Secrets Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Gitleaks scan
        uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@production
        with:
          scan_path: "."
          fail_on_findings: "true"
          upload_artifact: "true"
```

Trivy composite action:

```yaml
name: Trivy Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  trivy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Trivy scan
        uses: nikolareljin/ci-helpers/.github/actions/trivy-scan@production
        with:
          scan_path: "."
          format: "sarif"
          output: "trivy-results.sarif"
          fail_on_findings: "true"
          upload_sarif: "true"
```

WordPress plugin-check composite action:

```yaml
name: WP Plugin Check
on:
  pull_request:
    branches: [ main, master ]

jobs:
  plugin_check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Plugin check
        uses: nikolareljin/ci-helpers/.github/actions/wp-plugin-check@production
        with:
          plugin_slug: my-plugin
          plugin_src_env: MY_PLUGIN_SRC
          plugin_src: "."
          php_version: "8.2"
          phpunit_command: "vendor/bin/phpunit"
          phpcs_warning_command: "vendor/bin/phpcs -p -s --warning-severity=1 --error-severity=0 ."
          fail_on_findings: "true"
```

Semver compare:

```yaml
name: Compare Versions
on:
  pull_request:
    branches: [ main, master ]

jobs:
  semver:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Compare versions
        id: semver
        uses: nikolareljin/ci-helpers/.github/actions/semver-compare@production
        with:
          version_a: "1.2.3"
          version_b: "1.4.0"
      - name: Use result
        run: echo "Result: ${{ steps.semver.outputs.result }}"
```

Release notes generator:

```yaml
name: Release Notes
on:
  workflow_dispatch:

jobs:
  notes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Generate release notes
        id: notes
        uses: nikolareljin/ci-helpers/.github/actions/release-notes@production
        with:
          binary_links: |
            Linux|myapp-linux
            macOS|myapp-mac
      - name: Use notes
        run: echo "${{ steps.notes.outputs.notes }}"
```

Release tag guard (PR):

```yaml
name: Release Tag Guard (PR)
on:
  pull_request:
    branches: [ main, master ]

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

Release tag guard (release):

```yaml
name: Release Tag Guard (Release)
on:
  release:
    types: [ created, published ]

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

Release tag gate (reusable workflow):

```yaml
name: Release Tag Gate
on:
  pull_request:

jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/release-tag-gate.yml@production
```

Auto tag release (reusable workflow):

```yaml
name: Auto Tag Release
on:
  push:
    branches: [ main, master ]

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@production
```

## Install specific versions from Git tags

When you publish tagged releases, you can install a specific version directly:

Go:

```bash
GOBIN="$HOME/.local/bin" go install github.com/OWNER/REPO@v1.2.3
```

Rust:

```bash
cargo install --git https://github.com/OWNER/REPO --tag v1.2.3 --bin your-binary
```

Python:

```bash
python -m pip install "git+https://github.com/OWNER/REPO@v1.2.3"
```

Java (build from tag):

```bash
git clone --branch v1.2.3 https://github.com/OWNER/REPO.git
cd REPO
./mvnw -DskipTests package
```

## Production branch (optional)

This repo includes a repo-local workflow that moves the `production` branch to
the latest non-rc tag. It is not a reusable workflow; copy it into other repos
only if you want the same behavior.

```yaml
name: Update Production Branch
on:
  push:
    tags:
      - "*.*.*"
      - "v*.*.*"

jobs:
  production:
    if: ${{ !contains(github.ref_name, 'rc') && !contains(github.ref_name, 'RC') }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - name: Update production
        run: ./scripts/create_production.sh -t "${GITHUB_REF_NAME}" --fetch-tags
```

Manual override (point production at an older tag):

```bash
./scripts/create_production.sh -t 1.2.2
```

Release build (generic):

```yaml
name: Release Build
on:
  push:
    tags: [ "v*.*.*" ]

jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/release-build.yml@production
    with:
      build_command: "go build -o dist/myapp ./cmd/myapp"
      artifact_paths: "dist/*"
      binary_links: |
        Linux|myapp-linux
        macOS|myapp-mac
```

PPA publish:

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

Required secrets for PPA publish:
- `PPA_GPG_PRIVATE_KEY`: armored private key used to sign the source package.
- `PPA_GPG_PASSPHRASE`: passphrase for the signing key.
- `PPA_GPG_KEY_ID`: key ID or fingerprint (passed as an input).
- `PPA_SSH_PRIVATE_KEY`: SSH key registered with Launchpad for uploads.
Optional inputs:
- `series`: distro codename override for `debian/changelog` (uses `dch`).

Debian package build:

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

RPM package build:

```yaml
name: RPM Build
on:
  push:
    branches: [ main ]

jobs:
  rpm:
    uses: nikolareljin/ci-helpers/.github/workflows/rpm-build.yml@production
    with:
      working_directory: "."
      prebuild_command: "./tools/gen-man.sh"
      spec_path: "packaging/myapp.spec"
      artifact_glob: "dist/*.rpm"
```

Arch package build:

```yaml
name: Arch Build
on:
  push:
    branches: [ main ]

jobs:
  arch:
    uses: nikolareljin/ci-helpers/.github/workflows/arch-build.yml@production
    with:
      working_directory: "."
```

Homebrew package build + publish:

```yaml
name: Homebrew
on:
  push:
    branches: [ main ]

jobs:
  brew:
    uses: nikolareljin/ci-helpers/.github/workflows/homebrew-package.yml@production
    with:
      working_directory: "."
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

Homebrew tap update:

```yaml
name: Brew Tap
on:
  push:
    tags: [ "v*.*.*" ]

jobs:
  brew:
    uses: nikolareljin/ci-helpers/.github/workflows/brew-tap.yml@production
    with:
      tap_repo: "your-org/homebrew-tap"
      formula_path: "Formula/myapp.rb"
    secrets:
      tap_token: ${{ secrets.BREW_TAP_TOKEN }}
```

Unified packaging release:

```yaml
name: Packaging Release
on:
  push:
    tags: [ "v*.*.*" ]

jobs:
  packaging:
    uses: nikolareljin/ci-helpers/.github/workflows/packaging-release.yml@production
    with:
      upload_ppa: true
      ppa_target: "ppa:your-launchpad-id/myapp"
      ppa_signing_key_id: ${{ secrets.PPA_GPG_KEY_ID }}
      ppa_deb_fullname: "Your Name"
      ppa_deb_email: "you@example.com"
      update_brew_tap: true
      brew_tap_repo: "your-org/homebrew-tap"
      brew_formula_path: "Formula/myapp.rb"
    secrets:
      ppa_gpg_private_key: ${{ secrets.PPA_GPG_PRIVATE_KEY }}
      ppa_gpg_passphrase: ${{ secrets.PPA_GPG_PASSPHRASE }}
      ppa_launchpad_ssh_private_key: ${{ secrets.PPA_SSH_PRIVATE_KEY }}
      brew_tap_token: ${{ secrets.BREW_TAP_TOKEN }}
```

Rust release build:

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

Go release build:

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

Java release build (Maven example):

```yaml
name: Java Release
on:
  push:
    tags: [ "v*.*.*" ]

jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/release-build.yml@production
    with:
      java_version: "17"
      build_command: "mvn -B package"
      artifact_paths: "target/*.jar"
```

Release tagging in external repos (recommended setup):

1) Add the PR gate to block merges when the tag already exists.
2) Require the gate in branch protection for your default branch.
3) Add the auto-tag workflow on the default branch; it fails if the tag already exists.

Minimal setup:

```yaml
name: Release Tag Gate
on:
  pull_request:

jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/release-tag-gate.yml@production
```

```yaml
name: Auto Tag Release
on:
  push:
    branches: [ main, master ]

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@production
```
