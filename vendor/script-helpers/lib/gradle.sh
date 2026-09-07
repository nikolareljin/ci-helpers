#!/usr/bin/env bash
# Gradle build helpers — a thin, predictable wrapper around the Gradle wrapper.
#
# Kept separate from the `android` module on purpose: Gradle is also used for
# plain JVM host components that have no Android SDK and no APK, and those
# callers should not have to import an Android toolchain to run `test`.
#
# Every function prefers the project's own `./gradlew` over a system `gradle`,
# because the wrapper pins the Gradle version and a system Gradle does not.
# All functions return non-zero when no Gradle is reachable, so callers degrade
# cleanly.

# Usage: gradle_available [dir=.]; returns 0 if a Gradle wrapper or a system
# gradle can build <dir>.
gradle_available() {
  local dir="${1:-.}"
  [[ -x "$dir/gradlew" ]] && return 0
  command -v gradle >/dev/null 2>&1
}

# Usage: gradle_wrapper [dir=.]; prints the Gradle command to use for <dir> —
# the absolute path to its ./gradlew when present, otherwise "gradle". Returns 3
# when neither is available.
gradle_wrapper() {
  local dir="${1:-.}"
  if [[ -x "$dir/gradlew" ]]; then
    ( cd "$dir" && pwd -P ) | sed 's|$|/gradlew|'
    return 0
  fi
  if command -v gradle >/dev/null 2>&1; then
    printf 'gradle\n'
    return 0
  fi
  log_error "gradle_wrapper: no ./gradlew in $dir and no gradle on PATH"
  return 3
}

# Usage: gradle_run <dir> <task...>; run Gradle tasks in <dir> with the wrapper.
# Adds --no-daemon, because a daemon left running between local checks is a
# surprise memory cost on a laptop. Returns 2 on missing arguments, 3 when no
# Gradle is available, otherwise Gradle's own exit status.
gradle_run() {
  local dir="${1:-}"; shift || true
  local cmd
  [[ -n "$dir" && $# -gt 0 ]] || { log_error "gradle_run: need <dir> <task...>"; return 2; }
  [[ -d "$dir" ]] || { log_error "gradle_run: not a directory: $dir"; return 2; }
  cmd="$(gradle_wrapper "$dir")" || return 3
  log_info "gradle: $* (in $dir)"
  ( cd "$dir" && "$cmd" --no-daemon "$@" )
}

# Usage: gradle_lint [dir=.]; run the `lint` task.
gradle_lint() { gradle_run "${1:-.}" lint; }

# Usage: gradle_test [dir=.]; run the `test` task.
gradle_test() { gradle_run "${1:-.}" test; }

# Usage: gradle_assemble [dir=.] [variant=Debug]; run `assemble<Variant>`.
# <variant> is capitalized as Gradle expects it (Debug, Release).
gradle_assemble() {
  local dir="${1:-.}" variant="${2:-Debug}"
  gradle_run "$dir" "assemble${variant}"
}

# Usage: gradle_clean [dir=.]; run the `clean` task.
gradle_clean() { gradle_run "${1:-.}" clean; }
