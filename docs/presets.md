# Presets

Presets are reusable workflows that wrap `ci.yml` with sane defaults for
specific stacks or E2E tools. All presets accept the same core inputs as
`ci.yml` and simply provide default values for common commands.

Related docs:
- [Reusable workflows](workflows.md)
- [Examples](examples.md)

Use a preset if you want a fast setup with minimal inputs, and override any
command or version as needed.

## Node

Workflow: `.github/workflows/node.yml`

Defaults:
- `node_version`: `20`
- `lint_command`: `npm ci && npm run lint`
- `test_command`: `npm test`
- `build_command`: `npm run build`

Example:

```yaml
jobs:
  node:
    uses: nikolareljin/ci-helpers/.github/workflows/node.yml@v0.1.1
    with:
      node_version: "20"
```

## React

Workflow: `.github/workflows/react.yml`

Defaults:
- `node_version`: `20`
- `lint_command`: `npm ci && npm run lint`
- `test_command`: `npm test -- --watchAll=false`
- `build_command`: `npm run build`

Example:

```yaml
jobs:
  react:
    uses: nikolareljin/ci-helpers/.github/workflows/react.yml@v0.1.1
    with:
      node_version: "20"
```

## Python

Workflow: `.github/workflows/python.yml`

Defaults:
- `python_version`: `3.12`
- `lint_command`: `python -m pip install -r requirements.txt`
- `test_command`: `python -m pytest`

Example:

```yaml
jobs:
  python:
    uses: nikolareljin/ci-helpers/.github/workflows/python.yml@v0.1.1
    with:
      python_version: "3.12"
```

## PHP

Workflow: `.github/workflows/php.yml`

Defaults:
- `php_version`: `8.2`
- `lint_command`: `composer install --no-interaction --prefer-dist`
- `test_command`: `vendor/bin/phpunit`

Example:

```yaml
jobs:
  php:
    uses: nikolareljin/ci-helpers/.github/workflows/php.yml@v0.1.1
    with:
      php_version: "8.2"
```

## Go

Workflow: `.github/workflows/go.yml`

Defaults:
- `go_version`: `1.22`
- `test_command`: `go test ./...`
- `build_command`: `go build ./...`

Example:

```yaml
jobs:
  go:
    uses: nikolareljin/ci-helpers/.github/workflows/go.yml@v0.1.1
    with:
      go_version: "1.22"
```

## Java

Workflow: `.github/workflows/java.yml`

Defaults:
- `java_version`: `17`
- `test_command`: `mvn -B test`
- `build_command`: `mvn -B package`

Example:

```yaml
jobs:
  java:
    uses: nikolareljin/ci-helpers/.github/workflows/java.yml@v0.1.1
    with:
      java_version: "17"
```

## C#

Workflow: `.github/workflows/csharp.yml`

Defaults:
- `dotnet_version`: `8.0.x`
- `test_command`: `dotnet test`
- `build_command`: `dotnet build -c Release`

Example:

```yaml
jobs:
  csharp:
    uses: nikolareljin/ci-helpers/.github/workflows/csharp.yml@v0.1.1
    with:
      dotnet_version: "8.0.x"
```

## Docker

Workflow: `.github/workflows/docker.yml`

Defaults:
- `docker_command`: `docker build .`

Example:

```yaml
jobs:
  docker:
    uses: nikolareljin/ci-helpers/.github/workflows/docker.yml@v0.1.1
    with:
      docker_command: "docker build -t myapp:ci ."
```

## Playwright

Workflow: `.github/workflows/playwright.yml`

Defaults:
- `node_version`: `20`
- `e2e_command`: `yarn install --frozen-lockfile && yarn dlx playwright install --with-deps && yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx playwright test'`

Notes:
- The default uses Yarn and `start-server-and-test` to boot the app before
  running the Playwright tests. Override `e2e_command` if your dev server
  command or URL differs.

Example:

```yaml
jobs:
  playwright:
    uses: nikolareljin/ci-helpers/.github/workflows/playwright.yml@v0.1.1
    with:
      node_version: "20"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:4173 'npx playwright test'"
```

## Cypress

Workflow: `.github/workflows/cypress.yml`

Defaults:
- `node_version`: `20`
- `e2e_command`: `yarn install --frozen-lockfile && yarn dlx cypress install && yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'`

Notes:
- The default uses Yarn and `start-server-and-test` to boot the app before
  running Cypress. Override `e2e_command` if your dev server command or URL
  differs.

Example:

```yaml
jobs:
  cypress:
    uses: nikolareljin/ci-helpers/.github/workflows/cypress.yml@v0.1.1
    with:
      node_version: "20"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:4173 'npx cypress run'"
```

## Overriding defaults

All presets accept the same inputs as `ci.yml`. For example, to add Docker and
E2E in the Node preset:

```yaml
jobs:
  node:
    uses: nikolareljin/ci-helpers/.github/workflows/node.yml@v0.1.1
    with:
      node_version: "20"
      docker_command: "docker build -t myapp:ci ."
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
```
