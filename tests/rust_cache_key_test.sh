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
    GITHUB_OUTPUT="$work/out" bash "$script" > "$work/log" 2>&1 || { echo "FAIL rust_cache_key exited $?:"; cat "$work/log"; fail=1; }
  sed -n 's/^key=//p' "$work/out"
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

k9="$(RUNNER_OS=macOS RUNNER_ARCH=ARM64 GITHUB_JOB=build-macos CARGO_WORKSPACE="$ws" CACHE_KEY_EXTRA="" RUSTC_CACHEKEY=20260102abcd bash "$script" 2>/dev/null | sed -n 's/^key=//p')"
[[ "$k9" == rust-macOS-ARM64-build-macos--20260102abcd-* ]] || { echo "FAIL runner os/arch/job not in key: $k9"; fail=1; }

rc=0; CARGO_WORKSPACE="$ws" RUSTC_CACHEKEY="" bash "$script" > "$work/log" 2>&1 || rc=$?
if ! { [[ "$rc" == 2 ]] && grep -q "RUSTC_CACHEKEY is empty" "$work/log"; }; then echo "FAIL empty rustc key: exit $rc"; cat "$work/log"; fail=1; fi

rc=0; CARGO_WORKSPACE="$work/nowhere" RUSTC_CACHEKEY=abc bash "$script" > "$work/log" 2>&1 || rc=$?
if ! { [[ "$rc" == 2 ]] && grep -q "is not a directory" "$work/log"; }; then echo "FAIL missing workspace: exit $rc"; cat "$work/log"; fail=1; fi

mkdir -p "$work/bare"
rc=0; CARGO_WORKSPACE="$work/bare" RUSTC_CACHEKEY=abc bash "$script" > "$work/log" 2>&1 || rc=$?
if ! { [[ "$rc" == 0 ]] && grep -q "::warning::no Cargo.lock or Cargo.toml" "$work/log"; }; then echo "FAIL a workspace without manifests: exit $rc"; cat "$work/log"; fail=1; fi

# The fixture crate the self-test builds.
rc=0; CARGO_WORKSPACE="$root/tests/fixtures/rust-crate" RUSTC_CACHEKEY=abc bash "$script" > "$work/log" 2>&1 || rc=$?
if ! { [[ "$rc" == 0 ]] && grep -q "^key=rust-" "$work/log"; }; then echo "FAIL on tests/fixtures/rust-crate: exit $rc"; cat "$work/log"; fail=1; fi

[[ "$fail" = 0 ]] && echo "ok: rust_cache_key is deterministic, follows the lockfile and the compiler environment, ignores target/, and refuses bad input"
exit "$fail"
