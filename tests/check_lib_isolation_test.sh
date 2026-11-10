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

checkout='      - uses: actions/checkout@0000000000000000000000000000000000000000
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}
          path: .ci-helpers-scripts
          persist-credentials: false'
isolate="$(cat <<'YML'
      - name: Isolate ci-helpers scripts
        id: ci_lib
        shell: sh
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
        shell: sh
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
          /bin/bash "$run_lib/scripts/setup_rust.sh"
          CI_HELPERS_RUN
          )"
YML
)"
release='      - name: Release ci-helpers library copy
        if: ${{ always() }}
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
expect "use step under shell: bash" 1 "$(wf "$checkout" "$isolate" "${use/shell: sh/shell: bash}")"
expect "isolate step under shell: bash" 1 "$(wf "$checkout" "${isolate/shell: sh/shell: bash}" "$use")"
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
expect "bash shell on a Windows runner" 0 "$(printf 'jobs:\n  j:\n    runs-on: windows-latest\n    steps:\n'; printf '%s\n' "$checkout" "${isolate/shell: sh/shell: bash}" "${use/shell: sh/shell: bash}" "$release")"
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
expect "composite action from the publication checkout" 0 "$(wf "$build" '      - uses: ./.ci-helpers-publication/.github/actions/publication-check')"

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

# The real isolate and Setup Rust steps of tauri.yml, run as the runner
# runs them: the caller's GITHUB_ENV first, then the step's own env: on top
# (it wins), then `sh -e <file>`; once with dash and once with bash --posix,
# which is sh on macOS. What a caller can set: BASH_ENV, ENV, SHELLOPTS=xtrace,
# BASHOPTS, PS4 with a command substitution, LD_PRELOAD (a real library that
# touches a canary when one can be built), GIT_DIR, a CI_HELPERS_* variable,
# git and bash shims first on PATH. None may run or reach the library code.
python3 - "$root/.github/workflows/tauri.yml" "$work" <<'PY'
import pathlib, sys, yaml
steps = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())["jobs"]["ci"]["steps"]
out = pathlib.Path(sys.argv[2])
for st in steps:
    for nm, tag in (("Isolate ci-helpers scripts", "isolate"), ("Setup Rust", "use")):
        if st.get("name") == nm:
            (out / f"step-{tag}.sh").write_text(st["run"])
            blanks = [k for k, v in (st.get("env") or {}).items() if v == ""]
            (out / f"blanks-{tag}").write_text("".join(f"{k}=\n" for k in blanks))
PY
[[ -s "$work/step-isolate.sh" && -s "$work/step-use.sh" ]] || { echo "FAIL: tauri.yml has no isolate or Setup Rust step to run"; fail=1; }
mkdir -p "$work/shim"
for t in git bash; do
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
step_as_runner() {  # step_as_runner <tag> <shell...> -- <extra env...>
  local tag="$1"; shift
  local -a sh=() extra=() blanks=()
  while [[ "$1" != -- ]]; do sh+=("$1"); shift; done; shift
  extra=("$@")
  mapfile -t blanks < "$work/blanks-$tag"
  env PATH="$work/shim:$PATH" BASH_ENV="$work/bashenv.sh" ENV="$work/bashenv.sh" \
    SHELLOPTS=xtrace BASHOPTS=extdebug PS4='$(touch "$HOME/canary-ps4")+TRACE ' \
    LD_PRELOAD="${preload:-$work/none.so}" GIT_DIR="$work/nowhere" CI_HELPERS_RUN=pwned \
    "${extra[@]}" "${blanks[@]}" "${sh[@]}" "$work/step-$tag.sh"
}
printf '#!/usr/bin/env bash\nenv > "%s/script-env"\nset -o > "%s/script-opts"\n' "$work" "$work" > "$work/stub-setup_rust.sh"
for shell in "/bin/sh -e" "/bin/bash --posix -e"; do
  read -r -a shv <<< "$shell"
  rm -f "$work"/canary-* "$work/script-env" "$work/script-opts"
  sha="$(mk_checkout)"
  cp "$work/stub-setup_rust.sh" "$work/ws/.ci-helpers-scripts/scripts/setup_rust.sh"
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
  grep -q '^xtrace[[:space:]]*off' "$work/script-opts" 2>/dev/null || { echo "FAIL [$shell] xtrace reached the library script"; fail=1; }
  ! grep -q 'TRACE' "$work/iso.out" "$work/use.out" || { echo "FAIL [$shell] a step traced its commands"; fail=1; }
  for c in bashenv ps4 preload shim; do
    [[ ! -e "$work/canary-$c" ]] || { echo "FAIL [$shell] the $c canary fired"; fail=1; }
  done
  # The envelope alone, without the env: blanks: still nothing reaches the
  # library script, though the outer shell may have read them.
  rm -f "$work/script-env"
  (cd "$work" && env SHELLOPTS=xtrace GIT_DIR="$work/nowhere" CI_HELPERS_RUN=pwned LIB="$lib" LIB_HASH="$hash" \
    RUST_TOOLCHAIN=stable RUNNER_TEMP="$work/tmp" HOME="$work" "${shv[@]}" "$work/step-use.sh") > "$work/use.out" 2>&1 || true
  for v in SHELLOPTS GIT_DIR CI_HELPERS_RUN; do
    ! grep -q "^$v=" "$work/script-env" 2>/dev/null || { echo "FAIL [$shell] $v crossed the env -i envelope"; fail=1; }
  done
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
