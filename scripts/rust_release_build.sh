#!/usr/bin/env bash
# SCRIPT: rust_release_build.sh
# DESCRIPTION: Build Rust release binaries for multiple targets and collect them in an artifacts directory.
# USAGE: ./rust_release_build.sh --bin-name <name> [--artifact-dir <dir>] [--targets <list>] [--linux-gnu-aliases <list>]
# PARAMETERS:
#   --bin-name <name>           Required. Cargo binary name.
#   --artifact-dir <dir>        Output directory for binaries (default: artifacts).
#   --targets <list>            Comma-delimited targets: windows,linux-gnu,linux-musl,macos (default: all).
#   --linux-gnu-aliases <list>  Comma-delimited extra Linux GNU artifact suffixes (e.g. deb,pacman,yum,redhat).
#   --install-deps              Install build dependencies via apt-get.
#   --apt-packages <list>       Space-delimited apt packages (default: build-essential mingw-w64 musl-tools).
#   -h, --help                  Show this help message.
# ----------------------------------------------------
set -euo pipefail

bin_name=""
artifact_dir="artifacts"
targets="windows,linux-gnu,linux-musl,macos"
linux_gnu_aliases=""
install_deps=false
apt_packages="build-essential mingw-w64 musl-tools"

usage() {
  sed -n '1,40p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-name) bin_name="$2"; shift 2;;
    --artifact-dir) artifact_dir="$2"; shift 2;;
    --targets) targets="$2"; shift 2;;
    --linux-gnu-aliases) linux_gnu_aliases="$2"; shift 2;;
    --install-deps) install_deps=true; shift;;
    --apt-packages) apt_packages="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

if [ -z "$bin_name" ]; then
  echo "Missing required --bin-name" >&2
  usage
  exit 2
fi

if $install_deps; then
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y $apt_packages
  else
    apt-get update
    apt-get install -y $apt_packages
  fi
fi

mkdir -p "$artifact_dir"

IFS=',' read -r -a target_list <<< "$targets"

build_target() {
  local target="$1"
  local out_name="$2"
  local src_path="$3"

  if [ -f "$src_path" ]; then
    cp "$src_path" "$artifact_dir/$out_name"
  else
    echo "Binary not found at $src_path" >&2
    exit 1
  fi
}

cargo build --release

for target in "${target_list[@]}"; do
  case "$target" in
    windows)
      cargo build --release --target=x86_64-pc-windows-gnu
      build_target \
        "windows" \
        "${bin_name}-windows.exe" \
        "target/x86_64-pc-windows-gnu/release/${bin_name}.exe"
      ;;
    linux-gnu)
      cargo build --release --target=x86_64-unknown-linux-gnu
      build_target \
        "linux-gnu" \
        "${bin_name}-linux" \
        "target/x86_64-unknown-linux-gnu/release/${bin_name}"
      if [ -n "$linux_gnu_aliases" ]; then
        IFS=',' read -r -a alias_list <<< "$linux_gnu_aliases"
        for alias in "${alias_list[@]}"; do
          cp "target/x86_64-unknown-linux-gnu/release/${bin_name}" "$artifact_dir/${bin_name}-${alias}"
        done
      fi
      ;;
    linux-musl)
      cargo build --release --target=x86_64-unknown-linux-musl
      build_target \
        "linux-musl" \
        "${bin_name}-musl" \
        "target/x86_64-unknown-linux-musl/release/${bin_name}"
      ;;
    macos)
      if command -v x86_64-apple-darwin-gcc >/dev/null 2>&1; then
        export CARGO_BUILD_TARGET_X86_64_APPLE_DARWIN_LINKER=x86_64-apple-darwin-gcc
        cargo build --release --target=x86_64-apple-darwin
        build_target \
          "macos" \
          "${bin_name}-mac" \
          "target/x86_64-apple-darwin/release/${bin_name}"
      else
        echo "macOS cross-compiler not found, skipping macOS build."
      fi
      ;;
    *)
      echo "Unknown target: $target" >&2
      exit 2
      ;;
  esac
done

ls -al "$artifact_dir"
