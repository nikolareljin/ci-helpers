# Examples

This file provides extended examples that combine multiple inputs and common
real-world patterns.

Related docs:
- [Reusable workflows](workflows.md)
- [Presets](presets.md)
- [Composite actions](actions.md)

## Monorepo (subdirectory)

```yaml
jobs:
  web:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@v0.1.0
    with:
      working_directory: "apps/web"
      node_version: "20"
      lint_command: "yarn lint"
      test_command: "yarn test"
      build_command: "yarn build"
```

## Playwright with start-server-and-test (custom port)

```yaml
jobs:
  e2e:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/playwright.yml@v0.1.0
    with:
      node_version: "20"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:4173 'npx playwright test'"
```

## Cypress with start-server-and-test (custom script)

```yaml
jobs:
  e2e:
    uses: nikolareljin/ci-helpers/.github/workflows/presets/cypress.yml@v0.1.0
    with:
      node_version: "20"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev:ci' http://localhost:3000 'npx cypress run'"
```

## Docker build + E2E

E2E always runs after Docker when both are set.

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/ci.yml@v0.1.0
    with:
      node_version: "20"
      docker_command: "docker build -t myapp:ci ."
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
```

## PR gate with release tag check

```yaml
jobs:
  gate:
    uses: nikolareljin/ci-helpers/.github/workflows/pr-gate.yml@v0.1.0
    with:
      check_release_tag: true
      release_branch: ${{ github.head_ref }}
      node_version: "20"
      test_command: "yarn test"
```

## Deploy with runtime setup

```yaml
jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/deploy.yml@v0.1.0
    with:
      node_version: "20"
      deploy_command: "./scripts/deploy.sh"
```
