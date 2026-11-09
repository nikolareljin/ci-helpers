#!/usr/bin/env bash
# SCRIPT: scan_egress_test.sh
# DESCRIPTION: scripts/check_scan_egress.py passes on this tree, flags each
#              way a scan workflow could send code, a token or findings out
#              (third-party action, tag-only docker run, checkout keeping its
#              token, secrets: inherit, write permissions, security-events
#              without an upload), stays quiet on what is allowed, and leaves
#              a non-scan workflow alone.
# USAGE: bash tests/scan_egress_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/check_scan_egress.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
# The fork owner comes from the environment; each case sets it or not.
unset GITHUB_REPOSITORY_OWNER

if ! python3 "$check" --root "$root" > "$work/out" 2>&1; then
  echo "FAIL this tree has findings:"; cat "$work/out"; fail=1
fi

# expect <name> <rc> <pattern-or-empty> [file] ; file body on stdin
expect() {
  local name="$1" want="$2" pattern="$3" file="${4:-.github/workflows/x-scan.yml}" rc=0
  rm -rf "${work:?}/t"; mkdir -p "$work/t/$(dirname "$file")"
  cat > "$work/t/$file"
  python3 "$check" --root "$work/t" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 0
  fi
  if [ -n "$pattern" ] && ! grep -qF -- "$pattern" "$work/out"; then
    echo "FAIL $name: no '$pattern' in output"; cat "$work/out"; fail=1
  fi
}

expect "third-party scanner action" 1 "uses: 'aquasecurity/trivy-action@38b337fff0a2f984d5be173c99e3f633438167ec' is not" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          persist-credentials: false
      - uses: aquasecurity/trivy-action@38b337fff0a2f984d5be173c99e3f633438167ec
YAML

expect "toolchain exception without a commit pin" 1 "toolchain exception 'shivammathur/setup-php' is not pinned to a commit" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: shivammathur/setup-php@v2
YAML

expect "docker run by tag" 1 "docker: \`docker run\` without an @sha256: image" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          if ! docker run --rm \
            -e TOKEN \
            snyk/snyk:docker test; then exit 1; fi
YAML

expect "checkout keeps its token" 1 "checkout: actions/checkout without persist-credentials: false" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          fetch-depth: 0
YAML

expect "mixed-case checkout keeps its token" 1 "checkout: actions/checkout without persist-credentials: false" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: Actions/Checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
YAML

expect "mixed-case SARIF upload counts as an upload" 0 "" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
      security-events: write
    runs-on: ubuntu-latest
    steps:
      - uses: Github/CodeQL-Action/upload-sarif@9b3254085494b55a0f7c4c2b3d2d52cc712ce370
YAML

expect "indented docker run in if" 1 "docker: \`docker run\` without an @sha256: image" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          if true; then
            docker run --rm alpine:3 true
          fi
YAML

expect "indented docker run in for" 1 "docker: \`docker run\` without an @sha256: image" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          for i in 1 2; do
            docker run --rm alpine:3 true
          done
YAML

expect "command docker run" 1 "docker: \`docker run\` without an @sha256: image" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          command docker run --rm alpine:3 true
YAML

expect "env docker run" 1 "docker: \`docker run\` without an @sha256: image" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          env X=1 docker run --rm alpine:3 true
YAML

expect "docker run split by a continuation" 1 "docker: \`docker run\` without an @sha256: image" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          docker \
            run --rm alpine:3 true
YAML

expect "checkout as actions/checkout/" 1 "checkout: actions/checkout without persist-credentials: false" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout/@3d3c42e5aac5ba805825da76410c181273ba90b1
YAML

expect "checkout as actions/checkout/." 1 "checkout: actions/checkout without persist-credentials: false" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout/.@3d3c42e5aac5ba805825da76410c181273ba90b1
YAML

expect "secrets: inherit" 1 "secrets: inherit hands every secret" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    uses: ./.github/workflows/other.yml
    secrets: inherit
YAML

expect "no permissions block" 1 "permissions: no \`permissions:\` block" <<'YAML'
on: push
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML

expect "contents: write" 1 "permissions: contents is 'write', not read" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: write
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML

expect "packages: write" 1 "permissions: packages: write is not a scan job's to have" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
      packages: write
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML

expect "security-events without an upload" 1 "security-events: write with no SARIF upload step" <<'YAML'
on: push
permissions:
  contents: read
  security-events: write
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML

expect "a scan action with a tag-only container" 1 "container action image 'docker://ghcr.io/x/scanner:latest' is not pinned" .github/actions/x-scan/action.yml <<'YAML'
name: x
runs:
  using: docker
  image: docker://ghcr.io/x/scanner:latest
YAML

expect "trivy reporting usage" 1 "telemetry: Trivy runs without --disable-telemetry" .github/workflows/build.yml <<'YAML'
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          "$TRIVY_BIN" --cache-dir "$CACHE_DIR" --skip-version-check image \
            --offline-scan "$IMAGE"
YAML

expect "trivy without the version check flag" 1 "telemetry: Trivy runs without --skip-version-check" .github/actions/x-scan/action.yml <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        if trivy --disable-telemetry fs .; then echo clean; fi
YAML

expect "ci-helpers under another owner" 1 "uses: 'evil/ci-helpers/.github/workflows/x.yml@main' is not" <<'YAML'
on: push
jobs:
  caller:
    permissions:
      contents: read
    uses: evil/ci-helpers/.github/workflows/x.yml@main
YAML

expect "what is allowed stays quiet" 0 "" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
      security-events: write
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          persist-credentials: false
      - uses: shivammathur/setup-php@eb7c497e18156a6bbabfef1d3a82760b9eda3962
      - uses: ./.github/actions/trivy-scan
      - uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@0000000000000000000000000000000000000000
      - run: |
          # docker run snyk/snyk:docker was the old form
          docker run --rm ghcr.io/zizmorcore/zizmor@sha256:f09cee55087d54e7a162fc255ffe82ef942f68e683f967c8a6471ffe35e7ec64 --offline .
          echo "never docker run an image by tag"  # docker run x:latest
          "$TRIVY_BIN" --cache-dir c --disable-telemetry --skip-version-check \
            fs --offline-scan .
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          persist-credentials: "false"
      - uses: Swatinem/rust-cache@0000000000000000000000000000000000000000
      - uses: NikolaReljin/ci-helpers/.github/actions/trivy-scan@0000000000000000000000000000000000000000
      - uses: github/codeql-action/upload-sarif@9b3254085494b55a0f7c4c2b3d2d52cc712ce370
  report:
    needs: scan
    permissions:
      issues: write
    runs-on: ubuntu-latest
    steps:
      - run: true
  caller:
    uses: ./.github/workflows/other.yml
YAML

expect "a workflow that is not a scan is not read" 0 "" .github/workflows/x-scan.yml <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
cat > "$work/t/.github/workflows/deploy.yml" <<'YAML'
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: docker/login-action@8aa5831fb8d48d8f76594c7ddde61ae58019f550
YAML
rc=0; python3 "$check" --root "$work/t" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 0 ]; then echo "FAIL deploy.yml was read as a scan workflow:"; cat "$work/out"; fail=1; fi

# In a fork, the library at the fork's owner is this library.
mkdir -p "$work/f/.github/workflows"
cat > "$work/f/.github/workflows/x-scan.yml" <<'YAML'
on: push
jobs:
  caller:
    permissions:
      contents: read
    uses: someowner/ci-helpers/.github/workflows/x.yml@main
YAML
rc=0; GITHUB_REPOSITORY_OWNER=SomeOwner python3 "$check" --root "$work/f" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 0 ]; then echo "FAIL the fork's own ci-helpers was refused:"; cat "$work/out"; fail=1; fi

[ "$fail" = 0 ] && echo "ok: scan-egress check flags each class, passes what is allowed and this tree"
exit "$fail"
