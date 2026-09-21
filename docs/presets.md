# Presets

Presets are reusable workflows that wrap `ci.yml` with sane defaults for
specific stacks or E2E tools, providing default values for common commands.

Every preset accepts and forwards the same **pass-through** inputs — `runner`,
`working_directory`, `concurrency_key`, `fetch_depth`, `submodules`, `cache` and
`timeout_minutes` — with the engine's own defaults, which
`scripts/check_engine_inputs.py` enforces on every commit. Beyond that set they
differ on purpose: `docker.yml` takes no lint, test or build command, the
database inputs exist only on `php.yml`, and every preset overrides the engine's
empty command defaults with something useful for its stack.

Related docs:

- [Reusable workflows](workflows.md)
- [Examples](examples.md)

Use a preset if you want a fast setup with minimal inputs, and override any
command or version as needed.

A preset calls `ci.yml` (Laravel: `php.yml`, then `ci.yml`) by relative path,
so it runs the `ci.yml` from the same ref you pinned the preset to: pinning
`node.yml@<tag>` pins the job it runs as well.

Composite actions have no same-commit form, so the workflows that use one
still call it at `@production`: `gitleaks-scan.yml` (the `gitleaks-scan`
action) and `tauri-release.yml` (`macos-sign`, `windows-sign`). Pinning those
workflows does not pin the action they run.

Concurrency: `ci.yml` cancels a superseded run in the same group. Without a
`concurrency_key`, the group is keyed on the caller workflow, the ref, the
working directory, the runner and the toolchain versions (`node_version`,
`java_version`, `dotnet_version`, `python_version`, `go_version`,
`flutter_version`/`flutter_channel`, `php_version`, `rust_toolchain`). Two jobs
in one workflow that share all of those still cancel each other; give each a
distinct `concurrency_key` (every preset, Laravel included, passes it through).

## Node

Workflow: `.github/workflows/node.yml`

Defaults:

- `node_version`: `22`
- `lint_command`: `npm ci && npm run --if-present lint`
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
- `lint_command`: `npm ci && npm run --if-present lint`
- `test_command`: `npm ci && npm test`
- `build_command`: `npm run build`

These are identical to `preset-node`'s. That is deliberate: a React project
needs nothing in CI that a Node project does not, and this preset exists so a
call site can say what the repository *is* rather than what it runs. Keep the
two in step — if one gains an input or a default, the other should too.

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
- `install_command`: `if [ -f requirements.txt ]; then python -m pip install -r requirements.txt; elif [ -f pyproject.toml ]; then python -m pip install .; fi`
- `lint_command`: `python -m pip install ruff && ruff check .`
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

## Pimcore

Workflow: `.github/workflows/pimcore.yml`

Runs PHPCS and PHPUnit for a Pimcore bundle **inside your own Docker Compose
stack**, so the checks run against a real PHP + MySQL environment rather than a
bare runner.

Defaults:

- `php_versions`: `'["8.3", "8.4"]'` — each version runs as its own matrix leg
- `php_version`: `""` — set it to test exactly one version; overrides `php_versions`
- `php_version_env`: `PHP_VERSION` — env var the version is exported as
- `compose_file`: `test/docker-compose.yml`
- `phpcs_command`: `vendor/bin/phpcs --standard=PSR12 --extensions=php src/`
- `phpunit_command`: `vendor/bin/phpunit --testdox`

Example:

```yaml
jobs:
  pimcore:
    uses: nikolareljin/ci-helpers/.github/workflows/pimcore.yml@production
    with:
      compose_file: docker-test/docker-compose.yml
```

### Choosing PHP versions

The preset tests **8.3 and 8.4** by default. Pass any JSON array to test
something else — the versions are not checked against an allow-list, so older
and newer lines both work:

```yaml
    with:
      php_versions: '["8.1", "8.2", "8.3", "8.4"]'
```

To test a single version, use `php_version`; it takes precedence, so you do not
need a one-element array:

```yaml
    with:
      php_version: "8.2"
```

The value must be a non-empty JSON array. Anything else fails the run rather
than expanding to an empty matrix, which would report as a skipped job and read
like a pass.

### Making the version reach your containers

Setting a version is only half of it. The checks run inside **your** compose
stack, which the workflow cannot see into, so the preset exports the selected
version into the environment — as `PHP_VERSION` unless you change
`php_version_env`. Your compose file has to consume it, or every matrix leg will
build the same image and the run will report version coverage it does not have.

```yaml
# docker-test/docker-compose.yml
services:
  php:
    build:
      context: ..
      dockerfile: docker-test/Dockerfile
      args:
        PHP_VERSION: ${PHP_VERSION:-8.3}
```

```dockerfile
# docker-test/Dockerfile
ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-cli
```

Set `php_version_env: ""` to export nothing, if your stack pins its PHP version
some other way.

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
- `project`: `""` — project or solution to restore, build, test and format, relative to `working_directory`. Passed to the default commands; ignored if you override a command.
- `lint_command`: `dotnet format --verify-no-changes` (the SDK built-in). `""` disables the stage, as elsewhere.

With `project` set and the commands left at their defaults, the project is passed to each: `dotnet format --verify-no-changes -- "<project>"`, `dotnet restore -- "<project>" && dotnet test -- "<project>"`, and so on. Override a command and `project` is not woven into it — your command is used exactly as given.

**Pass `project` unless the directory holds exactly one project or solution.** A directory with both a `.sln` and a `.csproj` fails a bare `dotnet build` with `MSB1011`, and a project in a subdirectory fails with `MSB1003`. The `.sln`/`.csproj` case is subtler than it looks: it only fails when the two base names *differ*. `App.sln` beside `App.csproj` is picked silently, while `Solution.sln` beside `App.csproj` is refused — so a repository can appear fine until it renames something.

`project` is validated before use: letters, digits, dot, underscore, slash, dash and space; no leading or trailing space; and it may not begin with `-`, which `dotnet` would read as a flag rather than a path. This is for legibility, not security — the command inputs beside it are arbitrary shell by contract.

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

## Godot

Workflow: `.github/workflows/godot.yml`

Defaults:

- `godot_version`: `4.3.0`
- `godot_use_dotnet`: `false`
- `lint_command`: imports the project and fails on anything the import logged
- `test_command`: none — it fails and tells you to set one, for the reason below

Example:

```yaml
jobs:
  godot:
    uses: nikolareljin/ci-helpers/.github/workflows/godot.yml@production
    with:
      godot_version: "4.3.0"
      test_command: ./dev test
```

### Write the version with three parts

`setup-godot` parses `godot_version` as a full version. `project.godot` records
a two-part one, and copying it across gives `Invalid version: 4.3` **before any
step runs** — the job fails at setup, which reads as infrastructure trouble
rather than a typo. Write `4.3.0`.

### Import before anything else

Godot resolves `class_name` types through
`.godot/global_script_class_cache.cfg`, which is produced by importing the
project and is not in version control. Every CI run starts without it, so until
the project is imported every `class_name` is "not declared in the current
scope": scripts referencing one fail to parse, `preload()` returns an invalid
script, and `.tres` files load as a bare `Resource`. The default
`lint_command` is that import, and it doubles as the parse gate.

**But the import cannot be trusted to fail.** Measured on 4.3: a project
containing a script with a syntax error imports, prints
`SCRIPT ERROR: Parse Error`, and **exits 0**. So a bare
`godot --headless --import` is a lint step that can never fail — which is the
obvious thing to write, and wrong. The default here reads the import log and
fails on what is in it. If you override `lint_command`, keep that property.

### An error during a run never reaches the exit status

This is the one that matters, and it is narrower than "Godot always exits 0" —
measured on 4.3:

| What went wrong | `godot --headless --script ...` exits |
|---|---|
| The script fails to parse or load (an unresolved `class_name`, a syntax error) | **1** |
| The engine prints `ERROR:` *while the script runs* (`push_error`, a bad format string, a failed resource load) | **0** |
| `--import` over a project whose scripts do not parse | **0** |

So the exit status catches the loud failures and misses the quiet ones — which
are exactly what a test suite is for. There is no honest default test command,
which is why the preset's default fails and asks for one. Put the check in your repository next to your tests, so it runs the
same way locally, and pass it as `test_command`:

```bash
#!/usr/bin/env bash
set -uo pipefail

log="$(mktemp)"
godot --headless --import                     # build the class cache first

godot --headless --script res://tests/TestRunner.gd 2>&1 | tee "$log"

# Fail on anything Godot printed as an error, minus the one line --headless
# always prints: the dummy renderer reports `Parameter "m" is null` for every
# mesh it cannot realise, which says nothing about your project.
if grep -nE "ERROR:|Failed to load|Parse Error" "$log" | grep -vE 'Parameter "m" is null'; then
  echo "Godot printed the errors above and still exited 0." >&2
  exit 1
fi

# "No errors" is not "the tests ran" — a runner that dies quietly prints
# nothing and still exits 0. Require the completion line it is supposed to
# print.
grep -q "all tests passed" "$log" || { echo "The runner never reported success." >&2; exit 1; }
```

Note the direction of that error check: it lists what is known to be
**harmless** and fails on everything else. An allowlist of error strings to
look for is the tempting shape and it is the wrong one — it ignores any kind
nobody thought of, and a format string with more placeholders than arguments
(Godot reports `ERROR: a number is required`) reached a physical device that
way while CI reported success.

## Go scan

Workflow: `.github/workflows/go-scan.yml`

Defaults:

- `go_version`: `1.25`
- `govulncheck_version`: `v1.7.0`
- `vulncheck`: `false`

```yaml
jobs:
  scan:
    uses: nikolareljin/ci-helpers/.github/workflows/go-scan.yml@production
    with:
      vulncheck: true
```

`gosec` is a static analyser: it reads this repository's own code. It is not a
dependency audit and says nothing about a known advisory in a module you import.
`govulncheck` is that audit, and it reports only advisories reachable from your
code, so importing a vulnerable module without calling into it is not flagged.

It is **off by default**. Turning it on fleet-wide would fail repositories that
changed nothing, on the day an advisory is published.

`v1.7.0` rather than the newest: `x/vuln` v1.8.0 declares `go 1.26.0`, and
`actions/setup-go` sets `GOTOOLCHAIN=local`, so installing it fails with
`requires go >= 1.26.0`. It installs fine on a developer machine, where Go
downloads the newer toolchain on demand, which is a difference worth knowing
before trusting a local check. Raise this input only together with
`go_version`.

`govulncheck_version` is pinned and validated as `vX.Y.Z`. A floating `@latest`
means the gate changes behaviour without a commit here, and a new advisory class
turns every consumer red on a day nobody shipped.

govulncheck exits **3** when it finds something, not 1. The step relies on
non-zero rather than a specific code.

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
- `lint_command`: `pnpm run --if-present lint`
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

That matters on pull requests, where the build runs third-party code (pip, npm
postinstall, generator plugins) while those write scopes are live and nothing is
being published. If you would rather not grant them there, call
`pages-build.yml` and `pages-deploy.yml` as two jobs instead — see
[Pages, split](#pages-split) below. `pages.yml` remains the simpler choice for a
repository that publishes from every event it builds on.

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
  `working_directory`. Absolute paths and any `..` segment are refused. The
  root of `working_directory` is allowed — a repository whose root is the site
  is a normal Pages layout — but warns, because "everything here" is rarely
  what someone means to publish. `upload-pages-artifact` excludes `.git`,
  `.github` and dotfiles; it does not exclude source
- `deploy`: `true` — set `false` to build without publishing
- `timeout_minutes`: `20`

The build fails if `pages_path` is missing, or contains no files by the time
the site is uploaded — a tree of empty directories is not a site — whether a generator ran and produced nothing, or a deploy-only call
points at a directory that is not there. That check is why `build_command` does
not need to be mandatory: an empty site cannot replace a working one on a green
run either way. `require_entry_file` extends the same idea one step — a
directory full of files with no entry document publishes cleanly and then serves
404 to every visitor.

`working_directory` gets the same treatment: relative, no climbing out of the
checkout, and it must exist. A path that does not exist otherwise fails several
steps later with a message about whichever command happened to run first. Both
inputs are caller-defined workflow configuration, at the same trust level as the
workflow file — these guards catch a typo, not an attacker.

`actions/configure-pages` runs before the build on deploying runs, so a
generator that needs the site's own address can read it:

| Variable | Example |
|---|---|
| `PAGES_BASE_URL` | `https://owner.github.io/repo` |
| `PAGES_ORIGIN` | `https://owner.github.io` |
| `PAGES_HOST` | `owner.github.io` |

```yaml
with:
  build_command: "hugo --baseURL \"$PAGES_BASE_URL\""
```

They are empty when `deploy` is `false`: a repository validating its site on
pull requests before ever enabling Pages should fail on its own site, not on the
Pages API. The repository must have **Settings → Pages → Source: GitHub
Actions** for a deploying run to succeed.

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

## Pages, split

Workflows: `.github/workflows/pages-build.yml` and
`.github/workflows/pages-deploy.yml`

The same publisher as `pages.yml`, in two callable halves. Reach for it when a
repository builds its site on pull requests and publishes only from its default
branch, and you do not want the pull-request build holding deploy-capable
scopes. `pages.yml` calls these two internally, so behaviour is identical — the
only difference is which permissions the caller has to grant on which event.

Minimum grants, both measured against a real run rather than inferred:

| Job | Grant | Measured |
| --- | --- | --- |
| `pages-build.yml` | `contents: read` + `pages: read` | succeeds |
| `pages-build.yml` | `contents: read` alone | `startup_failure` — `pages: read` is genuinely required |
| `pages-deploy.yml` | `pages: write` + `id-token: write` | succeeds |

`pages-build.yml` takes every input `pages.yml` does except `deploy` and
`concurrency_key`, plus two of its own:

- `upload`: `true` — upload the built site as the `github-pages` artifact for a
  later deploy job. Set `false` on runs that only check the site builds, so no
  artifact is stored for a deploy that never happens
- `configure_pages`: `false` — run `actions/configure-pages` and export
  `PAGES_BASE_URL`, `PAGES_ORIGIN` and `PAGES_HOST` to `build_command`. Off by
  default because it calls the Pages API, which fails on a repository that has
  not enabled Pages — the common case for a caller that only validates its site.
  Turn it on for the deploying run of a generator that builds absolute links

`pages-deploy.yml` takes `runner`, `timeout_minutes` and `concurrency_key`, and
outputs `page_url`. It checks out nothing and builds nothing: the write scopes
are only ever live in a job that runs no third-party code.

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

jobs:
  build:
    uses: nikolareljin/ci-helpers/.github/workflows/pages-build.yml@production
    permissions:
      contents: read
      pages: read
    with:
      python_version: "3.12"
      requirements_file: "requirements-docs.txt"
      build_command: "mkdocs build --strict"
      pages_path: "site"
      upload: ${{ github.ref == 'refs/heads/main' }}

  deploy:
    needs: build
    if: ${{ github.ref == 'refs/heads/main' && github.event_name != 'pull_request' }}
    uses: nikolareljin/ci-helpers/.github/workflows/pages-deploy.yml@production
    permissions:
      pages: write
      id-token: write
```

On a pull request the `deploy` job is skipped, so its token is never minted and
the run holds no write scope anywhere.

**Concurrency:** `pages-deploy.yml` serialises on
`ci-helpers-pages-deploy-<key>`, which is deliberately *not* the
`ci-helpers-pages-<key>` group `pages.yml` uses. A called workflow's group is
evaluated alongside its caller's, so sharing the name would leave the deploy
queued behind the run that started it. The same rule applies to your own
workflow: do not name a group `ci-helpers-pages-deploy-*`.

## pnpm + Pages

Workflow: `.github/workflows/pnpm-pages.yml`

Builds a pnpm monorepo, optionally runs a Playwright capture script to produce
screenshots and videos, runs a static-site generator, and deploys the result to
GitHub Pages. Requires `pages: write` and `id-token: write` in the caller.

Defaults:

- `runner`: `ubuntu-latest`
- `concurrency_key`: `""` — overrides `github.ref` in the concurrency group, for callers publishing several sites from one ref (#133)

Migrating a caller (#133): the workflow's own concurrency group is now
`ci-helpers-pnpm-pages-<key>`, so a caller no longer collides with it.
**Remove** any caller-level `concurrency:` block that was added to work around
the old collision; keep one only if you want the caller's *own* runs
serialised, and give it a name that is not `pages-<ref>`. Two callers
publishing different sites from one ref pass distinct `concurrency_key`
values and stop queueing behind each other.

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

## Cloudflare Workers

Workflows: `.github/workflows/cloudflare-deploy.yml`, `.github/workflows/cloudflare-build.yml`

Two workflows, not one, and no orchestrator wrapping them. `cloudflare-build.yml`
declares no secrets at all; `cloudflare-deploy.yml` declares the token and the
Environment. GitHub validates a called workflow's declared permissions and
secrets when the run starts — before any job-level `if:` — so a single combined
workflow would put a live deploy credential in scope on pull-request runs, while
npm postinstall scripts and build plugins execute. Splitting them is the only
way a caller can decline that.

This differs from `pages.yml`, which *does* ship an orchestrator. There, the
deploy half is useless alone, so an orchestrator earns its place. Here the
deploy workflow is already self-sufficient, and an orchestrator would force
`secrets: inherit` onto every event it handles.

### Before anything deploys

1. Create an API token at <https://dash.cloudflare.com/profile/api-tokens> with
   **Account → Workers Scripts → Edit** on the account that owns the Worker.
   Add **Workers KV Storage → Edit** only if your own deploy command writes KV;
   binding a namespace does not need it.
2. Add it as `CLOUDFLARE_API_TOKEN`, on the Environment you are deploying to.
3. Add `CLOUDFLARE_ACCOUNT_ID` as a repository or environment **variable**. It
   is an identifier, not a credential, and a readable one in the log is what
   tells you a deploy landed on the wrong account. A secret of the same name
   also works.
4. Add a `BASE_URL` variable on that Environment — the host the smoke test
   checks. `smoke_path` defaults to `/health`, so **without this the deploy
   succeeds and the run then goes red at the smoke step**. Set `base_url:`
   instead if you would rather pass it as an input, or `smoke_path: ""` to turn
   the check off (and lose the only thing that proves the deploy took effect).
5. Set the repository variable `CLOUDFLARE_DEPLOY_ENABLED` to `true`. Until you
   do, every run is a visible no-op that explains itself in the job summary.
6. On a production Environment, add a required reviewer. The workflow puts the
   Environment on its own deploy job, which is what makes the reviewer apply.

### 1. A release tag deploys production

```yaml
name: deploy
on:
  push:
    tags: ['[0-9]+.[0-9]+.[0-9]+']

jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/cloudflare-deploy.yml@production
    secrets: inherit
    permissions:
      contents: read
    with:
      enabled: ${{ vars.CLOUDFLARE_DEPLOY_ENABLED }}
      node_version: "22"
      build_command: "npm run build"
      config_glob: "dist/*/wrangler.json"
      smoke_version_path: /api/status
```

No `environment:` is needed: a bare-SemVer tag push resolves to
`production_environment`, which defaults to `production`. An rc tag does not:
`1.2.3-rc1` is rejected by the same check, so a release candidate cannot reach
production by accident.

**Keep the tag filter above.** A tag that is not bare SemVer resolves to no
environment, and that is a hard error — the run goes **red**, it is not skipped.
That is the right behaviour for a caller who forgot `environment:`, but with
`tags: ['*']` it means every rc tag reports a failure. Either filter the trigger
as shown, or pass `environment:` explicitly.

### 2. A dispatch picks its environment

```yaml
name: deploy
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [staging, production]

jobs:
  deploy:
    uses: nikolareljin/ci-helpers/.github/workflows/cloudflare-deploy.yml@production
    secrets: inherit
    permissions:
      contents: read
    with:
      enabled: ${{ vars.CLOUDFLARE_DEPLOY_ENABLED }}
      environment: ${{ inputs.environment }}
      node_version: "22"
      build_command: "npm run build"
      config_glob: "dist/*/wrangler.json"
```

### 3. Validate on pull requests, deploy from tags

The shape that keeps the token out of pull-request runs entirely.

```yaml
name: worker
on:
  pull_request:
  push:
    tags: ['[0-9]+.[0-9]+.[0-9]+']

jobs:
  build:
    if: ${{ github.event_name == 'pull_request' }}
    uses: nikolareljin/ci-helpers/.github/workflows/cloudflare-build.yml@production
    permissions:
      contents: read
    with:
      node_version: "22"
      build_command: "npm run build"
      config_glob: "dist/*/wrangler.json"

  deploy:
    if: ${{ github.event_name == 'push' }}
    uses: nikolareljin/ci-helpers/.github/workflows/cloudflare-deploy.yml@production
    secrets: inherit
    permissions:
      contents: read
    with:
      enabled: ${{ vars.CLOUDFLARE_DEPLOY_ENABLED }}
      node_version: "22"
      build_command: "npm run build"
      config_glob: "dist/*/wrangler.json"
      smoke_version_path: /api/status
```

The pull-request run writes no `secrets:` line, so no Cloudflare credential is
in scope for it.

### 4. Keep one deploy definition, shared with your laptop

If the repository already has a deploy script — a `./dev deploy`, say — point
`deploy_command` at it. Every gate still runs: the kill switch, the Environment
and its reviewer, the credential preflight, the version string, the smoke test
and the summary. Only the mechanism becomes yours.

```yaml
      deploy_command: ./dev deploy cloudflare --env "$CF_DEPLOY_ENV" --yes
```

The resolved values reach the command as environment variables:

| Variable | Meaning |
|---|---|
| `CLOUDFLARE_API_TOKEN` | the secret |
| `CLOUDFLARE_ACCOUNT_ID` | variable first, secret second, already proven non-empty |
| `CLOUDFLARE_ENV` | the resolved environment — this is **wrangler's own** environment selector, so a command that runs wrangler inherits it |
| `CF_DEPLOY_ENV` | the same value, under a name wrangler does not read |
| `CF_DEPLOY_COMMAND` | `deploy` / `versions upload` / `pages deploy` |
| `CF_DEPLOY_VERSION` | the version string |
| `CF_DEPLOY_REF` | the checked-out ref |
| `CF_DEPLOY_BASE_URL` | the resolved smoke base |
| `CF_DEPLOY_ARGS` | `deploy_args`, verbatim |

This is what stops the version string being defined twice. A script that reads
`CF_DEPLOY_VERSION` when it is set, and computes its own only when it is not,
has one live definition per run — CI's in CI, its own on a laptop.
`script-helpers`' `cloudflare` module does exactly that.

### Cloudflare Pages

Pages is reachable as an input combination, **not** a separate code path. The
Workers lane is the one that has been exercised end to end; this is documented
so it can be used, not claimed to be at parity.

```yaml
    with:
      enabled: ${{ vars.CLOUDFLARE_DEPLOY_ENABLED }}
      environment: staging
      command: "pages deploy"
      wrangler_env: none          # `wrangler pages deploy` rejects --env
      version_var: ""             # and it has no --var either
      build_command: "npm run build"
      deploy_args: "dist --project-name example-site"
```

The token needs **Account → Cloudflare Pages → Edit** instead of the Workers
scope.

### Pushing KV entries or seed data

**This is deliberately not automated, and there is no input for it.** If a
deploy needs to write KV entries, seed a namespace, or upload data alongside the
Worker, do it from your own `deploy_command`. Read this section first — the
failure modes here are quieter than the ones in a deploy.

Why it is not built in:

- **It needs a wider token.** Deploying a Worker needs *Workers Scripts → Edit*.
  Writing KV needs *Workers KV Storage → Edit* as well; binding a namespace does
  not. Folding a data push into a shared workflow would push every consumer
  toward minting the broader token whether or not they write data.
- **It is not one operation.** "Push the data" means something different per
  project — a whole namespace replaced, a few keys upserted, a file uploaded, a
  migration applied. Any input surface general enough to cover that is a shell
  command with extra steps, which is what `deploy_command` already is.
- **It is the step that is hardest to undo.** A Worker deploy is replaced by the
  next deploy. Overwritten data is gone.

Four things to get right, in the order they bite:

1. **Guard it with a string comparison, never a bare truthiness test.** A job
   output is a string, so `if: needs.resolve.outputs.push_data` is true even
   when that output is the literal `"false"` — every non-empty string is truthy.
   A data push guarded that way runs on *every* deploy, tag-driven production
   ones included, and the symptom is silent data loss on a green run. Write
   `== 'true'`, and prefer an enum over a boolean where you can.
2. **Make it idempotent, or make it refuse.** Deploys get re-run: a retried job,
   a re-pushed tag, someone clicking *Re-run all jobs*. A push that appends or
   overwrites unconditionally is a different outcome each time. If it cannot be
   idempotent, have it detect existing data and stop rather than clobber.
3. **It is not part of the deploy's atomicity.** wrangler deploying and your
   data landing are two operations with no shared transaction. Decide which
   order fails better for your service — data first means the new Worker meets
   data it understands; Worker first means old code may meet new data — and
   write the answer down next to the command.
4. **Keep it out of the pull-request lane.** `cloudflare-build.yml` declares no
   secrets precisely so pull requests hold no credential. Do not reach for a
   data push there.

Where it goes:

```yaml
    with:
      enabled: ${{ vars.CLOUDFLARE_DEPLOY_ENABLED }}
      environment: production
      # One command, owned by your repository. Everything the workflow resolved
      # is already in the environment: CLOUDFLARE_API_TOKEN,
      # CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ENV, CF_DEPLOY_VERSION,
      # CF_DEPLOY_CONFIG, CF_DEPLOY_REF.
      deploy_command: ./scripts/deploy-with-data.sh
```

The kill switch, the Environment and its required reviewer, the credential
preflight, the version string, the smoke test and the summary all still run.
Only the mechanism is yours — which is the point: the part that can destroy data
stays in the repository that owns the data, where it is reviewed against that
project's rules rather than a shared workflow's defaults.

### Things worth knowing before you rely on this

- **`deployed` is a string.** `if: needs.deploy.outputs.deployed` is truthy for
  `"false"` too — every non-empty string is. Compare it against `'true'`.
- **`--dry-run` proves less than it looks.** It validates the config and bundles
  the Worker. It does not check bindings, routes, or account access.
- **`npx --yes wrangler@<version>` fetches from npm at deploy time**, which is an
  unpinned-integrity dependency inside an otherwise SHA-pinned toolchain. For
  anything you care about, set `wrangler_command: "pnpm exec wrangler"` so your
  lockfile pins it. The default is convenience, and says so.
- **Set `smoke_version_path`.** Without it the smoke test proves something
  answered, which passes just as happily against the release that was already
  live. The summary says so rather than reporting a clean pass.

## Overriding defaults

Presets forward the pass-through inputs listed at the top of this page, and
most accept the engine's command inputs too. For example, to add Docker and
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
