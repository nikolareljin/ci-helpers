# Packaging and signing: DEB, PPA, macOS

One way for every repository: the package is defined in the repository
(`debian/`, Tauri config); building and signing happen in these workflows,
which hold the keys in steps that run none of the caller's commands.

| Package | Workflow | Signed with |
|---|---|---|
| `.deb` on a GitHub release | `deb-build.yml` | GPG: `<file>.asc`, `SHA256SUMS`, `SHA256SUMS.asc` |
| Source package on a Launchpad PPA | `ppa-deb.yml` | GPG: `debsign` on the `.changes` |
| macOS `.app`/`.dmg` (Tauri) | `tauri-release.yml` | Developer ID (`macos-sign`), notarized and stapled |

## Names

Use these names in every repository, so one set of values serves all of them
and every caller looks the same. User-owned repositories have no
account-wide secrets: set them per repository.

| Name | Kind | Value |
|---|---|---|
| `GPG_PRIVATE_KEY` | secret | `gpg --armor --export-secret-keys <FINGERPRINT>` |
| `GPG_PASSPHRASE` | secret | the key's passphrase |
| `GPG_KEY_ID` | variable | the 40-character fingerprint |
| `PPA_TARGET` | variable | `ppa:<launchpad-id>/<name>`; unset skips the PPA job |
| `LAUNCHPAD_SSH_PRIVATE_KEY` | secret | only for `upload_method: sftp` |
| `APPLE_CERTIFICATE` | secret | `base64` of the Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | secret | the `.p12` password |
| `APPLE_SIGNING_IDENTITY` | secret | `Developer ID Application: <Name> (<TEAMID>)` |
| `APPLE_TEAM_ID` | secret | 10-character team ID |
| `APPLE_ID` | secret | Apple ID e-mail, for notarization |
| `APPLE_APP_PASSWORD` | secret | app-specific password, for notarization |
| `APPLE_SIGNING_ENABLED` | variable | `true` once the Apple secrets are set |

Nothing fails while the names are unset: `deb-build` publishes unsigned with
a notice, the PPA job is skipped, Tauri builds unsigned. `deb-build` fails when
only one of `GPG_PRIVATE_KEY` and `GPG_KEY_ID` is set, or when `GPG_KEY_ID` is
not a key in `GPG_PRIVATE_KEY`.

## Callers

`.deb` on the release (and a PPA upload when `PPA_TARGET` is set):

```yaml
jobs:
  deb:
    uses: nikolareljin/ci-helpers/.github/workflows/deb-build.yml@production
    permissions:
      contents: write
    with:
      signing_key_id: ${{ vars.GPG_KEY_ID }}
    secrets:
      gpg_private_key: ${{ secrets.GPG_PRIVATE_KEY }}
      gpg_passphrase: ${{ secrets.GPG_PASSPHRASE }}

  ppa:
    if: ${{ vars.PPA_TARGET != '' }}
    uses: nikolareljin/ci-helpers/.github/workflows/ppa-deb.yml@production
    permissions:
      contents: read
    with:
      ppa_target: ${{ vars.PPA_TARGET }}
      signing_key_id: ${{ vars.GPG_KEY_ID }}
    secrets:
      gpg_private_key: ${{ secrets.GPG_PRIVATE_KEY }}
      gpg_passphrase: ${{ secrets.GPG_PASSPHRASE }}
```

The PPA upload is anonymous FTP by default; Launchpad accepts it on the
signature. For SFTP add `upload_method: sftp` and
`launchpad_ssh_private_key: ${{ secrets.LAUNCHPAD_SSH_PRIVATE_KEY }}`.

Launchpad builds the binary packages from the source package with no network,
so `debian/` must build offline: vendor Go modules or Rust crates into the
source package, or publish only the `.deb` from `deb-build`.

macOS (Tauri):

```yaml
jobs:
  release:
    uses: nikolareljin/ci-helpers/.github/workflows/tauri-release.yml@production
    permissions:
      contents: write
    with:
      sign_macos: ${{ vars.APPLE_SIGNING_ENABLED == 'true' }}
      notarize_macos: ${{ vars.APPLE_SIGNING_ENABLED == 'true' }}
    secrets:
      APPLE_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE }}
      APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
      APPLE_SIGNING_IDENTITY: ${{ secrets.APPLE_SIGNING_IDENTITY }}
      APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
      APPLE_ID: ${{ secrets.APPLE_ID }}
      APPLE_APP_PASSWORD: ${{ secrets.APPLE_APP_PASSWORD }}
```

Do not call `codesign`, `notarytool` or `gpg` in the repository's own
workflows: a key in a job that also runs the build is readable by every
dependency the build installs.

## Republishing a release

Re-running `deb-build` for a version that is already released:

| Published package | Same sha256 | Different sha256 |
|---|---|---|
| unsigned | kept | replaced, with a warning |
| signed (`<file>.asc`, or listed in a signed `SHA256SUMS`) | kept | run fails |

A signed package may already be installed and verified by users, so a fix
goes out as a new version. To replace it in place anyway, delete the package,
its `.asc`, `SHA256SUMS` and `SHA256SUMS.asc` from the release by hand, then
re-run. Characters GitHub renames in an asset name (`~`, `+`, `:`) are published
as `.`, so `SHA256SUMS` and the rerun check match the names on the release. An unsigned release rebuilt with signing on gets the new packages,
their `.asc` files and a signed `SHA256SUMS`; from then on it is protected.

## Verifying a download

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS
spctl -a -vvv -t install App.dmg      # macOS: "source=Notarized Developer ID"
```
