#!/usr/bin/env bash
# SCRIPT: rust_cache_key.sh
# DESCRIPTION: The actions/cache key for a cargo workspace, shaped like the
#              key of the cache action this replaces: runner OS and
#              architecture, the job id, an extra label, the rustc cache key
#              from setup_rust.sh, and a hash of every Cargo.lock, Cargo.toml,
#              rust-toolchain, rust-toolchain.toml and .cargo/config[.toml]
#              under the workspace (target/ excluded) plus the CARGO*, CC*,
#              build-affecting environment on an allowlist (RUSTFLAGS,
#              CARGO_PROFILE_*, CARGO_BUILD_*, CC, CFLAGS, ...; see `allow`),
#              less any name holding a secret word. The restore key
#              is the same without the hash, so a lockfile change still
#              restores the previous dependencies.
# USAGE: RUSTC_CACHEKEY=<from setup_rust.sh> bash scripts/rust_cache_key.sh
# ENVIRONMENT:
#   CARGO_WORKSPACE  Workspace directory (default: .).
#   CACHE_KEY_EXTRA  Extra label, e.g. the runner label (optional).
#   RUSTC_CACHEKEY   The cachekey output of setup_rust.sh (required).
#   GITHUB_JOB, RUNNER_OS, RUNNER_ARCH  Set by the runner; `local` when unset.
#   GITHUB_OUTPUT    Written when set.
# OUTPUT: key=<key> and restore_key=<prefix>, on stdout and, when
#         GITHUB_OUTPUT is set, appended there.
# EXIT CODES:
#   0  Key written.
#   2  RUSTC_CACHEKEY empty or the workspace is not a directory.
# ----------------------------------------------------
set -euo pipefail

workspace="${CARGO_WORKSPACE:-.}"
extra="${CACHE_KEY_EXTRA:-}"
rustc_key="${RUSTC_CACHEKEY:-}"

[[ -n "$rustc_key" ]] || { echo "::error::RUSTC_CACHEKEY is empty; run setup_rust.sh first and pass its cachekey output." >&2; exit 2; }
[[ -d "$workspace" ]] || { echo "::error::CARGO_WORKSPACE '$workspace' is not a directory." >&2; exit 2; }

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    echo "::error::Neither sha256sum nor shasum is available." >&2
    exit 1
  fi
}

# A cache key takes letters, digits, dot, underscore and dash; anything else
# in a label (a space, a comma from a label list) becomes an underscore.
clean() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Build-affecting variables, by exact name or a closed pattern: no open
# prefix, so a name nobody listed (CC_GITHUB_PAT) is never hashed.
arch='(x86_64|aarch64|i686|i586|armv7|arm|thumbv7em|riscv64gc|riscv32imac|wasm32|powerpc64le|s390x|loongarch64)'
arch_uc='(X86_64|AARCH64|I686|I586|ARMV7|ARM|THUMBV7EM|RISCV64GC|RISCV32IMAC|WASM32|POWERPC64LE|S390X|LOONGARCH64)'
pkey='(OPT_LEVEL|DEBUG|SPLIT_DEBUGINFO|STRIP|DEBUG_ASSERTIONS|OVERFLOW_CHECKS|LTO|PANIC|INCREMENTAL|CODEGEN_UNITS|RPATH)'
allow='RUSTFLAGS|RUSTDOCFLAGS|CARGO_ENCODED_RUSTFLAGS|CARGO_ENCODED_RUSTDOCFLAGS|CARGO_INCREMENTAL'
allow="$allow|CARGO_BUILD_(TARGET|RUSTFLAGS|RUSTDOCFLAGS|INCREMENTAL|RUSTC|RUSTC_WRAPPER|RUSTC_WORKSPACE_WRAPPER)"
allow="$allow|CARGO_PROFILE_[A-Z0-9]+(_BUILD_OVERRIDE)?_$pkey"
allow="$allow|CARGO_TARGET_${arch_uc}_[A-Z0-9_]+_(LINKER|RUNNER|RUSTFLAGS)"
allow="$allow|(CC|CXX|AR|CFLAGS|CXXFLAGS|LDFLAGS)(_${arch}_[a-z0-9_]+)?|(TARGET|HOST)_(CC|CXX|AR|CFLAGS|CXXFLAGS)"
allow="$allow|CMAKE_GENERATOR|CMAKE_BUILD_TYPE|CMAKE_TOOLCHAIN_FILE|RUSTC|RUSTC_WRAPPER|RUSTUP_TOOLCHAIN"

files="$(cd "$workspace" && find . \( -name target -prune \) -o -type f \( \
    -name Cargo.lock -o -name Cargo.toml -o -name rust-toolchain -o -name rust-toolchain.toml \
    -o -path '*/.cargo/config.toml' -o -path '*/.cargo/config' \) -print | LC_ALL=C sort)"

hash="$(
  {
    if [[ -n "$files" ]]; then
      printf '%s\n' "$files" | while IFS= read -r f; do
        printf '%s  %s\n' "$(sha256_stdin < "$workspace/$f")" "$f"
      done
    fi
    # An allowlist of what changes build output; nothing else is hashed, so
    # a proxy URL, a registry token or any other secret never reaches a key.
    # The secret-word exclusion is kept on top of it.
    env | LC_ALL=C grep -E "^(${allow})=" \
      | LC_ALL=C grep -Ev '^[A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|PASS|PWD|PW|PAT|CREDENTIAL|AUTH|KEY|PROXY)[A-Za-z0-9_]*=' \
      | LC_ALL=C sort || true
  } | sha256_stdin | head -c16
)"

prefix="rust-$(clean "${RUNNER_OS:-local}")-$(clean "${RUNNER_ARCH:-local}")-$(clean "${GITHUB_JOB:-local}")-$(clean "$extra")-$(clean "$rustc_key")-"
key="${prefix}${hash}"

if [[ -n "$files" ]]; then
  printf 'hashed in %s:\n%s\n' "$workspace" "$files"
else
  echo "::warning::no Cargo.lock or Cargo.toml under $workspace; the cache key depends on the environment only"
fi
printf 'key=%s\nrestore_key=%s\n' "$key" "$prefix"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'key=%s\nrestore_key=%s\n' "$key" "$prefix" >> "$GITHUB_OUTPUT"
fi
