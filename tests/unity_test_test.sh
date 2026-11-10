#!/usr/bin/env bash
# SCRIPT: unity_test_test.sh
# DESCRIPTION: scripts/unity_test.sh runs the unityci/editor image pinned by
#              digest in the pins file for the project's editor version, with
#              the mounts and environment the replaced action gave the
#              container; the licence secrets cross as `--env NAME` and no
#              value of theirs is in an argument or in the output; a Personal
#              licence file yields its serial; an unpinned version, a pin for
#              another version, a pin without a digest, a bad test mode or
#              path, a missing credential and an unsupported input are
#              refused before docker is called; the editor's exit code comes
#              back as it is; --return-license runs a second container only
#              after a test run. Then scripts/unity_container.sh against a
#              stub editor: the activation, test and return command lines,
#              the redacted activation log on failure, and the exit codes.
#              A stub docker records its argv and environment; nothing is
#              pulled or run.
# USAGE: bash tests/unity_test_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# The stub docker: argv to STUB_LOG, the variables the container would read
# to STUB_ENV.<name>, exit STUB_RC.
mkdir -p "$work/stub"
cat > "$work/stub/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_LOG"
for v in UNITY_SERIAL UNITY_EMAIL UNITY_PASSWORD UNITY_LICENSE TEST_PLATFORMS CUSTOM_PARAMETERS COVERAGE_ENABLED COVERAGE_OPTIONS UNITY_VERSION PROJECT_PATH ARTIFACTS_PATH; do
  if [[ -n "${!v+x}" ]]; then printf '%s' "${!v}" > "$STUB_ENV.$v"; fi
done
# A container writes where it can: into every host directory it was given.
prev=""
for a in "$@"; do
  if [[ "$prev" == --volume ]]; then
    host="${a%%:*}"
    [[ -d "$host" && -w "$host" ]] && echo tampered > "$host/.written-by-container"
  fi
  prev="$a"
done
exit "${STUB_RC:-0}"
STUB
chmod +x "$work/stub/docker"

digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
image="docker.io/unityci/editor:ubuntu-6000.0.23f1-linux-il2cpp-3@sha256:$digest"
cat > "$work/pins.env" <<EOF
# test pins
UNITY_EDITOR_IMAGE_6000_0_23f1=$image
UNITY_EDITOR_IMAGE_2021_3_45f1=docker.io/unityci/editor:ubuntu-2021.3.44f1-linux-il2cpp-3@sha256:$digest
UNITY_EDITOR_IMAGE_2020_3_48f1=docker.io/unityci/editor:ubuntu-2020.3.48f1-linux-il2cpp-3
UNITY_EDITOR_IMAGE_2019_2_21f1=docker.io/unityci/editor:ubuntu-2019.2.21f1-base-3@sha256:$digest
EOF

# Projects: one per editor version.
project() {
  mkdir -p "$work/ws/$1/ProjectSettings" "$work/ws/$1/Assets"
  printf 'm_EditorVersion: %s\nm_EditorVersionWithRevision: %s (0123456789ab)\n' "$2" "$2" > "$work/ws/$1/ProjectSettings/ProjectVersion.txt"
}
project game 6000.0.23f1
project old 2022.3.62f1
project wrong 2021.3.45f1
project nodigest 2020.3.48f1
project ancient 2019.2.21f1
mkdir -p "$work/ws/noversion/Assets"

email="dev@example.com"
password="hunter2-pw-value"
serial="SC-1111-2222-3333-4444-5555"
# A Personal .ulf: the serial after a four-byte prefix, base64, in
# DeveloperData. The prefix holds a NUL, as a real file does.
ulf_serial="F4-AAAA-BBBB-CCCC-DDDD-EEEE"
dev_data="$(printf '\000\000\000\033%s' "$ulf_serial" | base64 -w0)"
ulf="$(printf '<?xml version="1.0" encoding="UTF-8"?>\n<root>\n  <License id="Terms">\n    <DeveloperData Value="%s"/>\n    <Features/>\n  </License>\n</root>\n' "$dev_data")"

# run <name> <expected rc> [--return-license]; the caller sets the inputs in
# the environment, and these defaults apply unless set (empty counts as set).
# The runner's own GITHUB_WORKSPACE and RUNNER_TEMP are never inherited: the
# test's are T_WS and T_TMP, so the paths asserted below are the test's.
run() {
  local name="$1" want="$2" rc=0; shift 2
  # The script's only flag, and the one misspelling the test probes.
  local flag=()
  case "${1:-}" in
    "") ;;
    --return-license) flag=(--return-license) ;;
    --return-licence) flag=(--return-licence) ;;
    *) echo "FAIL $name: unexpected argument"; fail=1; return 1 ;;
  esac
  : > "$work/log"; rm -f "$work"/env.* "$work/gh-out"
  PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_ENV="$work/env" \
    TOOLCHAIN_PINS="$work/pins.env" RUNNER_TEMP="${T_TMP-$work/tmp}" \
    GITHUB_WORKSPACE="$work/ws" GITHUB_OUTPUT="$work/gh-out" GITHUB_ACTIONS=true \
    UNITY_EMAIL="${UNITY_EMAIL-$email}" UNITY_PASSWORD="${UNITY_PASSWORD-$password}" \
    UNITY_SERIAL="${UNITY_SERIAL-$serial}" UNITY_LICENSE="${UNITY_LICENSE-}" \
    PROJECT_PATH="${PROJECT_PATH-game}" TEST_MODE="${TEST_MODE-editmode}" \
    bash "$root/scripts/unity_test.sh" ${flag[@]+"${flag[@]}"} > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
  return 0
}
argv() { cat "$work/log"; }
argv_has() {
  grep -qF -- "$1" "$work/log" || { echo "FAIL $name: docker argv lacks '$1':"; argv; fail=1; }
}
argv_lacks() {
  if grep -qF -- "$1" "$work/log"; then echo "FAIL $name: docker argv holds '$1':"; argv; fail=1; fi
}
not_called() {
  if [[ -s "$work/log" ]]; then echo "FAIL $name: docker was called:"; argv; fail=1; fi
}
says() {
  grep -qF -- "$1" "$work/out" || { echo "FAIL $name: no '$1' in output:"; cat "$work/out"; fail=1; }
}
# An ::add-mask:: line is a runner command, consumed and never printed; the
# rest of the output must not hold the value.
silent_on() {
  if grep -vF '::add-mask::' "$work/out" | grep -qF -- "$1"; then echo "FAIL $name: output holds '$1'"; fail=1; fi
}
output_has() {
  grep -qxF -- "$1" "$work/gh-out" 2>/dev/null || { echo "FAIL $name: GITHUB_OUTPUT lacks '$1':"; cat "$work/gh-out" 2>/dev/null; fail=1; }
}
# env_is <name> <value>: the file the stub wrote for that variable, found
# among the files it wrote, not by a path built from the name.
env_is() {
  local f got="<unset>"
  for f in "$work"/env.*; do
    [[ -f "$f" && "${f##*/env.}" == "$1" ]] && got="$(cat "$f")"
  done
  [[ "$got" == "$2" ]] || { echo "FAIL $name: container env $1 is '$got', expected '$2'"; fail=1; }
}
# no_secret_in_argv: the values are in the environment only.
no_secret_in_argv() {
  argv_lacks "$password"; argv_lacks "$email"; argv_lacks "$serial"; argv_lacks "$ulf_serial"; argv_lacks "DeveloperData"
  argv_lacks "--env UNITY_LICENSE"
  silent_on "$password"; silent_on "$serial"; silent_on "$ulf_serial"
}

# ---- the editor run ----
name="editmode runs the pinned image with the action's mounts and environment"
if run "$name" 0; then
  argv_has "run --rm --shm-size=1025m --workdir /github/workspace --security-opt no-new-privileges --cap-drop NET_RAW --cap-drop MKNOD --cap-drop SYS_CHROOT --cap-drop SETFCAP --cap-drop AUDIT_WRITE --cidfile $work/tmp/ci-helpers-unity/cid --env CI_HELPERS_UNITY_STEP=test --env UNITY_EMAIL --env UNITY_PASSWORD --volume $work/tmp/ci-helpers-unity/home:/root --volume $work/tmp/ci-helpers-unity/BlankProject:/BlankProject --volume $work/tmp/ci-helpers-unity/steps:/steps:ro --env UNITY_SERIAL"
  argv_has "--env GITHUB_WORKSPACE=/github/workspace --volume $work/ws/game:/github/workspace/game --volume $work/ws/artifacts:/github/workspace/artifacts --volume $work/ws/CodeCoverage:/github/workspace/CodeCoverage"
  argv_lacks "--volume $work/ws:/github/workspace"
  argv_lacks "$root"
  argv_has " $image /bin/bash /steps/unity_container.sh"
  argv_has "--cpus="
  no_secret_in_argv
  [[ -f "$work/ws/game/.written-by-container" ]] || { echo "FAIL $name: the stub container did not write into the project mount"; fail=1; }
  env_is UNITY_SERIAL "$serial"
  env_is TEST_PLATFORMS editmode
  env_is UNITY_VERSION 6000.0.23f1
  env_is PROJECT_PATH game
  env_is ARTIFACTS_PATH artifacts
  env_is COVERAGE_ENABLED true
  env_is COVERAGE_OPTIONS "generateAdditionalMetrics;generateHtmlReport;generateBadgeReport;dontClear"
  output_has "artifactsPath=artifacts"
  output_has "coveragePath=CodeCoverage"
  output_has "image=$image"
  says "::add-mask::SC-1111-2222-3333-4444-XXXX"
  [[ -f "$work/tmp/ci-helpers-unity/activated" ]] || { echo "FAIL $name: no activated marker"; fail=1; }
  [[ -x "$work/tmp/ci-helpers-unity/steps/unity_container.sh" ]] || { echo "FAIL $name: container script not copied"; fail=1; }
  grep -qx "m_EditorVersion: 6000.0.23f1" "$work/tmp/ci-helpers-unity/BlankProject/ProjectSettings/ProjectVersion.txt" || { echo "FAIL $name: blank project version"; fail=1; }
  [[ "$(stat -c %a "$work/tmp/ci-helpers-unity/home")" == 700 ]] || { echo "FAIL $name: home directory is not 0700"; fail=1; }
fi

name="a project at the workspace root mounts the workspace once, as the action did"
if PROJECT_PATH=. UNITY_VERSION=6000.0.23f1 run "$name" 0; then
  argv_has "--volume $work/ws:/github/workspace --volume $work/ws/artifacts:/github/workspace/artifacts --volume $work/ws/CodeCoverage:/github/workspace/CodeCoverage"
fi

name="all runs playmode, editmode and the combining pass, as the action did"
TEST_MODE=all run "$name" 0 && env_is TEST_PLATFORMS "playmode;editmode;COMBINE_RESULTS"

name="a Personal licence file yields its serial, in the environment only"
if UNITY_SERIAL='' UNITY_LICENSE="$ulf" run "$name" 0; then
  env_is UNITY_SERIAL "$ulf_serial"
  no_secret_in_argv
  says "::add-mask::F4-AAAA-BBBB-CCCC-DDDD-XXXX"
fi

name="a licence file without DeveloperData is refused"
UNITY_SERIAL='' UNITY_LICENSE="<root/>" run "$name" 4 && says "no <DeveloperData Value=...>" && not_called

name="a leading ./ is dropped and a . segment is refused, so the mount path is plain"
if PROJECT_PATH=./game run "$name" 0; then
  argv_has "--volume $work/ws/game:/github/workspace/game"
  env_is PROJECT_PATH game
fi
PROJECT_PATH=game/./Assets run "a . segment in the project path is refused" 4 && says "must not contain a '.' segment" && not_called

name="custom parameters and coverage off reach the container, and CodeCoverage is not mounted"
if CUSTOM_PARAMETERS="-nographics -extra x" COVERAGE_ENABLED=false run "$name" 0; then
  env_is CUSTOM_PARAMETERS "-nographics -extra x"
  env_is COVERAGE_ENABLED false
  argv_lacks "CodeCoverage"
fi

name="a named version is used over ProjectVersion.txt"
UNITY_VERSION=6000.0.23f1 PROJECT_PATH=old run "$name" 0 && env_is UNITY_VERSION 6000.0.23f1

name="a version before 2019.3 uses the base image, as the action did"
PROJECT_PATH=ancient run "$name" 0 && argv_has "docker.io/unityci/editor:ubuntu-2019.2.21f1-base-3@sha256:$digest"

name="the editor's exit code comes back and the results path is still written"
if STUB_RC=2 run "$name" 2; then
  says "some tests failed"
  output_has "artifactsPath=artifacts"
fi
STUB_RC=3 run "the editor's other failure comes back as 3" 3 && says "other than a failing test"
STUB_RC=125 run "docker's own failure comes back as it is" 125 && says "docker could not run"

# ---- refusals, before docker ----
name="an unpinned version is refused with the line to add"
if PROJECT_PATH=old run "$name" 4; then
  says "Unity 2022.3.62f1 has no image pin"
  says "docker buildx imagetools inspect docker.io/unityci/editor:ubuntu-2022.3.62f1-linux-il2cpp-3"
  says "UNITY_EDITOR_IMAGE_2022_3_62f1=docker.io/unityci/editor:ubuntu-2022.3.62f1-linux-il2cpp-3@sha256:<digest>"
  not_called
fi
name="a pin whose tag names another version is refused"
PROJECT_PATH=wrong run "$name" 4 && says "not docker.io/unityci/editor:ubuntu-2021.3.45f1-linux-il2cpp-<n>@sha256:<digest>" && not_called
name="a pin without a digest is refused"
PROJECT_PATH=nodigest run "$name" 4 && says "not docker.io/unityci/editor:ubuntu-2020.3.48f1-linux-il2cpp-<n>@sha256:<digest>" && not_called
name="a project without ProjectVersion.txt is refused"
PROJECT_PATH=noversion run "$name" 4 && says "ProjectVersion.txt" && not_called
name="a version that is not a Unity version is refused"
UNITY_VERSION=latest run "$name" 4 && says "not <year>.<minor>.<patch><letter><build>" && not_called
name="standalone is refused with the reason"
TEST_MODE=standalone run "$name" 4 && says "standalone needs the action's player build scripts" && not_called
name="an unknown test mode is refused"
TEST_MODE=bogus run "$name" 4 && says "TEST_MODE must be all, editmode or playmode" && not_called
name="an absolute project path is refused"
PROJECT_PATH=/abs run "$name" 4 && says "must be relative" && not_called
name="a project path with .. is refused"
PROJECT_PATH=game/../old run "$name" 4 && says "must not contain '..'" && not_called
name="an artifacts path with .. is refused"
ARTIFACTS_PATH=../out run "$name" 4 && says "ARTIFACTS_PATH must not contain '..'" && not_called
name="a symlinked project directory is refused before anything is written"
ln -s / "$work/ws/evil"
PROJECT_PATH=evil run "$name" 4 && says "is a symlink" && not_called
[[ -e "$work/gh-out" ]] && { echo "FAIL $name: outputs were written"; fail=1; }
ARTIFACTS_PATH=evil run "a symlinked artifacts directory is refused" 4 && says "is a symlink" && not_called
mkdir -p "$work/ws/sub"; ln -s ../game "$work/ws/sub/p"
PROJECT_PATH=sub/p run "a project path through a symlink is refused" 4 && says "is a symlink" && not_called
rm -rf "$work/ws/CodeCoverage"; ln -s "$work/tmp" "$work/ws/CodeCoverage"
run "a symlinked CodeCoverage directory is refused" 4 && says "is a symlink" && not_called
rm -rf "$work/ws/CodeCoverage" "$work/ws/evil"
PROJECT_PATH='game;x' run "a project path with shell punctuation is refused" 4 && says "not a plain relative path" && not_called

name="a missing email is refused"
UNITY_EMAIL='' run "$name" 4 && says "UNITY_EMAIL and UNITY_PASSWORD are needed" && not_called
name="no serial and no licence is refused"
UNITY_SERIAL='' run "$name" 4 && says "neither UNITY_SERIAL nor UNITY_LICENSE" && not_called
name="an input of the action with no equivalent is refused by name"
CUSTOM_IMAGE=unityci/editor:latest run "$name" 4 && says "CUSTOM_IMAGE is set; the action's input customImage has no equivalent" && not_called
UNITY_LICENSING_SERVER=http://license.example.test run "a licensing server is refused" 4 && says "unityLicensingServer" && not_called
name="a coverage flag that is not true or false is refused"
COVERAGE_ENABLED=yes run "$name" 4 && says "not true or false" && not_called
name="an unknown flag is refused"
run "$name" 4 --return-licence && says "the only flag is --return-license" && not_called

name="a runner that is not Linux is refused"
mkdir -p "$work/mac"
printf '#!/usr/bin/env bash\necho Darwin\n' > "$work/mac/uname"; chmod +x "$work/mac/uname"
PATH="$work/mac:$PATH" run "$name" 4 && says "Linux runner with docker" && not_called

# ---- --return-license ----
name="nothing to return before a run"
T_TMP="$work/fresh" run "$name" 0 --return-license && says "nothing to return" && not_called

name="after a run the licence is returned in a second container, serial not passed"
run "a run to return" 0
if run "$name" 0 --return-license; then
  argv_has "--env CI_HELPERS_UNITY_STEP=return --env UNITY_EMAIL --env UNITY_PASSWORD --volume $work/tmp/ci-helpers-unity/home:/root"
  argv_has " $image /bin/bash /steps/unity_container.sh"
  argv_lacks "--env UNITY_SERIAL"
  argv_lacks ":/github/workspace"
  no_secret_in_argv
  [[ -f "$work/tmp/ci-helpers-unity/activated" ]] && { echo "FAIL $name: marker kept after a return"; fail=1; }
fi
name="a failed return warns and does not fail the step"
run "a run to return" 0
STUB_RC=1 run "$name" 0 --return-license && says "::warning::returning the licence failed"
name="a return without the account is refused"
UNITY_PASSWORD='' run "$name" 4 --return-license && says "needed to return"
name="a container left running by a cancelled run is removed before the return"
run "a run to return" 0
cid=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf '%s\n' "$cid" > "$work/tmp/ci-helpers-unity/cid"
if run "$name" 0 --return-license; then
  argv_has "rm -f $cid"
  [[ "$(head -n 1 "$work/log")" == "rm -f $cid" ]] || { echo "FAIL $name: the leftover container is not removed first:"; argv; fail=1; }
fi
name="a cid file that is not a container id is not passed to docker"
run "a run to return" 0
printf '%s\n' '--help; id' > "$work/tmp/ci-helpers-unity/cid"
run "$name" 0 --return-license && argv_lacks "rm -f" && argv_lacks "--help"
name="the container runs without new privileges and without the capabilities the editor does not use"
run "$name" 0 && argv_has "--security-opt no-new-privileges --cap-drop NET_RAW --cap-drop MKNOD --cap-drop SYS_CHROOT --cap-drop SETFCAP --cap-drop AUDIT_WRITE"

# ---- the container script against a stub editor ----
# The stub records each call's argv, one line, to EDITOR_LOG; writes the
# -logFile it is given (an activation log echoes the command line, as the
# editor does); writes a results file for -runTests; exits by what it was
# asked: EDITOR_ACTIVATE_RC, EDITOR_TEST_RC, EDITOR_RETURN_RC.
mkdir -p "$work/editor"
cat > "$work/editor/unity-editor" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$EDITOR_LOG"
log=""; results=""; mode=test; ser=""
prev=""
for a in "$@"; do
  case "$prev" in
    -logFile) log="$a" ;;
    -testResults) results="$a" ;;
    -serial) ser="$a" ;;
  esac
  case "$a" in
    -serial) mode=activate ;;
    -returnlicense) mode=return ;;
  esac
  prev="$a"
done
if [[ -n "$log" ]]; then
  { echo "COMMAND LINE ARGUMENTS:"; printf '%s\n' "$0" "$@"; echo "LICENSE SYSTEM [2026] Next license update check"
    [[ -n "$ser" ]] && echo "[Licensing::Module] serial ${ser:0:${#ser}-4}XXXX"; } > "$log"
fi
case "$mode" in
  activate) exit "${EDITOR_ACTIVATE_RC:-0}" ;;
  return) exit "${EDITOR_RETURN_RC:-0}" ;;
esac
if [[ -n "$results" ]]; then
  printf '<?xml version="1.0"?>\n<test-run total="1" passed="1" failed="0" result="Passed">\n</test-run>\n' > "$results"
  exit "${EDITOR_TEST_RC:-0}"
fi
exit 0
STUB
chmod +x "$work/editor/unity-editor"

# container <name> <expected rc>; inputs from the environment as above.
container() {
  local name="$1" want="$2" rc=0
  : > "$work/elog"; rm -rf "$work/cws"; mkdir -p "$work/cws/game"
  PATH="$work/editor:$PATH" EDITOR_LOG="$work/elog" \
    CI_HELPERS_UNITY_STEP="${CI_HELPERS_UNITY_STEP-test}" GITHUB_WORKSPACE="$work/cws" \
    PROJECT_PATH=game ARTIFACTS_PATH=artifacts COVERAGE_RESULTS_PATH=CodeCoverage \
    TEST_PLATFORMS="${TEST_PLATFORMS-editmode}" UNITY_VERSION=6000.0.23f1 \
    COVERAGE_ENABLED="${COVERAGE_ENABLED-true}" COVERAGE_OPTIONS="opts;more" \
    CUSTOM_PARAMETERS="${CUSTOM_PARAMETERS-}" UNITY_ACTIVATION_RETRY_DELAY=0 \
    UNITY_SERIAL="${UNITY_SERIAL-$serial}" UNITY_EMAIL="$email" UNITY_PASSWORD="${UNITY_PASSWORD_OVERRIDE-$password}" \
    bash "$root/scripts/unity_container.sh" > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
  return 0
}
editor_has() {
  grep -qxF -- "$1" "$work/elog" || { echo "FAIL $name: editor was not called with '$1':"; cat "$work/elog"; fail=1; }
}
editor_calls() {
  local n; n="$(wc -l < "$work/elog")"
  [[ "$n" == "$1" ]] || { echo "FAIL $name: $n editor calls, expected $1:"; cat "$work/elog"; fail=1; }
}

name="container: activation, one test run per platform, the combining pass, with the action's arguments"
if TEST_PLATFORMS="playmode;editmode;COMBINE_RESULTS" CUSTOM_PARAMETERS="-nographics -extra x" container "$name" 0; then
  editor_has "-logFile /tmp/unity-activation.log -quit -serial $serial -username $email -password $password -projectPath /BlankProject"
  editor_has "-batchmode -logFile $work/cws/artifacts/playmode.log -projectPath $work/cws/game -runTests -testPlatform playmode -testResults $work/cws/artifacts/playmode-results.xml -enableCodeCoverage -debugCodeOptimization -coverageResultsPath $work/cws/CodeCoverage -coverageOptions opts;more -nographics -extra x"
  editor_has "-batchmode -logFile $work/cws/artifacts/editmode.log -projectPath $work/cws/game -runTests -testPlatform editmode -testResults $work/cws/artifacts/editmode-results.xml -enableCodeCoverage -debugCodeOptimization -coverageResultsPath $work/cws/CodeCoverage -coverageOptions opts;more -nographics -extra x"
  editor_has "-batchmode -logFile $work/cws/artifacts/COMBINE_RESULTS.log -projectPath $work/cws/game -quit -enableCodeCoverage -debugCodeOptimization -coverageResultsPath $work/cws/CodeCoverage -coverageOptions opts;more -nographics -extra x"
  editor_calls 4
  silent_on "$password"; silent_on "$serial"
  says "Activation complete."
  says "editmode: run succeeded, no failures"
  says '<test-run total="1"'
  [[ -f "$work/cws/artifacts/editmode-results.xml" ]] || { echo "FAIL $name: no results file"; fail=1; }
fi

name="container: coverage off drops the coverage arguments and the combining pass"
if TEST_PLATFORMS="playmode;editmode;COMBINE_RESULTS" COVERAGE_ENABLED=false container "$name" 0; then
  editor_has "-batchmode -logFile $work/cws/artifacts/editmode.log -projectPath $work/cws/game -runTests -testPlatform editmode -testResults $work/cws/artifacts/editmode-results.xml"
  editor_calls 3
fi

name="container: a failing test run exits 2 after every platform ran"
if EDITOR_TEST_RC=2 TEST_PLATFORMS="playmode;editmode" container "$name" 2; then
  editor_calls 3
  says "playmode: run succeeded, some tests failed"
fi

name="container: a failed activation retries, then prints the log redacted and exits with the editor's code"
if EDITOR_ACTIVATE_RC=1 container "$name" 1; then
  editor_calls 5
  says "activation failed after 5 attempts (exit 1)"
  says "COMMAND LINE ARGUMENTS:"
  says "***"
  silent_on "$password"; silent_on "$serial"; silent_on "$email"
  if grep -q -- "-runTests" "$work/elog"; then echo "FAIL $name: tests ran after a failed activation"; fail=1; fi
fi

name="container: a multi-line password and the editor's masked serial are redacted line by line"
pw2=$'first-pw-line\nsecond-pw-line'
masked="${serial:0:${#serial}-4}XXXX"
if EDITOR_ACTIVATE_RC=1 UNITY_PASSWORD_OVERRIDE="$pw2" container "$name" 1; then
  silent_on "first-pw-line"; silent_on "second-pw-line"; silent_on "$masked"
fi

name="container: return runs -returnlicense with the account and no serial"
if CI_HELPERS_UNITY_STEP="return" container "$name" 0; then
  editor_has "-logFile /tmp/unity-return.log -quit -returnlicense -username $email -password $password -projectPath /BlankProject"
  editor_calls 1
  says "Licence returned."
fi
name="container: a failed return exits with the editor's code and prints the log redacted"
if CI_HELPERS_UNITY_STEP=return EDITOR_RETURN_RC=3 container "$name" 3; then
  says "::warning::-returnlicense exited 3"
  silent_on "$password"
fi
name="container: an unknown step is refused"
CI_HELPERS_UNITY_STEP=build container "$name" 1 && says "must be test or return"
name="container: no serial is refused before the editor runs"
UNITY_SERIAL='' container "$name" 1 && says "are needed to activate" && editor_calls 0

# ---- the workflow's steps: the library leaves the workspace as a read-only
# copy with a content hash, and a step runs nothing from a copy whose hash
# has moved ----
# The run blocks come from unity.yml itself, so this cannot pass against a
# workflow that has since changed. The checkout is a clone of this tree at
# HEAD with a core.fsmonitor planted in its .git/config, as a tampered
# checkout would carry; the stub docker writes into every mount it is given.
mkdir -p "$work/wf"
python3 - "$root/.github/workflows/unity.yml" "$work/wf" <<'PY2'
import pathlib, sys, yaml
doc = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
want = {"Verify ci-helpers scripts commit": "verify", "Run Unity tests": "tests",
        "Return the Unity licence": "return", "Test summary": "summary"}
for step in doc["jobs"]["test"]["steps"]:
    if step.get("name") in want:
        pathlib.Path(sys.argv[2], want[step["name"]] + ".sh").write_text(step["run"])
PY2
for f in verify tests return summary; do
  [[ -s "$work/wf/$f.sh" ]] || { echo "FAIL: unity.yml has no run block for the $f step"; fail=1; }
done
wsf="$work/wsf"
mkdir -p "$wsf/game/ProjectSettings" "$wsf/game/Assets"
cp "$work/ws/game/ProjectSettings/ProjectVersion.txt" "$wsf/game/ProjectSettings/"
canary="$work/fsmonitor-ran"
printf '#!/usr/bin/env bash\ntouch "%s"\necho "[]"\n' "$canary" > "$work/fsmonitor.sh"; chmod +x "$work/fsmonitor.sh"
checkout() {
  rm -rf "$wsf/.ci-helpers-scripts"
  git clone -q "$root" "$wsf/.ci-helpers-scripts"
  git -C "$wsf/.ci-helpers-scripts" config core.fsmonitor "$work/fsmonitor.sh"
  git -C "$wsf/.ci-helpers-scripts" config core.hooksPath "$work/hooks"
}
mkdir -p "$work/hooks"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$canary" > "$work/hooks/post-checkout"; chmod +x "$work/hooks/post-checkout"
checkout
sha="$(git -C "$wsf/.ci-helpers-scripts" rev-parse HEAD)"

# step <name> <expected rc> <block>; cwd is the workspace, as on a runner.
step() {
  local name="$1" want="$2" block rc=0
  case "$3" in
    verify) block=verify.sh ;;
    tests) block=tests.sh ;;
    return) block=return.sh ;;
    summary) block=summary.sh ;;
    *) echo "FAIL $name: no such step block"; fail=1; return 1 ;;
  esac
  : > "$work/log"; : > "$work/gh-out"; : > "$work/summary"
  (cd "$wsf" && PATH="$work/stub:$PATH" STUB_LOG="$work/log" STUB_ENV="$work/env" \
    RUNNER_TEMP="$work/rt" GITHUB_OUTPUT="$work/gh-out" GITHUB_ACTIONS=true \
    GITHUB_STEP_SUMMARY="$work/summary" \
    TOOLCHAIN_PINS="$work/pins.env" GITHUB_WORKSPACE="$wsf" \
    WF_SHA="${WF_SHA-$sha}" LIB="${LIB-$lib}" LIB_HASH="${LIB_HASH-$hash}" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    UNITY_EMAIL="$email" UNITY_PASSWORD="$password" UNITY_SERIAL="$serial" UNITY_LICENSE="" \
    PROJECT_PATH=game UNITY_VERSION=auto TEST_MODE=editmode ARTIFACTS_PATH=artifacts \
    bash "$work/wf/$block") > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; return 1
  fi
  return 0
}

mkdir -p "$work/rt"
lib=""; hash=""
name="workflow: the verify step copies the library out of the workspace, read-only, hashed, and drops the checkout"
if step "$name" 0 verify; then
  lib="$(sed -n 's/^lib=//p' "$work/gh-out")"
  hash="$(sed -n 's/^hash=//p' "$work/gh-out")"
  [[ -n "$lib" && -f "$lib/scripts/unity_test.sh" && -f "$lib/toolchain-pins.env" ]] || { echo "FAIL $name: no lib output or no copy there: '$lib'"; fail=1; }
  [[ "$lib" == "$work/rt/"* ]] || { echo "FAIL $name: lib '$lib' is not under RUNNER_TEMP"; fail=1; }
  [[ -e "$lib/.git" ]] && { echo "FAIL $name: the copy carries .git"; fail=1; }
  [[ -w "$lib/scripts/unity_test.sh" ]] && { echo "FAIL $name: the copy's files are writable"; fail=1; }
  [[ -w "$lib/scripts" ]] || { echo "FAIL $name: the copy's directories are read-only; a self-hosted runner could not clear them"; fail=1; }
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL $name: hash output '$hash'"; fail=1; }
  [[ -e "$wsf/.ci-helpers-scripts" ]] && { echo "FAIL $name: .ci-helpers-scripts is still in the workspace"; fail=1; }
  [[ -e "$canary" ]] && { echo "FAIL $name: the planted fsmonitor or hook ran during the verify step"; fail=1; }
fi
name="workflow: the verify step refuses a checkout that is not at the workflow's commit"
checkout
WF_SHA=0000000000000000000000000000000000000000 step "$name" 1 verify && says "expected 0000000000000000000000000000000000000000"
rm -rf "$wsf/.ci-helpers-scripts"

if [[ -n "$lib" && -n "$hash" ]]; then
  name="workflow: the test step runs the copy; the container writes nowhere the host reads a script from"
  if step "$name" 0 tests; then
    argv_has "--volume $wsf/game:/github/workspace/game"
    argv_lacks "$lib"
    [[ -f "$wsf/game/.written-by-container" ]] || { echo "FAIL $name: the stub did not write into the project"; fail=1; }
    now="$(cd "$lib" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
    [[ "$now" == "$hash" ]] || { echo "FAIL $name: the library copy changed under a container run"; fail=1; }
  fi
  name="workflow: the return step runs after the test step, from the same copy"
  step "$name" 0 return && argv_has "--env CI_HELPERS_UNITY_STEP=return"
  name="workflow: the summary step reads the results"
  mkdir -p "$wsf/artifacts" && cp "$work/cws/artifacts/editmode-results.xml" "$wsf/artifacts/" 2>/dev/null || true
  if step "$name" 0 summary; then
    grep -qF "## Unity tests (editmode)" "$work/summary" || { echo "FAIL $name: no heading in the step summary:"; cat "$work/summary"; fail=1; }
  fi

  # Tampered, each way the check must see: a changed script, a new file, a
  # hash that is not the copy's. No step runs a script from it.
  chmod -R u+w "$lib"
  cp "$lib/scripts/unity_test.sh" "$work/unity_test.sh.orig"
  echo "# changed" >> "$lib/scripts/unity_test.sh"
  for block in tests return summary; do
    name="workflow: the $block step refuses a copy with a changed file"
    step "$name" 1 "$block" && says "::error::the library copy changed since it was verified" && not_called
  done
  cp "$work/unity_test.sh.orig" "$lib/scripts/unity_test.sh"
  touch "$lib/scripts/added-by-container.sh"
  name="workflow: the test step refuses a copy with a new file"
  step "$name" 1 tests && says "changed since it was verified" && not_called
  rm -f "$lib/scripts/added-by-container.sh"
  name="workflow: the test step refuses a hash that is not the copy's"
  LIB_HASH=1111111111111111111111111111111111111111111111111111111111111111 step "$name" 1 tests && says "changed since it was verified" && not_called
  name="workflow: the test step refuses an empty hash"
  LIB_HASH='' step "$name" 1 tests && says "no verified library copy" && not_called
  name="workflow: the restored copy runs again"
  step "$name" 0 tests
  [[ -e "$canary" ]] && { echo "FAIL: the planted fsmonitor or hook ran during a later step"; fail=1; }
fi

[[ "$fail" == 0 ]] && echo "ok: unity_test.sh runs the pinned editor image as the action did, keeps the licence out of argv, refuses what it must, and the container script drives the editor as the action's steps did"
exit "$fail"
