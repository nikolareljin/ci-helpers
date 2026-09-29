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
#      foxguard: https://github.com/0sec-labs/foxguard/releases (and its checksums.txt)
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

# -- foxguard (static analysis in ci_security.sh) --
# Not an image: a release binary that `ci_security.sh --install-foxguard`
# downloads and checks against these SHA-256 values, copied from the release's
# checksums.txt when the version was pinned. A binary that does not match is
# refused. Bump the version and every checksum together.
CI_DEFAULT_FOXGUARD_VERSION="${CI_DEFAULT_FOXGUARD_VERSION:-0.14.0}"
CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64="${CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64:-ef56a4d5cfc4cc4462e435bf31ca0f90694f47df1384772361a67828427db3d9}"
CI_DEFAULT_FOXGUARD_SHA256_LINUX_AARCH64="${CI_DEFAULT_FOXGUARD_SHA256_LINUX_AARCH64:-7d5c7263d71089eb06113a634aa3394ab8b54782b16e67a349693fedbb598120}"
CI_DEFAULT_FOXGUARD_SHA256_MACOS_X86_64="${CI_DEFAULT_FOXGUARD_SHA256_MACOS_X86_64:-628b6dcecbba8abd7312be1c94ac2346a363a680429b979ec5f63cf8ac7bca4b}"
CI_DEFAULT_FOXGUARD_SHA256_MACOS_AARCH64="${CI_DEFAULT_FOXGUARD_SHA256_MACOS_AARCH64:-aa47b956f31bfbc87e0f43cd48e01f3bc73229192ffff0113ff094e5b3fd7d12}"
CI_DEFAULT_FOXGUARD_SHA256_WINDOWS_X86_64="${CI_DEFAULT_FOXGUARD_SHA256_WINDOWS_X86_64:-6ff15185c968da849845afa321f23f14de142d45efd568a9513d2600eec281c2}"

# -- Wrangler (Cloudflare deploys) --
# Not an image: this is the version `lib/cloudflare.sh` hands to `npx` when a
# project has no wrangler of its own. A project with a lockfile gets the version
# it was tested against instead, which is always the better answer -- this is
# the floor for projects that have none.
CI_DEFAULT_WRANGLER_VERSION="${CI_DEFAULT_WRANGLER_VERSION:-4.42.0}"
