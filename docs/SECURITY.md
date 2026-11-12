# CI Security Best Practices

This document covers general security practices for using CI workflows in this repository.

## Secrets Handling
- Store secrets in GitHub Actions Secrets (repo or org).
- Never commit keys or credentials to source control.
- Use `::add-mask::` for secrets before use.
- Disable shell tracing (`set +x`) in steps that handle secrets.

## Service Credentials
- Use least-privilege service accounts.
- Rotate keys on a schedule (e.g., every 90 days).
- Revoke keys immediately if leaked.

## Apple App Store Connect
- Use App Store Connect API keys (not user passwords).
- Store .p8 in base64 format in secrets.

## Google Play
- Use a dedicated service account with release permissions.
- Keep JSON key in GitHub Secrets only.

## Fastlane Match
- Store signing assets in a **private** repository.
- Restrict access to the certificate repo.

## Logs & Artifacts
- Avoid printing secrets in logs.
- Do not upload logs that contain secrets.
- Limit artifact retention to what you need.

## Trusted Dependencies
- Pin critical tool versions (Fastlane, Flutter) in CI where possible.
- Review changes to workflows and actions.

## Allowed Actions
A third-party action runs inside the job with the checkout, the job token
and every secret the step is given. This repository keeps one explicit list
of the actions its workflows and actions may run, `ALLOWED_ACTIONS` in
`scripts/check_scan_egress.py`, and refuses every other, however it is
pinned:

| Pattern | Reason | Where |
|---|---|---|
| `actions/*` | GitHub's own actions | anywhere |
| `github/*` | GitHub's own actions (CodeQL) | anywhere |
| `azure/artifact-signing-action` | Microsoft, Azure Artifact Signing, SHA-pinned | `tauri-release.yml`, job `sign-windows` only |

This library's own actions and workflows and local `./` paths need no entry.
No other third-party action runs anywhere.

To propose an addition: open a pull request that adds the entry to
`ALLOWED_ACTIONS` with its reason in the comment, and, for an action that
handles credentials, the file and job it is bound to. `workflow-yaml-check`
fails on any `uses:` outside that list; `tests/scan_egress_test.sh` holds
the gate to that.

## Cache Trust
A cache entry is written by whichever run owned its key first: a default
branch build whose dependency scripts were compromised, or the post-job save
of `actions/cache`, which stores whatever the job left under the path after
every step ran, the caller's build scripts included. The entry is a tar
archive, and restore unpacks it where its members point, not only under the
declared path, so a digest check on the restored file comes too late: the
entry can have overwritten the library checkout or the workspace already. A
job that restores any entry and then signs, pushes or uploads what it built
has put unread content into a release. `scripts/check_cache_trust.py`, run
by `workflow-yaml-check`, holds every workflow and action to this:

| Job | Restore | Save |
|---|---|---|
| trusted: reads a `secrets.*` other than `GITHUB_TOKEN`, names a deployment `environment:`, holds any `write` permission, is needed by such a job, is called by one on a publish chain or runs with a caller's write token (a called job with no `permissions:` in a workflow with none), or is in a workflow named for release, deploy, publish, sign or submit | none: no `actions/cache`, no `actions/cache/restore`, no BuildKit `type=gha` (in a step or in the job's or workflow's `env:`), no `uses:` written as an expression (a third-party cache action such as `astral-sh/setup-uv` or `ruby/setup-ruby` is refused in every job by `scripts/check_scan_egress.py`); every `actions/setup-*` step writes its action's off value (`cache: false` for setup-go and setup-dotnet, `cache: ""` for setup-python and setup-java, `cache: ""` and `package-manager-cache: false` for setup-node), as a missing key is the action's default and setup-go's is on | none |
| plain | anything, the downloaded-archive caches of Flutter and Godot included | `actions/cache/save` two steps after its `actions/cache/restore`, right after the dependency fetch, before any step that runs `inputs.<name>command` (`inputs.install-command` and `inputs['x_command']` included), and after none when the job's or workflow's `env:` carries one |

`actions/cache` itself is used nowhere: its save runs when the job ends.
Release, deploy and publish jobs download every toolchain and dependency on
every run and are slower for it: by the dependency fetch (npm, pip, Maven,
NuGet, Go modules, gems, cargo registry), the toolchain archive (Flutter,
Godot), a full `target/` build for Rust, every Docker layer for
`docker-multiarch.yml`, and a cold `Library` import for `unity.yml`, the
largest of these. That is time and runner minutes on each release, not
on each pull request. A plain CI job keeps `setup-*` caches: it
holds no secret and no write token, and nothing it restores reaches a
release. A composite action is held to the trusted rules, as it runs inside
whatever job calls it.

## Library Isolation

The control is structure: a step that holds a secret or a write token
(registry login, release upload, signing, publishing, a licence) must run in
a job with no caller-controlled step, or before the first one. A caller step
runs as the runner's user and can write `GITHUB_ENV`, `GITHUB_PATH`, the
workspace and `RUNNER_TEMP`, and can leave a process running; nothing inside
the same job is a trust boundary against it. Moving every publish step into
such a job is separate work and not complete yet.

What follows is defence in depth for the library steps that still share a
job with caller code. The control is the second part of this work: publish,
sign and login steps move to jobs with no caller code, and that change
follows this one. A workflow that runs one of the library's scripts
checks the library out at `job.workflow_sha` into `.ci-helpers-scripts` (or
reads `scripts/` from the `.ci-helpers-publication` or `.ci-helpers-actions`
checkout it already has), and the step right after it runs
`scripts/lib_isolate.sh`:

| What | How |
|---|---|
| commit | `git rev-parse HEAD` must equal `job.workflow_sha`, run once by absolute path with `-c core.fsmonitor= -c core.hooksPath=/dev/null` and no user or system config |
| copy | `scripts/`, `toolchain-pins.env` and `scanner-pins.env` go to a fresh `mktemp -d` under `RUNNER_TEMP`; anything other than a regular file or a directory is refused |
| hash | sha256 over every directory path and every file's content and path, recorded as the step output `hash`, with `lib` (the copy) and `pins` (sha256 of `toolchain-pins.env`, for cache keys) |
| mode | files and directories read-only; the job's last step, `if: always()`, makes them writable again so a self-hosted runner can clear its `_temp` |
| checkout | removed from the workspace; kept only with `--keep`, for a checkout that also holds a composite action the job uses next |

Each step that runs library code, the isolate step and the release step
included, has two layers:

- its `env:` sets `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `PS4`,
  `LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, the `DYLD_*` loader
  variables, `PYTHONPATH`, `PYTHONSTARTUP`, `PERL5LIB`, `PERL5OPT`,
  `RUBYOPT`, `NODE_OPTIONS`, `GIT_DIR`, `GIT_CONFIG_PARAMETERS` and
  `GIT_EXEC_PATH` to `""`. A step's `env:` wins over `GITHUB_ENV`, so these
  never reach the shell the runner starts;
- `shell: /bin/sh -e {0}` in a job whose `runs-on` names a Linux or macOS
  runner, so bash's startup handling is not on the path where `sh` is
  dash. The path is absolute because the runner looks a bare `sh` or `bash`
  up on `PATH` with the `GITHUB_PATH` entries first, so a caller could
  supply the shell itself. A job whose `runs-on` is an expression (a
  `runner` input, a matrix) can land on Windows, where `/bin/sh` is not a
  path the runner can start, so it keeps `shell: sh`; a Windows job uses
  `bash`. In those jobs a `GITHUB_PATH` entry can still supply the shell.
  This is a known limit: moving publish, sign and login steps to jobs with
  no caller code closes it;
- `set +xv`, then a refusal when an exported `BASH_FUNC_*` is present (where
  `sh` is bash, on macOS and Git Bash);
- `exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" LANG=C.UTF-8
  NAME="$NAME"... /bin/bash --noprofile --norc`: an allowlist of named
  variables (the step's own `env:` keys and the runner's `GITHUB_*` and
  `RUNNER_*` files and paths), never one that changes bash, the loader,
  Python, Perl or git.

Inside, the step copies the copy to a fresh directory, hashes that with
tools at absolute paths, compares it to `LIB_HASH`, and only then runs a
script from it, as `/bin/bash` or `/usr/bin/python3 -I`. Before the script
runs, `scripts/lib_path.sh` (sourced from the checked copy) gives it the
step's `PATH` back, because toolchains live there, behind a fresh
directory of links to the `/usr/bin` or `/bin` copies of `git`, `gh`,
`curl`, `wget`, `tar`, `gzip`, `xz`, `unzip`, `zip`, `sha256sum`,
`shasum`, `gpg`, `openssl`, `ssh`, `scp`, `docker` and `cosign`, where they
exist. A `GITHUB_PATH` entry can still shadow every other tool (`python3`,
`node`, `php`, `cargo` and the like, which a toolchain step selects there),
and those tools where the system has no copy (`gh` on macOS). A step
that holds a token, password or licence (`github_release.sh`,
`docker_login.sh`, `unity_test.sh`) sources `lib_path.sh secret` instead:
its `PATH` is the links, `/usr/bin` and `/bin` only, and the step's `PATH`
is dropped.

The step that checks a library checkout's commit runs under
`/bin/bash --noprofile --norc -e -o pipefail {0}` (bare `bash` where
`runs-on` is an expression or Windows) with the same blanks
except the `GIT_*` ones (an empty `GIT_DIR` stops git), and runs git as
`"${genv[@]}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$git" -c
core.fsmonitor= -c core.hooksPath=/dev/null -C <checkout> rev-parse HEAD`,
with `git` the first of `/usr/bin/git`, `/mingw64/bin/git.exe`,
`/clangarm64/bin/git.exe` and `/cmd/git.exe` that exists (`env` does not
add `.exe`). `genv` is
`/usr/bin/env -i PATH=/usr/bin:/bin`; under Git Bash, where `git.exe` does
not start without the Windows environment, it is `/usr/bin/env` with each
`GIT_*` variable that points git elsewhere unset.

A composite or node action from a library checkout (`publication-check`,
`publication-guard`, `macos-sign`, `windows-sign` and the scan actions)
runs from the workspace through `uses:`, so it cannot run from the copy.
Instead:

- nothing runs between its checkout and the `uses:` step but the checkout's
  own commit check, isolate and library steps, other actions from that
  checkout, and actions pinned to a commit SHA. Where a workflow step must
  run in between (release notes, staging), the job removes the checkout
  and checks it out and verifies it again right before the action;
- the `uses:` step sets the same blanks as the commit check, so
  `NODE_OPTIONS` or `BASH_ENV` from `GITHUB_ENV` does not reach the action;
- inside each action under `.github/actions`, every step sets those blanks
  too, for a caller that uses the action directly. The Linux and macOS
  actions (`macos-sign`, `trivy-scan`, `wp-plugin-check`,
  `pimcore-bundle-check`) name their shell as `/bin/bash --noprofile
  --norc -e -o pipefail {0}`; the actions callers also run on Windows (the
  gitleaks, foxguard and data-safety scans, `publication-guard`,
  `check-release-tag`, `semver-compare`, `windows-sign`) keep `bash`, or
  `pwsh -NoProfile -NonInteractive`, found on `PATH`. Scripts in the
  action's directory run as `/bin/bash`, and
  `macos-sign` sets `PATH=/usr/bin:/bin:/usr/sbin:/sbin` before it touches
  the certificate.

`scripts/check_lib_isolation.py`, run by `workflow-yaml-check`, fails a
workflow or action that:

- runs a file under a library checkout, or under `$RUNNER_TEMP/ci-helpers-*`,
  other than through the isolate step, or reads one through `env:` or
  `with:` (a pins path, a `hashFiles()` cache key);
- runs the isolate step anywhere but right after its checkout (or right after
  that checkout's `Verify` step), or without the checkout's `if:`;
- reads `$LIB` outside the envelope above, passes a forbidden or renamed
  variable into it, uses the copy before comparing its hash, or runs a
  library script through `PATH`;
- has no `always()` step that releases the read-only copy, or releases it
  under a bare `sh`;
- runs a library step under a bare `sh`, sets `PATH` itself, or runs a
  library script before sourcing `lib_path.sh`;
- runs git on a library checkout other than in the hardened form above, or
  under a bare `bash`, or without the blanks;
- runs a step between a library checkout and an action from it, or uses
  such an action without the blanks; or has a composite step without
  them, under a shell named without its path, or calling `bash` by name;
- runs a step that holds a secret without `lib_path.sh secret`;
- runs git on a library checkout later than the step right after it, or on
  the copy;
- mounts the copy or a checkout into a container (`-v`, `--volume`,
  `--mount`, `container.volumes`).

Not covered here: a caller that uses one of these actions directly runs
it after its own steps, which can rewrite the action's files in
`_actions`; a process a caller step leaves running can still rewrite a
checkout between two steps; where `runs-on` is an expression or Windows,
and in the actions that run on Windows, the shell is found on `PATH` (Git
Bash and pwsh live under `C:\Program Files`, and the runner splits
`shell:` at the first space); on Windows `lib_path.sh` leaves the step's
`PATH` as it is; the post step of `publication-check`
runs from its checkout after every other step. Holding publish steps to a
job without caller code is the next section's gate.

## Privileged Jobs

A job that runs code the caller controls (a `*_command` input, the
caller's build, test or install tooling, `debian/rules`, a Dockerfile, a
local action) holds no write permission, no secret other than
`GITHUB_TOKEN` and no `environment:`. Publishing, signing and deploying
run in a separate job that:

- needs the build job and checks out nothing of the caller's;
- downloads the build job's outputs with `actions/download-artifact`;
- writes the build job's sha256 manifest (a job output) to a file, refuses
  the artifact when its file list differs from the manifest or it holds
  anything but regular files, and runs `sha256sum --check --strict` before
  it uses a file;
- runs only steps from this workflow, at the workflow's commit.

Every value the build job hands over (file names, the `.changes` name, the
version) is caller-chosen data. The privileged job checks each against a
strict pattern before use: `go-deploy` requires `bin_file` to be a plain
name under `bin/`, `ppa-deb` requires every file a `.changes` or `.dsc`
names to be a plain name in the artifact, and `manifest-version` matches
the whole version value, so a second line cannot pass.

The build job stages only regular files: it refuses a symlink and a file that
resolves outside its tree, copies with `cp -P` and checks the staged tree
holds nothing else, so caller code cannot point the artifact at a runner file.
The build job uploads with `retention-days: 1`, under a name that carries
the run id, the attempt and a random suffix, so two calls in one run do not
collide.

`scripts/check_privileged_jobs.py` refuses a job that holds `contents`,
`packages`, `id-token`, `pages`, `deployments`, `attestations` or `actions`
write (or no `permissions:` block, which takes the caller's), a
`secrets.<name>` or an `environment:`, and also runs caller code. It finds
caller code by pattern: a `${{ inputs.<name> }}` ending in `command`,
`cmd`, `script`, `script_path`, `args` or `hook` (plural forms too), any
input used as a command word, a library action handed such an input, a
build, package or install tool as a command word, a script from the
checked-out tree run by a relative path, a dot-directory path or a
workspace path (`$GITHUB_WORKSPACE`, `${{ github.workspace }}`, `$PWD`),
directly or by an interpreter (in a reusable workflow, where that tree is
the caller's; `.ci-helpers-*` library copies excepted), a library script that builds
the caller's tree, or an action that does. Installing a named tool (`dotnet tool install`, `npm install -g`,
`cargo install <crate>`, `go install <path>@<version>`) is not caller code.
A tool the pattern does not know is not seen.

Split: `go-deploy.yml` (`build`, then `deploy` with the SSH key),
`ppa-deb.yml` (`build`, then `ppa` with the GPG and Launchpad keys) and
`manifest-version.yml` (`version`, then `tag-and-dispatch` with the write
token). Each privileged job runs on its own runner input
(`deploy_runner`, `publish_runner`, `tag_runner`, default `ubuntu-latest`):
a reused self-hosted machine can carry state left by the build. The
release workflows (`release-build.yml`, `deb-build.yml`, `rpm-build.yml`,
`go-release.yml`, `rust-release*.yml`, `fpc-release.yml`) already build in
a read-only job. The gate's `PENDING` list names the jobs not yet split,
each with its reason; an entry that passes is itself a finding.

`unity.yml` activates the Unity licence for the caller's test run, so the
licence and the caller's tests share a job; the licence is returned in an
`always()` step after the tests.