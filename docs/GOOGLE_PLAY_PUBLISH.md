# Google Play Publishing (Fastlane + GitHub Actions)

This guide documents the **generic** steps required to automate Android publishing using **Fastlane** in GitHub Actions.
It aligns with the Flutter workflows in this repository.

---

## Overview
To automate Google Play uploads you need:

1. **Google Play Console app** (package created)
2. **Service account** with upload permissions
3. **Fastlane lane** in the app repo
4. **GitHub Actions secrets** wired to the reusable workflow

---

## Google Play Console Setup
1) Create an app in Google Play Console.
2) Enable API access and link a Google Cloud project.
3) Create a service account and grant it access to your app.

Dashboard URLs:
```
https://play.google.com/console
https://console.cloud.google.com/iam-admin/serviceaccounts
```

---

## Service Account JSON
Download the JSON key for the service account and store it as a GitHub secret.

Required secret (per workflow):
- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`

---

## Fastlane Lane (app repo)
Example `fastlane/Fastfile` lane:
```
platform :android do
  lane :android_release do
    upload_to_play_store(
      track: "internal",
      aab: "build/app/outputs/bundle/release/app-release.aab"
    )
  end
end
```

---

## GitHub Actions Integration
Use the reusable workflow in `ci-helpers`:

```
jobs:
  android_release:
    uses: nikolareljin/ci-helpers/.github/workflows/flutter-release.yml@production
    with:
      build_android: true
      deploy_google_play: true
      fastlane_android_lane: android_release
      working_directory: "."
    secrets:
      android_keystore_base64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
      android_keystore_password: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
      android_key_alias: ${{ secrets.ANDROID_KEY_ALIAS }}
      android_key_password: ${{ secrets.ANDROID_KEY_PASSWORD }}
      google_play_service_account_json: ${{ secrets.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON }}
```

---

## Troubleshooting

- **Upload fails with 403**: ensure service account has access to the app.
- **Fastlane not found**: ensure Fastlane is installed or use `bundle exec`.
- **Track not found**: verify the release track exists in Play Console.

---

## Security Notes
- Store service account JSON only in GitHub Secrets.
- Avoid committing keys to the repository.
