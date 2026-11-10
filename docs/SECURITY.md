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
`KEPT_THIRD_PARTY` in the same file is the temporary list of third-party
actions still in use, each to be replaced by a first-party step and removed;
nothing is added to it.

To propose an addition: open a pull request that adds the entry to
`ALLOWED_ACTIONS` with its reason in the comment, and, for an action that
handles credentials, the file and job it is bound to. `workflow-yaml-check`
fails on any `uses:` outside the two lists; `tests/scan_egress_test.sh` holds
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
| trusted: reads a `secrets.*` other than `GITHUB_TOKEN`, holds any `write` permission, is needed by such a job, is called by one on a publish chain, or is in a workflow named for release, deploy, publish, sign or submit | none: no `actions/cache`, no `actions/cache/restore`, no BuildKit `type=gha`; every `actions/setup-*` step writes its action's off value (`cache: false` for setup-go and setup-dotnet, `cache: ""` for setup-python and setup-java, `cache: ""` and `package-manager-cache: false` for setup-node), as a missing key is the action's default and setup-go's is on | none |
| plain | anything, the downloaded-archive caches of Flutter and Godot included | `actions/cache/save` two steps after its `actions/cache/restore`, right after the dependency fetch, before any step that runs `inputs.<name>command` |

`actions/cache` itself is used nowhere: its save runs when the job ends.
Release, deploy and publish jobs download every toolchain and dependency on
every run and are slower for it. A plain CI job keeps `setup-*` caches: it
holds no secret and no write token, and nothing it restores reaches a
release. A composite action is held to the trusted rules, as it runs inside
whatever job calls it.
