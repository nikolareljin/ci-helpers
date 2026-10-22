# Windows signing

`windows-sign` and `tauri-release` support three Windows signing modes, plus
`none` (the `tauri-release` default). Each mode is opt-in: nothing is signed
until a caller sets the mode and its secrets.

| Mode | What it signs | Certificate from |
|---|---|---|
| `tauri_updater` | `.sig` files for the Tauri updater (ED25519) | `cargo tauri signer generate`, free |
| `pfx` | MSI and EXE, Authenticode | a `.pfx` you hold: in practice a private CA or self-signed certificate (see below) |
| `azure` | MSI and EXE, Authenticode | Azure Artifact Signing (formerly Trusted Signing) |

Facts on this page were checked against the linked sources on 2026-10-21.
Prices and vendor processes change; the vendor page is the authority.

## Comparison

| | `tauri_updater` | `pfx` (public CA) | `pfx` (private CA / self-signed) | `azure` |
|---|---|---|---|---|
| Cost | free | CA price per year, check the vendor page | free | monthly subscription, see [pricing][az-price] |
| Who can get it | anyone | nobody new: exportable keys ended 2023-06-01, and those certificates have expired (see below) | anyone | organizations in the listed countries; individuals in the US and Canada only ([quickstart][az-quick]) |
| SmartScreen | no effect (not Authenticode) | reputation builds per file and publisher; EV gives no head start since 2024 | warning on every machine that does not trust the CA | reputation builds like OV |
| Key custody | your key file | PFX in a GitHub secret | PFX in a GitHub secret | Microsoft-managed HSM; you never hold the key |
| CI setup effort | low: two secrets | low: two secrets | low, plus deploying the root to client machines | medium: Azure account, identity validation, app registration, six secrets |

## pfx

### What a code-signing certificate is

An Authenticode certificate binds a publisher name, checked by a certificate
authority (CA), to a key. Windows shows that name instead of "Unknown
publisher" and SmartScreen builds reputation for it.

- **OV** (organization validation): the CA checks that the organization
  exists and that the requester works for it.
- **EV** (extended validation): a stricter check. Until 2024 it gave
  immediate SmartScreen reputation. Microsoft removed that: "EV-signed files
  now go through the same reputation-building process as OV certificates"
  ([code signing options][ms-options]; also [SmartScreen reputation][ms-ss]).

### The 2023 hardware-key rule

Since 2023-06-01 the CA/Browser Forum Code Signing Baseline Requirements
require the subscriber's private key to be generated, stored and used in a
hardware crypto module certified to at least FIPS 140-2 Level 2 or Common
Criteria EAL 4+ (sections 6.2.7.4.1 and 6.2.7.4.2, [Code Signing BRs][cabf]).
This applies to OV as well as EV.

So a publicly trusted certificate bought today comes on a USB token, in your
own HSM, or in the CA's cloud HSM, and its key cannot be exported. **A new
public certificate cannot normally be delivered as a `.pfx`**, and pfx mode
cannot use it.

### Paths to a PFX that works in CI

1. **A public certificate issued before 2023-06-01 with an exportable key.**
   This path has closed. Code-signing certificates issued before 2026-03-01
   were valid for at most 39 months (section 6.3.2 of the
   [Code Signing BRs][cabf]; 460 days from that date), so the last ones
   issued before 2023-06-01 expired by 2026-09-01. Signatures already
   timestamped with them stay valid; new signing with them does not.
2. **A private CA or self-signed certificate.** For internal tools, test
   builds, or managed machines where you deploy the root certificate through
   Group Policy or Intune. Machines without that root see an untrusted
   signature. Set `windows_pfx_verify_trust: false` in `tauri-release`
   (`verify_trust: "false"` on `windows-sign`): the runner does not trust
   your root either. Each file is still checked for your certificate's
   signature and a timestamp.
3. **Public trust today: a CA cloud-HSM signing service.** These are not
   pfx mode: the key never leaves the CA. Examples:
   [DigiCert KeyLocker][dc-kl], [SSL.com eSigner][ssl-es],
   [Certum SimplySign][certum-ss], [GlobalSign Digital Signing Service][gs-dss].
   Sectigo issues to a token or your own HSM ([Sectigo code signing][sectigo]).
   ci-helpers has no mode for these. For public trust, use `azure`.

### Where to buy

A publicly trusted certificate bought today has a hardware-bound key, so it
is for a token, an HSM or the CA's cloud signing service (path 3), not for
pfx mode. These are the CAs and their product pages:

| CA | Code-signing product page |
|---|---|
| DigiCert | https://www.digicert.com/signing/code-signing-certificates |
| Sectigo | https://www.sectigo.com/ssl-certificates-tls/code-signing |
| SSL.com | https://www.ssl.com/certificates/code-signing/ |
| GlobalSign | https://www.globalsign.com/en/code-signing-certificate |
| Certum | https://shop.certum.eu/data-safety/code-signing-certificates.html |

Validation, roughly: the CA checks the organization in government
registries and business databases such as Dun & Bradstreet (a D-U-N-S
number helps), screens it against fraud and sanctions lists, and calls a
verified phone number to confirm the requester's authority
([DigiCert OV validation][dc-ov]). Individual certificates need a
government ID. How long it takes depends on the CA and on how current your
public records are; ask the vendor.

### Make the PFX

Pick a password of at least 20 random characters, for example
`openssl rand -base64 30`. Keep it only in the secret store and your password
manager.

**Windows, certificate in the store** (for example one issued by your private
CA):

```powershell
$pw = Read-Host -AsSecureString "PFX password"
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object Subject -like "*Your Org*"
Export-PfxCertificate -Cert $cert -FilePath codesign.pfx -Password $pw -ChainOption BuildChain
```

**Windows, self-signed for testing or internal use** (path 2):

```powershell
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=Your Org Internal" `
  -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(2)
$pw = Read-Host -AsSecureString "PFX password"
Export-PfxCertificate -Cert $cert -FilePath codesign.pfx -Password $pw
Export-Certificate -Cert $cert -FilePath codesign-root.cer   # deploy this to clients
```

**OpenSSL, from a key and certificate** (for example issued by your private
CA):

```bash
openssl pkcs12 -export -inkey codesign.key -in codesign.crt -certfile ca-chain.crt \
  -out codesign.pfx -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256
```

AES-256 with SHA-256 is the OpenSSL 3 default ([openssl-pkcs12][openssl])
and Windows imports it from Windows 10 1709 and Windows Server 2019
([PKCS12 PBES2][ms-pbes2]); `windows-latest` is newer. An older Windows
importer needs `openssl pkcs12 -export -legacy ...` (3DES).

Check the file before storing it:

```bash
openssl pkcs12 -in codesign.pfx -noout -info    # asks for the password
```

### Store it as secrets

```bash
base64 -w0 codesign.pfx > codesign.pfx.b64          # Linux; macOS: base64 -i codesign.pfx
gh secret set WINDOWS_CERTIFICATE < codesign.pfx.b64
gh secret set WINDOWS_CERTIFICATE_PASSWORD           # prompts; nothing in shell history
shred -u codesign.pfx.b64                            # macOS: rm -P codesign.pfx.b64
```

On Windows: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("codesign.pfx")) | Set-Content codesign.pfx.b64`.

Keep the `.pfx` itself offline (password manager or encrypted backup), not
in the repository. Use an environment secret with required reviewers if more
than the release workflow can read repository secrets.

### Timestamping

Each file is timestamped by an RFC 3161 server. The timestamp proves the
signature was made while the certificate was valid, so the signature stays
valid after the certificate expires. Without it, every signed release turns
invalid on the expiry date.

The default is `http://timestamp.digicert.com`
([DigiCert TSA][dc-tsa]). Plain http is fine: the response is signed by the
TSA and checked by signtool. Override it with `timestamp_server`
(`windows_timestamp_server` in `tauri-release`), for example
`http://timestamp.sectigo.com` ([Sectigo TSA][sectigo-tsa]). The action
retries each file 4 times with 2, 4 and 8 second waits, then fails.

### Expiry, renewal, revocation

- The action fails on an expired certificate and warns 30 days before
  expiry.
- Renewing a public certificate gets you a hardware-bound key (see above),
  which pfx mode cannot use: move to `azure`, or to a cloud-HSM service once
  ci-helpers supports one.
- If the PFX or password leaks: ask the CA to revoke the certificate, delete
  both secrets, and rotate. Tell the CA when the key was first exposed.

### Verify a signed file

```powershell
signtool verify /pa /v app-setup.exe
Get-AuthenticodeSignature app-setup.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
```

`signtool verify /pa` uses the default Authenticode policy and fails if the
chain is not trusted ([signtool][signtool]). For a private CA, run it on a
machine that trusts your root. `Get-AuthenticodeSignature` is described in
[its reference][ms-gas].

### Turning pfx on

1. Get a private CA or self-signed certificate (path 2). A publicly trusted
   certificate cannot be had as a PFX today; for public trust use `azure`.
2. Make the PFX and check it with `openssl pkcs12 -info`.
3. Set `WINDOWS_CERTIFICATE` and `WINDOWS_CERTIFICATE_PASSWORD`.
4. In the caller, set `windows_sign_mode: pfx` and pass both secrets:

   ```yaml
   jobs:
     release:
       uses: nikolareljin/ci-helpers/.github/workflows/tauri-release.yml@production
       # The release job creates the GitHub Release and uploads to it.
       permissions:
         contents: write
       with:
         windows_sign_mode: pfx
         # Private CA or self-signed: the runner does not trust the root.
         windows_pfx_verify_trust: false
       secrets:
         WINDOWS_CERTIFICATE: ${{ secrets.WINDOWS_CERTIFICATE }}
         WINDOWS_CERTIFICATE_PASSWORD: ${{ secrets.WINDOWS_CERTIFICATE_PASSWORD }}
   ```

5. Check the first signed release: the `sign-windows` job log shows
   `PFX ok: <subject>` and `ok: <file> signed by ...` per file. Download the
   MSI and setup EXE from the release and run the verify commands above.

Keep `windows_pfx_verify_trust: false` for a private CA or self-signed
certificate, and remove it only for a root the runner trusts: otherwise
`signtool verify /pa` fails. The signer and timestamp are still checked.

Where signing runs: in `tauri-release`'s `sign-windows` job, not in the
build job. The build runs the app's npm and cargo scripts, and anything they
do can change files, `PATH` or `GITHUB_ENV` for every later step of that
job, so a signing step there would hand them the certificate. `sign-windows`
downloads the unsigned installers, checks out only the ci-helpers actions,
runs no app code, and is the only job given the certificate secrets. The PFX
is written to `RUNNER_TEMP` with an owner-only ACL for `signtool /f`, deleted
when the step ends (on failure too), and never imported into a certificate
store.

What is signed: the installers the build job collects, the MSI and the NSIS
setup EXE, found recursively under the downloaded folder; a symbolic
link or junction there is refused. The application EXE inside the installers
is not signed by this step; sign it from Tauri's own
`bundle.windows.signCommand` if you need that. Authenticode changes the file,
so pfx cannot be combined with `tauri_updater` `.sig` files made during the
build.

## azure

Azure Artifact Signing, called Trusted Signing until its rename, is a
Microsoft-managed signing service ([docs][az-docs]). Certificates live a few
days and are renewed by the service; the key never leaves Microsoft's HSM.
Plans are Basic and Premium, with monthly signature quotas; see the
[pricing page][az-price] for the current price.

Eligibility ([quickstart][az-quick]): public-trust certificates for
organizations in the United States, Canada, the European Union, the United
Kingdom, Australia, New Zealand, Japan, South Korea, Singapore, Switzerland,
Norway and Israel; individual developers in the United States or Canada
only. Identity validation takes 1 to 20 business days.

Setup:

1. Azure subscription and Entra tenant. Register the `Microsoft.CodeSigning`
   resource provider.
2. Create an Artifact Signing account in a supported region; note the
   region's endpoint, for example `https://eus.codesigning.azure.net`.
3. With the "Artifact Signing Identity Verifier" role, create an identity
   validation in the portal (not possible from the CLI).
4. Create a Public Trust certificate profile bound to that validation.
5. Create an app registration (service principal) with a client secret, and
   assign it the "Artifact Signing Certificate Profile Signer" role on the
   profile ([assign roles][az-roles]; older pages call it "Trusted Signing
   Certificate Profile Signer").
6. Set the secrets `tauri-release` reads: `AZURE_TENANT_ID`,
   `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TRUSTED_SIGNING_ENDPOINT`,
   `AZURE_CODE_SIGNING_ACCOUNT`, `AZURE_CERT_PROFILE`, and set
   `windows_sign_mode: azure`.

`tauri-release` signs in the `sign-windows` job, away from the build, for
the same reason as pfx (see "Where signing runs" above), and checks that
each installer has a valid, timestamped signature.

ci-helpers authenticates with the client secret; an OIDC federated
credential (no stored secret) is not wired through `tauri-release` yet.

## tauri_updater

The Tauri updater checks an ED25519 signature (`.sig`) on each update bundle
before installing it. It is not Authenticode: Windows, SmartScreen and
`signtool` never see it, and it does not replace `pfx` or `azure`. Generate
the key with `cargo tauri signer generate -w ~/.tauri/myapp.key` and set
`TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.

## Sources

- CA/Browser Forum Code Signing Baseline Requirements, sections 6.2.7.4.1-6.2.7.4.2: https://cabforum.org/working-groups/code-signing/requirements/
- Microsoft, Code signing options for app developers: https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options
- Microsoft, SmartScreen reputation: https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation
- Azure Artifact Signing: https://learn.microsoft.com/azure/artifact-signing/
- Artifact Signing quickstart: https://learn.microsoft.com/azure/artifact-signing/quickstart
- Artifact Signing roles: https://learn.microsoft.com/azure/artifact-signing/tutorial-assign-roles
- Artifact Signing pricing: https://azure.microsoft.com/en-us/pricing/details/artifact-signing/
- SignTool: https://learn.microsoft.com/windows/win32/seccrypto/signtool
- Get-AuthenticodeSignature: https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature
- [ms-pbes2]: PKCS12_PBES2_EXPORT_PARAMS (AES-256 PFX support): https://learn.microsoft.com/windows/win32/api/wincrypt/ns-wincrypt-pkcs12_pbes2_export_params
- openssl-pkcs12: https://docs.openssl.org/3.0/man1/openssl-pkcs12/
- DigiCert RFC 3161 timestamp server: https://knowledge.digicert.com/general-information/rfc3161-compliant-time-stamp-authority-server
- Sectigo timestamping server: https://sectigo.com/resource-library/time-stamping-server
- DigiCert organization validation: https://docs.digicert.com/manage-certificates/organization-domain-management/organization-validation
- DigiCert KeyLocker: https://docs.digicert.com/en/digicert-keylocker.html
- SSL.com eSigner: https://www.ssl.com/esigner/
- Certum code signing in the cloud (SimplySign): https://shop.certum.eu/standard-code-signing-in-the-cloud.html
- GlobalSign Digital Signing Service: https://www.globalsign.com/en/digital-signing-service
- Sectigo code signing: https://www.sectigo.com/ssl-certificates-tls/code-signing

[cabf]: https://cabforum.org/working-groups/code-signing/requirements/
[ms-options]: https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options
[ms-ss]: https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation
[az-docs]: https://learn.microsoft.com/azure/artifact-signing/
[az-quick]: https://learn.microsoft.com/azure/artifact-signing/quickstart
[az-roles]: https://learn.microsoft.com/azure/artifact-signing/tutorial-assign-roles
[az-price]: https://azure.microsoft.com/en-us/pricing/details/artifact-signing/
[signtool]: https://learn.microsoft.com/windows/win32/seccrypto/signtool
[ms-gas]: https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature
[ms-pbes2]: https://learn.microsoft.com/windows/win32/api/wincrypt/ns-wincrypt-pkcs12_pbes2_export_params
[openssl]: https://docs.openssl.org/3.0/man1/openssl-pkcs12/
[dc-tsa]: https://knowledge.digicert.com/general-information/rfc3161-compliant-time-stamp-authority-server
[sectigo-tsa]: https://sectigo.com/resource-library/time-stamping-server
[dc-ov]: https://docs.digicert.com/manage-certificates/organization-domain-management/organization-validation
[dc-kl]: https://docs.digicert.com/en/digicert-keylocker.html
[ssl-es]: https://www.ssl.com/esigner/
[certum-ss]: https://shop.certum.eu/standard-code-signing-in-the-cloud.html
[gs-dss]: https://www.globalsign.com/en/digital-signing-service
[sectigo]: https://www.sectigo.com/ssl-certificates-tls/code-signing
