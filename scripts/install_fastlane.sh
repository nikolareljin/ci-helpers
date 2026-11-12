#!/usr/bin/env bash
# SCRIPT: install_fastlane.sh
# DESCRIPTION: Install the fastlane gem at the version pinned in
#              toolchain-pins.env into GEMS, with the Ruby in RUBY_BIN, for
#              the flutter-release upload jobs. No Gemfile is read: the
#              install runs in an empty directory with BUNDLE_GEMFILE unset.
#              Run it in a step that holds no secret: gem builds native
#              extensions here.
# USAGE: RUBY_BIN=<ruby bin dir> GEMS=<dir> bash scripts/install_fastlane.sh
# ENVIRONMENT:
#   RUBY_BIN        Directory holding ruby and gem (setup_ruby.sh ruby_bin).
#   GEMS            Install directory (created; must not exist yet).
#   TOOLCHAIN_PINS  Pins file (default: toolchain-pins.env beside scripts/).
#   GITHUB_OUTPUT   Receives gems=<GEMS> when set.
# EXIT CODES:
#   0  Installed; GEMS/bin/fastlane exists.
#   1  gem failed or left no fastlane.
#   2  Usage error: no pin, a pin not X.Y.Z, no ruby, GEMS already there.
# ----------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="${TOOLCHAIN_PINS:-$script_dir/../toolchain-pins.env}"
[[ -f "$pins" ]] || { echo "::error::Pins file $pins is missing." >&2; exit 2; }
version="$(awk -F= '$1 == "FASTLANE_VERSION" { print $2; exit }' "$pins")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::FASTLANE_VERSION in $pins is '$version', not X.Y.Z." >&2; exit 2; }
[[ "${RUBY_BIN:-}" == /* && -x "$RUBY_BIN/ruby" && -f "$RUBY_BIN/gem" ]] || { echo "::error::RUBY_BIN '${RUBY_BIN:-}' holds no ruby and gem." >&2; exit 2; }
[[ "${GEMS:-}" == /* && ! -e "$GEMS" && ! -L "$GEMS" ]] || { echo "::error::GEMS '${GEMS:-}' is not a new absolute path." >&2; exit 2; }

empty="$(mktemp -d)"
trap 'rm -rf "$empty"' EXIT
cd "$empty"
unset BUNDLE_GEMFILE RUBYOPT RUBYLIB GEM_HOME GEM_PATH
"$RUBY_BIN/ruby" "$RUBY_BIN/gem" install fastlane -N -v "$version" --install-dir "$GEMS" --bindir "$GEMS/bin"
[[ -f "$GEMS/bin/fastlane" ]] || { echo "::error::gem install left no $GEMS/bin/fastlane." >&2; exit 1; }
echo "gems=$GEMS"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "gems=$GEMS" >> "$GITHUB_OUTPUT"
fi
