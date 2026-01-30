#!/usr/bin/env bash
# SCRIPT: gen_brew_formula.sh
# DESCRIPTION: Generate a Homebrew formula for a tarball release.
# USAGE: ./gen_brew_formula.sh --name <name> --desc <desc> --homepage <url> --tarball <path> [options]
# EXAMPLE: ./gen_brew_formula.sh --name isoforge --desc "ISO tool" --homepage https://example.com --tarball dist/isoforge-1.0.0.tar.gz --url https://example.com/isoforge-1.0.0.tar.gz
# PARAMETERS:
#   --name <name>          Formula/package name (required).
#   --desc <desc>          Short description (required).
#   --homepage <url>       Project homepage (required).
#   --tarball <path>       Tarball path (required).
#   --url <url>            Tarball URL (default: GitHub releases URL).
#   --repo-slug <slug>     GitHub repo slug (owner/repo) for default URL (optional).
#   --version <version>    Version override (default: from tarball name).
#   --license <license>    License (default: MIT).
#   --dep <name>           Dependency (repeatable).
#   --entrypoint <path>    Entrypoint script (default: name).
#   --man-path <path>      Manpage path (optional).
#   --formula-path <path>  Output formula path (default: packaging/brew/<name>.rb).
#   --use-libexec          Install into libexec and generate wrapper (default: false).
#   --env-var <name>       Env var for wrapper (used with --use-libexec).
#   -h, --help             Show help.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help packaging

usage() { display_help; }

repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
name=""
desc=""
homepage=""
tarball=""
url=""
version=""
license="MIT"
deps=()
entrypoint=""
man_path=""
formula_path=""
use_libexec=false
env_var=""
repo_slug="${SOURCE_REPO:-${GITHUB_REPOSITORY:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name="$2"; shift 2;;
    --desc) desc="$2"; shift 2;;
    --homepage) homepage="$2"; shift 2;;
    --tarball) tarball="$2"; shift 2;;
    --url) url="$2"; shift 2;;
    --repo-slug) repo_slug="$2"; shift 2;;
    --version) version="$2"; shift 2;;
    --license) license="$2"; shift 2;;
    --dep) deps+=("$2"); shift 2;;
    --entrypoint) entrypoint="$2"; shift 2;;
    --man-path) man_path="$2"; shift 2;;
    --formula-path) formula_path="$2"; shift 2;;
    --use-libexec) use_libexec=true; shift;;
    --env-var) env_var="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ -z "$name" || -z "$desc" || -z "$homepage" || -z "$tarball" ]]; then
  log_error "--name, --desc, --homepage, and --tarball are required"
  exit 2
fi

if [[ ! -f "$tarball" ]]; then
  log_error "Tarball not found: $tarball"
  exit 2
fi

if [[ -z "$version" ]]; then
  version="$(basename "$tarball" | sed -E "s/^${name}-([0-9][0-9\\.]+)\\.tar\\.gz$/\\1/")"
fi

if [[ -z "$url" ]]; then
  if [[ -n "$repo_slug" ]]; then
    url="https://github.com/${repo_slug}/releases/download/v$version/$name-$version.tar.gz"
  else
    url="https://github.com/$name/releases/download/v$version/$name-$version.tar.gz"
  fi
fi

sha256="$(shasum -a 256 "$tarball" | awk '{print $1}')"
if [[ -z "$entrypoint" ]]; then
  entrypoint="$name"
fi

if [[ -z "$formula_path" ]]; then
  formula_path="$repo_dir/packaging/brew/$name.rb"
fi

mkdir -p "$(dirname "$formula_path")"

class_name="$(pkg_classify_name "$name")"

deps_block=""
for dep in "${deps[@]}"; do
  deps_block+="  depends_on \"$dep\"\n"
done

man_block=""
if [[ -n "$man_path" ]]; then
  man_block="    man1.install \"#{libexec}/$man_path\""
fi

if $use_libexec; then
  if [[ -z "$env_var" ]]; then
    log_error "--env-var is required when using --use-libexec"
    exit 2
  fi
  cat >"$formula_path" <<EOF
class ${class_name} < Formula
  desc "$desc"
  homepage "$homepage"
  url "$url"
  version "$version"
  sha256 "$sha256"
  license "$license"

$deps_block
  def install
    libexec.install Dir["*"]
    (bin/"$entrypoint").write <<~EOS
      #!/bin/bash
      export $env_var="#{libexec}"
      exec "#{libexec}/$entrypoint" "\$@"
    EOS
$man_block
  end
end
EOF
else
  cat >"$formula_path" <<EOF
class ${class_name} < Formula
  desc "$desc"
  homepage "$homepage"
  url "$url"
  version "$version"
  sha256 "$sha256"
  license "$license"

$deps_block
  def install
    bin.install "$entrypoint"
EOF
  if [[ -n "$man_path" ]]; then
    cat >>"$formula_path" <<EOF
    man1.install "$man_path"
EOF
  fi
  cat >>"$formula_path" <<EOF
  end
end
EOF
fi

log_info "Wrote Homebrew formula: $formula_path"
