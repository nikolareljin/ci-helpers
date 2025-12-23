# certs

Self-signed certificate creation and trust-store installation helpers.

Functions
---------

- create_self_signed_certs cert_dir domain
  - Purpose: Create a key and self-signed certificate for the given domain under `cert_dir`.
  - Outputs: `${cert_dir}/${domain}.key` and `${cert_dir}/${domain}.crt` with sane permissions.
  - Dependencies: `openssl`.
  - May use: `sudo` via `run_with_optional_sudo` for directory creation and perms.

- add_cert_to_trust_store cert_file [friendly_name=script-helpers]
  - Purpose: Install a CA certificate into the system trust store.
  - Platform-specific behavior:
    - Linux: tries `update-ca-certificates`, `update-ca-trust`, or `trust anchor`.
    - macOS: uses `security add-trusted-cert` (System keychain).
    - Windows shells: prints PowerShell instructions.
  - Returns: non-zero when unable to install automatically.
  - Note: Most operations require administrative privileges.

Dependencies
------------

- `openssl`; platform trust-store tools (`update-ca-certificates`, `update-ca-trust`, `trust`, `security`).

