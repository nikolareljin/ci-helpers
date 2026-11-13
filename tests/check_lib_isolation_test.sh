#!/usr/bin/env bash
# Workflow text in single quotes is meant literally.
# shellcheck disable=SC2016
# SCRIPT: check_lib_isolation_test.sh
# DESCRIPTION: scripts/check_lib_isolation.py refuses a workflow that runs a
#              library script from the workspace checkout, runs git on it
#              later, mounts it into a container or skips the hash check, and
#              accepts the repository's workflows. scripts/lib_isolate.sh
#              copies, hashes and removes a checkout and refuses a wrong one.
# USAGE: bash tests/check_lib_isolation_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gate="$root/scripts/check_lib_isolation.py"
work="$(mktemp -d)"; trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
fail=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

expect() {  # expect <name> <rc> <yaml>
  local name="$1" want="$2" rc=0
  rm -rf "$work/r"; mkdir -p "$work/r/.github/workflows"
  printf '%s\n' "$3" > "$work/r/.github/workflows/w.yml"
  python3 "$gate" --root "$work/r" > "$work/out" 2>&1 || rc=$?
  [[ "$rc" == "$want" ]] || { echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; }
}

SH='shell: /bin/sh -e {0}'
checkout='      - uses: actions/checkout@0000000000000000000000000000000000000000
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}
          path: .ci-helpers-scripts
          persist-credentials: false'
isolate="$(cat <<'YML'
      - name: Isolate ci-helpers scripts
        id: ci_lib
        shell: /bin/sh -e {0}
        env:
          WF_SHA: ${{ job.workflow_sha }}
          BASH_ENV: ""
          ENV: ""
          SHELLOPTS: ""
          BASHOPTS: ""
          PS4: ""
          LD_PRELOAD: ""
          LD_LIBRARY_PATH: ""
          LD_AUDIT: ""
          DYLD_INSERT_LIBRARIES: ""
          DYLD_LIBRARY_PATH: ""
          DYLD_FRAMEWORK_PATH: ""
          PYTHONPATH: ""
          PYTHONSTARTUP: ""
          PERL5LIB: ""
          PERL5OPT: ""
          RUBYOPT: ""
          NODE_OPTIONS: ""
          GIT_DIR: ""
          GIT_CONFIG_PARAMETERS: ""
          GIT_EXEC_PATH: ""
        run: |
          set +xv
          case "$(/usr/bin/env)" in *BASH_FUNC_*) echo "::error::an exported shell function is in the environment; nothing runs."; exit 1 ;; esac
          exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" LANG=C.UTF-8 WF_SHA="$WF_SHA" RUNNER_TEMP="$RUNNER_TEMP" GITHUB_OUTPUT="$GITHUB_OUTPUT" /bin/bash --noprofile --norc .ci-helpers-scripts/scripts/lib_isolate.sh
YML
)"
use="$(cat <<'YML'
      - name: Setup
        shell: /bin/sh -e {0}
        env:
          LIB: ${{ steps.ci_lib.outputs.lib }}
          LIB_HASH: ${{ steps.ci_lib.outputs.hash }}
          RUST_TOOLCHAIN: stable
          BASH_ENV: ""
          ENV: ""
          SHELLOPTS: ""
          BASHOPTS: ""
          PS4: ""
          LD_PRELOAD: ""
          LD_LIBRARY_PATH: ""
          LD_AUDIT: ""
          DYLD_INSERT_LIBRARIES: ""
          DYLD_LIBRARY_PATH: ""
          DYLD_FRAMEWORK_PATH: ""
          PYTHONPATH: ""
          PYTHONSTARTUP: ""
          PERL5LIB: ""
          PERL5OPT: ""
          RUBYOPT: ""
          NODE_OPTIONS: ""
          GIT_DIR: ""
          GIT_CONFIG_PARAMETERS: ""
          GIT_EXEC_PATH: ""
        run: |
          set +xv
          case "$(/usr/bin/env)" in *BASH_FUNC_*) echo "::error::an exported shell function is in the environment; nothing runs."; exit 1 ;; esac
          exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" LANG=C.UTF-8 STEP_PATH="$PATH" LIB="$LIB" LIB_HASH="$LIB_HASH" RUST_TOOLCHAIN="$RUST_TOOLCHAIN" \
            /bin/bash --noprofile --norc -euo pipefail -c "$(/bin/cat <<'CI_HELPERS_RUN'
          run_lib="$(/usr/bin/mktemp -d)"
          /bin/cp -RP "$LIB/." "$run_lib/"
          now=x
          [[ "$now" == "$LIB_HASH" ]] || exit 1
          . "$run_lib/scripts/lib_path.sh"
          /bin/bash "$run_lib/scripts/setup_rust.sh"
          CI_HELPERS_RUN
          )"
YML
)"
release='      - name: Release ci-helpers library copy
        if: ${{ always() }}
        shell: /bin/sh -e {0}
        env:
          LIB_0: ${{ steps.ci_lib.outputs.lib }}
          BASH_ENV: ""
          ENV: ""
          SHELLOPTS: ""
          BASHOPTS: ""
          PS4: ""
          LD_PRELOAD: ""
          LD_LIBRARY_PATH: ""
          LD_AUDIT: ""
          DYLD_INSERT_LIBRARIES: ""
          DYLD_LIBRARY_PATH: ""
          DYLD_FRAMEWORK_PATH: ""
          PYTHONPATH: ""
          PYTHONSTARTUP: ""
          PERL5LIB: ""
          PERL5OPT: ""
          RUBYOPT: ""
          NODE_OPTIONS: ""
          GIT_DIR: ""
          GIT_CONFIG_PARAMETERS: ""
          GIT_EXEC_PATH: ""
        run: /bin/chmod -R u+w "$LIB_0"'
build='      - run: make build'
wf() { printf 'jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n'; printf '%s\n' "$@" "$release"; }
wf_raw() { printf 'jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n'; printf '%s\n' "$@"; }

expect "isolated, then used after the caller's build" 0 "$(wf "$checkout" "$isolate" "$build" "$use")"
# Issue 375: a secret never becomes an argument of env. The keep form
# passes names; the env -i form may still carry the step's other variables.
keep_line="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import check_lib_isolation as c; print(c.KEEP_PREFIX, end="")' "$root/scripts")"
tok_use="${use/RUST_TOOLCHAIN: stable/RUST_TOOLCHAIN: stable
          GH_TOKEN: \$\{\{ secrets.GH_TOKEN \}\}}"
tok_use="${tok_use/          . \"\$run_lib\/scripts\/lib_path.sh\"/          . \"\$run_lib\/scripts\/lib_path.sh\" secret}"
leak_use="${tok_use/RUST_TOOLCHAIN=\"\$RUST_TOOLCHAIN\" \\/RUST_TOOLCHAIN=\"\$RUST_TOOLCHAIN\" GH_TOKEN=\"\$GH_TOKEN\" \\}"
# shellcheck disable=SC1003 # the trailing backslash is literal workflow text
keep_old='exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" LANG=C.UTF-8 STEP_PATH="$PATH" LIB="$LIB" LIB_HASH="$LIB_HASH" RUST_TOOLCHAIN="$RUST_TOOLCHAIN" \'
keep_use="${tok_use/"$keep_old"/"${keep_line}HOME STEP_PATH LIB LIB_HASH RUST_TOOLCHAIN GH_TOKEN' \\"}"
[[ "$leak_use" != "$tok_use" && "$keep_use" != "$tok_use" && "$tok_use" != "$use" ]] || { echo "FAIL premise: the issue 375 fixtures did not change"; fail=1; }
expect "secret step that does not pass the secret on" 0 "$(wf "$checkout" "$isolate" "$tok_use")"
expect "secret passed as an env -i argument" 1 "$(wf "$checkout" "$isolate" "$leak_use")"
expect "secret kept by name" 0 "$(wf "$checkout" "$isolate" "$keep_use")"
expect "keep form without HOME" 1 "$(wf "$checkout" "$isolate" "${keep_use/HOME STEP_PATH/STEP_PATH}")"
expect "keep form keeping BASH_ENV" 1 "$(wf "$checkout" "$isolate" "${keep_use/HOME STEP_PATH/HOME BASH_ENV STEP_PATH}")"
expect "keep form keeping a non-name" 1 "$(wf "$checkout" "$isolate" "${keep_use/HOME STEP_PATH/HOME A-B STEP_PATH}")"
expect "keep form with an edited snippet" 1 "$(wf "$checkout" "$isolate" "${keep_use/-u \"\$n\"/-u x}")"
expect "plain step: secret passed to env" 1 "$(wf_raw '      - env:
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
        run: /usr/bin/env -i PATH=/usr/bin:/bin T="$NPM_TOKEN" npm publish')"
expect "plain step: secrets expression passed to env" 1 "$(wf_raw '      - run: env X=${{ secrets.NPM_TOKEN }} npm publish')"
expect "plain step: secret-named variable passed to env" 1 "$(wf_raw '      - env:
          DEPLOY_PASSWORD: ${{ inputs.pw }}
        run: env P="${DEPLOY_PASSWORD}" ./deploy')"
expect "plain step: non-secret variable passed to env beside a secret" 0 "$(wf_raw '      - env:
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
          REGISTRY: https://registry.example.com
        run: env R="$REGISTRY" npm publish')"
expect "plain step: secret read from the environment" 0 "$(wf_raw '      - env:
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
        run: npm publish')"

expect "script run from the checkout after a build" 1 "$(wf "$checkout" "$isolate" "$build" '      - run: bash .ci-helpers-scripts/scripts/setup_rust.sh')"
expect "script run from a checkout moved under RUNNER_TEMP" 1 "$(wf "$checkout" "$isolate" '      - run: bash "$RUNNER_TEMP/ci-helpers-scripts/scripts/setup_php.sh"')"
expect "release upload from the publication checkout" 1 "$(wf "$build" '      - run: bash .ci-helpers-publication/scripts/github_release.sh')"
expect "isolate step not right after the checkout" 1 "$(wf "$checkout" "$build" "$isolate" "$use")"
expect "isolate step without an id" 1 "$(wf "$checkout" "${isolate/        id: ci_lib
/}" "$use")"
expect "git on the checkout after a caller step" 1 "$(wf "$checkout" "$isolate" "$build" '      - run: git -C .ci-helpers-scripts rev-parse HEAD')"
expect "git on the copy" 1 "$(wf "$checkout" "$isolate" '      - env:
          LIB: x
        run: git -C "$LIB" status')"
expect "git on the caller repo naming the checkout in a path" 0 "$(wf "$checkout" "$isolate" "      - run: printf '/.ci-helpers-scripts/' >> \"\$(git rev-parse --git-path info/exclude)\"")"
expect "use without the hash check" 1 "$(wf "$checkout" "$isolate" "${use/\[\[ \"\$now\" == \"\$LIB_HASH\" \]\] || exit 1/true}")"
expect "hash check without a fresh copy" 1 "$(wf "$checkout" "$isolate" "${use/\/bin\/cp -RP/cp -RP}")"
expect "script run straight from \$LIB" 1 "$(wf "$checkout" "$isolate" "${use/\$run_lib\/scripts/\$LIB\/scripts}")"
expect "script run through PATH bash" 1 "$(wf "$checkout" "$isolate" "${use/\/bin\/bash \"/bash \"}")"
expect "python script without -I" 1 "$(wf "$checkout" "$isolate" "${use/\/bin\/bash \"\$run_lib\/scripts\/setup_rust.sh\"/\/usr\/bin\/python3 \"\$run_lib\/scripts\/junit_summary.py\"}")"
expect "python script with -I" 0 "$(wf "$checkout" "$isolate" "${use/\/bin\/bash \"\$run_lib\/scripts\/setup_rust.sh\"/\/usr\/bin\/python3 -I \"\$run_lib\/scripts\/junit_summary.py\"}")"
expect "isolate through PATH bash" 1 "$(wf "$checkout" "${isolate/\/bin\/bash --noprofile --norc /bash }" "$use")"
expect "use step under shell: bash" 1 "$(wf "$checkout" "$isolate" "${use/$SH/shell: bash}")"
expect "isolate step under shell: bash" 1 "$(wf "$checkout" "${isolate/$SH/shell: bash}" "$use")"
expect "no BASH_FUNC_ guard" 1 "$(wf "$checkout" "$isolate" "${use/\*BASH_FUNC_\*/*NOPE*}")"
expect "xtrace left on" 1 "$(wf "$checkout" "$isolate" "${use/set +xv/true}")"
expect "env without -i" 1 "$(wf "$checkout" "$isolate" "${use/env -i PATH/env PATH}")"
expect "caller PATH as PATH" 1 "$(wf "$checkout" "$isolate" "${use/PATH=\/usr\/bin:\/bin/PATH=\"\$PATH\"}")"
expect "BASH_ENV passed through" 1 "$(wf "$checkout" "$isolate" "${use/RUST_TOOLCHAIN=\"\$RUST_TOOLCHAIN\"/BASH_ENV=\"\$BASH_ENV\"}")"
expect "SHELLOPTS passed through" 1 "$(wf "$checkout" "$isolate" "${use/RUST_TOOLCHAIN=\"\$RUST_TOOLCHAIN\"/SHELLOPTS=\"\$SHELLOPTS\"}")"
expect "GIT_DIR passed through" 1 "$(wf "$checkout" "$isolate" "${use/RUST_TOOLCHAIN=\"\$RUST_TOOLCHAIN\"/GIT_DIR=\"\$GIT_DIR\"}")"
expect "CI_HELPERS_ variable passed through" 1 "$(wf "$checkout" "$isolate" "${use/RUST_TOOLCHAIN=\"\$RUST_TOOLCHAIN\"/CI_HELPERS_RUN=\"\$CI_HELPERS_RUN\"}")"
expect "a name passed another's value" 1 "$(wf "$checkout" "$isolate" "${use/RUST_TOOLCHAIN=\"\$RUST_TOOLCHAIN\"/RUST_TOOLCHAIN=\"\$BASH_ENV\"}")"
expect "LIB_HASH not passed in" 1 "$(wf "$checkout" "$isolate" "${use/ LIB_HASH=\"\$LIB_HASH\"/}")"
expect "library code after the clean bash" 1 "$(wf "$checkout" "$isolate" "$use
          bash \"\$LIB/scripts/x.sh\"")"
late_cp="${use/          \/bin\/cp -RP \"\$LIB\/.\" \"\$run_lib\/\"
/}"
expect "hash compared before the copy is made" 1 "$(wf "$checkout" "$isolate" "${late_cp/          \/bin\/bash \"\$run_lib/          /bin/cp -RP \"\$LIB/.\" \"\$run_lib/\"
          /bin/bash \"\$run_lib}")"
expect "isolate step running more after the exec" 1 "$(wf "$checkout" "$isolate
          bash .ci-helpers-scripts/scripts/lib_isolate.sh" "$use")"
expect "use step without the PS4 blank" 1 "$(wf "$checkout" "$isolate" "${use/          PS4: \"\"
/}")"
expect "isolate step without the LD_PRELOAD blank" 1 "$(wf "$checkout" "${isolate/          LD_PRELOAD: \"\"
/}" "$use")"
expect "release step without the BASH_ENV blank" 1 "$(printf 'jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n'; printf '%s\n' "$checkout" "$isolate" "$use" "${release/          BASH_ENV: \"\"
/}")"
expect "bash shell on a Windows runner" 0 "$(printf 'jobs:\n  j:\n    runs-on: windows-latest\n    steps:\n'; printf '%s\n' "$checkout" "${isolate/$SH/shell: bash}" "${use/$SH/shell: bash}" "${release/$SH/shell: bash}")"
expect "bare sh where runs-on is an expression" 0 "$(printf 'jobs:\n  j:\n    runs-on: ${{ inputs.runner }}\n    steps:\n'; printf '%s\n' "$checkout" "${isolate/$SH/shell: sh}" "${use/$SH/shell: sh}" "${release/$SH/shell: sh}")"
expect "/bin/sh where runs-on is an expression, which a Windows runner cannot start" 1 "$(printf 'jobs:\n  j:\n    runs-on: ${{ inputs.runner }}\n    steps:\n'; printf '%s\n' "$checkout" "$isolate" "$use" "$release")"
expect "sh shell on a Windows runner" 1 "$(printf 'jobs:\n  j:\n    runs-on: windows-latest\n    steps:\n'; printf '%s\n' "$checkout" "$isolate" "$use" "$release")"
expect "isolate passing an extra variable" 1 "$(wf "$checkout" "${isolate/WF_SHA=\"\$WF_SHA\"/WF_SHA=\"\$WF_SHA\" GIT_DIR=\"\$GIT_DIR\"}" "$use")"
expect "no always() step releases the read-only copy" 1 "$(wf_raw "$checkout" "$isolate" "$use")"
expect "hash check after the use" 1 "$(wf "$checkout" "$isolate" "${use/          now=x/          /bin/bash \"\$run_lib/scripts/setup_rust.sh\"}")"
expect "LIB from a caller-controlled step" 1 "$(wf "$checkout" "$isolate" "${use//steps.ci_lib/steps.build}")"
expect "LIB read from the hash output" 1 "$(wf "$checkout" "$isolate" "${use/outputs.lib/outputs.hash}")"
expect "LIB set by GITHUB_ENV, not the step env" 1 "$(wf "$checkout" "$isolate" '      - run: |
          [[ "$now" == "$LIB_HASH" ]] || exit 1
          bash "$LIB/scripts/setup_rust.sh"')"
expect "copy mounted into a container" 1 "$(wf "$checkout" "$isolate" '      - run: docker run --rm -v "$LIB":/lib alpine true')"
expect "checkout mounted into a container" 1 "$(wf "$checkout" "$isolate" '      - run: docker run --rm --volume "$PWD/.ci-helpers-scripts:/x" alpine true')"
expect "workspace mounted, not the library" 0 "$(wf "$checkout" "$isolate" '      - run: docker run --rm -v "$PWD":/src alpine true')"
expect "job container volume naming the copy" 1 "$(printf 'jobs:\n  j:\n    runs-on: ubuntu-latest\n    container:\n      image: alpine\n      volumes:\n        - /home/runner/work/_temp/ci-helpers-lib.x:/lib\n    steps:\n%s\n' "$build")"
expect "pins file read from the checkout through env" 1 "$(wf "$checkout" "$isolate" '      - env:
          PINS: ${{ github.workspace }}/.ci-helpers-actions/scanner-pins.env
        run: cat "$PINS"')"
expect "cache key hashing a checkout file" 1 "$(wf "$checkout" "$isolate" "      - uses: actions/cache/restore@0000000000000000000000000000000000000000
        with:
          key: k-\${{ hashFiles('.ci-helpers-scripts/toolchain-pins.env') }}")"

# Composite and node actions from a library checkout, and the git that
# verifies that checkout.
blanks=""
for k in BASH_ENV ENV SHELLOPTS BASHOPTS PS4 LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT DYLD_INSERT_LIBRARIES \
    DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH PYTHONPATH PYTHONSTARTUP PERL5LIB PERL5OPT RUBYOPT NODE_OPTIONS \
    ; do
  blanks+="          $k: \"\"
"
done
blanks="${blanks%
}"
pubco='      - uses: actions/checkout@0000000000000000000000000000000000000000
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}
          path: .ci-helpers-publication
          persist-credentials: false'
pubverify="      - name: Verify publication action revision
        shell: /bin/bash --noprofile --norc -e -o pipefail {0}
        env:
          TRUSTED_SHA: \${{ job.workflow_sha }}
$blanks
        run: |
          git=; for g in /usr/bin/git /mingw64/bin/git.exe /clangarm64/bin/git.exe /cmd/git.exe; do if [[ -x \"\$g\" ]]; then git=\"\$g\"; break; fi; done; [[ -n \"\$git\" ]] || { echo \"::error::no git at a fixed path\"; exit 1; }
          genv=(/usr/bin/env -i PATH=/usr/bin:/bin); [[ ! -x /usr/bin/cygpath ]] || genv=(/usr/bin/env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_COMMON_DIR -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_EXEC_PATH)
          [[ \"\$(\"\${genv[@]}\" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \"\$git\" -c core.fsmonitor= -c core.hooksPath=/dev/null -C .ci-helpers-publication rev-parse HEAD)\" == \"\$TRUSTED_SHA\" ]] || exit 1"
pubuse="      - uses: ./.ci-helpers-publication/.github/actions/publication-check
        env:
$blanks"
pubrm="      - name: Remove publication action checkout
        shell: /bin/sh -e {0}
        env:
$blanks
        run: /bin/rm -rf -- .ci-helpers-publication"
pinned='      - uses: actions/upload-artifact@0000000000000000000000000000000000000000'
expect "publication action right after its checked checkout" 0 "$(wf_raw "$build" "$pubco" "$pubverify" "$pubuse" "$pinned" "$pubuse")"
expect "publication action with no checkout" 1 "$(wf_raw "$build" "$pubuse")"
expect "publication action after a run step since its checkout" 1 "$(wf_raw "$pubco" "$pubverify" "$pubuse" "$build" "$pubuse")"
expect "publication action after a fresh checkout" 0 "$(wf_raw "$pubco" "$pubverify" "$pubuse" "$build" "$pubrm" "$pubco" "$pubverify" "$pubuse")"
expect "publication action without the env: blanks" 1 "$(wf_raw "$pubco" "$pubverify" '      - uses: ./.ci-helpers-publication/.github/actions/publication-check')"
expect "publication action without the NODE_OPTIONS blank" 1 "$(wf_raw "$pubco" "$pubverify" "${pubuse/NODE_OPTIONS: \"\"/NODE_OPTIONS_X: \"\"}")"
expect "verify through PATH git" 1 "$(wf_raw "$pubco" "${pubverify/\"\$git\" -c core.fsmonitor= -c core.hooksPath=\/dev\/null -C/git -C}" "$pubuse")"
expect "verify git without hooksPath off" 1 "$(wf_raw "$pubco" "${pubverify/ -c core.hooksPath=\/dev\/null/}" "$pubuse")"
expect "verify git reading the global config" 1 "$(wf_raw "$pubco" "${pubverify/ GIT_CONFIG_GLOBAL=\/dev\/null/}" "$pubuse")"
expect "verify git from a planted \$git" 1 "$(wf_raw "$pubco" "${pubverify/git=; for g in/git=git; for g in}" "$pubuse")"
expect "verify step under PATH bash" 1 "$(wf_raw "$pubco" "${pubverify/shell: \/bin\/bash --noprofile --norc -e -o pipefail \{0\}/shell: bash}" "$pubuse")"
expect "verify step without the PS4 blank" 1 "$(wf_raw "$pubco" "${pubverify/          PS4: \"\"
/}" "$pubuse")"
expect "verify step with an empty GIT_DIR, which stops git" 1 "$(wf_raw "$pubco" "${pubverify/          PS4: \"\"/          PS4: \"\"
          GIT_DIR: \"\"}" "$pubuse")"
expect "verify git outside the genv wrapper" 1 "$(wf_raw "$pubco" "${pubverify//\"\${genv\[@\]}\" /}" "$pubuse")"
expect "verify step without the genv line" 1 "$(wf_raw "$pubco" "${pubverify/genv=(*GIT_EXEC_PATH)
/}" "$pubuse")"
expect "use step under shell: sh, found through PATH" 1 "$(wf "$checkout" "$isolate" "${use/$SH/shell: sh}")"
expect "isolate step under shell: sh, found through PATH" 1 "$(wf "$checkout" "${isolate/$SH/shell: sh}" "$use")"
expect "step PATH restored without the trusted tools" 1 "$(wf "$checkout" "$isolate" "${use/. \"\$run_lib\/scripts\/lib_path.sh\"/export PATH=\"\$STEP_PATH\"}")"
expect "release step under shell: sh, found through PATH" 1 "$(wf_raw "$checkout" "$isolate" "$use" "${release/$SH/shell: sh}")"
expect "PATH set again after lib_path.sh" 1 "$(wf "$checkout" "$isolate" "${use/. \"\$run_lib\/scripts\/lib_path.sh\"/. \"\$run_lib/scripts/lib_path.sh\"
          export PATH=\"\$STEP_PATH\"}")"
tok='GH_TOKEN: ${{ github.token }}'
expect "a step holding a token without lib_path.sh secret" 1 "$(wf "$checkout" "$isolate" "${use/RUST_TOOLCHAIN: stable/$tok}")"
expect "a step holding a token with lib_path.sh secret" 0 "$(wf "$checkout" "$isolate" "${use/RUST_TOOLCHAIN: stable/$tok}" | sed 's|lib_path.sh"$|lib_path.sh" secret|')"
expect "library script without lib_path.sh" 1 "$(wf "$checkout" "$isolate" "${use/          . \"\$run_lib\/scripts\/lib_path.sh\"
/}")"
expect "trusted tools set after the script runs" 1 "$(wf "$checkout" "$isolate" "${use/          . \"\$run_lib\/scripts\/lib_path.sh\"
          \/bin\/bash \"\$run_lib\/scripts\/setup_rust.sh\"/          /bin/bash \"\$run_lib/scripts/setup_rust.sh\"
          . \"\$run_lib/scripts/lib_path.sh\"}")"
expect "verify step without the git= line" 1 "$(wf_raw "$pubco" "${pubverify/git=; for g in*no git at a fixed path\"; exit 1; \}
/}")"
expect "verify step also running git through PATH" 1 "$(wf_raw "$pubco" "$pubverify
          git status" "$pubuse")"

expect_action() {  # expect_action <name> <rc> <action yaml> [action dir]
  local name="$1" want="$2" rc=0 dir="${4:-x}"
  rm -rf "$work/r"; mkdir -p "$work/r/.github/actions/$dir"
  printf '%s\n' "$3" > "$work/r/.github/actions/$dir/action.yml"
  python3 "$gate" --root "$work/r" > "$work/out" 2>&1 || rc=$?
  [[ "$rc" == "$want" ]] || { echo "FAIL $name: exit $rc, expected $want"; cat "$work/out"; fail=1; }
}
act="runs:
  using: composite
  steps:
    - name: Install
      shell: /bin/bash --noprofile --norc -e -o pipefail {0}
      env:
        ACTION_PATH: \${{ github.action_path }}
${blanks//          /        }
      run: /bin/bash \"\$ACTION_PATH/../../../scripts/install_foxguard.sh\""
expect_action "composite step running a library script with the blanks" 0 "$act"
expect_action "composite step running a library script without the BASH_ENV blank" 1 "${act/        BASH_ENV: \"\"
/}"
expect_action "composite step under a bare bash" 1 "${act/shell: \/bin\/bash --noprofile --norc -e -o pipefail \{0\}/shell: bash}"
expect_action "composite step calling bash through PATH" 1 "${act/run: \/bin\/bash/run: bash}"
expect_action "composite PowerShell step without -NoProfile" 1 "${act/shell: \/bin\/bash --noprofile --norc -e -o pipefail \{0\}/shell: pwsh}" windows-sign
pwsh_sh="shell: pwsh -NoProfile -NonInteractive -Command \". '{0}'\""
expect_action "composite PowerShell step with -NoProfile" 0 "${act/shell: \/bin\/bash --noprofile --norc -e -o pipefail \{0\}/$pwsh_sh}" windows-sign
expect_action "cross-platform composite step under bash" 0 "${act/shell: \/bin\/bash --noprofile --norc -e -o pipefail \{0\}/shell: bash}" gitleaks-scan
expect_action "cross-platform composite step under /bin/bash" 1 "$act" gitleaks-scan
expect_action "composite step running a script by github.action_path without blanks" 1 'runs:
  using: composite
  steps:
    - shell: bash
      run: bash "${{ github.action_path }}/data-safety-scan.sh"'

python3 "$gate" --root "$root" > "$work/out" 2>&1 || { echo "FAIL the repository's workflows:"; cat "$work/out"; fail=1; }

# lib_isolate.sh against a real git checkout. lib_hash is the listing and
# content hash every workflow step computes inline.
lib_hash() {
  (cd "$1" && export LC_ALL=C && { find . -type d -print0 | sort -z | xargs -0 printf 'd %s\n'; find . -type f -print0 | sort -z | xargs -0 sha256sum; } | sha256sum | cut -d' ' -f1)
}
iso="$root/scripts/lib_isolate.sh"
mk_checkout() {
  rm -rf "$work/ws"; mkdir -p "$work/ws/.ci-helpers-scripts/scripts" "$work/tmp"
  cp "$iso" "$work/ws/.ci-helpers-scripts/scripts/"
  printf 'echo hi\n' > "$work/ws/.ci-helpers-scripts/scripts/setup_x.sh"
  printf 'X=1\n' > "$work/ws/.ci-helpers-scripts/toolchain-pins.env"
  git -C "$work/ws/.ci-helpers-scripts" -c init.defaultBranch=main init -q
  git -C "$work/ws/.ci-helpers-scripts" add -A
  git -C "$work/ws/.ci-helpers-scripts" -c user.name=t -c user.email=t@example.com commit -qm t
  git -C "$work/ws/.ci-helpers-scripts" rev-parse HEAD
}
run_iso() {  # run_iso <sha> -> rc
  local sha="$1"
  (cd "$work/ws" && WF_SHA="$sha" RUNNER_TEMP="$work/tmp" GITHUB_OUTPUT="$work/gh_out" \
    bash .ci-helpers-scripts/scripts/lib_isolate.sh) > "$work/iso.out" 2>&1
}

sha="$(mk_checkout)"; : > "$work/gh_out"
if run_iso "$sha"; then
  lib="$(sed -n 's/^lib=//p' "$work/gh_out")"; hash="$(sed -n 's/^hash=//p' "$work/gh_out")"
  [[ -f "$lib/scripts/setup_x.sh" && -f "$lib/toolchain-pins.env" ]] || { echo "FAIL isolate: copy incomplete"; fail=1; }
  [[ ! -e "$work/ws/.ci-helpers-scripts" ]] || { echo "FAIL isolate: checkout left in the workspace"; fail=1; }
  [[ ! -w "$lib/scripts/setup_x.sh" ]] || { echo "FAIL isolate: copy is writable"; fail=1; }
  [[ ! -w "$lib/scripts" ]] || { echo "FAIL isolate: a directory of the copy is writable"; fail=1; }
  now="$(lib_hash "$lib")"
  [[ "$now" == "$hash" ]] || { echo "FAIL isolate: recorded hash $hash, recomputed $now"; fail=1; }
  chmod u+w "$lib/scripts/setup_x.sh"; echo 'echo pwned' >> "$lib/scripts/setup_x.sh"
  now="$(lib_hash "$lib")"
  [[ "$now" != "$hash" ]] || { echo "FAIL isolate: a rewritten script keeps the hash"; fail=1; }
else
  echo "FAIL isolate on a good checkout:"; cat "$work/iso.out"; fail=1
fi

sha="$(mk_checkout)"
run_iso "0000000000000000000000000000000000000000" && { echo "FAIL isolate accepted a checkout at another commit"; fail=1; }
run_iso "" && { echo "FAIL isolate accepted an empty job.workflow_sha"; fail=1; }

# A caller step that planted core.fsmonitor in the checkout's .git: the
# isolate step must not run it.
sha="$(mk_checkout)"
printf '#!/bin/sh\ntouch "%s/planted"\n' "$work" > "$work/fsm.sh"; chmod +x "$work/fsm.sh"
git -C "$work/ws/.ci-helpers-scripts" config core.fsmonitor "$work/fsm.sh"
run_iso "$sha" || { echo "FAIL isolate with a planted fsmonitor:"; cat "$work/iso.out"; fail=1; }
[[ ! -e "$work/planted" ]] || { echo "FAIL isolate ran a planted core.fsmonitor"; fail=1; }

sha="$(mk_checkout)"
ln -s /etc/passwd "$work/ws/.ci-helpers-scripts/scripts/link.sh"
run_iso "$sha" && { echo "FAIL isolate accepted a symlink in scripts/"; fail=1; }

sha="$(mk_checkout)"
mkfifo "$work/ws/.ci-helpers-scripts/scripts/pipe"
run_iso "$sha" && { echo "FAIL isolate accepted a fifo in scripts/"; fail=1; }

# The real isolate and Setup Rust steps of tauri-release.yml (build-macos, a
# fixed runner, so the step names /bin/sh), run as the runner
# runs them: the caller's GITHUB_ENV first, then the step's own env: on top
# (it wins), then `sh -e <file>`; once with dash and once with bash --posix,
# which is sh on macOS. What a caller can set: BASH_ENV, ENV, SHELLOPTS=xtrace,
# BASHOPTS, PS4 with a command substitution, LD_PRELOAD (a real library that
# touches a canary when one can be built), GIT_DIR, a CI_HELPERS_* variable,
# git and bash shims first on PATH. None may run or reach the library code.
# The release job's Create GitHub Release step (github_release.sh, with
# GH_TOKEN) runs through the same harness as `release`.
python3 - "$root/.github/workflows" "$work" <<'PY'
import pathlib, sys, yaml
wf = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
for fname, job, nm, tag in (("tauri-release.yml", "build-macos", "Isolate ci-helpers scripts", "isolate"),
                            ("tauri-release.yml", "build-macos", "Setup Rust and universal targets", "use"),
                            ("create-github-release.yml", "release", "Create GitHub Release", "release")):
    for st in yaml.safe_load((wf / fname).read_text())["jobs"][job]["steps"]:
        if st.get("name") == nm:
            (out / f"step-{tag}.sh").write_text(st["run"])
            (out / f"shell-{tag}").write_text(str(st.get("shell") or ""))
            blanks = [k for k, v in (st.get("env") or {}).items() if v == ""]
            (out / f"blanks-{tag}").write_text("".join(f"{k}=\n" for k in blanks))
PY
for tag in isolate use release; do
  [[ -s "$work/step-$tag.sh" ]] || { echo "FAIL: no $tag step to run"; fail=1; }
done
mkdir -p "$work/shim"
# A caller's GITHUB_PATH entry: a shell the runner could pick for the step,
# and tools a library script calls by name.
for t in sh bash; do
  printf '#!/bin/sh\ntouch "%s/canary-shim"\nexec /bin/%s "$@"\n' "$work" "$t" > "$work/shim/$t"; chmod +x "$work/shim/$t"
done
for t in git curl gh tar; do
  printf '#!/bin/sh\ntouch "%s/canary-shim"\nexec /usr/bin/%s "$@"\n' "$work" "$t" > "$work/shim/$t"; chmod +x "$work/shim/$t"
done
printf 'touch "%s/canary-bashenv"\n' "$work" > "$work/bashenv.sh"
preload=""
if command -v cc >/dev/null 2>&1; then
  printf '#include <stdio.h>\n__attribute__((constructor)) static void c(void) { FILE *f = fopen("%s/canary-preload", "w"); if (f) fclose(f); }\n' "$work" > "$work/canary.c"
  cc -shared -fPIC -o "$work/canary.so" "$work/canary.c" 2>/dev/null && preload="$work/canary.so"
fi
if [[ -n "$preload" ]]; then
  LD_PRELOAD="$preload" /bin/true
  [[ -e "$work/canary-preload" ]] || { echo "FAIL premise: the LD_PRELOAD canary does not fire"; fail=1; preload=""; }
  rm -f "$work/canary-preload"
else
  echo "note: no C compiler; LD_PRELOAD is checked by presence only"
fi
# The runner finds the step's shell the way WhichUtil.Which does: an
# absolute path as is, a bare name on the PATH with the GITHUB_PATH entries
# first. `sh` would be the caller's shim.
runner_shell() {  # runner_shell <tag> -> the command the runner starts
  local s f
  case "$1" in isolate) f=isolate ;; use) f=use ;; release|argv) f=release ;; verify) f=verify ;; *) return 1 ;; esac
  s="$(< "$work/shell-$f")"; s="${s%% *}"
  if [[ "$s" == /* ]]; then echo "$s"; else PATH="$work/shim:$PATH" command -v "$s"; fi
}
step_as_runner() {  # step_as_runner <tag> <shell...> -- <extra env...>
  local tag="$1"; shift
  local -a sh=() extra=() blanks=()
  while [[ "$1" != -- ]]; do sh+=("$1"); shift; done; shift
  extra=("$@")
  mapfile -t blanks < "$work/blanks-${tag/argv/release}"
  # The binary the runner would start, with the arguments of the variant.
  [[ "$(runner_shell "$tag")" == "/bin/sh" ]] || sh[0]="$(runner_shell "$tag")"
  env PATH="$work/shim:$PATH" BASH_ENV="$work/bashenv.sh" ENV="$work/bashenv.sh" \
    SHELLOPTS=xtrace BASHOPTS=extdebug PS4='$(touch "$HOME/canary-ps4")+TRACE ' \
    LD_PRELOAD="${preload:-$work/none.so}" GIT_DIR="$work/nowhere" CI_HELPERS_RUN=pwned \
    "${extra[@]}" "${blanks[@]}" "${sh[@]}" "$work/step-$tag.sh"
}
printf '#!/usr/bin/env bash\nenv > "%s/script-env"\nset -o > "%s/script-opts"\nfor t in git curl tar; do command -v "$t"; done > "%s/script-tools"\n' "$work" "$work" "$work" > "$work/stub-setup_rust.sh"
for shell in "/bin/sh -e" "/bin/bash --posix -e"; do
  read -r -a shv <<< "$shell"
  rm -f "$work"/canary-* "$work/script-env" "$work/script-opts"
  sha="$(mk_checkout)"
  cp "$work/stub-setup_rust.sh" "$work/ws/.ci-helpers-scripts/scripts/setup_rust.sh"
  cp "$work/stub-setup_rust.sh" "$work/ws/.ci-helpers-scripts/scripts/github_release.sh"
  cp "$root/scripts/lib_path.sh" "$work/ws/.ci-helpers-scripts/scripts/lib_path.sh"
  git -C "$work/ws/.ci-helpers-scripts" add -A
  git -C "$work/ws/.ci-helpers-scripts" -c user.name=t -c user.email=t@example.com commit -qm stub
  sha="$(git -C "$work/ws/.ci-helpers-scripts" rev-parse HEAD)"
  : > "$work/gh_out"
  (cd "$work/ws" && step_as_runner isolate "${shv[@]}" -- WF_SHA="$sha" RUNNER_TEMP="$work/tmp" \
    GITHUB_OUTPUT="$work/gh_out" HOME="$work") > "$work/iso.out" 2>&1 \
    || { echo "FAIL [$shell] the isolate step as the runner runs it:"; cat "$work/iso.out"; fail=1; }
  lib="$(sed -n 's/^lib=//p' "$work/gh_out")"; hash="$(sed -n 's/^hash=//p' "$work/gh_out")"
  (cd "$work" && step_as_runner use "${shv[@]}" -- LIB="$lib" LIB_HASH="$hash" RUST_TOOLCHAIN=stable \
    RUNNER_TEMP="$work/tmp" HOME="$work") > "$work/use.out" 2>&1 \
    || { echo "FAIL [$shell] the Setup Rust step as the runner runs it:"; cat "$work/use.out"; fail=1; }
  [[ -f "$work/script-env" ]] || { echo "FAIL [$shell] the library script did not run"; fail=1; }
  for v in BASH_ENV ENV SHELLOPTS BASHOPTS PS4 LD_PRELOAD GIT_DIR CI_HELPERS_RUN; do
    ! grep -q "^$v=" "$work/script-env" 2>/dev/null || { echo "FAIL [$shell] $v reached the library script"; fail=1; }
  done
  grep -q '^RUST_TOOLCHAIN=stable$' "$work/script-env" 2>/dev/null || { echo "FAIL [$shell] a named variable did not reach the library script"; fail=1; }
  ! grep -q "^$work/shim/" "$work/script-tools" 2>/dev/null || { echo "FAIL [$shell] a GITHUB_PATH entry shadowed a tool the library script calls:"; cat "$work/script-tools"; fail=1; }
  grep -q '^/.*/git$' "$work/script-tools" 2>/dev/null || { echo "FAIL [$shell] the library script found no git"; fail=1; }
  for c in bashenv ps4 preload shim; do
    [[ ! -e "$work/canary-$c" ]] || { echo "FAIL [$shell] the $c canary fired in the isolate or Setup Rust step"; fail=1; }
  done
  rm -f "$work/script-env" "$work/script-tools"
  (cd "$work" && step_as_runner release "${shv[@]}" -- LIB="$lib" LIB_HASH="$hash" GH_TOKEN=t TAG_NAME=v1 \
    RELEASE_NAME=v1 BODY_PATH= PRERELEASE=false MAKE_LATEST=true RUNNER_TEMP="$work/tmp" HOME="$work") > "$work/rel.out" 2>&1 \
    || { echo "FAIL [$shell] the Create GitHub Release step as the runner runs it:"; cat "$work/rel.out"; fail=1; }
  grep -q '^GH_TOKEN=t$' "$work/script-env" 2>/dev/null || { echo "FAIL [$shell] github_release.sh did not run with GH_TOKEN"; fail=1; }
  for v in BASH_ENV ENV SHELLOPTS BASHOPTS PS4 LD_PRELOAD GIT_DIR CI_HELPERS_RUN; do
    ! grep -q "^$v=" "$work/script-env" 2>/dev/null || { echo "FAIL [$shell] $v reached github_release.sh"; fail=1; }
  done
  ! grep -q "^$work/shim/" "$work/script-tools" 2>/dev/null || { echo "FAIL [$shell] a GITHUB_PATH entry shadowed a tool github_release.sh calls"; fail=1; }
  grep -q '^xtrace[[:space:]]*off' "$work/script-opts" 2>/dev/null || { echo "FAIL [$shell] xtrace reached the library script"; fail=1; }
  ! grep -q 'TRACE' "$work/iso.out" "$work/use.out" || { echo "FAIL [$shell] a step traced its commands"; fail=1; }
  for c in bashenv ps4 preload shim; do
    [[ ! -e "$work/canary-$c" ]] || { echo "FAIL [$shell] the $c canary fired"; fail=1; }
  done
  # The token never becomes an argument: every env and the bash that starts
  # it record their own /proc/self/cmdline, and none may hold the value. The
  # step is the real one, with only those two paths pointed at the recorders.
  if [[ -r /proc/self/cmdline ]]; then
    tok="tok-375-$$-$RANDOM"
    rm -rf "$work/argv"; mkdir -p "$work/argv"; rm -f "$work/script-env"
    for t in env bash; do
      d=/usr/bin; [[ "$t" == env ]] || d=/bin
      printf '#!/bin/sh\n/usr/bin/tr "\\000" " " < /proc/$$/cmdline >> "%s/argv/seen"; echo >> "%s/argv/seen"\nexec %s/%s "$@"\n' \
        "$work" "$work" "$d" "$t" > "$work/argv/$t"
      chmod +x "$work/argv/$t"
    done
    sed -e "s#/usr/bin/env #$work/argv/env #g" -e "s#^exec /bin/bash #exec $work/argv/bash #" "$work/step-release.sh" > "$work/step-argv.sh"
    (cd "$work" && step_as_runner argv "${shv[@]}" -- A-B=1 LIB="$lib" LIB_HASH="$hash" GH_TOKEN="$tok" TAG_NAME=v1 \
      RELEASE_NAME=v1 BODY_PATH= PRERELEASE=false MAKE_LATEST=true RUNNER_TEMP="$work/tmp" HOME="$work") > "$work/rel.out" 2>&1 \
      || { echo "FAIL [$shell] the Create GitHub Release step with recorded argv:"; cat "$work/rel.out"; fail=1; }
    grep -q -- '-u' "$work/argv/seen" 2>/dev/null || grep -q -- ' -i ' "$work/argv/seen" 2>/dev/null \
      || { echo "FAIL premise [$shell] no env stage was recorded"; fail=1; }
    ! grep -qF -- "$tok" "$work/argv/seen" 2>/dev/null \
      || { echo "FAIL [$shell] GH_TOKEN's value is in the argv of the env stage"; fail=1; }
    grep -qx "GH_TOKEN=$tok" "$work/script-env" 2>/dev/null || { echo "FAIL [$shell] GH_TOKEN did not reach github_release.sh by the environment"; fail=1; }
    ! grep -q '^A-B=' "$work/script-env" 2>/dev/null || { echo "FAIL [$shell] a variable with an invalid name reached github_release.sh"; fail=1; }
  fi
  # The envelope alone, without the env: blanks: still nothing reaches the
  # library script, though the outer shell may have read them.
  rm -f "$work/script-env"
  (cd "$work" && env SHELLOPTS=xtrace GIT_DIR="$work/nowhere" CI_HELPERS_RUN=pwned LIB="$lib" LIB_HASH="$hash" \
    RUST_TOOLCHAIN=stable RUNNER_TEMP="$work/tmp" HOME="$work" "${shv[@]}" "$work/step-use.sh") > "$work/use.out" 2>&1 || true
  for v in SHELLOPTS GIT_DIR CI_HELPERS_RUN; do
    ! grep -q "^$v=" "$work/script-env" 2>/dev/null || { echo "FAIL [$shell] $v crossed the env -i envelope"; fail=1; }
  done
done

# The real Verify step of release-upload.yml, as the runner runs it, after
# a caller step set GIT_DIR, BASH_ENV and a git and bash shim on PATH and
# planted core.fsmonitor and a hook in the checkout: it must still accept
# the right commit, refuse a wrong one, and run none of them.
python3 - "$root/.github/workflows/release-upload.yml" "$work" <<'PY'
import pathlib, sys, yaml
out = pathlib.Path(sys.argv[2])
for st in yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())["jobs"]["upload"]["steps"]:
    if st.get("name") == "Verify publication action revision":
        (out / "step-verify.sh").write_text(st["run"])
        (out / "shell-verify").write_text(str(st.get("shell") or ""))
        (out / "blanks-verify").write_text("".join(f"{k}=\n" for k, v in (st.get("env") or {}).items() if v == ""))
        break
PY
[[ -s "$work/step-verify.sh" ]] || { echo "FAIL: release-upload.yml has no Verify publication action revision step"; fail=1; }
sha="$(mk_checkout)"
mv "$work/ws/.ci-helpers-scripts" "$work/ws/.ci-helpers-publication"
git -C "$work/ws/.ci-helpers-publication" config core.fsmonitor "$work/fsm.sh"
printf '#!/bin/sh\ntouch "%s/planted"\n' "$work" > "$work/ws/.ci-helpers-publication/.git/hooks/post-checkout"
chmod +x "$work/ws/.ci-helpers-publication/.git/hooks/post-checkout"
git -C "$work/ws" -c init.defaultBranch=main init -q
rm -f "$work"/canary-* "$work/planted"
verify_sh="$(runner_shell verify)"
read -r -a verify_args <<< "$(cut -d' ' -f2- "$work/shell-verify" | sed 's/{0}//')"
mapfile -t verify_blanks < "$work/blanks-verify"
(cd "$work/ws" && env PATH="$work/shim:$PATH" GIT_DIR="$work/nowhere" BASH_ENV="$work/bashenv.sh" TRUSTED_SHA="$sha" \
  HOME="$work" "${verify_blanks[@]}" "$verify_sh" "${verify_args[@]}" "$work/step-verify.sh") > "$work/verify.out" 2>&1 \
  || { echo "FAIL the Verify step refused the right commit:"; cat "$work/verify.out"; fail=1; }
(cd "$work/ws" && env PATH="$work/shim:$PATH" TRUSTED_SHA=0000000000000000000000000000000000000000 \
  HOME="$work" "${verify_blanks[@]}" "$verify_sh" "${verify_args[@]}" "$work/step-verify.sh") > "$work/verify.out" 2>&1 \
  && { echo "FAIL the Verify step accepted another commit"; fail=1; }
for c in "$work/canary-shim" "$work/canary-bashenv" "$work/planted"; do
  [[ ! -e "$c" ]] || { echo "FAIL the Verify step ran $(basename "$c")"; fail=1; }
done
(cd "$work/ws" && env TRUSTED_SHA="$sha" HOME="$work" "${verify_blanks[@]}" "$verify_sh" "${verify_args[@]}" \
  "$work/step-verify.sh") > "$work/verify.out" 2>&1 || { echo "FAIL the Verify step on a clean runner:"; cat "$work/verify.out"; fail=1; }
grep -qx '/.ci-helpers-publication/' "$work/ws/.git/info/exclude" \
  || { echo "FAIL the Verify step no longer keeps the checkout out of the caller's git status"; fail=1; }

# The scripts that hold a token, password or licence run with
# `lib_path.sh secret`: every tool they call by name must resolve to the
# trusted links, /usr/bin or /bin, with a hostile entry for each of those
# names first on the step's PATH.
mkdir -p "$work/hostile" "$work/seclib/scripts"
cp "$root/scripts/lib_path.sh" "$work/seclib/scripts/"
for s in github_release docker_login unity_test; do
  names="$(python3 "$root/tests/secret_script_tools.py" < "$root/scripts/$s.sh")"
  for need in github_release:gh docker_login:docker unity_test:docker; do
    [[ "${need%%:*}" != "$s" ]] || grep -qx "${need#*:}" <<< "$names" \
      || { echo "FAIL premise: no ${need#*:} found in $s.sh by the tool lister"; fail=1; }
  done
  for n in $names; do
    printf '#!/bin/sh\ntouch "%s/canary-hostile"\n' "$work" > "$work/hostile/$n"; chmod +x "$work/hostile/$n"
  done
  # shellcheck disable=SC2030,SC2031
  bad="$(run_lib="$work/seclib" STEP_PATH="$work/hostile:$PATH" names="$names" HOSTPATH="$PATH" /bin/bash --noprofile --norc -c '
    set -euo pipefail
    rm -rf "$run_lib/.trusted-bin"
    . "$run_lib/scripts/lib_path.sh" secret
    for n in $names; do
      PATH="$HOSTPATH" command -v "$n" >/dev/null 2>&1 || continue   # not a tool on this host
      case "$(type -t "$n")" in builtin|keyword|function) continue ;; esac
      p="$(command -v "$n" || true)"
      case "$p" in "$run_lib/.trusted-bin/"*|/usr/bin/*|/bin/*) ;; *) echo "$n -> ${p:-not found}" ;; esac
    done')" || { echo "FAIL lib_path.sh secret did not load"; fail=1; }
  [[ -z "$bad" ]] || { echo "FAIL $s.sh under lib_path.sh secret calls a tool outside the trusted set:"; echo "$bad"; fail=1; }
  chmod -R u+w "$work/seclib"; rm -rf "$work/seclib/.trusted-bin"
done

# An exported function survives into bash and can shadow a builtin. Where
# sh is bash (macOS, Git Bash on Windows) the step sees it and refuses;
# where sh is dash (Ubuntu) dash drops it, and it must not run either way.
(cd "$work" && env 'BASH_FUNC_cd%%=() { touch "$HOME/func-ran"; }' LIB="$lib" LIB_HASH="$hash" HOME="$work" \
  /bin/bash --posix -e "$work/step-use.sh") > "$work/use.out" 2>&1 \
  && { echo "FAIL the step ran with an exported function under bash as sh"; fail=1; }
grep -q 'exported shell function' "$work/use.out" || { echo "FAIL no BASH_FUNC_ refusal under bash as sh:"; cat "$work/use.out"; fail=1; }
(cd "$work" && env 'BASH_FUNC_cd%%=() { touch "$HOME/func-ran"; }' LIB="$lib" LIB_HASH="$hash" RUST_TOOLCHAIN=stable \
  RUNNER_TEMP="$work/tmp" HOME="$work" /bin/sh -e "$work/step-use.sh") > "$work/use.out" 2>&1 \
  || { echo "FAIL the step under dash with an exported function:"; cat "$work/use.out"; fail=1; }
[[ ! -e "$work/func-ran" ]] || { echo "FAIL the exported function ran"; fail=1; }

# Premise: bash does read BASH_ENV, so the sh envelope is what keeps it out.
(cd "$work" && BASH_ENV="$work/bashenv.sh" /bin/bash --noprofile --norc -c true)
[[ -e "$work/canary-bashenv" ]] || { echo "FAIL premise: bash did not read BASH_ENV, so the envelope is untested"; fail=1; }

sha="$(mk_checkout)"; : > "$work/gh_out"
mv "$work/ws/.ci-helpers-scripts" "$work/ws/.ci-helpers-publication"
(cd "$work/ws" && WF_SHA="$sha" RUNNER_TEMP="$work/tmp" GITHUB_OUTPUT="$work/gh_out" \
  bash .ci-helpers-publication/scripts/lib_isolate.sh .ci-helpers-publication --keep) > "$work/iso.out" 2>&1 \
  || { echo "FAIL isolate --keep:"; cat "$work/iso.out"; fail=1; }
[[ -d "$work/ws/.ci-helpers-publication" ]] || { echo "FAIL isolate --keep removed the checkout"; fail=1; }
grep -q '^pins=[0-9a-f]\{64\}$' "$work/gh_out" || { echo "FAIL isolate wrote no pins hash"; fail=1; }

[[ "$fail" == 0 ]] && echo "ok: library scripts run only from a verified copy; check_lib_isolation.py and lib_isolate.sh hold it"
exit "$fail"
