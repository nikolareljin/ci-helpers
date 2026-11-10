#!/usr/bin/env bash
# SCRIPT: check_cache_trust_test.sh
# DESCRIPTION: scripts/check_cache_trust.py passes on this tree, and fails on
#              each way a cache could put unread content into a release: any
#              cache restored into a job that reads a secret, holds a write
#              token, is needed by such a job, is called by one through a
#              publish chain or is in a workflow named deploy, release,
#              publish, sign or submit (cargo, gem, Library, package store,
#              a verified toolchain archive, BuildKit type=gha); a setup-*
#              step there without its action's off value written, setup-go's
#              and setup-node's defaults being on; a post-job actions/cache
#              save anywhere; an actions/cache/save with no restore two steps
#              before it, not right after a run step, or after a caller step;
#              a save in a trusted job. It stays quiet on restore, fetch,
#              save in a plain job, on setup-* caches in a plain job and on
#              the off values in a trusted one.
# USAGE: bash tests/check_cache_trust_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/check_cache_trust.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

if ! python3 "$check" --root "$root" > "$work/out" 2>&1; then
  echo "FAIL this tree has findings:"; cat "$work/out"; fail=1
fi

# expect <name> <rc> <pattern-or-empty> [file] [keep] ; file body on stdin.
# `keep` leaves the files of the previous case in place, for a two-file case.
expect() {
  local name="$1" want="$2" pattern="$3" file="${4:-.github/workflows/x.yml}" keep="${5:-}" rc=0
  [[ -n "$keep" ]] || rm -rf "${work:?}/t"
  mkdir -p "$work/t/$(dirname "$file")"
  cat > "$work/t/$file"
  python3 "$check" --root "$work/t" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 0
  fi
  if [ -n "$pattern" ] && ! grep -qF -- "$pattern" "$work/out"; then
    echo "FAIL $name: no '$pattern' in output"; cat "$work/out"; fail=1
  fi
}

pin=55cc8345863c7cc4c66a329aec7e433d2d1c52a9

# --- what main shipped before the gate -------------------------------------

expect "cargo cache in a job with signing secrets" 1 "restores and saves '~/.cargo/registry/index/ target/' in a job that reads secrets.APPLE_CERTIFICATE" <<YAML
on: push
jobs:
  build-macos:
    permissions:
      contents: read
    runs-on: macos-latest
    steps:
      - uses: actions/cache@$pin
        with:
          path: |
            ~/.cargo/registry/index/
            target/
          key: rust-x
      - run: cargo build --release
        env:
          APPLE_CERTIFICATE: \${{ secrets.APPLE_CERTIFICATE }}
YAML

expect "gem cache in a job with store secrets" 1 "restores and saves 'vendor/bundle' in a job that reads secrets.GOOGLE_PLAY_JSON" <<YAML
on: push
jobs:
  release:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache@$pin
        with:
          path: vendor/bundle
          key: gems-x
      - run: bundle exec fastlane deploy
        env:
          JSON: \${{ secrets.GOOGLE_PLAY_JSON }}
YAML

expect "setup-node cache in a deploy job" 1 "actions/setup-node with cache: 'pnpm' restores a dependency cache into a job that reads secrets.CLOUDFLARE_API_TOKEN" <<'YAML'
on: push
jobs:
  deploy:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1
        with:
          node-version: '24'
          cache: pnpm
      - run: pnpm run deploy
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
YAML

expect "setup-* cache as an expression in a trusted job" 1 "restores a dependency cache into a job that holds contents: write" <<'YAML'
on: push
jobs:
  release:
    permissions:
      contents: write
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0
        with:
          cache: ${{ inputs.requirements_file != '' && 'pip' || '' }}
YAML

expect "BuildKit cache from the Actions cache in a push job" 1 "a BuildKit cache from the Actions cache in a job that reads secrets.registry_token; holds packages: write" <<'YAML'
on: push
jobs:
  build-push:
    permissions:
      contents: read
      packages: write
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/docker_build.sh
        env:
          CACHE_FROM: type=gha
          CACHE_TO: type=gha,mode=max
          REGISTRY_PASSWORD: ${{ secrets.registry_token }}
YAML

expect "Library cache in a job with licence secrets" 1 "restores and saves 'Library' in a job that reads secrets.UNITY_LICENSE" <<YAML
on: push
jobs:
  test:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache@$pin
        with:
          path: Library
          key: unity-x
      - run: unity-test-runner
        env:
          UNITY_LICENSE: \${{ secrets.UNITY_LICENSE }}
YAML

expect "post-job actions/cache in a plain job" 1 "actions/cache saves '~/.cargo/registry/index/ target/' when the job ends, after the caller's code ran under it" <<YAML
on: push
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache@$pin
        with:
          path: |
            ~/.cargo/registry/index/
            target/
          key: rust-x
      - run: cargo test
YAML

# --- trust by write permissions, needs and calls ----------------------------

expect "restore into a job trusted by workflow-level write" 1 "restores 'target/' into a job that holds contents: write" <<YAML
on: push
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: cargo build --release
YAML

expect "job-level permissions override the workflow's" 0 "" <<YAML
on: push
permissions:
  contents: write
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: cargo fetch
      - uses: actions/cache/save@$pin
        with:
          path: target/
          key: rust-x
YAML

expect "write-all" 1 "restores 'target/' into a job that permissions: write-all" <<YAML
on: push
jobs:
  release:
    permissions: write-all
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
YAML

expect "a build job the release job needs" 1 "restores 'target/' into a job that is needed by trusted job release" <<YAML
on: push
jobs:
  build-linux:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: cargo build --release
  release:
    needs: [build-linux]
    permissions:
      contents: write
    runs-on: ubuntu-latest
    steps:
      - run: gh release upload
YAML

expect "GITHUB_TOKEN alone is not a secret, read is not write" 0 "" <<YAML
on: push
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: cargo fetch
        env:
          GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}
      - uses: actions/cache/save@$pin
        with:
          path: target/
          key: rust-x
YAML

# A build workflow called by the job a Pages deploy needs: the deploy
# publishes what the called workflow built.
expect "the called build workflow (first file)" 0 "" .github/workflows/pb.yml <<'YAML'
on:
  workflow_call:
jobs:
  build:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0
        with:
          cache: pip
      - run: mkdocs build
YAML
expect "a build workflow called by the job a deploy needs" 1 "pb.yml: jobs.build.steps[0] 'actions/setup-python': actions/setup-python with cache: 'pip' restores a dependency cache into a job that is called by trusted job .github/workflows/pages.yml: jobs.build" .github/workflows/pages.yml keep <<'YAML'
on: push
jobs:
  build:
    uses: ./.github/workflows/pb.yml
    permissions:
      contents: read
  deploy:
    needs: build
    permissions:
      pages: write
      id-token: write
    runs-on: ubuntu-latest
    steps:
      - run: echo deploy
YAML

# A caller that grants a write scope the called workflow never asks for
# does not make the called jobs trusted: that file declares what it holds.
expect "the called CI workflow (first file)" 0 "" .github/workflows/pnpm.yml <<'YAML'
on:
  workflow_call:
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1
        with:
          cache: pnpm
      - run: pnpm test
YAML
expect "a caller trusted by its own permissions only passes nothing on" 0 "" .github/workflows/self-test.yml keep <<'YAML'
on: push
jobs:
  pnpm-defaults-can-pass:
    uses: ./.github/workflows/pnpm.yml
    permissions:
      contents: read
      checks: write
YAML

expect "secrets read by name through an expression" 1 "restores 'target/' into a job that reads secrets[" <<YAML
on: push
jobs:
  release:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: echo "\$TOKEN"
        env:
          TOKEN: \${{ secrets[inputs.token_name] }}
YAML

# Every form of a secrets-context read, wherever the expression sits.
secret_form() {   # secret_form <name> <pattern> <yaml fragment under steps[0]'s env>
  expect "$1" 1 "$2" <<YAML
on:
  workflow_call:
    inputs:
      name:
        type: string
jobs:
  release:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: cargo build
        env:
          X: $3
YAML
}
secret_form "secrets['X']"              "reads secrets['"                 "\${{ secrets['STORE_KEY'] }}"
secret_form "secrets[inputs.name]"       "reads secrets["                  "\${{ secrets[inputs.name] }}"
secret_form "toJSON(secrets)"            "reads secrets"                   "\${{ toJSON(secrets) }}"
secret_form "contains(secrets.X, ...)"   "reads secrets.STORE_KEY"         "\${{ contains(secrets.STORE_KEY, 'a') }}"
secret_form "format(..., secrets.X)"     "reads secrets.STORE_KEY"         "\${{ format('{0}', secrets.STORE_KEY) }}"
secret_form "secrets . X with spaces"    "reads secrets . STORE_KEY"       "\${{ secrets . STORE_KEY }}"
secret_form "SECRETS.X in upper case"    "reads SECRETS.STORE_KEY"         "\${{ SECRETS.STORE_KEY }}"
secret_form "secrets.GITHUB_TOKEN['x']"  "reads secrets.GITHUB_TOKEN["     "\${{ secrets.GITHUB_TOKEN['x'] }}"
secret_form "a secret beside the token"  "reads secrets.OTHER"             "\${{ secrets.GITHUB_TOKEN || secrets.OTHER }}"

expect "a secret in a job-level env" 1 "into a job that reads secrets.STORE_KEY" <<YAML
on: push
jobs:
  release:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    env:
      STORE_KEY: \${{ secrets.STORE_KEY }}
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
YAML

expect "a secret in a step if without braces" 1 "into a job that reads secrets.STORE_KEY" <<YAML
on: push
jobs:
  release:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - if: secrets.STORE_KEY != ''
        run: echo signed
YAML

expect "a secret in the job-level if" 1 "into a job that reads secrets.STORE_KEY" <<YAML
on: push
jobs:
  release:
    if: \${{ secrets.STORE_KEY != '' }}
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
YAML

expect "the word secrets in run prose is not a read" 0 "" <<YAML
on: push
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: echo "no secrets. Error if any."
YAML

expect "secrets.GITHUB_TOKEN in any case is not a secret of the repository" 0 "" <<YAML
on: push
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: gh api
        env:
          A: \${{ SECRETS.github_token }}
          B: \${{ secrets . GITHUB_TOKEN }}
YAML

# A reusable call that passes secrets is trusted, and what it needs is too.
expect "a reusable call passing a secrets mapping trusts what it needs" 1 "restores 'target/' into a job that is needed by trusted job publish" <<YAML
on: push
jobs:
  build:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: cargo build
  publish:
    needs: build
    uses: ./.github/workflows/other.yml
    secrets:
      store_key: \${{ secrets.STORE_KEY }}
YAML

expect "secrets: inherit on a reusable call trusts what it needs" 1 "restores 'target/' into a job that is needed by trusted job publish" <<YAML
on: push
jobs:
  build:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
      - run: cargo build
  publish:
    needs: build
    uses: ./.github/workflows/other.yml
    secrets: inherit
YAML

expect "id-token: write" 1 "restores 'target/' into a job that holds id-token: write" <<YAML
on: push
jobs:
  deploy-pages:
    permissions:
      contents: read
      id-token: write
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
YAML

expect "workflow-level write-all with no job permissions" 1 "restores 'target/' into a job that permissions: write-all" <<YAML
on: push
permissions: write-all
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
YAML

expect "a word that holds a shipping token is not one" 0 "" .github/workflows/design-check.yml <<'YAML'
on: push
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e
        with:
          go-version: '1.25'
YAML

# --- save placement ---------------------------------------------------------

expect "a save after a caller command passed through env" 1 "actions/cache/save after steps[2] 'Frontend install', which runs the caller's inputs.<name>command" <<YAML
on:
  workflow_call:
    inputs:
      frontend_install_command:
        type: string
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: ~/.cargo/registry/index/
          key: rust-x
      - run: cargo fetch
      - name: Frontend install
        env:
          INSTALL_CMD: \${{ inputs.frontend_install_command }}
        run: bash -c "\$INSTALL_CMD"
      - uses: actions/cache/save@$pin
        with:
          path: ~/.cargo/registry/index/
          key: rust-x
YAML

expect "a save after the caller's step" 1 "actions/cache/save after steps[2] 'Install', which runs the caller's inputs.<name>command" <<YAML
on:
  workflow_call:
    inputs:
      install_command:
        type: string
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: ~/.pnpm-store
          key: pnpm-x
      - run: cargo fetch
      - name: Install
        run: \${{ inputs.install_command }}
      - uses: actions/cache/save@$pin
        with:
          path: ~/.pnpm-store
          key: pnpm-x
YAML

expect "a save with no restore two steps before it" 1 "actions/cache/save without actions/cache/restore of the same path and key two steps before it" <<YAML
on: push
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: cargo fetch
      - uses: actions/cache/save@$pin
        with:
          path: ~/.cargo/registry/index/
          key: rust-x
YAML

expect "a save whose restore names another key" 1 "without actions/cache/restore of the same path and key" <<YAML
on: push
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: ~/.cargo/registry/index/
          key: rust-x
      - run: cargo fetch
      - uses: actions/cache/save@$pin
        with:
          path: ~/.cargo/registry/index/
          key: rust-y
YAML

expect "a save right after a uses step, not the fetch" 1 "the step before actions/cache/save is not a run step" <<YAML
on: push
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: ~/.cargo/registry/index/
          key: rust-x
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1
      - uses: actions/cache/save@$pin
        with:
          path: ~/.cargo/registry/index/
          key: rust-x
YAML

expect "a save in a trusted job, verified archive or not" 1 "saves '\${{ runner.temp }}/ci-helpers-godot-archive' from a job that reads secrets.STORE_KEY; a trusted job writes no cache" <<YAML
on: push
jobs:
  release:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: \${{ runner.temp }}/ci-helpers-godot-archive
          key: godot-x
      - run: bash .ci-helpers-scripts/scripts/setup_godot.sh
      - uses: actions/cache/save@$pin
        with:
          path: \${{ runner.temp }}/ci-helpers-godot-archive
          key: godot-x
      - run: godot --export-release
        env:
          STORE_KEY: \${{ secrets.STORE_KEY }}
YAML

# --- no restore of any kind in a trusted job -------------------------------

expect "a verified toolchain archive restored into a job with secrets" 1 "restores '\${{ steps.flutter_resolve.outputs.cache_path }}' into a job that reads secrets.ANDROID_KEYSTORE; a cache entry is a tar archive" <<YAML
on: push
jobs:
  release:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: \${{ steps.flutter_resolve.outputs.cache_path }}
          key: \${{ steps.flutter_resolve.outputs.cache_key }}
      - name: Setup Flutter
        run: bash .ci-helpers-scripts/scripts/setup_flutter.sh
      - run: flutter build appbundle
        env:
          KEYSTORE: \${{ secrets.ANDROID_KEYSTORE }}
YAML

expect "the Godot archive restored into a job the release job needs" 1 "restores '\${{ runner.temp }}/ci-helpers-godot-archive' into a job that is needed by trusted job release" <<YAML
on: push
jobs:
  build:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: \${{ runner.temp }}/ci-helpers-godot-archive
          key: godot-x
      - run: bash .ci-helpers-scripts/scripts/setup_godot.sh
      - run: godot --export-release
  release:
    needs: build
    permissions:
      contents: write
    runs-on: ubuntu-latest
    steps:
      - run: gh release upload
YAML

# --- a workflow named for what it ships ---------------------------------------

expect "setup-go with no cache key in a deploy workflow" 1 "deploy.yml: jobs.deploy.steps[0] 'Setup Go': actions/setup-go without cache: in a job that is a job of deploy.yml, a workflow named for what it ships; the action's default may restore a dependency cache there, so write cache: false" .github/workflows/deploy.yml <<'YAML'
on:
  workflow_call:
    inputs:
      deploy_command:
        type: string
jobs:
  deploy:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - name: Setup Go
        uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e
        with:
          go-version: '1.25'
      - run: ${{ inputs.deploy_command }}
YAML

expect "setup-node without package-manager-cache in a release workflow" 1 "actions/setup-node without package-manager-cache: in a job that is a job of go-release.yml, a workflow named for what it ships; the action's default may restore a dependency cache there, so write package-manager-cache: false" .github/workflows/go-release.yml <<'YAML'
on: push
jobs:
  build:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1
        with:
          node-version: '24'
          cache: ""
      - run: npm run build
YAML

expect "a setup action the off table does not know, in a trusted job" 1 "actions/setup-ruby is not in SETUP_OFF" <<'YAML'
on: push
jobs:
  release:
    permissions:
      contents: write
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-ruby@0000000000000000000000000000000000000000
        with:
          ruby-version: '3.4'
YAML

expect "the wrong off value for the action" 1 "actions/setup-python with cache: false restores a dependency cache into a job that holds contents: write; write cache: \"\"" <<'YAML'
on: push
jobs:
  release:
    permissions:
      contents: write
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0
        with:
          cache: false
YAML

# --- what stays quiet -------------------------------------------------------

expect "every action's off value, written, in a trusted job" 0 "" <<'YAML'
on: push
jobs:
  release:
    permissions:
      contents: write
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1
        with:
          cache: ""
          package-manager-cache: false
      - uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e
        with:
          cache: "false"
      - uses: actions/setup-dotnet@0f4a354dd5547a28c70b7853dbd95d5b67886e73
        with:
          cache: false
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0
        with:
          cache: ""
      - uses: actions/setup-java@77dd5b2ce225ea11469928ac317850245a74ae78
        with:
          cache: ""
      - run: go build
YAML

expect "restore, fetch, save in a plain job, then the caller's steps" 0 "" <<YAML
on:
  workflow_call:
    inputs:
      test_command:
        type: string
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - id: cache
        uses: actions/cache/restore@$pin
        with:
          path: |
            ~/.cargo/registry/index/
            ~/.cargo/registry/cache/
          key: rust-x
          restore-keys: rust-
      - run: cargo fetch --locked
      - if: \${{ steps.cache.outputs.cache-hit != 'true' }}
        uses: actions/cache/save@$pin
        with:
          path: |
            ~/.cargo/registry/index/
            ~/.cargo/registry/cache/
          key: rust-x
      - run: \${{ inputs.test_command }}
YAML

expect "setup-* caches in a plain job" 0 "" <<'YAML'
on: push
jobs:
  ci:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1
        with:
          cache: pnpm
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0
        with:
          cache: ${{ steps.probe.outputs.python }}
      - run: pnpm test
YAML

# --- composite actions ------------------------------------------------------

expect "actions/cache in a composite action" 1 "action.yml: runs.steps[0] 'actions/cache': restores and saves 'node_modules' in a job that may run inside a job that holds a secret" .github/actions/x/action.yml <<YAML
name: x
runs:
  using: composite
  steps:
    - uses: actions/cache@$pin
      with:
        path: node_modules
        key: n-x
    - run: npm test
      shell: bash
YAML

# --- the tree is read whole ---------------------------------------------------

expect "a .yaml workflow is read" 1 "y.yaml: jobs.release" .github/workflows/y.yaml <<YAML
on: push
jobs:
  release:
    permissions:
      contents: write
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@$pin
        with:
          path: target/
          key: rust-x
YAML

rm -rf "${work:?}/t"; mkdir -p "$work/t"
rc=0; python3 "$check" --root "$work/t" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 2 ]; then echo "FAIL a tree with no workflow: exit $rc, expected 2"; cat "$work/out"; fail=1; fi

rm -rf "${work:?}/t"; mkdir -p "$work/t/.github/workflows"
printf 'on: push\njobs: [\n' > "$work/t/.github/workflows/bad.yml"
rc=0; python3 "$check" --root "$work/t" > "$work/out" 2>&1 || rc=$?
if [ "$rc" != 2 ] || ! grep -q "cannot read" "$work/out"; then echo "FAIL a file that does not parse: exit $rc, expected 2"; cat "$work/out"; fail=1; fi

[[ "$fail" = 0 ]] && echo "ok: the cache-trust check passes on this tree, refuses every restore into a trusted job and every save after the caller's code, and stays quiet on the rest"
exit "$fail"
