#!/usr/bin/env bash
# Workflow text in single quotes is meant literally.
# shellcheck disable=SC2016
# SCRIPT: check_privileged_jobs_test.sh
# DESCRIPTION: scripts/check_privileged_jobs.py refuses a job that runs caller
#              code while it holds a write permission, a secret or an
#              environment, accepts the split form and read-only jobs, flags a
#              stale PENDING entry, refuses go-deploy.yml, ppa-deb.yml and
#              manifest-version.yml as they were before the split, and accepts this repository.
# USAGE: bash tests/check_privileged_jobs_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gate="$root/scripts/check_privileged_jobs.py"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

expect() {  # expect <name> <rc> <yaml> [gate args...]
  local name="$1" want="$2" body="$3" rc=0
  shift 3
  rm -rf "$work/r"; mkdir -p "$work/r/.github/workflows"
  printf '%s\n' "$body" > "$work/r/.github/workflows/w.yml"
  python3 "$gate" --root "$work/r" "$@" > "$work/out" 2>&1 || rc=$?
  [[ "$rc" == "$want" ]] || { echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; }
}
np=--no-pending
head='on:
  workflow_call:
jobs:
  j:
    runs-on: ubuntu-latest'

expect "write token and an inputs command" 1 "$head
    permissions:
      contents: write
    steps:
      - run: \${{ inputs.build_command }}" $np
expect "a secret and npm ci" 1 "$head
    permissions:
      contents: read
    steps:
      - run: npm ci
        env:
          T: \${{ secrets.npm_token }}" $np
expect "an environment and docker build" 1 "$head
    permissions: {}
    environment: prod
    steps:
      - run: docker build -t x ." $np
expect "packages write and build-push-action" 1 "$head
    permissions:
      packages: write
    steps:
      - uses: docker/build-push-action@0000000000000000000000000000000000000000" $np
expect "a library builder script under a secret" 1 "$head
    permissions:
      contents: read
    steps:
      - run: /bin/bash \"\$run_lib/scripts/docker_build.sh\"
        env:
          P: \${{ secrets.registry_token }}" $np
expect "a local action of the caller" 1 "$head
    permissions:
      id-token: write
    steps:
      - uses: ./.github/actions/build" $np
expect "no permissions block inherits the caller's" 1 "$head
    steps:
      - run: make" $np
expect "workflow-level write applies to the job" 1 "on:
  workflow_call:
permissions:
  contents: write
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          set -e
          cargo build --release" $np
expect "a tool after sudo inside a branch" 1 "$head
    permissions:
      pages: write
    steps:
      - run: if true; then sudo -E dpkg-buildpackage -S; fi" $np

expect "read-only job runs the caller's command" 0 "$head
    permissions:
      contents: read
    steps:
      - run: \${{ inputs.build_command }}
        env:
          T: \${{ secrets.GITHUB_TOKEN }}" $np
expect "installing a named tool is not caller code" 0 "$head
    permissions:
      contents: read
    steps:
      - run: |
          dotnet tool update --global wingetcreate
          npm install -g some-cli
          cargo install tauri-cli --locked
          go install example.com/tool@v1.2.3
        env:
          T: \${{ secrets.winget_token }}" $np
expect "a command input through env:" 1 "$head
    permissions:
      contents: write
    steps:
      - run: /bin/bash \"\$lib/run.sh\"
        env:
          CMD: \${{ inputs.prebuild_command }}" $np
expect "post_deploy_command runs on the deploy target" 0 "$head
    permissions: {}
    steps:
      - run: ssh host \"\$CMD\"
        env:
          K: \${{ secrets.ssh_key }}
          CMD: \${{ inputs.post_deploy_command }}" $np
expect "manifest-version before the split" 1 "on:
  workflow_call:
permissions:
  contents: write
  actions: write
jobs:
  tag-and-dispatch:
    runs-on: ubuntu-latest
    steps:
      - name: Extract version from manifest
        env:
          VERSION_CMD: \${{ inputs.version_command }}
        run: version=\$(bash -c \"\$VERSION_CMD\")
      - run: git push origin tag" $np
expect "an install line that also builds" 1 "$head
    permissions:
      contents: write
    steps:
      - run: cargo install cross && make" $np
expect "cargo install --path is caller code" 1 "$head
    permissions:
      contents: write
    steps:
      - run: cargo install --path ." $np
expect "the split form passes" 0 "on:
  workflow_call:
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
      - run: \${{ inputs.build_command }}
      - uses: actions/upload-artifact@0000000000000000000000000000000000000000
  publish:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@0000000000000000000000000000000000000000
      - run: sha256sum --check --strict manifest
      - run: gh release upload \"\$TAG\" dist/*
        env:
          GH_TOKEN: \${{ github.token }}
          K: \${{ secrets.signing_key }}" $np
expect "staging that follows symlinks" 1 "$head
    permissions:
      contents: read
    steps:
      - name: Stage the files
        run: cp -- \"\$f\" \"\$out/\"" $np
expect "staging that refuses symlinks" 0 "$head
    permissions:
      contents: read
    steps:
      - name: Stage the files
        run: |
          [[ -f \"\$f\" && ! -L \"\$f\" ]] || exit 1
          [[ \"\$(realpath -e -- \"\$f\")\" == \"\$top\"/* ]] || exit 1
          cp -P -- \"\$f\" \"\$out/\"
          [[ -z \"\$(find \"\$out\" -mindepth 1 ! -type f ! -type d)\" ]] || exit 1" $np
expect "words that only look like tools" 0 "$head
    permissions:
      contents: write
    steps:
      - run: |
          echo make sure the go version matches
          gh release create \"\$TAG\" --notes-file notes.md" $np

# A PENDING entry that no longer fails is a finding: the fixture tree has
# none of the pending jobs.
expect "write-all and a *_cmd input" 1 "$head
    permissions: write-all
    steps:
      - run: \${{ inputs.build_cmd }}" $np
expect "a script_path input" 1 "$head
    permissions:
      contents: write
    steps:
      - run: bash \"\${{ inputs.script_path }}\"" $np
expect "an input of any name run as the command, matrix job, environment" 1 "$head
    permissions: {}
    environment: prod
    strategy:
      matrix:
        a: [1]
    steps:
      - run: \${{ inputs.build }}" $np
expect "a library action handed a command input" 1 "$head
    permissions:
      contents: write
    steps:
      - uses: ./.ci-helpers-x/.github/actions/wp-plugin-check
        with:
          phpunit_command: \${{ inputs.phpunit_command }}" $np
expect "a caller script run by path" 1 "$head
    permissions:
      contents: write
    steps:
      - run: ./scripts/release.sh" $np
expect "a caller script run by an interpreter" 1 "$head
    permissions:
      contents: write
    steps:
      - run: |
          echo hi
          python3 tools/bump.py" $np
expect "a repository script outside a reusable workflow" 0 "on:
  push:
jobs:
  j:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - run: ./scripts/create_production.sh" $np
expect "a library script from the trusted checkout" 0 "$head
    permissions:
      contents: write
    steps:
      - run: bash .ci-helpers-x/scripts/tag.sh" $np
expect "stale PENDING entries" 1 "$head
    permissions:
      contents: read
    steps:
      - run: true"
grep -q "is in PENDING but no longer fails" "$work/out" || { echo "FAIL: stale entry not named"; fail=1; }

# go-deploy.yml and ppa-deb.yml before the split, cut to the steps that
# matter: the caller's build and the key in one job.
expect "go-deploy before the split" 1 "$head
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
      - name: Build binary
        run: go build -o \"\$bin_name\" \"\${INPUT_MAIN_PATH}\"
      - name: Deploy to remote
        env:
          DEPLOY_SSH_KEY: \${{ secrets.ssh_key }}
        run: rsync -az -- \"\$bin_name\" host:/srv/" $np
expect "ppa-deb before the split" 1 "$head
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
      - name: Build source package (unsigned)
        run: /bin/bash \"\$SH_DIR/scripts/ppa_upload.sh\" --dry-run
      - name: Sign the source package
        env:
          GPG_PRIVATE_KEY: \${{ secrets.gpg_private_key }}
        run: debsign \"\$CHANGES\"" $np
rc=0; python3 "$gate" > "$work/out" 2>&1 || rc=$?
[[ "$rc" == 0 ]] || { echo "FAIL: this repository: exit $rc"; cat "$work/out"; fail=1; }

[[ "$fail" == 0 ]] && echo "ok: no job runs caller code with a write token, a secret or an environment"
exit "$fail"
