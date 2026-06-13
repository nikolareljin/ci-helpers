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
- `node_version`: `22`
- `lint_command`: `npm ci && npm run lint`
- `test_command`: `npm ci && npm test`
- `build_command`: `npm run build`

Example:

```yaml
jobs:
  node:
    uses: nikolareljin/ci-helpers/.github/workflows/node.yml@production
    with:
      node_version: "22"
```

## React

Workflow: `.github/workflows/react.yml`

Defaults:
- `node_version`: `22`
- `lint_command`: `npm ci && npm run lint`
- `test_command`: `npm ci && npm test -- --watchAll=false`
- `build_command`: `npm run build`

Example:

```yaml
jobs:
  react:
    uses: nikolareljin/ci-helpers/.github/workflows/react.yml@production
    with:
      node_version: "22"
```

## Python

Workflow: `.github/workflows/python.yml`

Defaults:
- `python_version`: `3.13`
- `lint_command`: `if [ -f requirements.txt ]; then python -m pip install -r requirements.txt; elif [ -f pyproject.toml ]; then python -m pip install pyinstaller && python -m pip install .; fi && python -m pip install ruff && ruff check .`
- `test_command`: `python -m pip install pytest && python -m pytest`

Example:

```yaml
jobs:
  python:
    uses: nikolareljin/ci-helpers/.github/workflows/python.yml@production
    with:
      python_version: "3.13"
```

## PHP

Workflow: `.github/workflows/php.yml`

Defaults:
- `php_version`: `8.4`
- `node_version`: `""` (empty — set to e.g. `"22"` to install Node.js; also set `build_command` to run npm/yarn steps)
- `lint_command`: `composer install --no-interaction --prefer-dist && vendor/bin/phpcs --standard=PSR12 --extensions=php`
- `test_command`: `vendor/bin/phpunit`

Example:

```yaml
jobs:
  php:
    uses: nikolareljin/ci-helpers/.github/workflows/php.yml@production
    with:
      php_version: "8.4"
```

## Go

Workflow: `.github/workflows/go.yml`

Defaults:
- `go_version`: `1.24`
- `lint_command`: `test -z "$(gofmt -l .)" && go vet ./...`
- `test_command`: `go mod download && go test ./...`
- `build_command`: `go build ./...`

Example:

```yaml
jobs:
  go:
    uses: nikolareljin/ci-helpers/.github/workflows/go.yml@production
    with:
      go_version: "1.24"
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

## pnpm

Workflow: `.github/workflows/pnpm.yml`

Defaults:
- `node_version`: `22`
- `pnpm_version`: `latest`
- `lint_command`: `pnpm run lint`
- `test_command`: `pnpm run test`
- `build_command`: `pnpm run build`

Optional test result upload:
- `upload_test_results`: `false` — set to `true` to upload JUnit XML via `dorny/test-reporter`
- `test_results_path`: `test-results/**/*.xml` — glob for JUnit files; configure your test runner to emit XML here
- `artifact_suffix`: `""` — appended to the `junit-xml-pnpm` artifact name and the `Tests` check run; set to e.g. `-node20` when invoking this preset multiple times in a matrix to avoid name collisions

Notes:
- Works with Turborepo monorepos — `pnpm run test` can delegate to `turbo run test`.
- To enable test result annotations in GitHub Actions UI, set `upload_test_results: true`
  and configure Vitest to emit JUnit XML:

  ```ts
  // vitest.config.ts
  export default defineConfig({
    test: {
      reporters: ['default', 'junit'],
      outputFile: { junit: 'test-results/results.xml' },
    },
  })
  ```

Example:

```yaml
jobs:
  ci:
    uses: nikolareljin/ci-helpers/.github/workflows/pnpm.yml@production
    with:
      node_version: "22"
      upload_test_results: true
```

## pnpm + Playwright

Workflow: `.github/workflows/pnpm-playwright.yml`

Defaults:
- `node_version`: `22`
- `pnpm_version`: `latest`
- `lint_command`: `""` — lint is disabled by default; set to e.g. `pnpm run lint` to enable
- `test_command`: `pnpm run test`
- `build_command`: `pnpm run build`
- `e2e_command`: `pnpm exec playwright install --with-deps && pnpm dlx start-server-and-test 'pnpm run preview' http://localhost:4173 'pnpm exec playwright test'`
- `upload_playwright_report`: `true` — uploads `playwright-report/` as an artifact on every run
- `playwright_report_path`: `playwright-report/`

Optional test result upload:
- `upload_test_results`: `false` — set to `true` to upload JUnit XML via `dorny/test-reporter`
- `test_results_path`: `test-results/**/*.xml` — glob for Playwright JUnit output
- `artifact_suffix`: `""` — appended to `playwright-report`, `junit-xml-playwright`, and the `Tests` check name; use in a matrix to avoid collisions

Notes:
- Use for pnpm monorepos. Playwright browsers are installed as part of `e2e_command`.
- Override `e2e_command` to change the preview server command or port.
- For a Turborepo monorepo where the demo app is a workspace, use e.g.
  `pnpm run preview` or `pnpm --filter demo preview`.

Example:

```yaml
jobs:
  e2e:
    uses: nikolareljin/ci-helpers/.github/workflows/pnpm-playwright.yml@production
    with:
      node_version: "22"
      e2e_command: "pnpm exec playwright install --with-deps && pnpm dlx start-server-and-test 'pnpm --filter demo preview' http://localhost:4173 'pnpm exec playwright test'"
```

## pnpm + Cypress

Workflow: `.github/workflows/pnpm-cypress.yml`

Defaults:
- `node_version`: `22`
- `pnpm_version`: `latest`
- `lint_command`: `""` — lint is disabled by default; set to e.g. `pnpm run lint` to enable
- `test_command`: `pnpm run test`
- `build_command`: `pnpm run build`
- `e2e_command`: `pnpm exec cypress install && pnpm exec cypress run --component`
- `upload_cypress_artifacts`: `true` — uploads videos and screenshots on failure
- `cypress_videos_path`: `cypress/videos`
- `cypress_screenshots_path`: `cypress/screenshots`

Optional test result upload:
- `upload_test_results`: `false` — set to `true` to upload JUnit XML via `dorny/test-reporter`
- `test_results_path`: `test-results/**/*.xml` — glob for Cypress JUnit output
- `artifact_suffix`: `""` — appended to `cypress-videos`, `cypress-screenshots`, `junit-xml-cypress`, and the `Tests` check name; use in a matrix to avoid collisions

Notes:
- Default runs Cypress in **component test** mode (`--component`), which bundles and
  tests components directly — no running server needed. Override `e2e_command` to
  switch to full E2E mode against a preview server.
- For E2E mode: `pnpm exec cypress install && pnpm dlx start-server-and-test 'pnpm run preview' http://localhost:4173 'pnpm exec cypress run'`

Example (component tests):

```yaml
jobs:
  cypress:
    uses: nikolareljin/ci-helpers/.github/workflows/pnpm-cypress.yml@production
    with:
      node_version: "22"
```

Example (E2E against preview server):

```yaml
jobs:
  cypress:
    uses: nikolareljin/ci-helpers/.github/workflows/pnpm-cypress.yml@production
    with:
      node_version: "22"
      e2e_command: "pnpm exec cypress install && pnpm dlx start-server-and-test 'pnpm --filter demo preview' http://localhost:4173 'pnpm exec cypress run'"
```

## Playwright (yarn)

Workflow: `.github/workflows/playwright.yml`

Defaults:
- `node_version`: `22`
- `e2e_command`: `yarn install --frozen-lockfile && yarn dlx playwright install --with-deps && yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx playwright test'`

Notes:
- Uses Yarn. For pnpm monorepos use `pnpm-playwright.yml` instead.

Example:

```yaml
jobs:
  playwright:
    uses: nikolareljin/ci-helpers/.github/workflows/playwright.yml@production
    with:
      node_version: "22"
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:4173 'npx playwright test'"
```

## Cypress (yarn)

Workflow: `.github/workflows/cypress.yml`

Defaults:
- `node_version`: `22`
- `e2e_command`: `yarn install --frozen-lockfile && yarn dlx cypress install && yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'`

Notes:
- Uses Yarn. For pnpm monorepos use `pnpm-cypress.yml` instead.

Example:

```yaml
jobs:
  cypress:
    uses: nikolareljin/ci-helpers/.github/workflows/cypress.yml@production
    with:
      node_version: "22"
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
      node_version: "22"
      docker_command: "docker build -t myapp:ci ."
      e2e_command: "yarn dlx start-server-and-test 'yarn dev' http://localhost:3000 'npx cypress run'"
```
