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
CI_DEFAULT_GITLEAKS_VERSION="${CI_DEFAULT_GITLEAKS_VERSION:-v8.30.1}"
CI_DEFAULT_GITLEAKS_IMAGE="${CI_DEFAULT_GITLEAKS_IMAGE:-zricethezav/gitleaks}"
# The release archives lib/gitleaks.sh installs on a host without gitleaks,
# copied from gitleaks_8.30.1_checksums.txt (the release's asset digests agree).
CI_DEFAULT_GITLEAKS_SHA256_LINUX_X64="${CI_DEFAULT_GITLEAKS_SHA256_LINUX_X64:-551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb}"
CI_DEFAULT_GITLEAKS_SHA256_LINUX_ARM64="${CI_DEFAULT_GITLEAKS_SHA256_LINUX_ARM64:-e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080}"
CI_DEFAULT_GITLEAKS_SHA256_DARWIN_X64="${CI_DEFAULT_GITLEAKS_SHA256_DARWIN_X64:-dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709}"
CI_DEFAULT_GITLEAKS_SHA256_DARWIN_ARM64="${CI_DEFAULT_GITLEAKS_SHA256_DARWIN_ARM64:-b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5}"
CI_DEFAULT_GITLEAKS_SHA256_WINDOWS_X64="${CI_DEFAULT_GITLEAKS_SHA256_WINDOWS_X64:-d29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e}"

# -- foxguard (static analysis in ci_security.sh) --
# Not an image: a release binary that `ci_security.sh --install-foxguard`
# downloads and checks against these SHA-256 values, copied from the release's
# checksums.txt when the version was pinned. A binary that does not match is
# refused. Bump the version and every checksum together.
CI_DEFAULT_FOXGUARD_VERSION="${CI_DEFAULT_FOXGUARD_VERSION:-0.14.1}"
CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64="${CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64:-10a531279f7f3e9dcd01996e5e288309cd6d7d2bb2b7fa35de583d0bbe715bc2}"
CI_DEFAULT_FOXGUARD_SHA256_LINUX_AARCH64="${CI_DEFAULT_FOXGUARD_SHA256_LINUX_AARCH64:-f374bb1b81ffcb01aa5446719dee199245c673fffc9c659e985bbabe0faaa032}"
CI_DEFAULT_FOXGUARD_SHA256_MACOS_X86_64="${CI_DEFAULT_FOXGUARD_SHA256_MACOS_X86_64:-df78bc22307b893975c4d75799b36a1d7f1664be92aeeab19e61b7d0ecfafa26}"
CI_DEFAULT_FOXGUARD_SHA256_MACOS_AARCH64="${CI_DEFAULT_FOXGUARD_SHA256_MACOS_AARCH64:-e466cb4692a959fb500cd9f55d35aac0dd530afce8358643ed186e2c8c85f8c5}"
CI_DEFAULT_FOXGUARD_SHA256_WINDOWS_X86_64="${CI_DEFAULT_FOXGUARD_SHA256_WINDOWS_X86_64:-0fb139cb088a302a2c6567087079c4152025c20ac0e06a64107e9a0382e4bffb}"

# -- Ollama (lib/ollama_install.sh) --
# The release archive ollama_install downloads, and the SHA-256 of each, copied
# from the release's sha256sum.txt when the version was pinned
# (https://github.com/ollama/ollama/releases/tag/v0.40.0). An archive that does
# not match is refused and nothing is unpacked. Bump the version and every
# checksum together.
CI_DEFAULT_OLLAMA_VERSION="${CI_DEFAULT_OLLAMA_VERSION:-0.40.0}"
CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64="${CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64:-c94aa4156b3d13e64ebc2efe5ea53f015384c882be776e6695cfb37fb180d5ad}"
CI_DEFAULT_OLLAMA_SHA256_LINUX_ARM64="${CI_DEFAULT_OLLAMA_SHA256_LINUX_ARM64:-4d27cb1d8f46176a3c0ce10aea2a16e4ad73dfe1599f2ed13468f29e5b8aba0d}"
CI_DEFAULT_OLLAMA_SHA256_DARWIN="${CI_DEFAULT_OLLAMA_SHA256_DARWIN:-b490b4925a95c5f3dfcd889e566cf3dcd727848d59057fb00b03f1d6630326dc}"
CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64="${CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64:-3623e256762ca89bd6fa99b0cc4106401919ce9df926411673e632e3ea287bb5}"
CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64="${CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64:-18eec8eeb6a1193b998b09c9aed2668b1b360663edf31ccf061c07a09f7bcb25}"

# -- Wrangler (Cloudflare deploys) --
# Not an image: this is the version `lib/cloudflare.sh` hands to `npx` when a
# project has no wrangler of its own. A project with a lockfile gets the version
# it was tested against instead, which is always the better answer -- this is
# the floor for projects that have none.
CI_DEFAULT_WRANGLER_VERSION="${CI_DEFAULT_WRANGLER_VERSION:-4.42.0}"
