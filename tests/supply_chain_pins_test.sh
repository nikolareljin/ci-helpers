#!/usr/bin/env bash
# SCRIPT: supply_chain_pins_test.sh
# DESCRIPTION: scripts/check_supply_chain_pins.py passes on this tree, flags
#              each unpinned image, unverified download and unchecked host key
#              in a scratch tree, and stays quiet on look-alikes (host:port,
#              uid:gid, comments, caller-composed images).
# USAGE: bash tests/supply_chain_pins_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/check_supply_chain_pins.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

if ! python3 "$check" --root "$root" > "$work/out" 2>&1; then
  echo "FAIL this tree has findings:"; cat "$work/out"; fail=1
fi

# expect <name> <rc> <pattern-or-empty> ; workflow body on stdin
expect() {
  local name="$1" want="$2" pattern="$3" rc=0
  rm -rf "${work:?}/t"; mkdir -p "$work/t/.github/workflows"
  cat > "$work/t/.github/workflows/w.yml"
  python3 "$check" --root "$work/t" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 0
  fi
  if [ -n "$pattern" ] && ! grep -qF -- "$pattern" "$work/out"; then
    echo "FAIL $name: no '$pattern' in output"; cat "$work/out"; fail=1
  fi
}

expect "tag-only input default" 1 "input 'db_image' default 'postgres:16'" <<'YAML'
on:
  workflow_call:
    inputs:
      db_image:
        type: string
        default: "postgres:16"
jobs: {}
YAML

expect "latest in docker run" 1 "'snyk/snyk:latest' is not pinned" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          docker run --rm \
            snyk/snyk:latest test
YAML

expect "service image" 1 "services.db.image 'mysql:8'" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    services:
      db:
        image: mysql:8
    steps:
      - run: true
YAML

expect "compose heredoc image" 1 "'mariadb:10.11' is not pinned" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          cat > c.yml <<EOF
          services:
            db:
              image: mariadb:10.11
          EOF
YAML

expect "StrictHostKeyChecking=no" 1 "hostkey: StrictHostKeyChecking=no" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: ssh -o StrictHostKeyChecking=no host true
YAML

expect "ssh-keyscan tofu" 1 "trust on first use" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: ssh-keyscan -H example.org >> ~/.ssh/known_hosts
YAML

expect "StrictHostKeyChecking=accept-new" 1 "hostkey: StrictHostKeyChecking=accept-new" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: ssh -o StrictHostKeyChecking=accept-new host true
YAML

expect "ssh-keyscan via tee" 1 "trust on first use" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: ssh-keyscan example.org | tee -a ~/.ssh/known_hosts
YAML

expect "curl redirected to a file" 1 "download: saved to a file" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: curl -fsSL https://example.org/tool > tool
YAML

expect "wget with no -O" 1 "download: saved to a file" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: wget -q https://example.org/tool.tar.gz
YAML

expect "download without sha256" 1 "download: saved to a file" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          curl -fsSLo tool https://example.org/tool
          chmod +x tool
YAML

expect "url default without sha256 default" 1 "'tool_sha256' defaults to empty" <<'YAML'
on:
  workflow_call:
    inputs:
      tool_url:
        type: string
        default: "https://example.org/tool"
      tool_sha256:
        type: string
        default: ""
jobs: {}
YAML

expect "look-alikes stay quiet" 0 "" <<'YAML'
on:
  workflow_call:
    inputs:
      image_name:
        type: string
        default: "ci-image:latest"
      db_image:
        type: string
        default: "postgres:16@sha256:ca0bd484cb98bf4b24eb1010e73fb3fcbd6714d240fbc1a10eea5b7dbecb641d"
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          # ssh -o StrictHostKeyChecking=no is what this replaced
          # docker run snyk/snyk:docker was the old form
          echo "db:3306" "33:33" "${{ github.server_url }}/a/b"
          image="wordpress:${WP}-apache"
          curl -fsSL -o /dev/null https://example.org/health
          curl -fsS https://example.org/api 2>/dev/null | jq . > out.json
          sudo apt-get install -y wget
          curl -fsSLo tool https://example.org/tool
          echo "abc  tool" | sha256sum -c -
          ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=k host true
YAML

[ "$fail" = 0 ] && echo "ok: supply-chain pin check flags each class and passes this tree"
exit "$fail"
