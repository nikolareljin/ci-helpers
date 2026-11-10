#!/usr/bin/env bash
# SCRIPT: setup_php.sh
# DESCRIPTION: Install the requested PHP on an Ubuntu runner from apt, so a
#              workflow runs no third-party action for it. A version the
#              image's own sources hold (8.3 on ubuntu-24.04) comes from
#              them; any other comes from the ondrej/php PPA, added here with
#              its signing key fetched by fingerprint from keyserver.ubuntu.com
#              and checked against the fingerprint pinned in
#              toolchain-pins.env before apt reads it. Extensions are apt
#              packages (php<ver>-<ext>); a name apt has no package for is
#              refused, nothing is built from PECL. Xdebug is installed and
#              enabled for coverage unless PHP_COVERAGE says pcov or none, as
#              the replaced action did. ini values go to one mods-available
#              file enabled for every SAPI. update-alternatives points php,
#              phar, php-config, phpize and phpdbg at the version, and `php`
#              on PATH is checked to report it. Composer is the release pinned
#              by version and sha256 in toolchain-pins.env, downloaded from
#              getcomposer.org and installed only after the digest matches;
#              a composer already on PATH with that digest is kept.
# USAGE: PHP_VERSION=<X.Y> bash scripts/setup_php.sh
# ENVIRONMENT:
#   PHP_VERSION      X.Y, such as 8.4. Required.
#   PHP_EXTENSIONS   Comma-separated extension names (the action's
#                    `extensions`), added to the default set. `name:version`,
#                    `:name` (disable) and anything apt has no package for
#                    are refused.
#   PHP_INI_VALUES   Comma- or newline-separated `key=value` lines (the
#                    action's `ini-values`), written after the defaults
#                    `date.timezone=UTC` and `memory_limit=-1`.
#   PHP_COVERAGE     xdebug (default), pcov or none.
#   PHP_TOOLS        Comma-separated; `composer` (also `composer:v2`,
#                    `composer:2`) or empty. Composer is installed either
#                    way, as the action did; any other tool is refused.
#   TOOLCHAIN_PINS   Pins file (default: toolchain-pins.env beside scripts/).
#   GITHUB_PATH, GITHUB_ENV, GITHUB_OUTPUT  Written when set.
#   PHP_SETUP_OS_RELEASE, PHP_SETUP_APT_ETC, PHP_SETUP_PHP_ETC,
#   PHP_SETUP_USR_BIN, PHP_SETUP_BIN_DIR, PHP_SETUP_COMPOSER_HOME
#                    Roots the tests redirect (/etc/os-release, /etc/apt,
#                    /etc/php, /usr/bin, /usr/local/bin and Composer's
#                    home).
# OUTPUT: php_version=<X.Y.Z php reports>, composer_version=<pinned>, on
#         stdout and, when GITHUB_OUTPUT is set, appended there.
# EXIT CODES:
#   0  php on PATH reports PHP_VERSION, the extensions load, composer runs.
#   1  apt could not install, the PPA key or the composer digest does not
#      match its pin, an extension did not load, or php reports another
#      version.
#   2  Usage error: no or malformed version, a refused extension, ini
#      line, coverage or tool, a missing pin, not an apt-based Linux.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
version="${PHP_VERSION:-}"
extensions="${PHP_EXTENSIONS:-}"
ini_values="${PHP_INI_VALUES:-}"
coverage="${PHP_COVERAGE:-xdebug}"
tools="${PHP_TOOLS:-}"
os_release="${PHP_SETUP_OS_RELEASE:-/etc/os-release}"
apt_etc="${PHP_SETUP_APT_ETC:-/etc/apt}"
php_etc="${PHP_SETUP_PHP_ETC:-/etc/php}"
bin_dir="${PHP_SETUP_BIN_DIR:-/usr/local/bin}"
usr_bin="${PHP_SETUP_USR_BIN:-/usr/bin}"

die() { echo "::error::$1" >&2; exit "${2:-1}"; }

# --- Inputs -------------------------------------------------------------
[[ -n "$version" ]] || die "PHP_VERSION is empty; name a version such as 8.4." 2
[[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || die "PHP_VERSION '$version' is not X.Y; this script installs apt's php<X.Y> packages, so 'latest', 'nightly' and X.Y.Z are not accepted." 2
case "$coverage" in
  xdebug|pcov|none) ;;
  *) die "PHP_COVERAGE '$coverage' is not xdebug, pcov or none." 2 ;;
esac

# Tools: composer only. The action set up composer whether or not it was
# named; the other tools it knew (phpunit, phpstan, ...) are refused here
# rather than silently skipped.
if [[ -n "$tools" ]]; then
  old_ifs="$IFS"; IFS=','
  for t in $tools; do
    t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
    [[ -n "$t" ]] || continue
    case "$t" in
      composer|composer:v2|composer:2) ;;
      *) die "PHP_TOOLS names '$t', which this script does not install; only composer (pinned in toolchain-pins.env) is supported. Install other tools in your own step with composer." 2 ;;
    esac
  done
  IFS="$old_ifs"
fi

# ini values: `key=value` only, one per comma or line.
ini_lines=""
if [[ -n "$ini_values" ]]; then
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_.]*=[^[:cntrl:]]*$ ]] || die "PHP_INI_VALUES line '$line' is not key=value." 2
    ini_lines="$ini_lines$line"$'\n'
  done <<EOF
$(printf '%s' "$ini_values" | tr ',' '\n')
EOF
fi

# --- Pins ----------------------------------------------------------------
pin() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"
}
[[ -f "$pins" ]] || die "Pins file $pins is missing." 2
ppa_fingerprint="$(pin PHP_PPA_FINGERPRINT)"
composer_version="$(pin COMPOSER_VERSION)"
composer_sha256="$(pin COMPOSER_PHAR_SHA256)"
[[ "$ppa_fingerprint" =~ ^[0-9A-F]{40}$ ]] || die "PHP_PPA_FINGERPRINT in $pins is '$ppa_fingerprint', not 40 upper-case hex digits." 2
[[ "$composer_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "COMPOSER_VERSION in $pins is '$composer_version', not X.Y.Z." 2
[[ "$composer_sha256" =~ ^[0-9a-f]{64}$ ]] || die "COMPOSER_PHAR_SHA256 in $pins is '$composer_sha256', not 64 hex digits." 2

# --- Platform ------------------------------------------------------------
[[ -r "$os_release" ]] || die "No $os_release; this script installs PHP with apt on Ubuntu and knows no other runner." 2
# shellcheck disable=SC1090  # /etc/os-release, or the tests' copy
os_id="$(. "$os_release" && printf '%s' "${ID:-}")"
# shellcheck disable=SC1090
os_like="$(. "$os_release" && printf '%s' "${ID_LIKE:-}")"
# shellcheck disable=SC1090
os_codename="$(. "$os_release" && printf '%s' "${VERSION_CODENAME:-}")"
case " $os_id $os_like " in
  *" ubuntu "*|*" debian "*) ;;
  *) die "This runner is '$os_id', not Ubuntu or Debian; this script installs PHP with apt and knows no other package manager. Use an Ubuntu runner." 2 ;;
esac
[[ -n "$os_codename" ]] || die "$os_release has no VERSION_CODENAME; the PPA suite cannot be named." 2
command -v apt-get >/dev/null 2>&1 || die "apt-get is not on PATH." 2
sudo_cmd=""
if [[ "$(id -u)" != 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Not root and no sudo on PATH; apt needs one of them." 2
  sudo_cmd="sudo -n"
fi
as_root() { $sudo_cmd env DEBIAN_FRONTEND=noninteractive "$@"; }

# --- Packages -------------------------------------------------------------
# The extensions the action's builds carried, as apt packages. Names that
# are compiled into php<ver>-cli or php<ver>-common need no package and are
# checked against `php -m` only.
default_packages="cli common bcmath bz2 curl gd gmp intl mbstring mysql opcache pgsql readline soap sqlite3 xml xsl zip"
builtin_exts="calendar core ctype date exif ffi fileinfo filter ftp gettext hash iconv json libxml openssl pcntl pcre pdo phar posix random reflection session shmop sockets sodium spl standard sysvmsg sysvsem sysvshm tokenizer zlib"

# package_for <extension>: the apt package suffix, or empty for a builtin.
package_for() {
  case "$1" in
    pdo_mysql|mysqli|mysqlnd) echo mysql ;;
    pdo_pgsql) echo pgsql ;;
    pdo_sqlite) echo sqlite3 ;;
    dom|simplexml|xmlreader|xmlwriter|xml) echo xml ;;
    zend\ opcache) echo opcache ;;
    *) case " $builtin_exts " in *" $1 "*) echo "" ;; *) echo "$1" ;; esac ;;
  esac
}

# The extensions to check after install (lowercase), and the packages.
check_exts=""
packages="$default_packages"
if [[ -n "$extensions" ]]; then
  old_ifs="$IFS"; IFS=','
  for e in $extensions; do
    e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"
    e="$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')"
    [[ -n "$e" ]] || continue
    [[ "$e" != :* ]] || die "PHP_EXTENSIONS names '$e'; disabling an extension with a leading ':' is not supported here." 2
    [[ "$e" != *:* ]] || die "PHP_EXTENSIONS names '$e'; a version after ':' is not supported, apt's package version is installed." 2
    [[ "$e" =~ ^[a-z0-9_]+$ ]] || die "PHP_EXTENSIONS names '$e', not an extension name." 2
    case "$e" in
      xdebug|pcov) die "PHP_EXTENSIONS names '$e'; choose the coverage driver with PHP_COVERAGE." 2 ;;
    esac
    check_exts="$check_exts $e"
    p="$(package_for "$e")"
    [[ -z "$p" ]] || packages="$packages $p"
  done
  IFS="$old_ifs"
fi
case "$coverage" in
  xdebug) packages="$packages xdebug" ;;
  pcov) packages="$packages pcov" ;;
esac
# Deduplicate, keep order, prefix.
pkg_list=""
for p in $packages; do
  case " $pkg_list " in *" php$version-$p "*) ;; *) pkg_list="$pkg_list php$version-$p" ;; esac
done
pkg_list="${pkg_list# }"

installed() {
  [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]
}
# A module apt installed for this version, whether its package is real or a
# Provides (php-xdebug provides php8.3-xdebug on noble).
has_mod_ini() {
  [[ -f "$php_etc/$version/mods-available/$1.ini" ]]
}
missing=""
for p in $pkg_list; do
  installed "$p" || missing="$missing $p"
done
missing="${missing# }"

# --- Sources ---------------------------------------------------------------
# The PPA is added only when the image's sources cannot supply php<ver>-cli:
# ubuntu-24.04 ships 8.3 from its own archive, every other version needs
# ondrej/php. The key comes from keyserver.ubuntu.com by fingerprint over
# TLS and is checked against the pin before apt sees it; apt then verifies
# every index it fetches from the PPA against that key.
candidate() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2; exit }'
}
ppa_sources="$apt_etc/sources.list.d/ci-helpers-ondrej-php.sources"
ppa_keyring="$apt_etc/keyrings/ci-helpers-ondrej-php.gpg"
if [[ -n "$missing" ]]; then
  cand="$(candidate "php$version-cli")"
  if [[ -z "$cand" || "$cand" == "(none)" ]]; then
    if [[ ! -f "$ppa_sources" ]]; then
      echo "php$version-cli is not in the runner's apt sources; adding the ondrej/php PPA for $os_codename"
      keytmp="$(mktemp -d)"
      trap 'rm -rf "$keytmp"' EXIT
      curl -fsSL --retry 3 --proto '=https' --tlsv1.2 \
        -o "$keytmp/key.asc" \
        "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$ppa_fingerprint" \
        || die "Could not fetch the PPA signing key 0x$ppa_fingerprint from keyserver.ubuntu.com." 1
      gpg --batch --dearmor -o "$keytmp/key.gpg" "$keytmp/key.asc" 2>/dev/null \
        || die "The key fetched for 0x$ppa_fingerprint is not an OpenPGP key." 1
      # Exactly one primary key, and it is the pinned one. A keyserver can
      # return several keys for a search, or a key someone else uploaded.
      fprs="$(gpg --batch --show-keys --with-colons "$keytmp/key.gpg" 2>/dev/null | awk -F: 'pub { if ($1 == "fpr") { print $10; pub = 0 } } $1 == "pub" { pub = 1 }')"
      [[ "$fprs" == "$ppa_fingerprint" ]] || die "The key from keyserver.ubuntu.com has fingerprint(s) '$(printf '%s' "$fprs" | tr '\n' ' ')', not the pinned $ppa_fingerprint; refusing to trust it." 1
      as_root install -d -m 0755 "$apt_etc/keyrings" "$apt_etc/sources.list.d"
      as_root install -m 0644 "$keytmp/key.gpg" "$ppa_keyring"
      printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/ondrej/php/ubuntu/\nSuites: %s\nComponents: main\nSigned-By: %s\n' "$os_codename" "$ppa_keyring" > "$keytmp/php.sources"
      as_root install -m 0644 "$keytmp/php.sources" "$ppa_sources"
      rm -rf "$keytmp"; trap - EXIT
    fi
  fi
  echo "apt-get update"
  as_root apt-get update -qq || die "apt-get update failed." 1
  cand="$(candidate "php$version-cli")"
  if [[ -z "$cand" || "$cand" == "(none)" ]]; then
    die "No php$version-cli package for $os_codename in the runner's sources or the ondrej/php PPA; PHP $version is not packaged there. Choose a version the PPA builds for this Ubuntu." 1
  fi
  # Refuse an extension with no package before installing anything, with the
  # name the caller used.
  bad=""
  for p in $missing; do
    c="$(candidate "$p")"
    if [[ -z "$c" || "$c" == "(none)" ]]; then
      # A virtual package (Provides) has no candidate but may be installable.
      apt-cache showpkg "$p" 2>/dev/null | awk '/^Reverse Provides:/ { f = 1; next } f && NF { found = 1 } END { exit !found }' || bad="$bad $p"
    fi
  done
  if [[ -n "$bad" ]]; then
    die "No apt package for:$bad. An extension named in PHP_EXTENSIONS must be packaged as php$version-<name> in Ubuntu or the ondrej/php PPA; this script builds nothing from PECL." 2
  fi
  echo "apt-get install $missing"
  # shellcheck disable=SC2086  # the package list is one word per package
  as_root apt-get install -y -qq --no-install-recommends $missing || die "apt-get install failed for: $missing" 1
fi

# --- Coverage driver and ini ----------------------------------------------
# One ini file for every SAPI: the defaults the action wrote, the coverage
# driver's switch, then the caller's values, in that order so a caller's
# value wins.
php_bin="$usr_bin/php$version"
[[ -x "$php_bin" ]] || die "$php_bin is missing after install." 1
mods_dir="$php_etc/$version/mods-available"
as_root install -d -m 0755 "$mods_dir"
case "$coverage" in
  xdebug)
    as_root phpenmod -v "$version" xdebug
    ! has_mod_ini pcov || as_root phpdismod -v "$version" pcov
    driver_ini="xdebug.mode=coverage"
    ;;
  pcov)
    ! has_mod_ini xdebug || as_root phpdismod -v "$version" xdebug
    as_root phpenmod -v "$version" pcov
    driver_ini="pcov.enabled=1"
    ;;
  none)
    ! has_mod_ini xdebug || as_root phpdismod -v "$version" xdebug
    ! has_mod_ini pcov || as_root phpdismod -v "$version" pcov
    driver_ini=""
    ;;
esac
initmp="$(mktemp)"
{
  printf '; priority=99\n; written by ci-helpers setup_php.sh\ndate.timezone=UTC\nmemory_limit=-1\n'
  [[ -z "$driver_ini" ]] || printf '%s\n' "$driver_ini"
  [[ -z "$ini_lines" ]] || printf '%s' "$ini_lines"
} > "$initmp"
as_root install -m 0644 "$initmp" "$mods_dir/ci-helpers.ini"
rm -f "$initmp"
as_root phpenmod -v "$version" ci-helpers

# --- Alternatives ------------------------------------------------------------
# As the action did: every binary of the version becomes the default, with
# the version digits as the priority.
for tool in php phar phar.phar php-config phpize phpdbg php-cgi; do
  target="$usr_bin/$tool$version"
  [[ -e "$target" ]] || continue
  as_root update-alternatives --quiet --install "$usr_bin/$tool" "$tool" "$target" "${version//./}" 2>/dev/null || true
  as_root update-alternatives --quiet --set "$tool" "$target" || die "update-alternatives could not point $tool at $target." 1
done
hash -r 2>/dev/null || true

# --- Checks ------------------------------------------------------------------
reported="$(php -r 'echo PHP_VERSION;' 2>/dev/null || true)"
[[ "$reported" == "$version".* ]] || die "php on PATH ($(command -v php || echo none)) reports '$reported', not $version.x." 1
modules="$(php -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
has_module() {
  local name="$1"
  [[ "$name" != opcache ]] || name="zend opcache"
  printf '%s\n' "$modules" | grep -qx -- "$name"
}
for e in $check_exts; do
  has_module "$e" || die "Extension '$e' is installed but php -m does not list it." 1
done
case "$coverage" in
  xdebug) has_module xdebug || die "Xdebug is not loaded after phpenmod." 1 ;;
  pcov) has_module pcov || die "PCOV is not loaded after phpenmod." 1 ;;
  none) if has_module xdebug || has_module pcov; then die "A coverage driver is still loaded with PHP_COVERAGE=none." 1; fi ;;
esac
echo "php $reported from $(command -v php) is on PATH (coverage: $coverage)"

# --- Composer ----------------------------------------------------------------
# The pinned release only. An existing composer whose phar has the pinned
# digest is kept (the hosted image ships one); anything else is replaced.
have_composer=""
if command -v composer >/dev/null 2>&1; then
  existing="$(command -v composer)"
  if [[ -f "$existing" && "$(sha256sum "$existing" | awk '{ print $1 }')" == "$composer_sha256" ]]; then
    have_composer="$existing"
  fi
fi
if [[ -z "$have_composer" ]]; then
  ctmp="$(mktemp -d)"
  trap 'rm -rf "$ctmp"' EXIT
  url="https://getcomposer.org/download/$composer_version/composer.phar"
  echo "Downloading composer $composer_version from getcomposer.org"
  curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "$ctmp/composer.phar" "$url" \
    || die "Could not download $url." 1
  actual="$(sha256sum "$ctmp/composer.phar" | awk '{ print $1 }')"
  if [[ "$actual" != "$composer_sha256" ]]; then
    rm -f "$ctmp/composer.phar"
    die "composer.phar $composer_version from getcomposer.org has sha256 $actual, not the pinned $composer_sha256; not installed." 1
  fi
  as_root install -d -m 0755 "$bin_dir"
  as_root install -m 0755 "$ctmp/composer.phar" "$bin_dir/composer"
  rm -rf "$ctmp"; trap - EXIT
  have_composer="$bin_dir/composer"
  hash -r 2>/dev/null || true
fi
composer_reported="$("$have_composer" --version --no-ansi 2>/dev/null | awk '/^Composer version/ { print $3; exit }')"
[[ "$composer_reported" == "$composer_version" ]] || die "$have_composer reports version '$composer_reported', not the pinned $composer_version." 1
# Later steps run whatever `composer` resolves to; it must be this one.
on_path="$(command -v composer || true)"
[[ "$on_path" == "$have_composer" ]] || die "composer on PATH is '$on_path', not $have_composer; a later step would run the other one." 1
echo "composer $composer_version at $have_composer"

# The action exported these for every later step, and put Composer's global
# bin directory on PATH.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  for kv in COMPOSER_PROCESS_TIMEOUT=0 COMPOSER_NO_INTERACTION=1 COMPOSER_NO_AUDIT=1; do
    k="${kv%%=*}"
    [[ -n "${!k:-}" ]] || printf '%s\n' "$kv" >> "$GITHUB_ENV"
  done
fi
if [[ -n "${GITHUB_PATH:-}" ]]; then
  composer_bin="$(env ${PHP_SETUP_COMPOSER_HOME:+COMPOSER_HOME="$PHP_SETUP_COMPOSER_HOME"} "$have_composer" global config bin-dir --absolute --no-ansi 2>/dev/null || true)"
  [[ -z "$composer_bin" ]] || printf '%s\n' "$composer_bin" >> "$GITHUB_PATH"
fi

printf 'php_version=%s\ncomposer_version=%s\n' "$reported" "$composer_version"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'php_version=%s\ncomposer_version=%s\n' "$reported" "$composer_version" >> "$GITHUB_OUTPUT"
fi
