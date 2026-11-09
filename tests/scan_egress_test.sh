#!/usr/bin/env bash
# SCRIPT: scan_egress_test.sh
# DESCRIPTION: scripts/check_scan_egress.py passes on this tree, flags each
#              way a scan workflow could send code, a token or findings out
#              (third-party action, tag-only docker run, checkout keeping its
#              token, secrets: inherit, write permissions, security-events
#              without an upload), stays quiet on what is allowed, holds every
#              other workflow and action to the kept third-party list and
#              nothing else, and leaves the scan-only rules off them.
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

expect "toolchain exception without a commit pin" 1 "uses: 'shivammathur/setup-php@v2' is not canonical" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: shivammathur/setup-php@v2
YAML

expect "docker run by tag" 1 "docker: container run or create without an @sha256: image" <<'YAML'
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

expect "mixed-case checkout is refused" 1 "uses: 'Actions/Checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' is not canonical" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: Actions/Checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
YAML

expect "mixed-case SARIF uploader is refused" 1 "is not canonical" <<'YAML'
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

expect "indented docker run in if" 1 "docker: container run or create without an @sha256: image" <<'YAML'
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

expect "indented docker run in for" 1 "docker: container run or create without an @sha256: image" <<'YAML'
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

expect "command docker run" 1 "docker: container run or create without an @sha256: image" <<'YAML'
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

expect "env docker run" 1 "docker: container run or create without an @sha256: image" <<'YAML'
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

expect "docker run split by a continuation" 1 "docker: container run or create without an @sha256: image" <<'YAML'
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

expect "checkout as actions/checkout/" 1 "is not canonical" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout/@3d3c42e5aac5ba805825da76410c181273ba90b1
YAML

expect "checkout as actions/checkout/." 1 "is not canonical" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout/.@3d3c42e5aac5ba805825da76410c181273ba90b1
YAML

expect "uses: checkout via .." 1 "uses: 'actions/checkout/../checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout/../checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
YAML

expect "uses: tag pin" 1 "uses: 'actions/checkout@v4'" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML

expect "uses: local path out of the repo" 1 "local path './../other/.github/actions/x' has an empty" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: ./../other/.github/actions/x
YAML

expect "uses: other owner production" 1 "uses: 'evil/ci-helpers/.github/workflows/x.yml@production'" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: evil/ci-helpers/.github/workflows/x.yml@production
YAML

expect "docker behind env -u" 1 "docker: container run or create" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          env -u HOME docker run --rm alpine:3 true
YAML

expect "docker behind command -p" 1 "docker: container run or create" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          command -p docker run --rm alpine:3 true
YAML

expect "docker behind sudo -E" 1 "docker: container run or create" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          sudo -E docker run --rm alpine:3 true
YAML

expect "docker behind podman" 1 "docker: container run or create" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          podman run --rm alpine:3 true
YAML

expect "docker behind docker compose run" 1 "docker: container run or create" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          docker compose run app
YAML

expect "docker behind docker create" 1 "docker: container run or create" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          x=$(docker create alpine:3)
YAML

expect "docker behind docker container run" 1 "docker: container run or create" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: |
          docker container run alpine:3
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
          "$TRIVY_BIN" --cache-dir c --disable-telemetry --skip-version-check \
            fs --offline-scan .
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          persist-credentials: "false"
      - uses: swatinem/rust-cache@0000000000000000000000000000000000000000
      - uses: nikolareljin/ci-helpers/.github/workflows/x.yml@production
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

# Every other workflow and action: a third-party `uses:` outside the kept
# list is a finding, in a step, in a job that calls a reusable workflow, and
# in a composite action. A kept one is not, and the removed release action
# does not come back.
expect "new third-party action in a build workflow" 1 "uses: 'some/new-action@0000000000000000000000000000000000000000' is not actions/*" .github/workflows/build.yml <<'YAML'
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: some/new-action@0000000000000000000000000000000000000000
YAML
# GitHub runs .yaml workflows and action.yaml actions too.
expect "a third-party action in a .yaml workflow" 1 "uses: 'evil/thing@0123456789012345678901234567890123456789' is not" .github/workflows/release.yaml <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: evil/thing@0123456789012345678901234567890123456789
YAML
expect "a third-party action in an action.yaml" 1 "uses: 'evil/thing@0123456789012345678901234567890123456789' is not" .github/actions/x/action.yaml <<'YAML'
runs:
  using: composite
  steps:
    - uses: evil/thing@0123456789012345678901234567890123456789
YAML
expect "a .yaml scan workflow keeps the scan rules" 1 "secrets: inherit" .github/workflows/x-scan.yaml <<'YAML'
on: push
jobs:
  a:
    uses: ./.github/workflows/other.yml
    secrets: inherit
YAML
expect "the replaced release action in a release workflow" 1 "uses: 'softprops/action-gh-release@8a0cd651e5b2365bd640854a3fa5dfc70e4875f3' is not" .github/workflows/release.yml <<'YAML'
on: push
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: softprops/action-gh-release@8a0cd651e5b2365bd640854a3fa5dfc70e4875f3
YAML
expect "the replaced test reporter in a test workflow" 1 "uses: 'dorny/test-reporter@d1b5dff021aa968b288b02285a8bf47471c5928a' is not" .github/workflows/node.yml <<'YAML'
on: push
jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: dorny/test-reporter@d1b5dff021aa968b288b02285a8bf47471c5928a
YAML
expect "third-party reusable workflow as a job" 1 "jobs.call: uses: 'some/repo/.github/workflows/x.yml@0000000000000000000000000000000000000000' is not" .github/workflows/build.yml <<'YAML'
on: push
jobs:
  call:
    uses: some/repo/.github/workflows/x.yml@0000000000000000000000000000000000000000
YAML
expect "third-party action inside a composite action" 1 "uses: 'some/new-action@0000000000000000000000000000000000000000' is not" .github/actions/helper/action.yml <<'YAML'
name: helper
runs:
  using: composite
  steps:
    - uses: some/new-action@0000000000000000000000000000000000000000
YAML
expect "unpinned kept action in a build workflow" 1 "uses: 'subosito/flutter-action@v2' is not canonical" .github/workflows/build.yml <<'YAML'
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: subosito/flutter-action@v2
YAML
expect "kept actions in a build workflow stay quiet" 0 "" .github/workflows/build.yml <<'YAML'
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2
      - uses: shivammathur/setup-php@eb7c497e18156a6bbabfef1d3a82760b9eda3962
      - uses: ./.github/actions/local
      - uses: nikolareljin/ci-helpers/.github/actions/gitleaks-scan@0000000000000000000000000000000000000000
      - run: docker run --rm alpine:3 true
YAML
# The kept list is for the other workflows; a scan workflow still allows
# only the toolchain installers.
expect "kept action in a scan workflow" 1 "uses: 'subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2' is not" <<'YAML'
on: push
jobs:
  scan:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2
YAML
# The kept list in the script is exactly the set of third-party actions this
# tree runs: an entry nobody uses is a leftover, deleted with its action.
python3 - "$root" <<'PY' || fail=1
import glob, re, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import check_scan_egress as egress
used = set()
for path in glob.glob(sys.argv[1] + "/.github/**/*.yml", recursive=True):
    for ref in re.findall(r"^\s*(?:-\s*)?uses:\s*([A-Za-z0-9._/-]+)@", open(path).read(), re.M):
        parts = ref.split("/")
        if parts[0] not in ("actions", "github") and len(parts) >= 2:
            used.add("/".join(parts[:2]))
used -= {o + "/ci-helpers" for o in egress.LIBRARY_OWNERS}
stale = sorted(egress.KEPT_THIRD_PARTY - used)
missing = sorted(used - egress.KEPT_THIRD_PARTY - egress.TOOLCHAIN_EXCEPTIONS)
if stale:
    print("FAIL kept third-party actions no workflow uses any more:", ", ".join(stale))
if missing:
    print("FAIL third-party actions in use but not kept:", ", ".join(missing))
sys.exit(1 if stale or missing else 0)
PY

# In a fork, the library at the fork's owner is this library.
mkdir -p "$work/f/.github/workflows"
cat > "$work/f/.github/workflows/x-scan.yml" <<'YAML'
on: push
jobs:
  caller:
    permissions:
      contents: read
    uses: someowner/ci-helpers/.github/workflows/x.yml@0000000000000000000000000000000000000000
YAML
rc=0; GITHUB_REPOSITORY_OWNER=SomeOwner python3 "$check" --root "$work/f" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 0 ]; then echo "FAIL the fork's own ci-helpers was refused:"; cat "$work/out"; fail=1; fi

[ "$fail" = 0 ] && echo "ok: scan-egress check flags each class, holds every workflow to the kept list, passes what is allowed and this tree"
exit "$fail"
