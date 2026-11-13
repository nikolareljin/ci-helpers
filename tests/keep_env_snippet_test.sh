#!/bin/bash
# Runs the keep form (KEEP_PREFIX in scripts/check_lib_isolation.py) for real,
# with the snippet text taken from a shipped workflow. Runs on Linux, macOS
# (/bin/bash 3.2, BSD env) and Windows Git Bash; self-test runs all three.
# Checks: a variable left off the keep list is gone, a kept one is there, a
# secret's value is never an argument, and every listing it cannot trust
# stops the step.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

line="$(grep -h -m1 -F "exec /bin/bash --noprofile --norc -c 'set +xv -f +o posix;" "$root/.github/workflows/auto-tag.yml")"
snip="${line#*-c \'}"
snip="${snip%%\' ci-helpers-env *}"
[[ -n "$snip" && "$snip" != "$line" && "$snip" == *"/usr/bin/env -0"* ]] || { echo "FAIL premise: no keep snippet in auto-tag.yml"; exit 1; }
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  want="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import check_lib_isolation as c; print(c.KEEP_SNIPPET, end="")' "$root/scripts")"
  [[ "$want" == "$snip" ]] || { echo "FAIL premise: auto-tag.yml does not carry KEEP_SNIPPET"; fail=1; }
fi

# rec records the arguments the snippet hands env, then runs the real env.
# shellcheck disable=SC2016 # the recorder script is written literally
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s/argv"\nexec /usr/bin/env "$@"\n' "$work" > "$work/rec"
chmod +x "$work/rec"
rec_snip="${snip//exec \/usr\/bin\/env /exec $work/rec }"
[[ "$rec_snip" != "$snip" ]] || { echo "FAIL premise: no exec of /usr/bin/env in the snippet"; exit 1; }
body="/usr/bin/env > $work/inner; echo ran > $work/ran"

run() {  # run <snippet> <env args...>: the keep form keeping HOME and KEEPME
  local s="$1"; shift
  rm -f "$work/inner" "$work/ran" "$work/argv"
  /usr/bin/env "$@" /bin/bash --noprofile --norc -c "$s" ci-helpers-env 'HOME KEEPME' \
    /bin/bash --noprofile --norc -c "$body" > "$work/out" 2>&1
}

tok="tok-375-$$-$RANDOM$RANDOM"
# 1. The real environment of this job, plus a secret and a kept variable.
if SECRET_TOKEN="$tok" KEEPME=kept run "$rec_snip"; then
  [[ -e "$work/ran" ]] || { echo "FAIL the body did not run"; fail=1; }
  ! grep -q '^SECRET_TOKEN=' "$work/inner" || { echo "FAIL SECRET_TOKEN reached the body"; fail=1; }
  grep -qx 'KEEPME=kept' "$work/inner" || { echo "FAIL KEEPME did not reach the body"; fail=1; }
  grep -q "^HOME=" "$work/inner" || { echo "FAIL HOME did not reach the body"; fail=1; }
  grep -qx 'PATH=/usr/bin:/bin' "$work/inner" || { echo "FAIL PATH is not /usr/bin:/bin in the body"; fail=1; }
  grep -qx 'SECRET_TOKEN' "$work/argv" || { echo "FAIL SECRET_TOKEN was not unset by name"; fail=1; }
  ! grep -qF -- "$tok" "$work/argv" || { echo "FAIL the secret's value is an argument of env"; fail=1; }
  # Bash adds PWD, SHLVL and _. On Windows the MSYS runtime re-adds
  # SYSTEMROOT and WINDIR to every process and Git Bash sets MSYSTEM; none
  # comes from the step, and SECRET_TOKEN is still checked above.
  allow='HOME|KEEPME|PATH|LANG|PWD|SHLVL|_'
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) allow="$allow|MSYSTEM|SYSTEMROOT|WINDIR" ;; esac
  extra="$(grep -v -E "^($allow)=" "$work/inner" | sed 's/=.*//' | tr '\n' ' ')"
  [[ -z "$extra" ]] || { echo "FAIL names besides the kept ones reached the body: $extra"; fail=1; }
else
  echo "FAIL the keep form refused this job's environment:"; cat "$work/out"; fail=1
fi
# The argv of the running outer bash, where /proc shows it.
if [[ -r /proc/self/cmdline ]]; then
  SECRET_TOKEN="$tok" /bin/bash --noprofile --norc -c "${snip//\$@//bin/cat /proc/\$\$/cmdline}" x 'HOME' > "$work/cmdline" 2>&1
  ! grep -qaF -- "$tok" "$work/cmdline" || { echo "FAIL the secret's value is in /proc cmdline"; fail=1; }
fi

# 2. Awkward names and values: removed by name, the body still runs.
nl_value="$(printf 'a\nCI_HELPERS_ENV_END\nPATH=/evil')"
if run "$snip" HOME="$work" PATH=/usr/bin:/bin KEEPME=k 'A-B=1' 'ProgramFiles(x86)=C:\p' "ML=$nl_value"; then
  ! grep -q -E '^(A-B|ProgramFiles\(x86\)|ML)=' "$work/inner" || { echo "FAIL an awkward name reached the body"; fail=1; }
  ! grep -q '^PATH=/evil' "$work/inner" || { echo "FAIL a newline in a value forged PATH"; fail=1; }
else
  echo "FAIL awkward names stopped the step:"; cat "$work/out"; fail=1
fi
f_snip="$snip"
# shellcheck disable=SC2317 # f is exported, never called
if (f() { :; }; export -f f; run "$f_snip" HOME="$work" PATH=/usr/bin:/bin); then
  ! grep -q '^BASH_FUNC_' "$work/inner" || { echo "FAIL an exported function reached the body"; fail=1; }
else
  echo "FAIL an exported function stopped the snippet:"; cat "$work/out"; fail=1
fi
# Many variables: all removed, none kept.
big=(HOME="$work" PATH=/usr/bin:/bin)
i=0; while [[ $i -lt 2000 ]]; do big+=("BIG_$i=$i"); i=$((i + 1)); done
if run "$snip" "${big[@]}"; then
  ! grep -q '^BIG_' "$work/inner" || { echo "FAIL a BIG_ variable reached the body"; fail=1; }
else
  echo "FAIL 2000 variables stopped the step:"; cat "$work/out"; fail=1
fi

# 3. Fail closed: a listing the snippet cannot trust stops the step.
refuses() {  # refuses <label> <lister body>
  printf '#!/bin/sh\n%s\n' "$2" > "$work/lister"; chmod +x "$work/lister"
  local s="${snip//\/usr\/bin\/env -0/$work/lister}"
  [[ "$s" != "$snip" ]] || { echo "FAIL premise: no env -0 in the snippet"; fail=1; return; }
  if run "$s" HOME="$work" PATH=/usr/bin:/bin KEEPME=k || [[ -e "$work/ran" ]]; then
    echo "FAIL the step ran when the listing $1"; fail=1
  fi
}
refuses "failed" 'exit 1'
refuses "was empty" 'exit 0'
refuses "has no PATH" 'printf "HOME=/h\000"'
refuses "holds an empty name" '/usr/bin/env -0; printf "=C:=C:\\\\x\000"'
refuses "holds an entry with no =" '/usr/bin/env -0; printf "NOEQ\000"'
refuses "printed the marker, then failed" '/usr/bin/env -0; printf "CI_HELPERS_ENV_END\000"; exit 1'
refuses "printed the marker, then more" '/usr/bin/env -0; printf "CI_HELPERS_ENV_END\000LATE=1\000"'
refuses "was cut off without a NUL" '/usr/bin/env -0; printf "TAIL=1"'

[[ "$fail" == 0 ]] && echo "keep_env_snippet_test: ok"
exit "$fail"
