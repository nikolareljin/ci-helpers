# CI Default Versions

All `ci_*.sh` helper scripts read their Docker image versions from a single
centralized module: `lib/ci_defaults.sh`. This page explains how the defaults
work, how to override them, and how to update them.

## How it works

```text
lib/ci_defaults.sh          <-- single source of truth for all versions
  |
  +-- scripts/ci_node.sh    IMAGE_TAG="$CI_DEFAULT_NODE_VERSION"
  +-- scripts/ci_python.sh  IMAGE_TAG="$CI_DEFAULT_PYTHON_VERSION"
  +-- scripts/ci_flutter.sh IMAGE_TAG="$CI_DEFAULT_FLUTTER_VERSION"
  +-- scripts/ci_gradle.sh  IMAGE_TAG="$CI_DEFAULT_GRADLE_VERSION"
  +-- scripts/ci_go.sh      IMAGE_TAG="$CI_DEFAULT_GO_VERSION"
  +-- scripts/ci_security.sh
        PY_VERSION="$CI_DEFAULT_PYTHON_VERSION"
        NODE_VERSION="$CI_DEFAULT_NODE_VERSION"
        GITLEAKS_VERSION="$CI_DEFAULT_GITLEAKS_VERSION"
```

## Overriding at runtime

CLI flags always take precedence over the centralized defaults:

```bash
# Use defaults from ci_defaults.sh
./scripts/ci_node.sh --workdir frontend

# Override the tag for this run only
./scripts/ci_node.sh --workdir frontend --version 22-bookworm

# Override the entire image reference
./scripts/ci_node.sh --workdir frontend --image myregistry/node:22
```

## Overriding via environment

Each default uses `${CI_DEFAULT_*:-fallback}` syntax, so you can also
override via environment variables without editing the file:

```bash
export CI_DEFAULT_NODE_VERSION="22-bookworm"
./scripts/ci_node.sh --workdir frontend
```

## Current defaults

| Service   | Variable                       | Default       | Image                              |
|-----------|--------------------------------|---------------|------------------------------------|
| Node.js   | `CI_DEFAULT_NODE_VERSION`      | `20-bullseye` | `node:20-bullseye`                 |
| Python    | `CI_DEFAULT_PYTHON_VERSION`    | `3.11-slim`   | `python:3.11-slim`                 |
| Flutter   | `CI_DEFAULT_FLUTTER_VERSION`   | `3.38.8`      | `ghcr.io/cirruslabs/flutter:3.38.8`|
| Gradle    | `CI_DEFAULT_GRADLE_VERSION`    | `8.7-jdk17`   | `gradle:8.7-jdk17`                 |
| Go        | `CI_DEFAULT_GO_VERSION`        | `1.22`        | `golang:1.22`                      |
| Gitleaks  | `CI_DEFAULT_GITLEAKS_VERSION`  | `v8.30.0`     | `zricethezav/gitleaks:v8.30.0`     |

## How to update versions

### Step 1 -- Check latest stable releases

Run these commands to find the latest versions:

```bash
# Node.js LTS (pick latest LTS + Debian codename)
# https://hub.docker.com/_/node/tags
docker run --rm node:lts cat /etc/os-release | grep VERSION_CODENAME
# or check: https://nodejs.org/en/about/previous-releases

# Python (pick 3.x-slim)
# https://hub.docker.com/_/python/tags
curl -s 'https://registry.hub.docker.com/v2/repositories/library/python/tags/?page_size=20&name=slim' \
  | jq -r '.results[].name' | grep -E '^3\.[0-9]+-slim$' | sort -V | tail -3

# Flutter (specific version, not "stable")
# https://github.com/cirruslabs/docker-images-flutter/pkgs/container/flutter
gh api repos/flutter/flutter/git/refs/tags --paginate \
  --jq '.[].ref' | grep -E '^refs/tags/[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -t. -k1,1n -k2,2n -k3,3n | tail -1

# Gradle (pick version-jdkNN)
# https://hub.docker.com/_/gradle/tags
curl -s 'https://registry.hub.docker.com/v2/repositories/library/gradle/tags/?page_size=50' \
  | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+-jdk[0-9]+$' | sort -V | tail -5

# Go (pick 1.x)
# https://hub.docker.com/_/golang/tags
gh api repos/golang/go/git/refs/tags --paginate \
  --jq '.[].ref' | grep -E '^refs/tags/go1\.[0-9]+(\.[0-9]+)?$' \
  | sort -V | tail -3

# Gitleaks
gh api repos/gitleaks/gitleaks/releases/latest --jq '.tag_name'
```

### Step 2 -- Edit lib/ci_defaults.sh

Update the version strings and the `LAST UPDATED` date comment:

```bash
$EDITOR lib/ci_defaults.sh
```

### Step 3 -- Commit

```bash
git add lib/ci_defaults.sh
git commit -m "chore: bump ci default versions"
```

### Step 4 -- Propagate to consuming repositories

Repositories that vendor script-helpers as a submodule need to update:

```bash
cd /path/to/consuming-repo
./update   # or: git submodule update --remote scripts/script-helpers
git add scripts/script-helpers
git commit -m "chore: update script-helpers submodule"
```

For ci-helpers (which vendors under `vendor/script-helpers/`):

```bash
cd /path/to/ci-helpers
./scripts/sync_script_helpers.sh
git add vendor/script-helpers
git commit -m "chore: sync script-helpers vendor"
```

## Supply-chain pinning

For stronger guarantees, pin images to an immutable digest:

```bash
# Flutter
./scripts/ci_flutter.sh --digest sha256:abcdef...

# Gitleaks
./scripts/ci_security.sh --gitleaks-digest sha256:abcdef...

# Any image via full override
./scripts/ci_node.sh --image node@sha256:abcdef...
```

To find the current digest for an image:

```bash
docker manifest inspect node:20-bullseye | jq -r '.manifests[0].digest'
# or
docker pull node:20-bullseye && docker inspect node:20-bullseye | jq -r '.[0].RepoDigests[0]'
```
