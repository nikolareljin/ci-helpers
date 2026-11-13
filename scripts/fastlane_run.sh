# shellcheck shell=bash
# SCRIPT: fastlane_run.sh
# DESCRIPTION: Sourced by the flutter-release upload scripts. Defines
#              `fastlane_run ACTION ARG...`, which runs the fastlane that
#              install_fastlane.sh installed from the library's lockfile
#              (`bundle exec`, frozen) from an empty directory: no Fastfile,
#              Appfile, Pluginfile or Gemfile of the caller's is there to
#              read, and no update check, usage report or changelog runs.
# ENVIRONMENT:
#   RUBY_BIN  Directory holding ruby (required).
#   GEMS      install_fastlane.sh's install directory (required).
# ----------------------------------------------------

fastlane_run() {
  [[ "${RUBY_BIN:-}" == /* && -x "$RUBY_BIN/ruby" ]] || { echo "::error::RUBY_BIN holds no ruby." >&2; return 2; }
  [[ "${GEMS:-}" == /* && -f "$GEMS/bundler/bin/bundle" && -f "$GEMS/app/Gemfile.lock" ]] || { echo "::error::GEMS holds no bundler and lockfile." >&2; return 2; }
  local empty rc=0
  empty="$(mktemp -d)"
  (
    cd "$empty" || exit 1
    unset RUBYOPT RUBYLIB FASTLANE_PLUGINFILE_PATH
    export GEM_HOME="$GEMS/bundler" GEM_PATH="$GEMS/bundler" BUNDLE_GEMFILE="$GEMS/app/Gemfile" \
      BUNDLE_APP_CONFIG="$GEMS/app/.bundle" BUNDLE_PATH="$GEMS/bundle" BUNDLE_FROZEN=true BUNDLE_DEPLOYMENT=true \
      FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 FASTLANE_OPT_OUT_USAGE=1 \
      FASTLANE_DISABLE_COLORS=1 FASTLANE_SKIP_ACTION_SUMMARY=1 CI=true
    if [[ "$(uname -s)" == Darwin ]]; then export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; fi
    "$RUBY_BIN/ruby" "$GEMS/bundler/bin/bundle" exec fastlane "$@"
  ) || rc=$?
  rm -rf "$empty"
  return "$rc"
}
