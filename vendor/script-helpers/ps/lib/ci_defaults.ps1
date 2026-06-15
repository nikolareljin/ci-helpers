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
