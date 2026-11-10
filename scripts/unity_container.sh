#!/usr/bin/env bash
# SCRIPT: unity_container.sh
# DESCRIPTION: The steps scripts/unity_test.sh runs inside the unityci/editor
#              container, as root, in place of the replaced action's
#              /steps/*.sh. CI_HELPERS_UNITY_STEP selects one:
#
#              test    Activate with the serial (five attempts, the delay
#                      doubling from UNITY_ACTIVATION_RETRY_DELAY seconds),
#                      then for each platform in TEST_PLATFORMS run the
#                      editor's test runner and print its log, then make the
#                      results readable by the host user. The activation log
#                      stays in /tmp and is printed, redacted, only when
#                      activation fails: the editor echoes its command line,
#                      and the serial, user and password are on it.
#              return  Return the licence (-returnlicense).
#
#              The values arrive in the environment from `--env NAME` on the
#              host; the editor takes them as arguments inside the container,
#              as it has no other way, and nothing here prints them.
# USAGE: run by scripts/unity_test.sh; not by hand.
# ENVIRONMENT: CI_HELPERS_UNITY_STEP, UNITY_SERIAL, UNITY_EMAIL,
#              UNITY_PASSWORD, TEST_PLATFORMS (`;`-separated: playmode,
#              editmode, COMBINE_RESULTS), UNITY_VERSION, PROJECT_PATH,
#              ARTIFACTS_PATH, COVERAGE_ENABLED, COVERAGE_OPTIONS,
#              COVERAGE_RESULTS_PATH, CUSTOM_PARAMETERS (split on whitespace),
#              GITHUB_WORKSPACE, UNITY_ACTIVATION_RETRY_DELAY (default 15).
# EXIT CODES: the editor's: 0 every test passed, 2 some failed, 3 another
#             failure; activation failure exits with the editor's code, or
#             1 when no strategy applies.
# ----------------------------------------------------
set -uo pipefail

step="${CI_HELPERS_UNITY_STEP:-}"

# redacted <log>: the editor prints its command line one argument per line;
# the line after -serial, -username or -password is hidden, and so is any
# line holding one of the values. awk reads them from the environment, so
# no value is an argument here either.
redacted() {
  awk '
    function hidden(s,  k) {
      for (k in keys) if (keys[k] != "" && index(s, keys[k]) > 0) return 1
      return 0
    }
    BEGIN {
      keys[1] = ENVIRON["UNITY_SERIAL"]; keys[2] = ENVIRON["UNITY_EMAIL"]; keys[3] = ENVIRON["UNITY_PASSWORD"]
    }
    skip { print "***"; skip = 0; next }
    $0 == "-serial" || $0 == "-username" || $0 == "-password" { print; skip = 1; next }
    hidden($0) { print "***"; next }
    { print }
  ' "$1"
}

if [[ "$step" == return ]]; then
  log=/tmp/unity-return.log
  unity-editor -logFile "$log" -quit -returnlicense \
    -username "$UNITY_EMAIL" -password "$UNITY_PASSWORD" -projectPath /BlankProject
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "::warning::-returnlicense exited $rc; the editor log, redacted:"
    [[ -f "$log" ]] && redacted "$log" | tail -n 100
    exit "$rc"
  fi
  echo "Licence returned."
  exit 0
fi

[[ "$step" == test ]] || { echo "::error::CI_HELPERS_UNITY_STEP must be test or return, not '$step'." >&2; exit 1; }
[[ -n "${UNITY_SERIAL:-}" && -n "${UNITY_EMAIL:-}" && -n "${UNITY_PASSWORD:-}" ]] || {
  echo "::error::UNITY_SERIAL, UNITY_EMAIL and UNITY_PASSWORD are needed to activate." >&2; exit 1; }

# A Personal serial (F...) activates against a machine id that must differ
# between runs, as the action arranged.
if [[ "$UNITY_SERIAL" == F* ]] && command -v dbus-uuidgen >/dev/null 2>&1 && [[ -w /etc/machine-id || ( ! -e /etc/machine-id && -w /etc ) ]]; then
  echo "Randomizing the machine id for a Personal licence"
  dbus-uuidgen > /etc/machine-id && mkdir -p /var/lib/dbus && ln -sf /etc/machine-id /var/lib/dbus/machine-id
fi

# ---- activation, five attempts, the delay doubling ----
log=/tmp/unity-activation.log
delay="${UNITY_ACTIVATION_RETRY_DELAY:-15}"
attempt=0
rc=1
while (( attempt < 5 )); do
  attempt=$((attempt + 1))
  echo "Requesting activation (attempt $attempt of 5)"
  rm -f "$log"
  unity-editor -logFile "$log" -quit \
    -serial "$UNITY_SERIAL" -username "$UNITY_EMAIL" -password "$UNITY_PASSWORD" \
    -projectPath /BlankProject
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "Activation complete."
    break
  fi
  echo "::warning::activation exited $rc"
  if (( attempt < 5 )); then
    echo "Retrying in $delay seconds"
    sleep "$delay"
    delay=$((delay * 2))
  fi
done
if [[ "$rc" -ne 0 ]]; then
  echo "::error::activation failed after $attempt attempts (exit $rc); the editor log, redacted:" >&2
  [[ -f "$log" ]] && redacted "$log" | tail -n 200 >&2
  exit "$rc"
fi

# ---- the tests, one editor run per platform ----
project="$GITHUB_WORKSPACE/$PROJECT_PATH"
artifacts="$GITHUB_WORKSPACE/$ARTIFACTS_PATH"
coverage="$GITHUB_WORKSPACE/$COVERAGE_RESULTS_PATH"
mkdir -p "$artifacts"
echo "Project: $project"
echo "Results: $artifacts"
echo "Unity $UNITY_VERSION"

coverage_args=()
if [[ "${COVERAGE_ENABLED:-true}" == true ]]; then
  coverage_args=(-enableCodeCoverage -debugCodeOptimization
                 -coverageResultsPath "$coverage" -coverageOptions "${COVERAGE_OPTIONS:-}")
fi
# Whitespace-separated, no globbing; as the action expanded it, unquoted.
set -f
# shellcheck disable=SC2206
custom=( ${CUSTOM_PARAMETERS:-} )
set +f
[[ ${#custom[@]} -gt 0 ]] && echo "Custom parameters: ${custom[*]}"

final=0
IFS=';' read -r -a platforms <<< "${TEST_PLATFORMS:-}"
for platform in "${platforms[@]}"; do
  [[ -n "$platform" ]] || continue
  if [[ "$platform" == COMBINE_RESULTS ]]; then
    # One more editor pass combines the coverage of the modes before it.
    [[ ${#coverage_args[@]} -gt 0 ]] || continue
    echo "== Combining coverage"
    run=(-quit)
  else
    echo "== Testing in $platform"
    run=(-runTests -testPlatform "$platform" -testResults "$artifacts/$platform-results.xml")
  fi
  unity-editor -batchmode -logFile "$artifacts/$platform.log" -projectPath "$project" \
    "${run[@]}" ${coverage_args[@]+"${coverage_args[@]}"} ${custom[@]+"${custom[@]}"}
  rc=$?
  [[ -f "$artifacts/$platform.log" ]] && cat "$artifacts/$platform.log"
  case "$rc" in
    0) echo "$platform: run succeeded, no failures" ;;
    2) echo "$platform: run succeeded, some tests failed" ;;
    3) echo "$platform: run failure (other failure)" ;;
    *) echo "$platform: unexpected exit code $rc" ;;
  esac
  [[ "$rc" -ne 0 ]] && final="$rc"
  if [[ "$platform" != COMBINE_RESULTS && -f "$artifacts/$platform-results.xml" ]]; then
    grep -m 1 '<test-run ' "$artifacts/$platform-results.xml" || true
  fi
done

# The container runs as root; the host user reads what it wrote.
chmod -R a+r "$artifacts" 2>/dev/null || true
chmod -R a+r "$project" 2>/dev/null || true
if [[ -d "$coverage" ]]; then
  chmod -R a+r "$coverage" 2>/dev/null || true
elif [[ ${#coverage_args[@]} -gt 0 ]]; then
  echo "No coverage results directory; the Code Coverage package may not be installed in the project."
fi
exit "$final"
