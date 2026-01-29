#!/usr/bin/env bash
# SCRIPT: packaging_init.sh
# DESCRIPTION: Scaffold packaging files (debian/, rpm spec, PKGBUILD, Homebrew formula) from templates.
# USAGE: ./packaging_init.sh [--repo PATH] [--config PATH] [--template-dir PATH] [--force] [--init-only]
# EXAMPLE: ./packaging_init.sh --repo .
# PARAMETERS:
#   --repo <path>         Repo path (default: GITHUB_WORKSPACE or cwd).
#   --config <path>       Packaging env file (default: packaging/packaging.env).
#   --template-dir <path> Template root (default: script-helpers/templates/packaging).
#   --force               Overwrite existing files.
#   --init-only            Only create packaging/packaging.env if missing.
#   -h, --help            Show help.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help packaging env

usage() { display_help; }

repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
config_path="packaging/packaging.env"
template_dir="${SCRIPT_HELPERS_DIR}/templates/packaging"
force=false
init_only=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo_dir="$2"; shift 2;;
    --config) config_path="$2"; shift 2;;
    --template-dir) template_dir="$2"; shift 2;;
    --force) force=true; shift;;
    --init-only) init_only=true; shift;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ "$config_path" != /* ]]; then
  config_path="$repo_dir/$config_path"
fi

mkdir -p "$repo_dir/packaging"

if [[ ! -f "$config_path" ]]; then
  if [[ -f "$template_dir/packaging.env" ]]; then
    cp "$template_dir/packaging.env" "$config_path"
    log_info "Created packaging metadata: $config_path"
    log_info "Edit it, then rerun packaging_init.sh to render templates."
    if $init_only; then
      exit 0
    fi
  else
    log_error "Template metadata not found: $template_dir/packaging.env"
    exit 1
  fi
fi

if $init_only; then
  log_info "Init-only complete: $config_path"
  exit 0
fi

pkg_load_metadata "$config_path"

set_default() {
  local key="$1" value="$2"
  if [[ -z "${!key:-}" ]]; then
    printf -v "$key" "%s" "$value"
  fi
}

set_default APP_NAME ""
set_default APP_BIN_NAME "${APP_NAME}"
set_default APP_TITLE "${APP_NAME}"
set_default APP_DESCRIPTION ""
set_default APP_DESCRIPTION_LONG "${APP_DESCRIPTION}"
set_default APP_HOMEPAGE ""
set_default APP_LICENSE ""
set_default APP_VENDOR ""
set_default APP_INSTALL_PREFIX "/usr"
set_default APP_BUILD_CMD "make"
set_default APP_INSTALL_CMD "make install"

set_default MAINTAINER_NAME ""
set_default MAINTAINER_EMAIL ""
set_default SOURCE_REPO ""

set_default APP_VERSION "$(pkg_guess_version "$repo_dir")"

set_default DEB_SECTION "utils"
set_default DEB_PRIORITY "optional"
set_default DEB_SERIES "jammy"
set_default DEB_ARCH "any"
set_default DEB_BUILD_DEPENDS "debhelper-compat (= 13)"
set_default DEB_DEPENDS ""
set_default DEB_RECOMMENDS ""
set_default DEB_SUGGESTS ""

set_default RPM_RELEASE "1%{?dist}"
set_default RPM_BUILD_REQUIRES ""
set_default RPM_REQUIRES ""
set_default RPM_FILES "/usr/bin/${APP_BIN_NAME}"

set_default ARCH_PKGREL "1"
set_default ARCH_ARCH "x86_64"
set_default ARCH_DEPENDS ""
set_default ARCH_MAKEDEPENDS ""
set_default ARCH_SOURCE_URL ""
set_default ARCH_SOURCE_SHA256 "SKIP"

set_default BREW_FORMULA_NAME "${APP_NAME}"
set_default BREW_FORMULA_CLASS ""
set_default BREW_DESC "${APP_DESCRIPTION}"
set_default BREW_HOMEPAGE "${APP_HOMEPAGE}"
set_default BREW_URL ""
set_default BREW_SHA256 ""
set_default BREW_LICENSE "${APP_LICENSE}"
set_default BREW_DEPENDS ""
set_default BREW_INSTALL_CMD 'system "make", "install", "PREFIX=#{prefix}"'
set_default BREW_TEST_CMD 'system "#{bin}/'"${APP_BIN_NAME}"'", "--version"'

if [[ -z "$APP_NAME" ]]; then
  log_error "APP_NAME is required in $config_path"
  exit 1
fi

if [[ -z "$MAINTAINER_NAME" || -z "$MAINTAINER_EMAIL" ]]; then
  log_error "MAINTAINER_NAME and MAINTAINER_EMAIL are required in $config_path"
  exit 1
fi

if [[ -z "$BREW_FORMULA_CLASS" ]]; then
  BREW_FORMULA_CLASS="$(pkg_classify_name "$BREW_FORMULA_NAME")"
fi

if [[ -z "$ARCH_SOURCE_URL" && -n "$SOURCE_REPO" ]]; then
  ARCH_SOURCE_URL="https://github.com/${SOURCE_REPO}/archive/refs/tags/v${APP_VERSION}.tar.gz"
fi

if [[ -z "$BREW_URL" && -n "$SOURCE_REPO" ]]; then
  BREW_URL="https://github.com/${SOURCE_REPO}/archive/refs/tags/v${APP_VERSION}.tar.gz"
fi

DEB_MAINTAINER="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"
DEB_DATE="$(date -R)"
RPM_MAINTAINER="$DEB_MAINTAINER"
RPM_DATE="$DEB_DATE"

DEB_DEPENDS_SUFFIX=""
if [[ -n "$DEB_DEPENDS" ]]; then
  deb_depends="$(pkg_join_list "$DEB_DEPENDS" ", ")"
  if [[ -n "$deb_depends" ]]; then
    DEB_DEPENDS_SUFFIX=", ${deb_depends}"
  fi
fi

DEB_RECOMMENDS_LINE=""
if [[ -n "$DEB_RECOMMENDS" ]]; then
  deb_recommends="$(pkg_join_list "$DEB_RECOMMENDS" ", ")"
  if [[ -n "$deb_recommends" ]]; then
    DEB_RECOMMENDS_LINE="Recommends: ${deb_recommends}"
  fi
fi

DEB_SUGGESTS_LINE=""
if [[ -n "$DEB_SUGGESTS" ]]; then
  deb_suggests="$(pkg_join_list "$DEB_SUGGESTS" ", ")"
  if [[ -n "$deb_suggests" ]]; then
    DEB_SUGGESTS_LINE="Suggests: ${deb_suggests}"
  fi
fi

RPM_BUILD_REQUIRES_LINES="$(pkg_render_lines "BuildRequires: " "$RPM_BUILD_REQUIRES")"
RPM_REQUIRES_LINES="$(pkg_render_lines "Requires: " "$RPM_REQUIRES")"

ARCH_DEPENDS_ARRAY="$(pkg_quote_list "$ARCH_DEPENDS")"
ARCH_MAKEDEPENDS_ARRAY="$(pkg_quote_list "$ARCH_MAKEDEPENDS")"

BREW_DEPENDS_LINES=""
if [[ -n "$BREW_DEPENDS" ]]; then
  brew_dep_lines=""
  IFS='|' read -r -a brew_items <<< "$BREW_DEPENDS"
  for brew_item in "${brew_items[@]}"; do
    brew_item="$(pkg_trim "$brew_item")"
    [[ -z "$brew_item" ]] && continue
    brew_dep_lines+="  depends_on \"${brew_item}\""$'\n'
  done
  BREW_DEPENDS_LINES="$brew_dep_lines"
fi

render_template() {
  local template="$1" dest="$2"
  awk \
    -v APP_NAME="$APP_NAME" \
    -v APP_BIN_NAME="$APP_BIN_NAME" \
    -v APP_TITLE="$APP_TITLE" \
    -v APP_VERSION="$APP_VERSION" \
    -v APP_DESCRIPTION="$APP_DESCRIPTION" \
    -v APP_DESCRIPTION_LONG="$APP_DESCRIPTION_LONG" \
    -v APP_HOMEPAGE="$APP_HOMEPAGE" \
    -v APP_LICENSE="$APP_LICENSE" \
    -v APP_VENDOR="$APP_VENDOR" \
    -v APP_INSTALL_PREFIX="$APP_INSTALL_PREFIX" \
    -v APP_BUILD_CMD="$APP_BUILD_CMD" \
    -v APP_INSTALL_CMD="$APP_INSTALL_CMD" \
    -v DEB_SECTION="$DEB_SECTION" \
    -v DEB_PRIORITY="$DEB_PRIORITY" \
    -v DEB_MAINTAINER="$DEB_MAINTAINER" \
    -v DEB_BUILD_DEPENDS="$DEB_BUILD_DEPENDS" \
    -v DEB_DEPENDS_SUFFIX="$DEB_DEPENDS_SUFFIX" \
    -v DEB_RECOMMENDS_LINE="$DEB_RECOMMENDS_LINE" \
    -v DEB_SUGGESTS_LINE="$DEB_SUGGESTS_LINE" \
    -v DEB_ARCH="$DEB_ARCH" \
    -v DEB_SERIES="$DEB_SERIES" \
    -v DEB_DATE="$DEB_DATE" \
    -v RPM_RELEASE="$RPM_RELEASE" \
    -v RPM_MAINTAINER="$RPM_MAINTAINER" \
    -v RPM_DATE="$RPM_DATE" \
    -v RPM_BUILD_REQUIRES_LINES="$RPM_BUILD_REQUIRES_LINES" \
    -v RPM_REQUIRES_LINES="$RPM_REQUIRES_LINES" \
    -v RPM_DESCRIPTION="$APP_DESCRIPTION" \
    -v RPM_LICENSE="$APP_LICENSE" \
    -v RPM_URL="$APP_HOMEPAGE" \
    -v RPM_FILES="$RPM_FILES" \
    -v ARCH_PKGREL="$ARCH_PKGREL" \
    -v ARCH_ARCH="$ARCH_ARCH" \
    -v ARCH_SOURCE_URL="$ARCH_SOURCE_URL" \
    -v ARCH_SOURCE_SHA256="$ARCH_SOURCE_SHA256" \
    -v ARCH_DEPENDS_ARRAY="$ARCH_DEPENDS_ARRAY" \
    -v ARCH_MAKEDEPENDS_ARRAY="$ARCH_MAKEDEPENDS_ARRAY" \
    -v BREW_FORMULA_CLASS="$BREW_FORMULA_CLASS" \
    -v BREW_DESC="$BREW_DESC" \
    -v BREW_HOMEPAGE="$BREW_HOMEPAGE" \
    -v BREW_URL="$BREW_URL" \
    -v BREW_SHA256="$BREW_SHA256" \
    -v BREW_LICENSE="$BREW_LICENSE" \
    -v BREW_DEPENDS_LINES="$BREW_DEPENDS_LINES" \
    -v BREW_INSTALL_CMD="$BREW_INSTALL_CMD" \
    -v BREW_TEST_CMD="$BREW_TEST_CMD" \
    '{
      gsub(/@APP_NAME@/, APP_NAME)
      gsub(/@APP_BIN_NAME@/, APP_BIN_NAME)
      gsub(/@APP_TITLE@/, APP_TITLE)
      gsub(/@APP_VERSION@/, APP_VERSION)
      gsub(/@APP_DESCRIPTION@/, APP_DESCRIPTION)
      gsub(/@APP_DESCRIPTION_LONG@/, APP_DESCRIPTION_LONG)
      gsub(/@APP_HOMEPAGE@/, APP_HOMEPAGE)
      gsub(/@APP_LICENSE@/, APP_LICENSE)
      gsub(/@APP_VENDOR@/, APP_VENDOR)
      gsub(/@APP_INSTALL_PREFIX@/, APP_INSTALL_PREFIX)
      gsub(/@APP_BUILD_CMD@/, APP_BUILD_CMD)
      gsub(/@APP_INSTALL_CMD@/, APP_INSTALL_CMD)
      gsub(/@DEB_SECTION@/, DEB_SECTION)
      gsub(/@DEB_PRIORITY@/, DEB_PRIORITY)
      gsub(/@DEB_MAINTAINER@/, DEB_MAINTAINER)
      gsub(/@DEB_BUILD_DEPENDS@/, DEB_BUILD_DEPENDS)
      gsub(/@DEB_DEPENDS_SUFFIX@/, DEB_DEPENDS_SUFFIX)
      gsub(/@DEB_RECOMMENDS_LINE@/, DEB_RECOMMENDS_LINE)
      gsub(/@DEB_SUGGESTS_LINE@/, DEB_SUGGESTS_LINE)
      gsub(/@DEB_ARCH@/, DEB_ARCH)
      gsub(/@DEB_SERIES@/, DEB_SERIES)
      gsub(/@DEB_DATE@/, DEB_DATE)
      gsub(/@RPM_RELEASE@/, RPM_RELEASE)
      gsub(/@RPM_MAINTAINER@/, RPM_MAINTAINER)
      gsub(/@RPM_DATE@/, RPM_DATE)
      gsub(/@RPM_BUILD_REQUIRES_LINES@/, RPM_BUILD_REQUIRES_LINES)
      gsub(/@RPM_REQUIRES_LINES@/, RPM_REQUIRES_LINES)
      gsub(/@RPM_DESCRIPTION@/, RPM_DESCRIPTION)
      gsub(/@RPM_LICENSE@/, RPM_LICENSE)
      gsub(/@RPM_URL@/, RPM_URL)
      gsub(/@RPM_FILES@/, RPM_FILES)
      gsub(/@ARCH_PKGREL@/, ARCH_PKGREL)
      gsub(/@ARCH_ARCH@/, ARCH_ARCH)
      gsub(/@ARCH_SOURCE_URL@/, ARCH_SOURCE_URL)
      gsub(/@ARCH_SOURCE_SHA256@/, ARCH_SOURCE_SHA256)
      gsub(/@ARCH_DEPENDS_ARRAY@/, ARCH_DEPENDS_ARRAY)
      gsub(/@ARCH_MAKEDEPENDS_ARRAY@/, ARCH_MAKEDEPENDS_ARRAY)
      gsub(/@BREW_FORMULA_CLASS@/, BREW_FORMULA_CLASS)
      gsub(/@BREW_DESC@/, BREW_DESC)
      gsub(/@BREW_HOMEPAGE@/, BREW_HOMEPAGE)
      gsub(/@BREW_URL@/, BREW_URL)
      gsub(/@BREW_SHA256@/, BREW_SHA256)
      gsub(/@BREW_LICENSE@/, BREW_LICENSE)
      gsub(/@BREW_DEPENDS_LINES@/, BREW_DEPENDS_LINES)
      gsub(/@BREW_INSTALL_CMD@/, BREW_INSTALL_CMD)
      gsub(/@BREW_TEST_CMD@/, BREW_TEST_CMD)
      print
    }' "$template" > "$dest"
}

create_file() {
  local template="$1" dest="$2"
  if [[ -f "$dest" && "$force" != "true" ]]; then
    log_info "Skipping existing: $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  render_template "$template" "$dest"
  log_info "Rendered: $dest"
}

create_file "$template_dir/debian/control" "$repo_dir/debian/control"
create_file "$template_dir/debian/changelog" "$repo_dir/debian/changelog"
create_file "$template_dir/debian/rules" "$repo_dir/debian/rules"
create_file "$template_dir/debian/copyright" "$repo_dir/debian/copyright"
create_file "$template_dir/debian/source/format" "$repo_dir/debian/source/format"
create_file "$template_dir/debian/source/options" "$repo_dir/debian/source/options"

create_file "$template_dir/rpm/app.spec" "$repo_dir/packaging/rpm/${APP_NAME}.spec"
create_file "$template_dir/arch/PKGBUILD" "$repo_dir/packaging/arch/PKGBUILD"
create_file "$template_dir/brew/app.rb" "$repo_dir/packaging/brew/${BREW_FORMULA_NAME}.rb"
create_file "$template_dir/README.md" "$repo_dir/packaging/README.md"

chmod +x "$repo_dir/debian/rules"

log_info "Packaging scaffold complete."
