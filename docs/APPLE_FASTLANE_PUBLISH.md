# Apple App Store Publishing (Fastlane + GitHub Actions)

This guide documents the **generic** steps required to automate iOS signing and App Store uploads using **Fastlane** in GitHub Actions.
It is designed for public CI libraries and does not contain any project‑specific values.

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
- **Manual signing with pre‑generated certificates**

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

## Option B: Manual signing (non‑Match)

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
```
base64 -i AuthKey_ABC123.p8 | pbcopy
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
      build_ios: true
      deploy_app_store: true
      fastlane_ios_lane: ios_release
      working_directory: "."
      runner: macos-latest
    secrets:
      app_store_connect_api_key_base64: ${{ secrets.APP_STORE_CONNECT_API_KEY_BASE64 }}
      app_store_connect_key_id: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
      app_store_connect_issuer_id: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
```

> App Store uploads require a **macOS runner**.

---

## Fastlane Files Required (app repo)
- `fastlane/Fastfile`
- `fastlane/Appfile` (with bundle ID and team ID)
- Optional `Gemfile` if you want pinned Fastlane

Example `fastlane/Appfile`:
```
app_identifier("com.example.app")
team_id("XXXXXXXXXX")
```

## Workflow Alignment (ci-helpers)
This repository ships a reusable Flutter workflow:
- `.github/workflows/flutter-release.yml`

That workflow:
- Builds Android/iOS artifacts
- Can deploy to App Store and Google Play using Fastlane
- Requires a macOS runner for iOS uploads

Inputs for App Store deploy:
- `deploy_app_store: true`
- `fastlane_ios_lane` (defaults to `ios_release`)

Secrets for App Store deploy:
- `APP_STORE_CONNECT_API_KEY_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

---

## Troubleshooting

**Upload fails: Invalid Signature**
- Verify cert/provisioning profile match the bundle ID
- Ensure correct Team ID in Appfile

**App Store Connect auth error**
- Verify Key ID / Issuer ID
- Verify .p8 file is correct and base64 encoded

**Fastlane not found**
- Ensure `bundle exec fastlane` or `gem install fastlane` is used

---

## Security Notes
- Store API key and certificates only in CI secrets.
- Keep Match repo private.
- Rotate keys annually or after staff changes.
