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
# RFC 2822, as debian/changelog requires. Spelled out rather than `date -R`,
# which BSD date (macOS) rejects, and in the C locale so the day and month
# names are English whatever the machine's locale is.
DEB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
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
  for brew_item in "${brew_items[@]+"${brew_items[@]}"}"; do
    brew_item="$(pkg_trim "$brew_item")"
    [[ -z "$brew_item" ]] && continue
    brew_dep_lines+="  depends_on \"${brew_item}\""$'\n'
  done
  BREW_DEPENDS_LINES="$brew_dep_lines"
fi

render_template() {
  local template="$1" dest="$2"
  # Values reach awk through the environment, not -v: the original awk
  # (macOS) rejects a -v value containing a newline ("newline in string"),
  # and the dependency lists are multi-line.
  _PKG_APP_NAME="$APP_NAME" \
  _PKG_APP_BIN_NAME="$APP_BIN_NAME" \
  _PKG_APP_TITLE="$APP_TITLE" \
  _PKG_APP_VERSION="$APP_VERSION" \
  _PKG_APP_DESCRIPTION="$APP_DESCRIPTION" \
  _PKG_APP_DESCRIPTION_LONG="$APP_DESCRIPTION_LONG" \
  _PKG_APP_HOMEPAGE="$APP_HOMEPAGE" \
  _PKG_APP_LICENSE="$APP_LICENSE" \
  _PKG_APP_VENDOR="$APP_VENDOR" \
  _PKG_APP_INSTALL_PREFIX="$APP_INSTALL_PREFIX" \
  _PKG_APP_BUILD_CMD="$APP_BUILD_CMD" \
  _PKG_APP_INSTALL_CMD="$APP_INSTALL_CMD" \
  _PKG_DEB_SECTION="$DEB_SECTION" \
  _PKG_DEB_PRIORITY="$DEB_PRIORITY" \
  _PKG_DEB_MAINTAINER="$DEB_MAINTAINER" \
  _PKG_DEB_BUILD_DEPENDS="$DEB_BUILD_DEPENDS" \
  _PKG_DEB_DEPENDS_SUFFIX="$DEB_DEPENDS_SUFFIX" \
  _PKG_DEB_RECOMMENDS_LINE="$DEB_RECOMMENDS_LINE" \
  _PKG_DEB_SUGGESTS_LINE="$DEB_SUGGESTS_LINE" \
  _PKG_DEB_ARCH="$DEB_ARCH" \
  _PKG_DEB_SERIES="$DEB_SERIES" \
  _PKG_DEB_DATE="$DEB_DATE" \
  _PKG_RPM_RELEASE="$RPM_RELEASE" \
  _PKG_RPM_MAINTAINER="$RPM_MAINTAINER" \
  _PKG_RPM_DATE="$RPM_DATE" \
  _PKG_RPM_BUILD_REQUIRES_LINES="$RPM_BUILD_REQUIRES_LINES" \
  _PKG_RPM_REQUIRES_LINES="$RPM_REQUIRES_LINES" \
  _PKG_RPM_DESCRIPTION="$APP_DESCRIPTION" \
  _PKG_RPM_LICENSE="$APP_LICENSE" \
  _PKG_RPM_URL="$APP_HOMEPAGE" \
  _PKG_RPM_FILES="$RPM_FILES" \
  _PKG_ARCH_PKGREL="$ARCH_PKGREL" \
  _PKG_ARCH_ARCH="$ARCH_ARCH" \
  _PKG_ARCH_SOURCE_URL="$ARCH_SOURCE_URL" \
  _PKG_ARCH_SOURCE_SHA256="$ARCH_SOURCE_SHA256" \
  _PKG_ARCH_DEPENDS_ARRAY="$ARCH_DEPENDS_ARRAY" \
  _PKG_ARCH_MAKEDEPENDS_ARRAY="$ARCH_MAKEDEPENDS_ARRAY" \
  _PKG_BREW_FORMULA_CLASS="$BREW_FORMULA_CLASS" \
  _PKG_BREW_DESC="$BREW_DESC" \
  _PKG_BREW_HOMEPAGE="$BREW_HOMEPAGE" \
  _PKG_BREW_URL="$BREW_URL" \
  _PKG_BREW_SHA256="$BREW_SHA256" \
  _PKG_BREW_LICENSE="$BREW_LICENSE" \
  _PKG_BREW_DEPENDS_LINES="$BREW_DEPENDS_LINES" \
  _PKG_BREW_INSTALL_CMD="$BREW_INSTALL_CMD" \
  _PKG_BREW_TEST_CMD="$BREW_TEST_CMD" \
  awk \
    'BEGIN {
      APP_NAME = ENVIRON["_PKG_APP_NAME"]
      APP_BIN_NAME = ENVIRON["_PKG_APP_BIN_NAME"]
      APP_TITLE = ENVIRON["_PKG_APP_TITLE"]
      APP_VERSION = ENVIRON["_PKG_APP_VERSION"]
      APP_DESCRIPTION = ENVIRON["_PKG_APP_DESCRIPTION"]
      APP_DESCRIPTION_LONG = ENVIRON["_PKG_APP_DESCRIPTION_LONG"]
      APP_HOMEPAGE = ENVIRON["_PKG_APP_HOMEPAGE"]
      APP_LICENSE = ENVIRON["_PKG_APP_LICENSE"]
      APP_VENDOR = ENVIRON["_PKG_APP_VENDOR"]
      APP_INSTALL_PREFIX = ENVIRON["_PKG_APP_INSTALL_PREFIX"]
      APP_BUILD_CMD = ENVIRON["_PKG_APP_BUILD_CMD"]
      APP_INSTALL_CMD = ENVIRON["_PKG_APP_INSTALL_CMD"]
      DEB_SECTION = ENVIRON["_PKG_DEB_SECTION"]
      DEB_PRIORITY = ENVIRON["_PKG_DEB_PRIORITY"]
      DEB_MAINTAINER = ENVIRON["_PKG_DEB_MAINTAINER"]
      DEB_BUILD_DEPENDS = ENVIRON["_PKG_DEB_BUILD_DEPENDS"]
      DEB_DEPENDS_SUFFIX = ENVIRON["_PKG_DEB_DEPENDS_SUFFIX"]
      DEB_RECOMMENDS_LINE = ENVIRON["_PKG_DEB_RECOMMENDS_LINE"]
      DEB_SUGGESTS_LINE = ENVIRON["_PKG_DEB_SUGGESTS_LINE"]
      DEB_ARCH = ENVIRON["_PKG_DEB_ARCH"]
      DEB_SERIES = ENVIRON["_PKG_DEB_SERIES"]
      DEB_DATE = ENVIRON["_PKG_DEB_DATE"]
      RPM_RELEASE = ENVIRON["_PKG_RPM_RELEASE"]
      RPM_MAINTAINER = ENVIRON["_PKG_RPM_MAINTAINER"]
      RPM_DATE = ENVIRON["_PKG_RPM_DATE"]
      RPM_BUILD_REQUIRES_LINES = ENVIRON["_PKG_RPM_BUILD_REQUIRES_LINES"]
      RPM_REQUIRES_LINES = ENVIRON["_PKG_RPM_REQUIRES_LINES"]
      RPM_DESCRIPTION = ENVIRON["_PKG_RPM_DESCRIPTION"]
      RPM_LICENSE = ENVIRON["_PKG_RPM_LICENSE"]
      RPM_URL = ENVIRON["_PKG_RPM_URL"]
      RPM_FILES = ENVIRON["_PKG_RPM_FILES"]
      ARCH_PKGREL = ENVIRON["_PKG_ARCH_PKGREL"]
      ARCH_ARCH = ENVIRON["_PKG_ARCH_ARCH"]
      ARCH_SOURCE_URL = ENVIRON["_PKG_ARCH_SOURCE_URL"]
      ARCH_SOURCE_SHA256 = ENVIRON["_PKG_ARCH_SOURCE_SHA256"]
      ARCH_DEPENDS_ARRAY = ENVIRON["_PKG_ARCH_DEPENDS_ARRAY"]
      ARCH_MAKEDEPENDS_ARRAY = ENVIRON["_PKG_ARCH_MAKEDEPENDS_ARRAY"]
      BREW_FORMULA_CLASS = ENVIRON["_PKG_BREW_FORMULA_CLASS"]
      BREW_DESC = ENVIRON["_PKG_BREW_DESC"]
      BREW_HOMEPAGE = ENVIRON["_PKG_BREW_HOMEPAGE"]
      BREW_URL = ENVIRON["_PKG_BREW_URL"]
      BREW_SHA256 = ENVIRON["_PKG_BREW_SHA256"]
      BREW_LICENSE = ENVIRON["_PKG_BREW_LICENSE"]
      BREW_DEPENDS_LINES = ENVIRON["_PKG_BREW_DEPENDS_LINES"]
      BREW_INSTALL_CMD = ENVIRON["_PKG_BREW_INSTALL_CMD"]
      BREW_TEST_CMD = ENVIRON["_PKG_BREW_TEST_CMD"]
    }
    function subst(s, token, val,    out, i) {
      # Literal replacement. gsub() treats & in the replacement as the matched
      # text and \\ as an escape, so a value such as "make && make docs" came
      # out as "make @TOKEN@@TOKEN@ make docs". index/substr has no such
      # metacharacters and behaves the same under mawk, gawk and BSD awk.
      out = ""
      while ((i = index(s, token)) > 0) {
        out = out substr(s, 1, i - 1) val
        s = substr(s, i + length(token))
      }
      return out s
    }
    {
      $0 = subst($0, "@APP_NAME@", APP_NAME)
      $0 = subst($0, "@APP_BIN_NAME@", APP_BIN_NAME)
      $0 = subst($0, "@APP_TITLE@", APP_TITLE)
      $0 = subst($0, "@APP_VERSION@", APP_VERSION)
      $0 = subst($0, "@APP_DESCRIPTION@", APP_DESCRIPTION)
      $0 = subst($0, "@APP_DESCRIPTION_LONG@", APP_DESCRIPTION_LONG)
      $0 = subst($0, "@APP_HOMEPAGE@", APP_HOMEPAGE)
      $0 = subst($0, "@APP_LICENSE@", APP_LICENSE)
      $0 = subst($0, "@APP_VENDOR@", APP_VENDOR)
      $0 = subst($0, "@APP_INSTALL_PREFIX@", APP_INSTALL_PREFIX)
      $0 = subst($0, "@APP_BUILD_CMD@", APP_BUILD_CMD)
      $0 = subst($0, "@APP_INSTALL_CMD@", APP_INSTALL_CMD)
      $0 = subst($0, "@DEB_SECTION@", DEB_SECTION)
      $0 = subst($0, "@DEB_PRIORITY@", DEB_PRIORITY)
      $0 = subst($0, "@DEB_MAINTAINER@", DEB_MAINTAINER)
      $0 = subst($0, "@DEB_BUILD_DEPENDS@", DEB_BUILD_DEPENDS)
      $0 = subst($0, "@DEB_DEPENDS_SUFFIX@", DEB_DEPENDS_SUFFIX)
      $0 = subst($0, "@DEB_RECOMMENDS_LINE@", DEB_RECOMMENDS_LINE)
      $0 = subst($0, "@DEB_SUGGESTS_LINE@", DEB_SUGGESTS_LINE)
      $0 = subst($0, "@DEB_ARCH@", DEB_ARCH)
      $0 = subst($0, "@DEB_SERIES@", DEB_SERIES)
      $0 = subst($0, "@DEB_DATE@", DEB_DATE)
      $0 = subst($0, "@RPM_RELEASE@", RPM_RELEASE)
      $0 = subst($0, "@RPM_MAINTAINER@", RPM_MAINTAINER)
      $0 = subst($0, "@RPM_DATE@", RPM_DATE)
      $0 = subst($0, "@RPM_BUILD_REQUIRES_LINES@", RPM_BUILD_REQUIRES_LINES)
      $0 = subst($0, "@RPM_REQUIRES_LINES@", RPM_REQUIRES_LINES)
      $0 = subst($0, "@RPM_DESCRIPTION@", RPM_DESCRIPTION)
      $0 = subst($0, "@RPM_LICENSE@", RPM_LICENSE)
      $0 = subst($0, "@RPM_URL@", RPM_URL)
      $0 = subst($0, "@RPM_FILES@", RPM_FILES)
      $0 = subst($0, "@ARCH_PKGREL@", ARCH_PKGREL)
      $0 = subst($0, "@ARCH_ARCH@", ARCH_ARCH)
      $0 = subst($0, "@ARCH_SOURCE_URL@", ARCH_SOURCE_URL)
      $0 = subst($0, "@ARCH_SOURCE_SHA256@", ARCH_SOURCE_SHA256)
      $0 = subst($0, "@ARCH_DEPENDS_ARRAY@", ARCH_DEPENDS_ARRAY)
      $0 = subst($0, "@ARCH_MAKEDEPENDS_ARRAY@", ARCH_MAKEDEPENDS_ARRAY)
      $0 = subst($0, "@BREW_FORMULA_CLASS@", BREW_FORMULA_CLASS)
      $0 = subst($0, "@BREW_DESC@", BREW_DESC)
      $0 = subst($0, "@BREW_HOMEPAGE@", BREW_HOMEPAGE)
      $0 = subst($0, "@BREW_URL@", BREW_URL)
      $0 = subst($0, "@BREW_SHA256@", BREW_SHA256)
      $0 = subst($0, "@BREW_LICENSE@", BREW_LICENSE)
      $0 = subst($0, "@BREW_DEPENDS_LINES@", BREW_DEPENDS_LINES)
      $0 = subst($0, "@BREW_INSTALL_CMD@", BREW_INSTALL_CMD)
      $0 = subst($0, "@BREW_TEST_CMD@", BREW_TEST_CMD)
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
