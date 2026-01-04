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
- `test_command`: `npm ci && npm test`
- `build_command`: `npm run build`

Example:

```yaml
jobs:
  node:
    uses: nikolareljin/ci-helpers/.github/workflows/node.yml@production
    with:
      node_version: "20"
```

## React

Workflow: `.github/workflows/react.yml`

Defaults:
- `node_version`: `20`
- `lint_command`: `npm ci && npm run lint`
- `test_command`: `npm ci && npm test -- --watchAll=false`
- `build_command`: `npm run build`

Example:

```yaml
jobs:
  react:
    uses: nikolareljin/ci-helpers/.github/workflows/react.yml@production
    with:
      node_version: "20"
```

## Python

Workflow: `.github/workflows/python.yml`

Defaults:
- `python_version`: `3.12`
- `lint_command`: `if [ -f requirements.txt ]; then python -m pip install -r requirements.txt; elif [ -f pyproject.toml ]; then python -m pip install pyinstaller && python -m pip install .; fi && python -m pip install ruff && ruff check .`
- `test_command`: `python -m pip install pytest && python -m pytest`

Example:

```yaml
jobs:
  python:
    uses: nikolareljin/ci-helpers/.github/workflows/python.yml@production
    with:
      python_version: "3.12"
```

## PHP

Workflow: `.github/workflows/php.yml`

Defaults:
- `php_version`: `8.2`
- `lint_command`: `composer install --no-interaction --prefer-dist && vendor/bin/phpcs --standard=PSR12 --extensions=php`
- `test_command`: `vendor/bin/phpunit`

Example:

```yaml
jobs:
  php:
    uses: nikolareljin/ci-helpers/.github/workflows/php.yml@production
    with:
      php_version: "8.2"
```

## Go

Workflow: `.github/workflows/go.yml`

Defaults:
- `go_version`: `1.22`
- `lint_command`: `test -z "$(gofmt -l .)" && go vet ./...`
- `test_command`: `go mod download && go test ./...`
- `build_command`: `go build ./...`

Example:

```yaml
jobs:
  go:
    uses: nikolareljin/ci-helpers/.github/workflows/go.yml@production
    with:
      go_version: "1.22"
```

## Java

Workflow: `.github/workflows/java.yml`

Defaults:
- `java_version`: `17`
- `lint_command`: `mvn -B -DskipTests checkstyle:check`
- `test_command`: `mvn -B test`
- `build_command`: `mvn -B package`

Example:

```yaml
jobs:
  java:
    uses: nikolareljin/ci-helpers/.github/workflows/java.yml@production
    with:
      java_version: "17"
```

## Java (Gradle)

Workflow: `.github/workflows/java-gradle.yml`

Defaults:
- `java_version`: `17`
- `lint_command`: `./gradlew check -x test`
- `test_command`: `./gradlew test`
- `build_command`: `./gradlew build`

Example:

```yaml
jobs:
  java_gradle:
    uses: nikolareljin/ci-helpers/.github/workflows/java-gradle.yml@production
    with:
      java_version: "17"
```

## Kotlin (Gradle/Android)

Workflow: `.github/workflows/kotlin.yml`

Defaults:
- `java_version`: `17`
- `lint_command`: `./gradlew lint`
- `test_command`: `./gradlew test`
- `build_command`: `./gradlew assembleDebug`

Example:

```yaml
jobs:
  kotlin:
    uses: nikolareljin/ci-helpers/.github/workflows/kotlin.yml@production
    with:
      java_version: "17"
```

## Rust

Workflow: `.github/workflows/rust.yml`

Defaults:
- `rust_toolchain`: `stable`
- `test_command`: `cargo test --verbose`
- `build_command`: `cargo build --verbose`

Example:

```yaml
jobs:
  rust:
    uses: nikolareljin/ci-helpers/.github/workflows/rust.yml@production
    with:
      rust_toolchain: "stable"
```

## C#

Workflow: `.github/workflows/csharp.yml`

Defaults:
- `dotnet_version`: `8.0.x`
- `lint_command`: `dotnet tool install -g dotnet-format && export PATH="$PATH:$HOME/.dotnet/tools" && dotnet-format --verify-no-changes`
- `test_command`: `dotnet restore && dotnet test`
- `build_command`: `dotnet restore && dotnet build -c Release`

Example:

```yaml
jobs:
  csharp:
    uses: nikolareljin/ci-helpers/.github/workflows/csharp.yml@production
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
    uses: nikolareljin/ci-helpers/.github/workflows/docker.yml@production
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
    uses: nikolareljin/ci-helpers/.github/workflows/playwright.yml@production
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
    uses: nikolareljin/ci-helpers/.github/workflows/cypress.yml@production
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
    uses: nikolareljin/ci-helpers/.github/workflows/node.yml@production
    with:
      node_version: "20"
      docker_command: "docker build -t myapp:ci ."
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
```
