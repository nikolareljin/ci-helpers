#!/usr/bin/env bash
# SCRIPT: setup_php_test.sh
# DESCRIPTION: scripts/setup_php.sh installs PHP from apt the way the
#              replaced action set it up (the version's packages, Xdebug for
#              coverage unless told otherwise, one ini file, alternatives,
#              composer pinned by digest), adds the ondrej/php PPA only when
#              the runner's sources lack the version and only under the
#              pinned key fingerprint, refuses every input it does not
#              support instead of ignoring it, and refuses a composer whose
#              digest is not the pin. apt, gpg, curl, php and the rest are
#              stubs that log what they were asked; nothing is downloaded
#              or installed. Runs under bash 3.2.
# USAGE: bash tests/setup_php_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/setup_php.sh"
pins="$root/toolchain-pins.env"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

fpr="$(awk -F= '$1 == "PHP_PPA_FINGERPRINT" { print $2 }' "$pins")"
composer_version="$(awk -F= '$1 == "COMPOSER_VERSION" { print $2 }' "$pins")"
[[ "$fpr" =~ ^[0-9A-F]{40}$ ]] || { echo "FAIL PHP_PPA_FINGERPRINT is '$fpr'"; fail=1; }
[[ "$composer_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL COMPOSER_VERSION is '$composer_version'"; fail=1; }
grep -Eq '^COMPOSER_PHAR_SHA256=[0-9a-f]{64}$' "$pins" || { echo "FAIL COMPOSER_PHAR_SHA256 is not 64 hex digits"; fail=1; }

# A fake composer.phar: a script that reports the pinned version. The test
# pins file carries its digest, so the "right digest" path is exercised.
printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "Composer version %s 2026-01-01 00:00:00" ;; global) echo "/home/x/.config/composer/vendor/bin" ;; esac\n' "$composer_version" > "$work/composer.phar"
chmod +x "$work/composer.phar"
phar_sha="$(sha256sum "$work/composer.phar" | awk '{ print $1 }')"
sed "s/^COMPOSER_PHAR_SHA256=.*/COMPOSER_PHAR_SHA256=$phar_sha/" "$pins" > "$work/pins.env"
# A valid-looking key file (gpg is a stub; it reads the fingerprint list).
printf 'fake key\n' > "$work/key.asc"

# The system directories, minus any composer: a hosted runner ships the
# pinned composer in /usr/bin, which would otherwise answer for the stubs.
# SETUP_PHP_TEST_SYSBIN adds a directory in front (the test of this guard).
sysbin="$work/sysbin"; mkdir -p "$sysbin"
for d in ${SETUP_PHP_TEST_SYSBIN:-} /bin /usr/bin; do
  for f in "$d"/*; do
    b="${f##*/}"
    [[ "$b" != composer && ! -e "$sysbin/$b" && ! -L "$sysbin/$b" ]] || continue
    ln -s "$f" "$sysbin/$b"
  done
done

# --- stubs -----------------------------------------------------------------
stubs="$work/stubs"; mkdir -p "$stubs"
state="$work/state"
cat > "$stubs/sudo" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "-n" ]] && shift
exec "$@"
SH
cat > "$stubs/apt-get" <<'SH'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STATE/log"
case "$1" in
  update)
    touch "$STATE/updated"
    if [[ -f "$APT_ETC/sources.list.d/ci-helpers-ondrej-php.sources" ]]; then
      [[ ! -f "$STATE/ppa_no_suite" ]] || { echo "E: The repository 'https://ppa.launchpadcontent.net/ondrej/php/ubuntu x Release' does not have a Release file."; exit 100; }
      touch "$STATE/ppa_updated"
    fi
    exit 0 ;;
  install)
    for a in "$@"; do
      case "$a" in
        php*-*) echo "$a" >> "$STATE/installed"
                v="${a#php}"; v="${v%%-*}"; e="${a#php*-}"
                case "$e" in xdebug|pcov) mkdir -p "$PHP_ETC/$v/mods-available"; touch "$PHP_ETC/$v/mods-available/$e.ini" ;; esac ;;
      esac
    done ;;
esac
SH
cat > "$stubs/apt-cache" <<'SH'
#!/usr/bin/env bash
echo "apt-cache $*" >> "$STATE/log"
case "$1" in
  policy)
    have=0
    if ! grep -qx -- "$2" "$STATE/unavailable" 2>/dev/null; then
      while IFS= read -r pat; do [[ -n "$pat" ]] || continue; case "$2" in $pat) have=1 ;; esac; done < "$STATE/available"
      if [[ -f "$STATE/updated" ]]; then
        while IFS= read -r pat; do [[ -n "$pat" ]] || continue; case "$2" in $pat) have=1 ;; esac; done < "$STATE/available_after_update"
      fi
      [[ ! -f "$STATE/ppa_updated" ]] || have=1
    fi
    if [[ "$have" == 1 ]]; then printf '%s:\n  Installed: (none)\n  Candidate: 1.0\n' "$2"; else printf '%s:\n  Installed: (none)\n  Candidate: (none)\n' "$2"; fi ;;
  showpkg) printf 'Package: %s\nReverse Provides: \n' "$2"; if grep -qx -- "$2" "$STATE/provided" 2>/dev/null; then echo "php-${2#php*-} 3.0"; fi ;;
esac
SH
cat > "$stubs/dpkg-query" <<'SH'
#!/usr/bin/env bash
pkg="${@: -1}"
if grep -qx -- "$pkg" "$STATE/installed" 2>/dev/null; then echo "install ok installed"; else exit 1; fi
SH
cat > "$stubs/gpg" <<'SH'
#!/usr/bin/env bash
echo "gpg $*" >> "$STATE/log"
case "$*" in
  *--dearmor*) out=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && { out="$2"; shift; }; in="$1"; shift; done; cp "$in" "$out" ;;
  *--show-keys*) while IFS= read -r f; do printf 'pub:-:4096:1:X::1::::::scESC::::::23::0:\nfpr:::::::::%s:\nuid:-::::1::X::Launchpad PPA:::::::::0:\nsub:-:4096:1:Y::1::::::s::::::23:\nfpr:::::::::0000000000000000000000000000000000000000:\n' "$f"; done < "$STATE/key_fprs" ;;
esac
SH
cat > "$stubs/curl" <<'SH'
#!/usr/bin/env bash
out=""; url=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift ;; http*) url="$1" ;; esac; shift; done
echo "curl $url" >> "$STATE/log"
[[ -z "${CURL_FAIL:-}" ]] || exit 22
case "$url" in
  *keyserver.ubuntu.com*) cp "$STATE/key.asc" "$out" ;;
  *getcomposer.org*) cp "$STATE/phar" "$out" ;;
  *) exit 22 ;;
esac
SH
for t in phpenmod phpdismod update-alternatives; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STATE/log"\n' "$t" > "$stubs/$t"
done
# php: reports what the state says, as the installed php would.
cat > "$stubs/php" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -r) cat "$STATE/php_version" ;;
  -m) printf '[PHP Modules]\n'; cat "$STATE/modules"; printf '\n[Zend Modules]\n' ;;
esac
SH
chmod +x "$stubs"/*

# run <name> <expected rc> [VAR=value ...]: a fresh state each time.
# STATE_* knobs: STATE_INSTALLED (packages, space-separated), STATE_AVAILABLE
# (candidate globs, before any update), STATE_UNAVAILABLE (never a candidate),
# STATE_PROVIDED (Reverse Provides only), STATE_PHP_VERSION, STATE_MODULES
# (`|`-separated, what php -m lists), STATE_MODS (mods-available ini files
# already there), STATE_FPR, STATE_EXISTING_COMPOSER (path to copy onto
# PATH as composer), STATE_PPA_PRESENT (the source file already written),
# STATE_SHADOW (that composer stays first on PATH), STATE_OS_ID. After an `apt-get update` with the PPA source written, every
# package not in STATE_UNAVAILABLE has a candidate.
run() {
  local name="$1" want="$2" rc=0 v=8.4 a; shift 2
  for a in "$@"; do case "$a" in PHP_VERSION=*) v="${a#*=}" ;; esac; done
  rm -rf "${work:?}/gh" "${state:?}" "${work:?}/etc" "${work:?}/usr" "${work:?}/path"
  mkdir -p "$work/gh" "$state" "$work/etc/apt" "$work/etc/php" "$work/usr/bin" "$work/usr/local/bin" "$work/path"
  printf '%s\n' ${STATE_INSTALLED:-} > "$state/installed"
  printf '%s\n' ${STATE_AVAILABLE:-} > "$state/available"
  printf '%s\n' ${STATE_UNAVAILABLE:-} > "$state/unavailable"
  printf '%s\n' ${STATE_PROVIDED:-} > "$state/provided"
  printf '%s\n' ${STATE_AVAILABLE_AFTER_UPDATE:-} > "$state/available_after_update"
  [[ -z "${STATE_PPA_NO_SUITE:-}" ]] || touch "$state/ppa_no_suite"
  printf '%s' "${STATE_PHP_VERSION:-8.4.3}" > "$state/php_version"
  printf '%s\n' "${STATE_MODULES:-core|date|xdebug}" | tr '|' '\n' > "$state/modules"
  [[ -z "${STATE_PPA_PRESENT:-}" ]] || { mkdir -p "$work/etc/apt/sources.list.d"; printf 'Types: deb\n' > "$work/etc/apt/sources.list.d/ci-helpers-ondrej-php.sources"; }
  printf '%s\n' "${STATE_FPR:-$fpr}" > "$state/key_fprs"
  cp "$work/key.asc" "$state/key.asc"
  cp "$work/composer.phar" "$state/phar"
  : > "$state/log"
  if [[ -n "${STATE_OS_RELEASE:-}" ]]; then printf '%s\n' "$STATE_OS_RELEASE"
  elif [[ -n "${STATE_OS_ID:-}" ]]; then printf 'ID=%s\nVERSION_ID=3.20\n' "$STATE_OS_ID"; else printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_CODENAME=noble\n'; fi > "$work/etc/os-release"
  for v in 8.1 8.2 8.3 8.4; do
    for t in php phar phar.phar php-config phpize phpdbg; do printf '#!/bin/sh\n' > "$work/usr/bin/$t$v"; chmod +x "$work/usr/bin/$t$v"; done
  done
  [[ -z "${STATE_EXISTING_COMPOSER:-}" ]] || cp "$STATE_EXISTING_COMPOSER" "$work/path/composer"
  [[ -z "${STATE_EXISTING_COMPOSER:-}" ]] || chmod +x "$work/path/composer"
  [[ -z "${STATE_MODS:-}" ]] || for m in $STATE_MODS; do mkdir -p "$work/etc/php/$v/mods-available"; touch "$work/etc/php/$v/mods-available/$m.ini"; done
  # As on the runner, /usr/local/bin precedes /usr/bin; STATE_SHADOW puts
  # the pre-existing composer first instead.
  local path="$work/usr/local/bin:$work/path:$stubs:$sysbin"
  [[ -z "${STATE_SHADOW:-}" ]] || path="$work/path:$work/usr/local/bin:$stubs:$sysbin"
  env -i PATH="$path" HOME="$work" STATE="$state" PHP_ETC="$work/etc/php" APT_ETC="$work/etc/apt" \
    TOOLCHAIN_PINS="${TEST_PINS:-$work/pins.env}" \
    PHP_SETUP_OS_RELEASE="$work/etc/os-release" PHP_SETUP_APT_ETC="$work/etc/apt" PHP_SETUP_PHP_ETC="$work/etc/php" \
    PHP_SETUP_USR_BIN="$work/usr/bin" PHP_SETUP_BIN_DIR="$work/usr/local/bin" PHP_SETUP_COMPOSER_HOME="$work/composer-home" \
    GITHUB_PATH="$work/gh/path" GITHUB_ENV="$work/gh/env" GITHUB_OUTPUT="$work/gh/out" \
    "$@" bash "$script" > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
  return 0
}
says() { grep -qF -- "$1" "$work/out" || { echo "FAIL $name: no '$1' in output:"; cat "$work/out"; fail=1; }; }
logged() { grep -qF -- "$1" "$state/log" || { echo "FAIL $name: stubs never saw '$1':"; cat "$state/log"; fail=1; }; }
not_logged() { ! grep -qF -- "$1" "$state/log" || { echo "FAIL $name: stubs saw '$1':"; cat "$state/log"; fail=1; }; }

# --- the image's 8.3: nothing fetched, nothing installed ---------------------
name="a version the image holds installs nothing and adds no source"
all83="php8.3-cli php8.3-common php8.3-bcmath php8.3-bz2 php8.3-curl php8.3-gd php8.3-gmp php8.3-intl php8.3-mbstring php8.3-mysql php8.3-opcache php8.3-pgsql php8.3-readline php8.3-soap php8.3-sqlite3 php8.3-xml php8.3-xsl php8.3-zip php8.3-xdebug"
STATE_INSTALLED="$all83" STATE_AVAILABLE="php8.3-*" STATE_PHP_VERSION=8.3.6 STATE_MODS="xdebug" STATE_EXISTING_COMPOSER="$work/composer.phar" \
  run "$name" 0 PHP_VERSION=8.3 && {
  not_logged "apt-get"; not_logged "curl"
  [[ ! -e "$work/etc/apt/sources.list.d/ci-helpers-ondrej-php.sources" ]] || { echo "FAIL $name: PPA source written"; fail=1; }
  logged "phpenmod -v 8.3 xdebug"
  logged "update-alternatives --quiet --set php $work/usr/bin/php8.3"
  logged "update-alternatives --quiet --set phpize $work/usr/bin/phpize8.3"
  grep -q "^php_version=8.3.6$" "$work/gh/out" || { echo "FAIL $name: php_version output"; cat "$work/gh/out"; fail=1; }
  grep -q "^composer_version=$composer_version$" "$work/gh/out" || { echo "FAIL $name: composer_version output"; fail=1; }
  [[ ! -e "$work/usr/local/bin/composer" ]] || { echo "FAIL $name: composer re-installed over one with the pinned digest"; fail=1; }
  says "composer $composer_version at $work/path/composer"
  for kv in COMPOSER_PROCESS_TIMEOUT=0 COMPOSER_NO_INTERACTION=1 COMPOSER_NO_AUDIT=1; do
    grep -qx "$kv" "$work/gh/env" || { echo "FAIL $name: $kv not in GITHUB_ENV"; cat "$work/gh/env"; fail=1; }
  done
  grep -qx "/home/x/.config/composer/vendor/bin" "$work/gh/path" || { echo "FAIL $name: composer bin-dir not on GITHUB_PATH"; cat "$work/gh/path"; fail=1; }
  ini="$work/etc/php/8.3/mods-available/ci-helpers.ini"
  [[ -f "$ini" ]] || { echo "FAIL $name: no $ini"; fail=1; }
  grep -qx "date.timezone=UTC" "$ini" && grep -qx "memory_limit=-1" "$ini" && grep -qx "xdebug.mode=coverage" "$ini" || { echo "FAIL $name: ini defaults:"; cat "$ini"; fail=1; }
  logged "phpenmod -v 8.3 ci-helpers"
}

name="a COMPOSER_* variable already set is left alone"
STATE_INSTALLED="$all83" STATE_AVAILABLE="php8.3-*" STATE_PHP_VERSION=8.3.6 STATE_EXISTING_COMPOSER="$work/composer.phar" \
  run "$name" 0 PHP_VERSION=8.3 COMPOSER_NO_AUDIT=0 && {
  ! grep -q "^COMPOSER_NO_AUDIT=" "$work/gh/env" || { echo "FAIL $name: COMPOSER_NO_AUDIT rewritten"; cat "$work/gh/env"; fail=1; }
  grep -qx "COMPOSER_NO_INTERACTION=1" "$work/gh/env" || { echo "FAIL $name: the unset one is missing"; fail=1; }
}

# --- a version the image lacks: the PPA under the pinned key --------------------
name="a version the image lacks comes from the PPA under the pinned key"
run "$name" 0 PHP_VERSION=8.4 && {
  logged "curl https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$fpr"
  src="$work/etc/apt/sources.list.d/ci-helpers-ondrej-php.sources"
  [[ -f "$src" ]] || { echo "FAIL $name: no PPA source file"; fail=1; }
  grep -qx "Suites: noble" "$src" && grep -qx "Signed-By: $work/etc/apt/keyrings/ci-helpers-ondrej-php.gpg" "$src" && grep -q "ppa.launchpadcontent.net/ondrej/php" "$src" || { echo "FAIL $name: source file:"; cat "$src"; fail=1; }
  [[ -f "$work/etc/apt/keyrings/ci-helpers-ondrej-php.gpg" ]] || { echo "FAIL $name: keyring not installed"; fail=1; }
  logged "apt-get update"
  logged "apt-get install -y -qq --no-install-recommends php8.4-cli php8.4-common php8.4-bcmath php8.4-bz2 php8.4-curl php8.4-gd php8.4-gmp php8.4-intl php8.4-mbstring php8.4-mysql php8.4-opcache php8.4-pgsql php8.4-readline php8.4-soap php8.4-sqlite3 php8.4-xml php8.4-xsl php8.4-zip php8.4-xdebug"
  logged "curl https://getcomposer.org/download/$composer_version/composer.phar"
  [[ -x "$work/usr/local/bin/composer" ]] || { echo "FAIL $name: composer not installed"; fail=1; }
  says "composer $composer_version at $work/usr/local/bin/composer"
  says "php 8.4.3 from"
}
name="a PPA source already written is not fetched again"
STATE_PPA_PRESENT=1 run "$name" 0 PHP_VERSION=8.4 && { not_logged "keyserver.ubuntu.com"; logged "apt-get update"; logged "apt-get install"; }

name="a key whose fingerprint is not the pin is refused before apt sees it"
STATE_FPR="0123456789ABCDEF0123456789ABCDEF01234567" run "$name" 1 PHP_VERSION=8.4 && {
  says "not the pinned $fpr"
  [[ ! -e "$work/etc/apt/sources.list.d/ci-helpers-ondrej-php.sources" ]] || { echo "FAIL $name: source written under a wrong key"; fail=1; }
  [[ ! -e "$work/etc/apt/keyrings/ci-helpers-ondrej-php.gpg" ]] || { echo "FAIL $name: keyring installed under a wrong key"; fail=1; }
  not_logged "apt-get install"
}

name="a Debian runner lacking the version is refused, the Ubuntu PPA is not added"
STATE_OS_RELEASE="$(printf 'ID=debian\nVERSION_CODENAME=bookworm')" run "$name" 2 PHP_VERSION=8.4 && {
  says "builds for Ubuntu only"; not_logged "keyserver"; not_logged "apt-get install"
  [[ ! -e "$work/etc/apt/sources.list.d/ci-helpers-ondrej-php.sources" ]] || { echo "FAIL $name: Ubuntu PPA written on Debian"; fail=1; }
}
name="an Ubuntu derivative gets the PPA suite of its Ubuntu base"
STATE_OS_RELEASE="$(printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_CODENAME=wilma\nUBUNTU_CODENAME=noble')" run "$name" 0 PHP_VERSION=8.4 && {
  grep -qx "Suites: noble" "$work/etc/apt/sources.list.d/ci-helpers-ondrej-php.sources" || { echo "FAIL $name: suite:"; cat "$work/etc/apt/sources.list.d/ci-helpers-ondrej-php.sources"; fail=1; }
}

name="empty apt lists: the image's own version is found after an update, no PPA"
STATE_AVAILABLE_AFTER_UPDATE="php8.4-*" run "$name" 0 PHP_VERSION=8.4 && {
  logged "apt-get update"; not_logged "keyserver"
  [[ ! -e "$work/etc/apt/sources.list.d/ci-helpers-ondrej-php.sources" ]] || { echo "FAIL $name: PPA added for a version the image holds"; fail=1; }
}
name="a PPA with no suite for this Ubuntu is removed again and refused"
STATE_PPA_NO_SUITE=1 run "$name" 1 PHP_VERSION=8.4 && {
  says "no build for noble"; says "ubuntu-24.04"
  [[ ! -e "$work/etc/apt/sources.list.d/ci-helpers-ondrej-php.sources" ]] || { echo "FAIL $name: broken PPA source left for later apt steps"; fail=1; }
  [[ ! -e "$work/etc/apt/keyrings/ci-helpers-ondrej-php.gpg" ]] || { echo "FAIL $name: keyring left"; fail=1; }
}

name="a key fetch that fails is an error, not a retry with add-apt-repository"
run "$name" 1 PHP_VERSION=8.4 CURL_FAIL=1 && { says "Could not fetch the PPA signing key"; not_logged "apt-get install"; }

name="a version the PPA does not build is refused after the update"
STATE_UNAVAILABLE="php7.0-cli" run "$name" 1 PHP_VERSION=7.0 && {
  logged "apt-get update"; not_logged "apt-get install"; says "PHP 7.0 is not packaged there"
}

# --- extensions -------------------------------------------------------------------
name="an extension maps to its apt package and is checked in php -m"
STATE_AVAILABLE="php8.4-*" STATE_MODULES="core|ctype|pdo_mysql|intl|xdebug" \
  run "$name" 0 PHP_VERSION=8.4 PHP_EXTENSIONS="pdo_mysql, intl, ctype" && {
  logged "php8.4-mysql"; logged "php8.4-intl"; not_logged "php8.4-ctype"; not_logged "php8.4-pdo_mysql"
}
name="an extension that did not load fails"
STATE_AVAILABLE="php8.4-*" STATE_MODULES="core|xdebug" run "$name" 1 PHP_VERSION=8.4 PHP_EXTENSIONS=intl && says "Extension 'intl' is installed but php -m does not list it"
name="an extension apt has no package for is refused before anything is installed"
STATE_AVAILABLE="php8.4-*" STATE_UNAVAILABLE="php8.4-foo" run "$name" 2 PHP_VERSION=8.4 PHP_EXTENSIONS="mbstring,foo" && {
  says "No apt package for: php8.4-foo"; says "builds nothing from PECL"; not_logged "apt-get install"
}
name="a package only Provides offers is installable"
STATE_AVAILABLE="php8.3-*" STATE_UNAVAILABLE="php8.3-xdebug" STATE_PROVIDED="php8.3-xdebug" STATE_INSTALLED="${all83% php8.3-xdebug}" STATE_PHP_VERSION=8.3.1 STATE_EXISTING_COMPOSER="$work/composer.phar" \
  run "$name" 0 PHP_VERSION=8.3 && { logged "apt-get install -y -qq --no-install-recommends php8.3-xdebug"; not_logged "keyserver"; }
name="opcache is checked as Zend OPcache"
STATE_AVAILABLE="php8.4-*" STATE_MODULES="core|zend opcache|xdebug" run "$name" 0 PHP_VERSION=8.4 PHP_EXTENSIONS=opcache
for bad in ":intl" "intl:3.0" "xdebug" "pcov" "in tl" "../x"; do
  name="extension '$bad' is refused"
  run "$name" 2 PHP_VERSION=8.4 PHP_EXTENSIONS="$bad" && { says "PHP_EXTENSIONS"; not_logged "apt-get"; }
done

# --- coverage ---------------------------------------------------------------------
name="pcov disables xdebug and enables pcov"
STATE_AVAILABLE="php8.4-*" STATE_MODS="xdebug" STATE_MODULES="core|pcov" run "$name" 0 PHP_VERSION=8.4 PHP_COVERAGE=pcov && {
  logged "php8.4-pcov"; not_logged "php8.4-xdebug"; logged "phpdismod -v 8.4 xdebug"; logged "phpenmod -v 8.4 pcov"
  grep -qx "pcov.enabled=1" "$work/etc/php/8.4/mods-available/ci-helpers.ini" || { echo "FAIL $name: no pcov.enabled"; fail=1; }
  ! grep -q "xdebug" "$work/etc/php/8.4/mods-available/ci-helpers.ini" || { echo "FAIL $name: xdebug ini line with pcov"; fail=1; }
}
name="none installs no driver and disables both"
STATE_AVAILABLE="php8.4-*" STATE_MODS="xdebug pcov" STATE_MODULES="core" run "$name" 0 PHP_VERSION=8.4 PHP_COVERAGE=none && {
  not_logged "php8.4-xdebug"; not_logged "php8.4-pcov"; logged "phpdismod -v 8.4 xdebug"; logged "phpdismod -v 8.4 pcov"
}
name="none with a driver still loaded fails"
STATE_AVAILABLE="php8.4-*" STATE_MODULES="core|xdebug" run "$name" 1 PHP_VERSION=8.4 PHP_COVERAGE=none && says "still loaded"
name="xdebug missing from php -m fails"
STATE_AVAILABLE="php8.4-*" STATE_MODULES="core" run "$name" 1 PHP_VERSION=8.4 && says "Xdebug is not loaded"
name="an unknown coverage driver is refused"
run "$name" 2 PHP_VERSION=8.4 PHP_COVERAGE=phpdbg && says "not xdebug, pcov or none"

# --- ini values ----------------------------------------------------------------------
name="ini values follow the defaults, comma- or newline-separated"
STATE_AVAILABLE="php8.4-*" run "$name" 0 PHP_VERSION=8.4 PHP_INI_VALUES="memory_limit=512M, max_execution_time=0
post_max_size=64M" && {
  ini="$work/etc/php/8.4/mods-available/ci-helpers.ini"
  [[ "$(grep -n "memory_limit=-1\|memory_limit=512M" "$ini" | cut -d: -f2 | tr '\n' ' ')" == "memory_limit=-1 memory_limit=512M " ]] || { echo "FAIL $name: order:"; cat "$ini"; fail=1; }
  grep -qx "max_execution_time=0" "$ini" && grep -qx "post_max_size=64M" "$ini" || { echo "FAIL $name: values:"; cat "$ini"; fail=1; }
  head -n 1 "$ini" | grep -q "priority=99" || { echo "FAIL $name: no priority header"; fail=1; }
}
name="an ini line that is not key=value is refused"
run "$name" 2 PHP_VERSION=8.4 PHP_INI_VALUES="memory_limit" && { says "is not key=value"; not_logged "apt-get"; }
for bad in "extension=/tmp/evil.so" "zend_extension=/tmp/evil.so" "Extension = x.so" "memory_limit=1
extension=x.so"; do
  name="ini line loading a module is refused: $bad"
  run "$name" 2 PHP_VERSION=8.4 PHP_INI_VALUES="$bad" && { says "loads a module"; not_logged "apt-get"; }
done
for bad in "[PHP]" "memory_limit=1; id" "a b=1"; do
  name="ini line '$bad' is refused"
  run "$name" 2 PHP_VERSION=8.4 PHP_INI_VALUES="$bad" && { says "PHP_INI_VALUES"; not_logged "apt-get"; }
done

# --- tools -------------------------------------------------------------------------
name="tools: composer is accepted"
STATE_AVAILABLE="php8.4-*" run "$name" 0 PHP_VERSION=8.4 PHP_TOOLS="composer"
name="tools: composer:v2 is accepted"
STATE_AVAILABLE="php8.4-*" run "$name" 0 PHP_VERSION=8.4 PHP_TOOLS="composer:v2"
for bad in phpunit "composer, phpstan" "composer:1" "composer:2.2"; do
  name="tools '$bad' is refused"
  run "$name" 2 PHP_VERSION=8.4 PHP_TOOLS="$bad" && { says "PHP_TOOLS names"; not_logged "apt-get"; }
done

# --- composer digest -----------------------------------------------------------------
name="a composer.phar whose digest is not the pin is not installed"
TEST_PINS="$pins" STATE_AVAILABLE="php8.4-*" run "$name" 1 PHP_VERSION=8.4 && {
  says "not the pinned"; says "not installed"
  [[ ! -e "$work/usr/local/bin/composer" ]] || { echo "FAIL $name: composer installed on a digest mismatch"; fail=1; }
}
name="an existing composer with another digest is replaced"
printf '#!/usr/bin/env bash\necho "Composer version 2.0.0 2020-01-01"\n' > "$work/old-composer"
STATE_AVAILABLE="php8.4-*" STATE_EXISTING_COMPOSER="$work/old-composer" run "$name" 0 PHP_VERSION=8.4 && {
  logged "curl https://getcomposer.org"; [[ -x "$work/usr/local/bin/composer" ]] || { echo "FAIL $name: not installed"; fail=1; }
}
name="a composer that still shadows the installed one on PATH fails"
STATE_AVAILABLE="php8.4-*" STATE_SHADOW=1 STATE_EXISTING_COMPOSER="$work/old-composer" run "$name" 1 PHP_VERSION=8.4 && says "composer on PATH is '$work/path/composer', not $work/usr/local/bin/composer"
name="a pin missing from the pins file is refused"
grep -v '^COMPOSER_VERSION=' "$work/pins.env" > "$work/pins-nover.env"
TEST_PINS="$work/pins-nover.env" run "$name" 2 PHP_VERSION=8.4 && says "COMPOSER_VERSION"
grep -v '^PHP_PPA_FINGERPRINT=' "$work/pins.env" > "$work/pins-nokey.env"
name="a missing key fingerprint pin is refused"
TEST_PINS="$work/pins-nokey.env" run "$name" 2 PHP_VERSION=8.4 && says "PHP_PPA_FINGERPRINT"

# --- version and platform --------------------------------------------------------------
name="php on PATH reporting another version fails"
STATE_AVAILABLE="php8.4-*" STATE_PHP_VERSION=8.3.6 run "$name" 1 PHP_VERSION=8.4 && says "reports '8.3.6', not 8.4.x"
for bad in "" latest 8.4.1 8 nightly "8.4 " "8.3; id" "8.3
8.4"; do
  name="PHP_VERSION '$bad' is refused"
  run "$name" 2 PHP_VERSION="$bad" && { says "PHP_VERSION"; not_logged "apt-get"; }
done
name="a runner without apt is refused"
STATE_OS_ID=alpine run "$name" 2 PHP_VERSION=8.4 && says "not Ubuntu or Debian"

[[ "$fail" == 0 ]] && echo "ok: setup_php.sh installs from apt under the pinned key, keeps composer to its digest and refuses what it does not support"
exit "$fail"
