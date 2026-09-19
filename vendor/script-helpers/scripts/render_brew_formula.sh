#!/usr/bin/env bash
# SCRIPT: render_brew_formula.sh
# DESCRIPTION: Render a Homebrew formula from packaging metadata.
# USAGE: ./render_brew_formula.sh [--repo PATH] [--config PATH] [--output PATH] [--url URL] [--sha256 SHA] [--version VERSION]
# EXAMPLE: ./render_brew_formula.sh --repo . --output /tmp/myapp.rb --url "https://..." --sha256 "..."
# PARAMETERS:
#   --repo <path>     Repo path (default: GITHUB_WORKSPACE or cwd).
#   --config <path>   Packaging env file (default: packaging/packaging.env).
#   --output <path>   Output formula path (default: packaging/brew/<formula>.rb).
#   --url <url>       Override Brew URL.
#   --sha256 <sha>    Override Brew SHA256.
#   --version <ver>   Override version.
#   -h, --help        Show help.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help packaging

usage() { display_help; }

repo_dir="${GITHUB_WORKSPACE:-$(pwd)}"
config_path="packaging/packaging.env"
output_path=""
override_url=""
override_sha=""
override_version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo_dir="$2"; shift 2;;
    --config) config_path="$2"; shift 2;;
    --output) output_path="$2"; shift 2;;
    --url) override_url="$2"; shift 2;;
    --sha256) override_sha="$2"; shift 2;;
    --version) override_version="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ "$config_path" != /* ]]; then
  config_path="$repo_dir/$config_path"
fi

pkg_load_metadata "$config_path"

APP_VERSION="${override_version:-${APP_VERSION:-$(pkg_guess_version "$repo_dir")}}"
BREW_URL="${override_url:-${BREW_URL:-}}"
BREW_SHA256="${override_sha:-${BREW_SHA256:-}}"

set_default() {
  local key="$1" value="$2"
  if [[ -z "${!key:-}" ]]; then
    printf -v "$key" "%s" "$value"
  fi
}

set_default APP_NAME ""
set_default APP_BIN_NAME "${APP_NAME}"
set_default APP_DESCRIPTION ""
set_default APP_HOMEPAGE ""
set_default APP_LICENSE ""
set_default BREW_FORMULA_NAME "${APP_NAME}"
set_default BREW_FORMULA_CLASS ""
set_default BREW_DESC "${APP_DESCRIPTION}"
set_default BREW_HOMEPAGE "${APP_HOMEPAGE}"
set_default BREW_LICENSE "${APP_LICENSE}"
set_default BREW_DEPENDS ""
set_default BREW_INSTALL_CMD 'system "make", "install", "PREFIX=#{prefix}"'
set_default BREW_TEST_CMD 'system "#{bin}/'"${APP_BIN_NAME}"'", "--version"'

if [[ -z "$APP_NAME" ]]; then
  log_error "APP_NAME is required in $config_path"
  exit 1
fi

# A formula with no checksum, or with the scaffold's placeholder, renders
# cleanly and then fails at `brew install`, far from the cause.
if [[ -z "$BREW_SHA256" || "$BREW_SHA256" == "REPLACE_WITH_SHA256" ]]; then
  log_error "BREW_SHA256 is not set (empty or the REPLACE_WITH_SHA256 placeholder); pass --sha256 or set it in $config_path"
  exit 1
fi

if [[ -z "$BREW_FORMULA_CLASS" ]]; then
  BREW_FORMULA_CLASS="$(pkg_classify_name "$BREW_FORMULA_NAME")"
fi

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

if [[ -z "$output_path" ]]; then
  output_path="$repo_dir/packaging/brew/${BREW_FORMULA_NAME}.rb"
fi

mkdir -p "$(dirname "$output_path")"

template_path="${SCRIPT_HELPERS_DIR}/templates/packaging/brew/app.rb"

# Values reach awk through the environment, not -v: the original awk
# (macOS) rejects a -v value containing a newline ("newline in string"),
# and the dependency lists are multi-line.
_PKG_APP_NAME="$APP_NAME" \
_PKG_APP_BIN_NAME="$APP_BIN_NAME" \
_PKG_APP_VERSION="$APP_VERSION" \
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
    APP_VERSION = ENVIRON["_PKG_APP_VERSION"]
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
    $0 = subst($0, "@APP_VERSION@", APP_VERSION)
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
  }' "$template_path" > "$output_path"

log_info "Rendered formula: $output_path"
