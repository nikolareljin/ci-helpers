# Apple App Store Publishing (Fastlane + GitHub Actions)

This guide documents the **generic** steps required to automate iOS signing and App Store uploads using **Fastlane** in GitHub Actions.
It is designed for public CI libraries and does not contain any project-specific values.

> Requirements: Apple Developer Program membership and App Store Connect access.

---

## Overview
You need four things to fully automate iOS publishing:

1. **Signing assets** (certificates + provisioning profiles)
2. **App Store Connect API access** (for CI upload)
3. **Fastlane lanes** to build and upload
4. **GitHub Actions secrets** wired to the reusable workflow

There are two common approaches to signing:

- **Fastlane Match (recommended for CI)**
- **Manual signing with pre-generated certificates**

---

## Option A: Fastlane Match (recommended)

### 1) Create App Store Connect API Key
In App Store Connect → Users and Access → Keys:

- Create a new API key
- Save:
  - Key ID
  - Issuer ID
  - `.p8` private key file

### 2) Create a private cert repository
Fastlane Match stores certs + profiles in a private git repo.

Example:
```
match_repo: git@github.com:your-org/ios-certificates.git
```

### 3) Add Fastlane config
Example `fastlane/Matchfile`:
```
git_url("git@github.com:your-org/ios-certificates.git")
storage_mode("git")
app_identifier(["com.example.app"])
type("appstore")
```

Example `fastlane/Fastfile` lane:
```
platform :ios do
  lane :ios_release do
    match(type: "appstore")
    build_app(scheme: "Runner")
    upload_to_app_store(skip_metadata: true, skip_screenshots: true)
  end
end
```

---

## Option B: Manual signing (non-Match)

1. Create an **iOS Distribution Certificate**
2. Create an **App Store Provisioning Profile**
3. Export a **.p12** and install it in CI
4. Configure Xcode build settings to use manual signing

This is harder to maintain than Match in CI.

---

## GitHub Actions Secrets

The reusable Flutter workflow expects the following secrets:

- `APP_STORE_CONNECT_API_KEY_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

**How to create APP_STORE_CONNECT_API_KEY_BASE64**:
```bash
# macOS: base64-encode and copy to clipboard
base64 -i AuthKey_ABC123.p8 | pbcopy

# Linux: base64-encode (copy from terminal or pipe to xclip)
base64 -w0 AuthKey_ABC123.p8 | xclip -selection clipboard
# or, without xclip:
# base64 -w0 AuthKey_ABC123.p8
```

Dashboard URLs:
```
https://appstoreconnect.apple.com/access/api
https://developer.apple.com/account/resources/certificates/list
```

---

## GitHub Actions Integration

Use the reusable workflow in `ci-helpers`:

```
jobs:
  ios_release:
    uses: nikolareljin/ci-helpers/.github/workflows/flutter-release.yml@production
    with:
      build_android: false
      deploy_app_store: true
      ios_bundle_id: com.example.app
      ios_team_id: XXXXXXXXXX
      working_directory: "."
      runner: macos-latest
    secrets:
      app_store_connect_api_key_base64: ${{ secrets.APP_STORE_CONNECT_API_KEY_BASE64 }}
      app_store_connect_key_id: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
      app_store_connect_issuer_id: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
      match_git_url: ${{ secrets.MATCH_GIT_URL }}
      match_password: ${{ secrets.MATCH_PASSWORD }}
      match_git_basic_authorization: ${{ secrets.MATCH_GIT_BASIC_AUTHORIZATION }}
```

> App Store uploads require a **macOS runner**.

---

## Fastlane Files (app repo, local use only)
`flutter-release.yml` reads none of these: the bundle id and team id come
from `ios_bundle_id` and `ios_team_id`. They are still useful from a
workstation:

- `fastlane/Fastfile`
- `fastlane/Appfile` (with bundle ID and team ID)

Example `fastlane/Appfile`:
```
app_identifier("com.example.app")
team_id("XXXXXXXXXX")
```

## Workflow Alignment (ci-helpers)
This repository ships a reusable Flutter workflow:

- `.github/workflows/flutter-release.yml`

That workflow:

- Builds Android/iOS artifacts with no secret on the runner
- Builds an unsigned `.xcarchive` (`ios_archive_command`) for an App Store
  upload; the `upload-app-store` job fetches the App Store certificate and
  profile with `fastlane match appstore --readonly`, exports and signs the
  IPA with `xcodebuild -exportArchive`, and uploads it with `fastlane pilot
  upload` (TestFlight) or `fastlane deliver`, all with the fastlane version
  pinned in the library, from an empty directory
- Requires a macOS runner for iOS builds and uploads

Inputs for App Store deploy:

- `deploy_app_store: true`
- `ios_bundle_id`, `ios_team_id`
- `app_store_destination` (`testflight`, the default, or `app_store`)

Secrets for App Store deploy:

- `APP_STORE_CONNECT_API_KEY_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `MATCH_GIT_URL`, `MATCH_PASSWORD` (and `MATCH_GIT_BASIC_AUTHORIZATION` for a private repository)

The profile name must be match's default, `match AppStore <bundle id>`. An
app with extensions (more than one bundle id) is not supported.

---

## Troubleshooting

**Upload fails: Invalid Signature**

- Verify cert/provisioning profile match the bundle ID
- Ensure correct Team ID in Appfile

**App Store Connect auth error**

- Verify Key ID / Issuer ID
- Verify .p8 file is correct and base64 encoded

---

## Security Notes
- Store API key and certificates only in CI secrets.
- Keep Match repo private.
- Rotate keys annually or after staff changes.
