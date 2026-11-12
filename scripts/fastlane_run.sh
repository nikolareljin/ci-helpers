# shellcheck shell=bash
# SCRIPT: fastlane_run.sh
# DESCRIPTION: Sourced by the flutter-release upload scripts. Defines
#              `fastlane_run ACTION ARG...`, which runs the fastlane installed
#              by install_fastlane.sh from an empty directory: no Fastfile,
#              Appfile, Pluginfile or Gemfile is there to read, and no
#              update check, usage report or changelog runs.
# ENVIRONMENT:
#   RUBY_BIN  Directory holding ruby (required).
#   GEMS      install_fastlane.sh's install directory (required).
# ----------------------------------------------------

fastlane_run() {
  [[ "${RUBY_BIN:-}" == /* && -x "$RUBY_BIN/ruby" ]] || { echo "::error::RUBY_BIN holds no ruby." >&2; return 2; }
  [[ "${GEMS:-}" == /* && -f "$GEMS/bin/fastlane" ]] || { echo "::error::GEMS holds no fastlane." >&2; return 2; }
  local empty rc=0
  empty="$(mktemp -d)"
  (
    cd "$empty" || exit 1
    unset BUNDLE_GEMFILE RUBYOPT RUBYLIB FASTLANE_PLUGINFILE_PATH
    # The Ruby's own gem directory too: gem install skips a dependency it
    # already holds there.
    GEM_PATH="$GEMS:$(env -u GEM_HOME -u GEM_PATH "$RUBY_BIN/ruby" -e 'print Gem.default_dir')" || exit 1
    export GEM_HOME="$GEMS" GEM_PATH FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 \
      FASTLANE_OPT_OUT_USAGE=1 FASTLANE_DISABLE_COLORS=1 FASTLANE_SKIP_ACTION_SUMMARY=1 CI=true
    if [[ "$(uname -s)" == Darwin ]]; then export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; fi
    "$RUBY_BIN/ruby" "$GEMS/bin/fastlane" "$@"
  ) || rc=$?
  rm -rf "$empty"
  return "$rc"
}
