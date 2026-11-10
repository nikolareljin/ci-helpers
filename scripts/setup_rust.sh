#!/usr/bin/env bash
# SCRIPT: setup_rust.sh
# DESCRIPTION: Install a Rust toolchain with the rustup the runner ships, so a
#              workflow runs no third-party action for it. A runner without
#              rustup gets the rustup-init pinned by version and sha256 in
#              toolchain-pins.env, checked before it runs. The toolchain
#              specification, components and targets are read as the action
#              this replaces read them: `stable`, `nightly`, `beta`,
#              `1.75.0`, `1.75`, `nightly-2026-01-01`, `stable minus 2
#              releases`, `stable 3 months ago`; components and targets
#              separated by commas or whitespace.
# USAGE: RUST_TOOLCHAIN=stable bash scripts/setup_rust.sh
# ENVIRONMENT:
#   RUST_TOOLCHAIN   Toolchain specification (required).
#   RUST_COMPONENTS  Components to add, e.g. "rustfmt, clippy" (optional).
#   RUST_TARGETS     Target triples to add (optional).
#   TOOLCHAIN_PINS   Pins file (default: toolchain-pins.env beside scripts/).
#   RUNNER_TEMP      Where a rustup-init download goes (default: mktemp -d).
#   GITHUB_PATH, GITHUB_ENV, GITHUB_OUTPUT  Written when set.
# OUTPUT: cachekey=<12 hex from the rustc commit date and hash> and
#         name=<toolchain as resolved>, on stdout and, when GITHUB_OUTPUT is
#         set, appended there. GITHUB_ENV gets CARGO_HOME, CARGO_INCREMENTAL=0
#         and CARGO_TERM_COLOR=always when the job has not set them.
# EXIT CODES:
#   0  The toolchain is installed and is the default.
#   1  rustup-init download or checksum failed, or rustup could not install.
#   2  Usage error, unsupported platform, or no pin for this platform.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
toolchain="${RUST_TOOLCHAIN:-}"
components="${RUST_COMPONENTS:-}"
targets="${RUST_TARGETS:-}"

[[ -n "$toolchain" ]] || { echo "::error::RUST_TOOLCHAIN is empty; name a toolchain such as stable or 1.75.0." >&2; exit 2; }

# KEY=value, first match; comments and blank lines are not keys.
pin() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{ print $1 }'
  else
    echo "::error::Neither sha256sum nor shasum is available to verify a download." >&2
    exit 1
  fi
}

# A Windows path for GITHUB_PATH and GITHUB_ENV when running under Git Bash.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# Stable releases are six weeks apart; 1.0 shipped on day 16569 of the epoch.
# These two forms and the `1.NN` shorthand are the action's arithmetic.
stable_release_at() {
  echo $(( ($1 / 60 / 60 / 24 - 16569) / 7 / 6 ))
}
ago_re='^stable [0-9]+ (year|month|week|day)s? ago$'
minus_re='^stable minus [0-9]+ releases?$'
minor_re='^1\.[0-9]+$'
if [[ "$toolchain" =~ $ago_re ]]; then
  n="$(printf '%s' "$toolchain" | sed 's/stable \([0-9]*\) .*/\1/')"
  unit="$(printf '%s' "$toolchain" | sed 's/stable [0-9]* \([a-z]\).*/\1/')"
  if date --date "1 day ago" +%s >/dev/null 2>&1; then
    then_s="$(date --date "${toolchain#stable }" +%s)"
  elif date -v-1d +%s >/dev/null 2>&1; then
    then_s="$(date -v"-${n}${unit}" +%s)"
  else
    echo "::error::'$toolchain' needs a date that takes --date (GNU) or -v (BSD); this one takes neither. Name the release, e.g. 1.85." >&2
    exit 2
  fi
  toolchain="1.$(stable_release_at "$then_s")"
elif [[ "$toolchain" =~ $minus_re ]]; then
  n="${toolchain//[^0-9]/}"
  toolchain="1.$(( $(stable_release_at "$(date +%s)") - n ))"
elif [[ "$toolchain" =~ $minor_re ]]; then
  i="${toolchain#1.}"
  c="$(stable_release_at "$(date +%s)")"
  toolchain="1.$(( i + 9 * i * (10 * i <= c) + 90 * i * (100 * i <= c) ))"
fi

# Where cargo and rustup live, as the action set it, so a later cache step
# and a caller's own steps read one value.
if [[ -z "${CARGO_HOME:-}" ]]; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) CARGO_HOME="${USERPROFILE:-$HOME}\\.cargo"; cargo_bin="$HOME/.cargo/bin" ;;
    *) CARGO_HOME="$HOME/.cargo"; cargo_bin="$CARGO_HOME/bin" ;;
  esac
  export CARGO_HOME
  [[ -n "${GITHUB_ENV:-}" ]] && printf 'CARGO_HOME=%s\n' "$CARGO_HOME" >> "$GITHUB_ENV"
elif command -v cygpath >/dev/null 2>&1; then
  cargo_bin="$(cygpath -u "$CARGO_HOME")/bin"
else
  cargo_bin="$CARGO_HOME/bin"
fi

# Installed but not on PATH (a self-hosted runner, a fresh shell): later steps
# need it too, not only this one.
if ! command -v rustup >/dev/null 2>&1 && [[ -x "$cargo_bin/rustup" ]]; then
  PATH="$cargo_bin:$PATH"
  export PATH
  [[ -n "${GITHUB_PATH:-}" ]] && host_path "$cargo_bin" >> "$GITHUB_PATH"
fi

if ! command -v rustup >/dev/null 2>&1; then
  [[ -r "$pins" ]] || { echo "::error::rustup is not on PATH and the pins file is not readable: $pins" >&2; exit 2; }
  rustup_version="$(pin RUSTUP_VERSION)"
  [[ "$rustup_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::RUSTUP_VERSION in $pins is '$rustup_version', not X.Y.Z." >&2; exit 2; }
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "::error::Unsupported architecture '$arch'; rustup-init is pinned for x86_64 and aarch64." >&2; exit 2 ;;
  esac
  case "$(uname -s)" in
    Linux) triple="${arch}-unknown-linux-gnu"; file=rustup-init ;;
    Darwin) triple="${arch}-apple-darwin"; file=rustup-init ;;
    MINGW*|MSYS*|CYGWIN*) triple="${arch}-pc-windows-msvc"; file=rustup-init.exe ;;
    *) echo "::error::Unsupported runner OS '$(uname -s)'; rustup-init is pinned for Linux, macOS and Windows." >&2; exit 2 ;;
  esac
  key="RUSTUP_INIT_SHA256_$(printf '%s' "$triple" | tr '[:lower:]-' '[:upper:]_')"
  expected="$(pin "$key" | tr '[:upper:]' '[:lower:]')"
  if [[ ${#expected} -ne 64 || -n "$(printf '%s' "$expected" | tr -d '0-9a-f')" ]]; then
    echo "::error::No 64-hex sha256 pinned for rustup-init $rustup_version on $triple ($key in $pins). Refusing to run an unverified installer." >&2
    exit 2
  fi
  if [[ -n "${RUNNER_TEMP:-}" ]]; then
    dest="$(mktemp -d "${RUNNER_TEMP}/rustup-init.XXXXXX")"
  else
    dest="$(mktemp -d)"
  fi
  url="https://static.rust-lang.org/rustup/archive/${rustup_version}/${triple}/${file}"
  echo "rustup is not on PATH; downloading $url"
  curl --proto '=https' --tlsv1.2 --retry 5 --retry-connrefused -fsSL "$url" -o "$dest/$file"
  actual="$(sha256_of "$dest/$file")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$dest/$file"
    echo "::error::Checksum mismatch for $file $rustup_version ($triple): expected $expected, got $actual." >&2
    exit 1
  fi
  echo "Verified $file $rustup_version ($triple, sha256 $actual)"
  chmod +x "$dest/$file"
  "$dest/$file" --default-toolchain none --profile minimal --no-modify-path -y
  rm -f "$dest/$file"
  PATH="$cargo_bin:$PATH"
  export PATH
  [[ -n "${GITHUB_PATH:-}" ]] && host_path "$cargo_bin" >> "$GITHUB_PATH"
fi

# Split on commas and whitespace without glob expansion; `${flags[@]+...}`
# because bash 3.2 reads an empty array as unbound under set -u.
set -f
flags=()
for t in ${targets//,/ }; do flags+=(--target "$t"); done
for c in ${components//,/ }; do flags+=(--component "$c"); done
set +f
if [[ "$toolchain" == nightly && -n "$components" ]]; then flags+=(--allow-downgrade); fi

# A release in progress makes static.rust-lang.org serve a manifest and a
# component that disagree for a few minutes; that one failure is retried.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
attempt=1
while :; do
  status=0
  RUSTUP_PERMIT_COPY_RENAME=1 rustup toolchain install "$toolchain" ${flags[@]+"${flags[@]}"} \
    --profile minimal --no-self-update --force-non-host 2>&1 | tee "$log" || status=$?
  [[ "$status" -eq 0 ]] && break
  if [[ "$attempt" -ge 5 ]] || ! grep -Fq 'checksum failed for ' "$log" \
      || ! grep -Fq 'this is likely due to an ongoing update of the official release server' "$log"; then
    echo "::error::rustup toolchain install $toolchain failed (exit $status)." >&2
    exit 1
  fi
  echo "Retrying rustup toolchain install in 30 seconds (retry $attempt of 4)" >&2
  sleep 30
  attempt=$((attempt + 1))
done

# A failure here leaves `rustc +toolchain` working, as the action accepted.
rustup default "$toolchain" --force-non-host || echo "::warning::rustup default $toolchain failed; cargo +$toolchain still works."

verbose="$(rustc +"$toolchain" --version --verbose)"
commit_date="$(printf '%s\n' "$verbose" | sed -n 's/^commit-date: \(20[0-9][0-9]\)-\([01][0-9]\)-\([0-3][0-9]\)$/\1\2\3/p')"
commit_hash="$(printf '%s\n' "$verbose" | sed -n 's/^commit-hash: //p')"
cachekey="$(printf '%s' "${commit_date}${commit_hash}" | head -c12)"
release="$(printf '%s\n' "$verbose" | sed -n 's/^release: //p')"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  [[ -z "${CARGO_INCREMENTAL+set}" ]] && echo "CARGO_INCREMENTAL=0" >> "$GITHUB_ENV"
  [[ -z "${CARGO_TERM_COLOR+set}" ]] && echo "CARGO_TERM_COLOR=always" >> "$GITHUB_ENV"
  # The sparse registry: implemented in 1.66, stabilised in 1.68, default from 1.70.
  if [[ -z "${CARGO_REGISTRIES_CRATES_IO_PROTOCOL+set}" ]]; then
    case "$release" in
      1.68.*|1.69.*) echo "CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse" >> "$GITHUB_ENV" ;;
      1.66.*|1.67.*) echo "CARGO_REGISTRIES_CRATES_IO_PROTOCOL=git" >> "$GITHUB_ENV" ;;
    esac
  fi
  # Spurious network errors with curl 8.0 in those two releases.
  case "$release" in
    1.70.*|1.71.*) echo "CARGO_HTTP_MULTIPLEXING=false" >> "$GITHUB_ENV" ;;
  esac
fi

printf '%s\n' "$verbose"
printf 'cachekey=%s\nname=%s\n' "$cachekey" "$toolchain"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'cachekey=%s\nname=%s\n' "$cachekey" "$toolchain" >> "$GITHUB_OUTPUT"
fi
