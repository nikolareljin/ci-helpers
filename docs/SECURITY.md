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
