#!/usr/bin/env bash
# SCRIPT: install_fastlane.sh
# DESCRIPTION: Install fastlane for the flutter-release upload jobs from the
#              library's scripts/fastlane/Gemfile.lock, frozen, so every gem
#              is the locked version and is checked against the lockfile's
#              sha256 (CHECKSUMS) as Bundler downloads it. Before anything
#              is fetched the lockfile must name rubygems.org as its only
#              source, have no GIT or PATH section, and carry one sha256 per
#              locked gem, and the Gemfile must pin FASTLANE_VERSION.
#              Bundler is BUNDLER_VERSION from rubygems.org, checked against
#              BUNDLER_GEM_SHA256 before `gem install --local`. Nothing of
#              the caller's is read: the install runs in an empty directory
#              from a private copy of the Gemfile. Run it in a step that
#              holds no secret: locked gems with native extensions build here.
# USAGE: RUBY_BIN=<ruby bin dir> GEMS=<new dir> bash scripts/install_fastlane.sh
# ENVIRONMENT:
#   RUBY_BIN        Directory holding ruby and gem (setup_ruby.sh ruby_bin).
#   GEMS            Install directory (created; must not exist yet).
#   TOOLCHAIN_PINS  Pins file (default: toolchain-pins.env beside scripts/).
#   FASTLANE_LOCK_DIR  Gemfile and Gemfile.lock (default: scripts/fastlane).
#   GITHUB_OUTPUT   Receives gems=<GEMS> when set.
# EXIT CODES:
#   0  Installed; fastlane_run.sh can run it.
#   1  A refusal (lockfile, Gemfile, bundler digest) or an install failure.
#   2  Usage error.
# ----------------------------------------------------
set -euo pipefail
export LC_ALL=C

fail() { echo "::error::$*" >&2; exit 1; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
lock_dir="${FASTLANE_LOCK_DIR:-$script_dir/fastlane}"
[[ -f "$pins" ]] || { echo "::error::Pins file $pins is missing." >&2; exit 2; }
pin() { awk -F= -v k="$1" '$1 == k { print $2; exit }' "$pins"; }
version="$(pin FASTLANE_VERSION)"
bversion="$(pin BUNDLER_VERSION)"
bsha="$(pin BUNDLER_GEM_SHA256)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::FASTLANE_VERSION in $pins is '$version', not X.Y.Z." >&2; exit 2; }
[[ "$bversion" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$bsha" =~ ^[0-9a-f]{64}$ ]] || { echo "::error::BUNDLER_VERSION / BUNDLER_GEM_SHA256 in $pins are not X.Y.Z and 64 hex." >&2; exit 2; }
[[ "${RUBY_BIN:-}" == /* && -x "$RUBY_BIN/ruby" && -f "$RUBY_BIN/gem" ]] || { echo "::error::RUBY_BIN '${RUBY_BIN:-}' holds no ruby and gem." >&2; exit 2; }
[[ "${GEMS:-}" == /* && ! -e "$GEMS" && ! -L "$GEMS" ]] || { echo "::error::GEMS '${GEMS:-}' is not a new absolute path." >&2; exit 2; }
gemfile="$lock_dir/Gemfile"; lock="$lock_dir/Gemfile.lock"
[[ -f "$gemfile" && ! -L "$gemfile" && -f "$lock" && ! -L "$lock" ]] || fail "no Gemfile and Gemfile.lock in $lock_dir."

# The Gemfile: one source, one gem, the pinned version.
want_gemfile="$(printf 'source "https://rubygems.org"\n\ngem "fastlane", "%s"' "$version")"
[[ "$(cat "$gemfile")" == "$want_gemfile" ]] || fail "$gemfile is not exactly rubygems.org and fastlane $version."
# The lockfile: rubygems.org only, no git or path gems, a sha256 per gem.
sections="$(grep -E '^[A-Z]+( [A-Z]+)?$' "$lock" | tr '\n' '|')" || true
[[ "$sections" == "GEM|PLATFORMS|DEPENDENCIES|CHECKSUMS|BUNDLED WITH|" ]] || fail "the lockfile's sections are '$sections', not GEM PLATFORMS DEPENDENCIES CHECKSUMS BUNDLED (no GIT or PATH)."
remotes="$(grep -E '^  remote:' "$lock" | sort -u)" || true
[[ "$remotes" == "  remote: https://rubygems.org/" ]] || fail "the lockfile names a source other than https://rubygems.org/."
specs="$(awk '/^GEM$/{f=1;next} /^[A-Z]/{f=0} f && /^    [^ ]/{print $1, $2}' "$lock" | sort -u)"
sums="$(awk '/^CHECKSUMS$/{f=1;next} /^$/{f=0} f' "$lock")"
[[ -n "$specs" ]] || fail "the lockfile locks no gem."
if grep -qvE '^  [A-Za-z0-9_.-]+ \([0-9A-Za-z._-]+\) sha256=[0-9a-f]{64}$' <<< "$sums"; then
  fail "a CHECKSUMS line is not '<gem> (<version>) sha256=<64 hex>'."
fi
summed="$(awk '{print $1, $2}' <<< "$sums" | sort -u)"
[[ "$specs" == "$summed" ]] || fail "the locked gems and the CHECKSUMS entries differ (a gem without a sha256)."
grep -qE "^    fastlane \($version\)$" "$lock" || fail "the lockfile does not lock fastlane $version."
grep -A1 -E '^BUNDLED WITH$' "$lock" | grep -qE "^   $bversion$" || fail "the lockfile was not written by Bundler $bversion."

mkdir -p "$GEMS/app" "$GEMS/bundler" "$GEMS/bundle"
chmod 700 "$GEMS"
cp -P -- "$gemfile" "$lock" "$GEMS/app/"
empty="$(mktemp -d)"
trap 'rm -rf "$empty"' EXIT
cd "$empty"
unset BUNDLE_GEMFILE RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_PATH BUNDLE_APP_CONFIG

curl -fsSL --proto '=https' --tlsv1.2 -o "$empty/bundler.gem" "https://rubygems.org/downloads/bundler-$bversion.gem"
if command -v sha256sum >/dev/null; then got="$(sha256sum "$empty/bundler.gem")"; else got="$(shasum -a 256 "$empty/bundler.gem")"; fi
[[ "${got%% *}" == "$bsha" ]] || fail "bundler-$bversion.gem has sha256 ${got%% *}, not $bsha."
"$RUBY_BIN/ruby" "$RUBY_BIN/gem" install --local "$empty/bundler.gem" -N --install-dir "$GEMS/bundler" --bindir "$GEMS/bundler/bin"
rm -f "$empty/bundler.gem"

export GEM_HOME="$GEMS/bundler" GEM_PATH="$GEMS/bundler" BUNDLE_GEMFILE="$GEMS/app/Gemfile" \
  BUNDLE_APP_CONFIG="$GEMS/app/.bundle" BUNDLE_PATH="$GEMS/bundle" BUNDLE_FROZEN=true \
  BUNDLE_DEPLOYMENT=true BUNDLE_DISABLE_CHECKSUM_VALIDATION=false BUNDLE_IGNORE_MESSAGES=true
"$RUBY_BIN/ruby" "$GEMS/bundler/bin/bundle" "_${bversion}_" install --jobs 4
echo "gems=$GEMS"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "gems=$GEMS" >> "$GITHUB_OUTPUT"
fi
