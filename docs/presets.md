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
- `timeout_minutes`: `20` (passed through to `ci.yml`)

Example:

```yaml
jobs:
  kotlin:
    uses: nikolareljin/ci-helpers/.github/workflows/kotlin.yml@production
    with:
      java_version: "17"
```

In an Android project, `./gradlew test` may be a no-op or run a broader set of
variant tests than the gate needs. Use `testDebugUnitTest` when the CI gate must
run the debug unit tests explicitly:

```yaml
    with:
      java_version: "17"
      lint_command: "./gradlew lintDebug"
      test_command: "./gradlew testDebugUnitTest"
```

On a private repo, consider running none of this on a server. See
[private-repo-ci-strategy.md](private-repo-ci-strategy.md): `script-helpers`
ships a local Gradle runner that accepts explicit variant-qualified task names.

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

## Pages (any static site)

Workflow: `.github/workflows/pages.yml`

Builds a static site with whatever generator the repository uses and deploys it
to GitHub Pages. Stack-agnostic: MkDocs, Sphinx, Hugo, Astro, or a plain
`cp -r`. Use `pnpm-pages.yml` instead when you need pnpm-workspace installs or a
Playwright capture step.

Requires `pages: write` and `id-token: write` in the caller **even on runs where
`deploy` is false** — GitHub validates a reusable workflow's declared
permissions when the run starts, before any job-level `if:` is evaluated, so a
caller granting less fails the whole run with `startup_failure`.

Defaults:
- `runner`: `ubuntu-latest`
- `working_directory`: `.`
- `concurrency_key`: `""` — defaults to `github.ref`. Every deployment to a ref
  is serialised, because Pages hosts one site per repository and two racing
  deploys decide the published content by whichever finishes last. Set this only
  when two workflows genuinely publish different things
- `fetch_depth`: `0` — full history, which generators reading git dates or tags
  need (`mkdocs-git-revision-date`, Hugo `.Lastmod`); set `1` when nothing does
- `python_version`: `""` — set to install Python before building
- `node_version`: `""` — set to install Node before building
- `requirements_file`: `""` — a pip requirements file relative to
  `working_directory`; when set and `install_command` is empty it is installed
  for you and used as the pip cache key
- `install_command`: `""` — overrides the `requirements_file` install
- `build_command`: `""` — the command that writes the site into `pages_path`.
  Leave it empty to publish a directory already committed to the repository: a
  plain HTML site needs no toolchain and no placeholder command
- `require_entry_file`: `true` — fail when `pages_path` has no `index.html` or
  `index.htm` at its root. A site without one deploys successfully and then
  serves 404 at its own address. Set `false` when publishing assets that are
  only ever linked to directly
- `artifact_retention_days`: `1` — how long the Pages artifact is kept. It
  exists to hand the site to the deploy job; keeping build output longer stores
  content nobody reads
- `pages_path`: `site` — directory uploaded to Pages, relative to
  `working_directory`
- `deploy`: `true` — set `false` to build without publishing
- `timeout_minutes`: `20`

The build fails if `pages_path` is missing or empty by the time the site is
uploaded — whether a generator ran and produced nothing, or a deploy-only call
points at a directory that is not there. That check is why `build_command` does
not need to be mandatory: an empty site cannot replace a working one on a green
run either way. `require_entry_file` extends the same idea one step — a
directory full of files with no entry document publishes cleanly and then serves
404 to every visitor.

`working_directory` is validated up front too, because a path that does not
exist otherwise fails several steps later with a message about whichever command
happened to run first.

**Do not set a `pages-*` concurrency group in the caller.** This preset's own
group is `ci-helpers-pages-<key>`. A caller whose group name collides with the
called workflow's own group leaves the called jobs queued behind the run that
started them — the run waits for a slot it is itself holding. If you are
migrating a hand-rolled Pages workflow, delete its `concurrency:` block; this
preset already serialises deployments.

Example (MkDocs — build on every pull request, publish only from `main`):

```yaml
name: Docs
on:
  push:
    branches: [main]
    paths: [docs/**, mkdocs.yml, requirements-docs.txt]
  pull_request:
    paths: [docs/**, mkdocs.yml, requirements-docs.txt]

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  pages:
    uses: nikolareljin/ci-helpers/.github/workflows/pages.yml@production
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      python_version: "3.12"
      requirements_file: "requirements-docs.txt"
      build_command: "mkdocs build --strict"
      pages_path: "site"
      deploy: ${{ github.event_name != 'pull_request' }}
```

Example (publish a directory already in the repository — no build, no toolchain):

```yaml
jobs:
  pages:
    uses: nikolareljin/ci-helpers/.github/workflows/pages.yml@production
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      pages_path: "site"
```

Example (a Node generator):

```yaml
jobs:
  pages:
    uses: nikolareljin/ci-helpers/.github/workflows/pages.yml@production
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      node_version: "22"
      install_command: "npm ci"
      build_command: "npm run build"
      pages_path: "dist"
```

## pnpm + Pages

Workflow: `.github/workflows/pnpm-pages.yml`

Builds a pnpm monorepo, optionally runs a Playwright capture script to produce
screenshots and videos, runs a static-site generator, and deploys the result to
GitHub Pages. Requires `pages: write` and `id-token: write` in the caller.

Defaults:
- `runner`: `ubuntu-latest`
- `working_directory`: `.` — set to a subdirectory when the pnpm workspace root is not the repo root
- `fetch_depth`: `0` — full history; this is the safe default for tag-based tooling (e.g. changeset
  version, release scripts); set to `1` for faster shallow clones when no tag/history access is needed
- `node_version`: `22`
- `pnpm_version`: `latest`
- `build_command`: `pnpm build` — runs before the capture and generate steps
- `capture_command`: `""` — optional; set to e.g. `node scripts/capture.mjs` to run a
  Playwright-based capture script before site generation
- `generate_command`: `node docs/generate.mjs` — generates the static site into `pages_path`
- `pages_path`: `docs/site` — directory uploaded to Pages (relative to `working_directory`)
- `install_playwright`: `false` — set to `true` to install the Playwright browser before capture
- `playwright_browser`: `chromium` — must be one of: `chromium`, `firefox`, `webkit`, `chrome`, `msedge`;
  validated before install so failures are deterministic

Notes:
- `pages: write` and `id-token: write` are scoped to the `deploy` job only; the `build` job
  only requires `contents: read`, so caller-supplied commands cannot exchange OIDC tokens.
- `playwright_browser` is validated against known Playwright browser names before install; an
  `::error::` annotation is emitted and the job fails immediately on an unknown value.
- The `playwright_browser` input is passed via `$PW_BROWSER` (not direct interpolation) to
  avoid shell-injection risk.
- All `run:` steps use `shell: bash` with `set -euo pipefail`, consistent with other pnpm presets.
- `pages_path` is automatically prefixed with `working_directory` when not `.`.

Required caller permissions:

```yaml
permissions:
  contents: read
  pages: write
  id-token: write
```

Example (with Playwright capture):

```yaml
jobs:
  pages:
    uses: nikolareljin/ci-helpers/.github/workflows/pnpm-pages.yml@production
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      build_command: "pnpm build"
      capture_command: "node scripts/capture.mjs"
      install_playwright: true
      playwright_browser: "chromium"
```

Example (generate only, no capture):

```yaml
jobs:
  pages:
    uses: nikolareljin/ci-helpers/.github/workflows/pnpm-pages.yml@production
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      build_command: "pnpm build"
      generate_command: "node docs/generate.mjs"
      pages_path: "docs/site"
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
