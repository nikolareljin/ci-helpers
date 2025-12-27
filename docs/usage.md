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
        uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@0.1.2
        with:
          scan_path: "."
          fail_on_findings: "true"
          upload_artifact: "true"
```

PHP scan (unit + framework lint + WP-CLI):

```yaml
name: PHP Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  php_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/php-scan.yml@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/python-scan.yml@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/go-scan.yml@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/rust-scan.yml@0.1.2
```

Java scan (tests + dependency check):

```yaml
name: Java Scan
on:
  pull_request:
    branches: [ main, master ]

jobs:
  java_scan:
    uses: nikolareljin/ci-helpers/.github/workflows/java-scan.yml@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/csharp-scan.yml@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/node-scan.yml@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/react-scan.yml@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/vue-scan.yml@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/docker-scan.yml@0.1.2
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
        uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@0.1.2
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
        uses: nikolareljin/ci-helpers/.github/actions/trivy-scan@0.1.2
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
        uses: nikolareljin/ci-helpers/.github/actions/wp-plugin-check@0.1.2
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
        uses: nikolareljin/ci-helpers/.github/actions/semver-compare@0.1.2
        with:
          version_a: "1.2.3"
          version_b: "1.4.0"
      - name: Use result
        run: echo "Result: ${{ steps.semver.outputs.result }}"
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
        uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@0.1.2
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
        uses: nikolareljin/ci-helpers/.github/actions/check-release-tag@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/release-tag-gate.yml@0.1.2
```

Auto tag release (reusable workflow):

```yaml
name: Auto Tag Release
on:
  push:
    branches: [ main, master ]

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@0.1.2
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
    uses: nikolareljin/ci-helpers/.github/workflows/release-tag-gate.yml@0.1.2
```

```yaml
name: Auto Tag Release
on:
  push:
    branches: [ main, master ]

jobs:
  tag:
    uses: nikolareljin/ci-helpers/.github/workflows/auto-tag-release.yml@0.1.2
```
