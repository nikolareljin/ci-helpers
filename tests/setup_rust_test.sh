#!/usr/bin/env bash
# SCRIPT: setup_rust_test.sh
# DESCRIPTION: scripts/setup_rust.sh asks rustup for the toolchain,
#              components and targets the way the replaced action did,
#              resolves the action's relative forms, writes the cachekey and
#              the cargo environment, and, with no rustup on PATH, installs
#              rustup-init only after its sha256 matches toolchain-pins.env.
#              rustup, rustc and curl are stubs; nothing is downloaded.
# USAGE: bash tests/setup_rust_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/setup_rust.sh"
pins="$root/toolchain-pins.env"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# The shipped pins file: a version and a 64-hex digest per platform.
version="$(awk -F= '$1 == "RUSTUP_VERSION" { print $2 }' "$pins")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL RUSTUP_VERSION is '$version'"; fail=1; }
for t in X86_64_UNKNOWN_LINUX_GNU AARCH64_UNKNOWN_LINUX_GNU X86_64_APPLE_DARWIN AARCH64_APPLE_DARWIN X86_64_PC_WINDOWS_MSVC AARCH64_PC_WINDOWS_MSVC; do
  d="$(awk -F= -v k="RUSTUP_INIT_SHA256_$t" '$1 == k { print $2 }' "$pins")"
  [[ "$d" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL RUSTUP_INIT_SHA256_$t is '$d', not 64 hex"; fail=1; }
done

mkdir -p "$work/stub"
cat > "$work/stub/rustup" <<'STUB'
#!/usr/bin/env bash
printf 'rustup %s\n' "$*" >> "$STUB_LOG"
if [[ "$1 $2" == "toolchain install" && -n "${STUB_INSTALL_FAILS:-}" ]]; then
  echo "error: $STUB_INSTALL_FAILS"
  exit 1
fi
exit 0
STUB
cat > "$work/stub/rustc" <<'STUB'
#!/usr/bin/env bash
printf 'rustc %s\n' "$*" >> "$STUB_LOG"
printf 'rustc %s (abcdef123 2026-01-02)\nbinary: rustc\ncommit-hash: abcdef1234567890abcdef1234567890abcdef12\ncommit-date: 2026-01-02\nhost: x86_64-unknown-linux-gnu\nrelease: %s\nLLVM version: 20.1.0\n' "${STUB_RELEASE:-1.95.0}" "${STUB_RELEASE:-1.95.0}"
STUB
chmod +x "$work/stub/rustup" "$work/stub/rustc"

# run <name> <rc> <toolchain> [components] [targets]
run() {
  local name="$1" want="$2" rc=0
  rm -rf "${work:?}/gh"; mkdir -p "$work/gh"; : > "$work/log"
  PATH="$work/stub:$PATH" STUB_LOG="$work/log" RUST_TOOLCHAIN="$3" RUST_COMPONENTS="${4-}" RUST_TARGETS="${5-}" \
    GITHUB_PATH="$work/gh/path" GITHUB_ENV="$work/gh/env" GITHUB_OUTPUT="$work/gh/out" RUNNER_TEMP="$work" \
    "$BASH" "$script" > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
}
logged() {
  grep -qxF -- "$1" "$work/log" || { echo "FAIL $name: rustup was not asked '$1':"; cat "$work/log"; fail=1; }
}
says() {
  grep -qF -- "$1" "$work/out" || { echo "FAIL $name: no '$1' in output:"; cat "$work/out"; fail=1; }
}

name="stable with components and targets"
if run "$name" 0 stable "rustfmt, clippy" "wasm32-unknown-unknown,x86_64-apple-darwin"; then
  logged "rustup toolchain install stable --target wasm32-unknown-unknown --target x86_64-apple-darwin --component rustfmt --component clippy --profile minimal --no-self-update --force-non-host"
  logged "rustup default stable --force-non-host"
  grep -q "^cachekey=20260102abcd$" "$work/gh/out" || { echo "FAIL $name: cachekey output:"; cat "$work/gh/out"; fail=1; }
  grep -q "^name=stable$" "$work/gh/out" || { echo "FAIL $name: name output"; fail=1; }
  grep -q "^CARGO_INCREMENTAL=0$" "$work/gh/env" || { echo "FAIL $name: CARGO_INCREMENTAL not set"; fail=1; }
  grep -q "^CARGO_TERM_COLOR=always$" "$work/gh/env" || { echo "FAIL $name: CARGO_TERM_COLOR not set"; fail=1; }
  grep -q "^CARGO_HOME=$HOME/.cargo$" "$work/gh/env" || { echo "FAIL $name: CARGO_HOME not set:"; cat "$work/gh/env"; fail=1; }
  grep -q "CARGO_REGISTRIES_CRATES_IO_PROTOCOL\|CARGO_HTTP_MULTIPLEXING" "$work/gh/env" && { echo "FAIL $name: old-release workarounds set for 1.95"; fail=1; }
  [[ -s "$work/gh/path" ]] && { echo "FAIL $name: GITHUB_PATH written though rustup was on PATH"; fail=1; }
fi

name="a job's own cargo environment is kept"
rm -rf "${work:?}/gh"; mkdir -p "$work/gh"; : > "$work/log"
CARGO_INCREMENTAL=1 CARGO_TERM_COLOR=never CARGO_HOME="$work/cargo" PATH="$work/stub:$PATH" STUB_LOG="$work/log" RUST_TOOLCHAIN=stable \
  GITHUB_ENV="$work/gh/env" "$BASH" "$script" > "$work/out" 2>&1 || { echo "FAIL $name: exit $?"; cat "$work/out"; fail=1; }
[[ -s "$work/gh/env" ]] && { echo "FAIL $name: GITHUB_ENV written:"; cat "$work/gh/env"; fail=1; }

name="nightly with components allows a downgrade"
run "$name" 0 nightly clippy && logged "rustup toolchain install nightly --component clippy --allow-downgrade --profile minimal --no-self-update --force-non-host"

name="nightly without components does not"
run "$name" 0 nightly && logged "rustup toolchain install nightly --profile minimal --no-self-update --force-non-host"

name="a dated nightly and a full version pass through"
run "$name" 0 nightly-2026-01-01 && logged "rustup toolchain install nightly-2026-01-01 --profile minimal --no-self-update --force-non-host"
run "$name" 0 1.75.0 && logged "rustup toolchain install 1.75.0 --profile minimal --no-self-update --force-non-host"

name="stable minus N releases"
current=$(( ($(date +%s) / 60 / 60 / 24 - 16569) / 7 / 6 ))
run "$name" 0 "stable minus 2 releases" && logged "rustup toolchain install 1.$((current - 2)) --profile minimal --no-self-update --force-non-host"

name="stable N weeks ago"
then_s=$(( $(date +%s) - 12 * 7 * 24 * 60 * 60 ))
if ! date --date "1 day ago" +%s >/dev/null 2>&1; then
  echo "SKIP $name: this date has no --date"
else run "$name" 0 "stable 12 weeks ago" && logged "rustup toolchain install 1.$(( (then_s / 60 / 60 / 24 - 16569) / 7 / 6 )) --profile minimal --no-self-update --force-non-host"
fi

name="the 1.N shorthand"
run "$name" 0 1.7 && logged "rustup toolchain install 1.70 --profile minimal --no-self-update --force-non-host"
run "$name" 0 1.75 && logged "rustup toolchain install 1.75 --profile minimal --no-self-update --force-non-host"

name="old releases get the registry and curl workarounds"
STUB_RELEASE=1.68.2 run "$name" 0 1.68.2 && { grep -q "^CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse$" "$work/gh/env" || { echo "FAIL $name: sparse not set"; fail=1; }; }
STUB_RELEASE=1.70.0 run "$name" 0 1.70.0 && { grep -q "^CARGO_HTTP_MULTIPLEXING=false$" "$work/gh/env" || { echo "FAIL $name: multiplexing not set"; fail=1; }; }

name="no toolchain"
run "$name" 2 "" && says "RUST_TOOLCHAIN is empty"

name="an install failure that is not a release in progress is final"
if STUB_INSTALL_FAILS="toolchain 'nope' is not installable" run "$name" 1 nope; then
  says "rustup toolchain install nope failed"
  [[ "$(grep -c "toolchain install" "$work/log")" == 1 ]] || { echo "FAIL $name: retried a final failure:"; cat "$work/log"; fail=1; }
fi

name="rustup under CARGO_HOME/bin but not on PATH reaches later steps"
rm -rf "${work:?}/gh" "${work:?}/cargo2"; mkdir -p "$work/gh" "$work/cargo2/bin"; : > "$work/log"
cp "$work/stub/rustup" "$work/stub/rustc" "$work/cargo2/bin/"
rc=0
PATH="${BASH%/*}:/usr/bin:/bin" STUB_LOG="$work/log" CARGO_HOME="$work/cargo2" RUST_TOOLCHAIN=stable \
  GITHUB_PATH="$work/gh/path" GITHUB_ENV="$work/gh/env" GITHUB_OUTPUT="$work/gh/out" \
  "$BASH" "$script" > "$work/out" 2>&1 || rc=$?
if command -v rustup >/dev/null 2>&1 && [[ "$(command -v rustup)" == /usr/bin/* || "$(command -v rustup)" == /bin/* ]]; then
  echo "SKIP $name: rustup is in /usr/bin here"
elif [[ "$rc" != 0 ]]; then
  echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1
else
  grep -qxF "$work/cargo2/bin" "$work/gh/path" 2>/dev/null || { echo "FAIL $name: CARGO_HOME/bin not appended to GITHUB_PATH"; fail=1; }
fi

name="stable N months ago with BSD date (no --date)"
mkdir -p "$work/bsddate"
real_date="$(command -v date)"
cat > "$work/bsddate/date" <<STUB
#!/usr/bin/env bash
case "\$1" in
  --date|-d) exit 1 ;;
  -v*) printf '%s\n' "\$1" >> "\$STUB_LOG"; echo 1767225600 ;;
  *) exec "$real_date" "\$@" ;;
esac
STUB
chmod +x "$work/bsddate/date"
rm -rf "${work:?}/gh"; mkdir -p "$work/gh"; : > "$work/log"
rc=0
PATH="$work/bsddate:$work/stub:$PATH" STUB_LOG="$work/log" RUST_TOOLCHAIN="stable 3 months ago" GITHUB_OUTPUT="$work/gh/out" \
  "$BASH" "$script" > "$work/out" 2>&1 || rc=$?
if [[ "$rc" != 0 ]]; then
  echo "FAIL $name: exit $rc"; cat "$work/out"; fail=1
else
  logged "-v-3m"
  logged "rustup toolchain install 1.92 --profile minimal --no-self-update --force-non-host"
fi

name="a relative toolchain with a date that has neither form is refused"
mkdir -p "$work/nodate"
printf '#!/usr/bin/env bash\nexit 1\n' > "$work/nodate/date"; chmod +x "$work/nodate/date"
rc=0
PATH="$work/nodate:$work/stub:$PATH" STUB_LOG="$work/log" RUST_TOOLCHAIN="stable 3 months ago" \
  "$BASH" "$script" > "$work/out" 2>&1 || rc=$?
[[ "$rc" == 2 ]] || { echo "FAIL $name: exit $rc, expected 2"; cat "$work/out"; fail=1; }
says "takes neither"

# No rustup on PATH: the installer is downloaded (curl is a stub that writes
# a script), checked against the pins, run, and the toolchain installed with
# the rustup it put under CARGO_HOME.
mkdir -p "$work/nocurl"
cat > "$work/installer" <<'INST'
#!/usr/bin/env bash
printf 'rustup-init %s\n' "$*" >> "$STUB_LOG"
mkdir -p "$CARGO_HOME/bin"
cp "$STUB_DIR/rustup" "$STUB_DIR/rustc" "$CARGO_HOME/bin/"
INST
cat > "$work/nocurl/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) [[ "$1" == https://* ]] && printf 'curl %s\n' "$1" >> "$STUB_LOG"; shift ;; esac
done
cp "$STUB_INSTALLER" "$out"
STUB
chmod +x "$work/nocurl/curl"
if command -v sha256sum >/dev/null 2>&1; then
  digest="$(sha256sum < "$work/installer" | awk '{ print $1 }')"
else
  digest="$(shasum -a 256 < "$work/installer" | awk '{ print $1 }')"
fi
triple="$(uname -m | sed 's/amd64/x86_64/; s/arm64/aarch64/')"
case "$(uname -s)" in
  Linux) triple="${triple}-unknown-linux-gnu" ;;
  Darwin) triple="${triple}-apple-darwin" ;;
esac
triple_key="RUSTUP_INIT_SHA256_$(printf '%s' "$triple" | tr '[:lower:]-' '[:upper:]_')"
printf 'RUSTUP_VERSION=1.29.3\n%s=%s\n' "$triple_key" "$digest" > "$work/good-pins.env"
printf 'RUSTUP_VERSION=1.29.3\n%s=%s\n' "$triple_key" "0000000000000000000000000000000000000000000000000000000000000000" > "$work/bad-pins.env"
printf 'RUSTUP_VERSION=1.29.3\n' > "$work/empty-pins.env"

# install_run <name> <rc> <pins>
install_run() {
  local name="$1" want="$2" rc=0
  rm -rf "${work:?}/gh" "${work:?}/cargo"; mkdir -p "$work/gh"; : > "$work/log"
  PATH="$work/nocurl:${BASH%/*}:/usr/bin:/bin" STUB_LOG="$work/log" STUB_DIR="$work/stub" STUB_INSTALLER="$work/installer" \
    CARGO_HOME="$work/cargo" TOOLCHAIN_PINS="$3" RUST_TOOLCHAIN=stable RUNNER_TEMP="$work" \
    GITHUB_PATH="$work/gh/path" GITHUB_ENV="$work/gh/env" GITHUB_OUTPUT="$work/gh/out" \
    "$BASH" "$script" > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
}
if command -v rustup >/dev/null 2>&1 && [[ "$(command -v rustup)" == /usr/bin/* || "$(command -v rustup)" == /bin/* ]]; then
  echo "SKIP the no-rustup cases: rustup is in /usr/bin here"
else
  name="no rustup: the pinned installer runs after its digest matches"
  if install_run "$name" 0 "$work/good-pins.env"; then
    logged "curl https://static.rust-lang.org/rustup/archive/1.29.3/$triple/rustup-init"
    logged "rustup-init --default-toolchain none --profile minimal --no-modify-path -y"
    logged "rustup toolchain install stable --profile minimal --no-self-update --force-non-host"
    says "Verified rustup-init 1.29.3"
    grep -qxF "$work/cargo/bin" "$work/gh/path" || { echo "FAIL $name: CARGO_HOME/bin not appended to GITHUB_PATH:"; cat "$work/gh/path"; fail=1; }
    grep -q "^cachekey=20260102abcd$" "$work/gh/out" || { echo "FAIL $name: no cachekey after install"; fail=1; }
  fi

  name="no rustup: a digest that does not match refuses to run the installer"
  if install_run "$name" 1 "$work/bad-pins.env"; then
    says "Checksum mismatch"
    grep -q "^rustup-init" "$work/log" && { echo "FAIL $name: the installer ran"; fail=1; }
    [[ -e "$work/cargo/bin/rustup" ]] && { echo "FAIL $name: rustup was installed"; fail=1; }
  fi

  name="no rustup: no pin for this platform refuses before downloading"
  if install_run "$name" 2 "$work/empty-pins.env"; then
    says "No 64-hex sha256 pinned"
    grep -q "^curl" "$work/log" && { echo "FAIL $name: downloaded without a pin"; fail=1; }
  fi
fi

[[ "$fail" = 0 ]] && echo "ok: setup_rust drives rustup as the action did, resolves its relative forms, and installs rustup only from a pinned, verified installer"
exit "$fail"
