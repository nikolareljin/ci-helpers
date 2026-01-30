# Module: ci_defaults

Centralized defaults for Docker images used by `scripts/ci_*.sh` helpers.

## Environment variables

All values can be overridden by setting the variable before invoking a script.

### Node.js
- `CI_DEFAULT_NODE_VERSION` (default: `20-bullseye`)
- `CI_DEFAULT_NODE_IMAGE` (default: `node`)

### Python
- `CI_DEFAULT_PYTHON_VERSION` (default: `3.11-slim`)
- `CI_DEFAULT_PYTHON_IMAGE` (default: `python`)

### Flutter
- `CI_DEFAULT_FLUTTER_VERSION` (default: `3.38.8`)
- `CI_DEFAULT_FLUTTER_IMAGE` (default: `ghcr.io/cirruslabs/flutter`)

### Gradle (Kotlin / Android)
- `CI_DEFAULT_GRADLE_VERSION` (default: `8.7-jdk17`)
- `CI_DEFAULT_GRADLE_IMAGE` (default: `gradle`)

### Go
- `CI_DEFAULT_GO_VERSION` (default: `1.22`)
- `CI_DEFAULT_GO_IMAGE` (default: `golang`)

### Gitleaks
- `CI_DEFAULT_GITLEAKS_VERSION` (default: `v8.30.0`)
- `CI_DEFAULT_GITLEAKS_IMAGE` (default: `zricethezav/gitleaks`)

## Usage

```bash
# Override the default Python image tag for this shell
export CI_DEFAULT_PYTHON_VERSION="3.12-slim"
./scripts/ci_python.sh --workdir backend
```

## See also

- `docs/ci_defaults.md` for update guidance and supply-chain pinning tips.
