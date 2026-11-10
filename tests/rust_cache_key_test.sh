#!/usr/bin/env bash
# SCRIPT: rust_cache_key_test.sh
# DESCRIPTION: scripts/rust_cache_key.sh writes a deterministic actions/cache
#              key from the runner, job, label, rustc key and a hash of the
#              workspace's cargo manifests and compiler environment; the key
#              moves with Cargo.lock and RUSTFLAGS, not with target/; the
#              restore key is the prefix without the hash; bad input refuses.
# USAGE: bash tests/rust_cache_key_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/rust_cache_key.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

ws="$work/ws"
mkdir -p "$ws/src" "$ws/target/debug" "$ws/member/.cargo"
printf '[package]\nname = "x"\nversion = "0.1.0"\n' > "$ws/Cargo.toml"
printf '# lock v1\n' > "$ws/Cargo.lock"
printf 'fn main() {}\n' > "$ws/src/main.rs"
printf '[build]\n' > "$ws/member/.cargo/config.toml"
printf '# a stale lockfile cargo copied into target\n' > "$ws/target/Cargo.lock"

# key <extra> -> prints key; env RUNNER_OS etc. fixed so the test is the same anywhere
key() {
  rm -f "$work/out"
  RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_JOB=build CARGO_WORKSPACE="$ws" CACHE_KEY_EXTRA="$1" RUSTC_CACHEKEY=20260102abcd \
    GITHUB_OUTPUT="$work/out" "$BASH" "$script" > "$work/log" 2>&1 || { echo "FAIL rust_cache_key exited $?:"; cat "$work/log"; fail=1; }
  if [[ -f "$work/out" ]]; then sed -n 's/^key=//p' "$work/out"; fi
}

k1="$(key ubuntu-24.04)"
k2="$(key ubuntu-24.04)"
[[ "$k1" == "$k2" ]] || { echo "FAIL two runs differ: $k1 vs $k2"; fail=1; }
[[ "$k1" =~ ^rust-Linux-X64-build-ubuntu-24\.04-20260102abcd-[0-9a-f]{16}$ ]] || { echo "FAIL key shape: $k1"; fail=1; }
restore="$(sed -n 's/^restore_key=//p' "$work/out")"
[[ "$restore" == "rust-Linux-X64-build-ubuntu-24.04-20260102abcd-" && "$k1" == "$restore"* ]] || { echo "FAIL restore key '$restore' is not the prefix of '$k1'"; fail=1; }
if ! { grep -q "./Cargo.lock" "$work/log" && grep -q "./member/.cargo/config.toml" "$work/log"; }; then echo "FAIL the hashed files are not listed:"; cat "$work/log"; fail=1; fi
grep -q "target/Cargo.lock" "$work/log" && { echo "FAIL a file under target/ was hashed"; fail=1; }

printf 'built\n' > "$ws/target/debug/x"
k3="$(key ubuntu-24.04)"
[[ "$k3" == "$k1" ]] || { echo "FAIL target/ contents moved the key"; fail=1; }

printf '# lock v2\n' > "$ws/Cargo.lock"
k4="$(key ubuntu-24.04)"
[[ "$k4" != "$k1" ]] || { echo "FAIL Cargo.lock change kept the key"; fail=1; }
[[ "$k4" == "$restore"* ]] || { echo "FAIL the restore key no longer matches after a lockfile change"; fail=1; }

k5="$(RUSTFLAGS="-C target-cpu=native" key ubuntu-24.04)"
[[ "$k5" != "$k4" ]] || { echo "FAIL RUSTFLAGS change kept the key"; fail=1; }

k6="$(key ubuntu-22.04)"
[[ "$k6" != "$k4" ]] || { echo "FAIL the runner label is not in the key"; fail=1; }

k7="$(key "self-hosted, linux x64")"
[[ "$k7" =~ ^rust-Linux-X64-build-self-hosted__linux_x64-20260102abcd-[0-9a-f]{16}$ ]] || { echo "FAIL label not sanitised: $k7"; fail=1; }

k8="$(key "")"
[[ "$k8" =~ ^rust-Linux-X64-build--20260102abcd-[0-9a-f]{16}$ ]] || { echo "FAIL empty label: $k8"; fail=1; }

k9="$(RUNNER_OS=macOS RUNNER_ARCH=ARM64 GITHUB_JOB=build-macos CARGO_WORKSPACE="$ws" CACHE_KEY_EXTRA="" RUSTC_CACHEKEY=20260102abcd "$BASH" "$script" 2>/dev/null | sed -n 's/^key=//p')"
[[ "$k9" == rust-macOS-ARM64-build-macos--20260102abcd-* ]] || { echo "FAIL runner os/arch/job not in key: $k9"; fail=1; }

rc=0; CARGO_WORKSPACE="$ws" RUSTC_CACHEKEY="" "$BASH" "$script" > "$work/log" 2>&1 || rc=$?
if ! { [[ "$rc" == 2 ]] && grep -q "RUSTC_CACHEKEY is empty" "$work/log"; }; then echo "FAIL empty rustc key: exit $rc"; cat "$work/log"; fail=1; fi

rc=0; CARGO_WORKSPACE="$work/nowhere" RUSTC_CACHEKEY=abc "$BASH" "$script" > "$work/log" 2>&1 || rc=$?
if ! { [[ "$rc" == 2 ]] && grep -q "is not a directory" "$work/log"; }; then echo "FAIL missing workspace: exit $rc"; cat "$work/log"; fail=1; fi

mkdir -p "$work/bare"
rc=0; CARGO_WORKSPACE="$work/bare" RUSTC_CACHEKEY=abc "$BASH" "$script" > "$work/log" 2>&1 || rc=$?
if ! { [[ "$rc" == 0 ]] && grep -q "::warning::no Cargo.lock or Cargo.toml" "$work/log"; }; then echo "FAIL a workspace without manifests: exit $rc"; cat "$work/log"; fail=1; fi

# The fixture crate the self-test builds.
rc=0; CARGO_WORKSPACE="$root/tests/fixtures/rust-crate" RUSTC_CACHEKEY=abc "$BASH" "$script" > "$work/log" 2>&1 || rc=$?
if ! { [[ "$rc" == 0 ]] && grep -q "^key=rust-" "$work/log"; }; then echo "FAIL on tests/fixtures/rust-crate: exit $rc"; cat "$work/log"; fail=1; fi

# A registry token or other credential in the CARGO* environment is not
# hashed (rotating it would churn the cache) and never printed.
t1="$(CARGO_REGISTRIES_PRIVATE_TOKEN=tok-one-secret CARGO_REGISTRY_TOKEN=tok-a key ubuntu-24.04)"
cp "$work/log" "$work/log-token"
t2="$(CARGO_REGISTRIES_PRIVATE_TOKEN=tok-two-secret CARGO_REGISTRY_TOKEN=tok-b CARGO_REGISTRIES_X_CREDENTIAL_PROVIDER=cargo:token key ubuntu-24.04)"
[[ "$t1" == "$k4" && "$t2" == "$k4" ]] || { echo "FAIL a token in the environment moved the key: $k4 / $t1 / $t2"; fail=1; }
grep -q "tok-" "$work/log-token" "$work/log" "$work/out" && { echo "FAIL a token value was printed"; fail=1; }

# Only build-affecting variables are hashed; anything else, a proxy URL or a
# key included, leaves the key alone.
base="$(key ubuntu-24.04)"
for v in CARGO_HTTP_PROXY CARGO_REGISTRIES_X_AUTH CC_AWS_ACCESS_KEY_ID RUSTC_WRAPPER_KEY CARGO_HTTP_PROXY_PASS \
         CARGO_REGISTRIES_X_TOKEN CARGO_BUILD_TOKEN CARGO_PROFILE_RELEASE_SECRET CARGO_TERM_COLOR CARGO_HOME \
         CC_GITHUB_PAT CFLAGS_DB_PW CARGO_BUILD_RUSTC_WRAPPER_PW CARGO_BUILD_FOO CARGO_PROFILE_RELEASE_FOO CC_foo \
         CARGO_TARGET_FOO_LINKER CARGO_PROFILE_RELEASE_LTO_PWD; do
  a="$(export "$v=one"; key ubuntu-24.04)"
  b="$(export "$v=two"; key ubuntu-24.04)"
  [[ "$a" == "$base" && "$b" == "$base" ]] || { echo "FAIL $v moved the key"; fail=1; }
done
for v in RUSTFLAGS RUSTDOCFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_INCREMENTAL CARGO_PROFILE_RELEASE_LTO CARGO_BUILD_TARGET \
         CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS \
         CC CXX AR CFLAGS CFLAGS_x86_64_unknown_linux_gnu CFLAGS_aarch64_apple_darwin CC_x86_64_unknown_linux_gnu \
         TARGET_CC HOST_CC TARGET_CFLAGS HOST_CFLAGS CARGO_PROFILE_DEV_OPT_LEVEL CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_OPT_LEVEL \
         CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS CXXFLAGS LDFLAGS CMAKE_GENERATOR CMAKE_BUILD_TYPE \
         CMAKE_TOOLCHAIN_FILE RUSTC RUSTC_WRAPPER RUSTUP_TOOLCHAIN; do
  a="$(export "$v=one"; key ubuntu-24.04)"
  b="$(export "$v=two"; key ubuntu-24.04)"
  [[ "$a" != "$b" ]] || { echo "FAIL $v did not move the key"; fail=1; }
done

# No sha256sum (macOS): shasum gives the same key.
mkdir -p "$work/noshasum"
for d in /usr/local/bin /usr/bin /bin; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    b="${f##*/}"
    [[ "$b" == sha256sum || "$b" == shasum || -e "$work/noshasum/$b" || -L "$work/noshasum/$b" ]] && continue
    ln -s "$f" "$work/noshasum/$b"
  done
done
real_sha="$(command -v sha256sum)"
printf '#!/bin/sh\n[ "$1 $2" = "-a 256" ] || exit 9\nexec %s\n' "$real_sha" > "$work/noshasum/shasum"
chmod +x "$work/noshasum/shasum"
ks="$(PATH="$work/noshasum" key ubuntu-24.04)"
[[ "$ks" == "$k4" ]] || { echo "FAIL the shasum path gives '$ks', not '$k4'"; cat "$work/log"; fail=1; }

[[ "$fail" = 0 ]] && echo "ok: rust_cache_key is deterministic, follows the lockfile and the compiler environment, ignores target/, and refuses bad input"
exit "$fail"
