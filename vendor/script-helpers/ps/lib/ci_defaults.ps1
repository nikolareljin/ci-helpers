# CI defaults — PowerShell companion to lib/ci_defaults.sh.
# Centralised Docker image version pins used by ci_*.ps1 scripts.
#
# NOTE: These pins use current stable versions and intentionally diverge from
# the Bash ci_defaults.sh (which targets older LTS versions for broader CI compat).
# Override any value by setting the env var before importing this module.

$env:CI_NODE_IMAGE    = if ($env:CI_NODE_IMAGE)    { $env:CI_NODE_IMAGE    } else { 'node:22-alpine'      }
$env:CI_PYTHON_IMAGE  = if ($env:CI_PYTHON_IMAGE)  { $env:CI_PYTHON_IMAGE  } else { 'python:3.13-slim'    }
$env:CI_GO_IMAGE      = if ($env:CI_GO_IMAGE)      { $env:CI_GO_IMAGE      } else { 'golang:1.24-alpine'  }
$env:CI_RUST_IMAGE    = if ($env:CI_RUST_IMAGE)    { $env:CI_RUST_IMAGE    } else { 'rust:1.78-slim'      }
$env:CI_PHP_IMAGE     = if ($env:CI_PHP_IMAGE)     { $env:CI_PHP_IMAGE     } else { 'php:8.4-cli'         }
$env:CI_FLUTTER_IMAGE = if ($env:CI_FLUTTER_IMAGE) { $env:CI_FLUTTER_IMAGE } else { 'ghcr.io/cirruslabs/flutter:stable' }
$env:CI_GRADLE_IMAGE  = if ($env:CI_GRADLE_IMAGE)  { $env:CI_GRADLE_IMAGE  } else { 'gradle:8-jdk21'      }

# Ollama (ollama_install.ps1): the Windows release zip and its SHA-256, copied
# from the release's sha256sum.txt. Must equal CI_DEFAULT_OLLAMA_* in
# lib/ci_defaults.sh; tests/ollama_install_test.sh compares the two.
$env:CI_DEFAULT_OLLAMA_VERSION = if ($env:CI_DEFAULT_OLLAMA_VERSION) { $env:CI_DEFAULT_OLLAMA_VERSION } else { '0.40.0' }
$env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 = if ($env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64) { $env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64 } else { '3623e256762ca89bd6fa99b0cc4106401919ce9df926411673e632e3ea287bb5' }
$env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64 = if ($env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64) { $env:CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64 } else { '18eec8eeb6a1193b998b09c9aed2668b1b360663edf31ccf061c07a09f7bcb25' }
