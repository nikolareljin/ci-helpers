#!/usr/bin/env bash
# Module: ci_defaults
# Centralized default versions for Docker images used by ci_*.sh scripts.
#
# All ci_*.sh scripts source these values as their defaults. CLI flags
# (--version, --image, --digest) still override them at runtime.
#
# HOW TO UPDATE
# -------------
# 1. Check the latest stable versions:
#      Node:     https://hub.docker.com/_/node/tags  (pick LTS + Debian codename)
#      Python:   https://hub.docker.com/_/python/tags (pick 3.x-slim)
#      Flutter:  https://github.com/cirruslabs/docker-images-flutter/pkgs/container/flutter
#      Gradle:   https://hub.docker.com/_/gradle/tags (pick version-jdkNN)
#      Go:       https://hub.docker.com/_/golang/tags (pick 1.x)
#      Gitleaks: https://github.com/gitleaks/gitleaks/releases
#      Wrangler: https://www.npmjs.com/package/wrangler?activeTab=versions
#
# 2. Update the version variables below.
# 3. Commit with: git commit -m "chore: bump ci default versions"
# 4. Run sync_script_helpers.sh in consuming repos to propagate the change.
#
# LAST UPDATED: 2026-09-22

# -- Node.js --
CI_DEFAULT_NODE_VERSION="${CI_DEFAULT_NODE_VERSION:-24-bookworm}"
CI_DEFAULT_NODE_IMAGE="${CI_DEFAULT_NODE_IMAGE:-node}"

# -- Python --
CI_DEFAULT_PYTHON_VERSION="${CI_DEFAULT_PYTHON_VERSION:-3.12-slim}"
CI_DEFAULT_PYTHON_IMAGE="${CI_DEFAULT_PYTHON_IMAGE:-python}"

# -- Flutter --
CI_DEFAULT_FLUTTER_VERSION="${CI_DEFAULT_FLUTTER_VERSION:-3.38.8}"
CI_DEFAULT_FLUTTER_IMAGE="${CI_DEFAULT_FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter}"

# -- Gradle (Kotlin / Android) --
CI_DEFAULT_GRADLE_VERSION="${CI_DEFAULT_GRADLE_VERSION:-8.7-jdk17}"
CI_DEFAULT_GRADLE_IMAGE="${CI_DEFAULT_GRADLE_IMAGE:-gradle}"

# -- Go --
CI_DEFAULT_GO_VERSION="${CI_DEFAULT_GO_VERSION:-1.22}"
CI_DEFAULT_GO_IMAGE="${CI_DEFAULT_GO_IMAGE:-golang}"

# -- Legacy bash (macOS compatibility gate) --
# macOS ships bash 3.2 as /bin/bash and always will, for licensing reasons. This
# image is how the suite is run against that shell from a Linux box, so the
# 3.2-safe idioms in lib/ are verified without needing a Mac.
CI_DEFAULT_BASH32_VERSION="${CI_DEFAULT_BASH32_VERSION:-3.2}"
CI_DEFAULT_BASH32_IMAGE="${CI_DEFAULT_BASH32_IMAGE:-bash}"

# -- Gitleaks (security scanning) --
CI_DEFAULT_GITLEAKS_VERSION="${CI_DEFAULT_GITLEAKS_VERSION:-v8.30.0}"
CI_DEFAULT_GITLEAKS_IMAGE="${CI_DEFAULT_GITLEAKS_IMAGE:-zricethezav/gitleaks}"

# -- Wrangler (Cloudflare deploys) --
# Not an image: this is the version `lib/cloudflare.sh` hands to `npx` when a
# project has no wrangler of its own. A project with a lockfile gets the version
# it was tested against instead, which is always the better answer -- this is
# the floor for projects that have none.
CI_DEFAULT_WRANGLER_VERSION="${CI_DEFAULT_WRANGLER_VERSION:-4.42.0}"
