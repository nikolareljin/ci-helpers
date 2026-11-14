#!/usr/bin/env bash
# SCRIPT: bash32_compat_test.sh
# DESCRIPTION: scripts/check_bash32.py refuses each bash 4 or 5 feature it
#              lists and accepts this repository; scripts/artifact_parts.sh
#              splits and reassembles a tree under the bash in BASH32.
# USAGE: bash tests/bash32_compat_test.sh                      # gate and scripts
#        BASH32=/bin/bash BASH32_REQUIRE=1 bash tests/bash32_compat_test.sh --scripts-only
#        --scripts-only skips the gate cases, which need PyYAML (the macOS
#        leg runs only the scripts; the Linux leg runs both).
# ENVIRONMENT:
#   BASH32          The bash that runs the scripts (default: bash).
#   BASH32_REQUIRE  1: fail unless BASH32 is bash 3.x (set on the macOS leg,
#                   so a runner image with a newer /bin/bash cannot pass it).
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gate="$root/scripts/check_bash32.py"
sh32="${BASH32:-bash}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

gate_cases=1
case "${1:-}" in
  --scripts-only) gate_cases=0 ;;
  "") ;;
  *) echo "usage: $0 [--scripts-only]" >&2; exit 2 ;;
esac

ver="$("$sh32" -c 'echo "${BASH_VERSINFO[0]}"')"
if [[ "${BASH32_REQUIRE:-0}" == 1 && "$ver" != 3 ]]; then
  echo "FAIL BASH32 ($sh32) is bash $ver, not 3.x"; fail=1
fi

expect() {  # expect <name> <rc> <script text>
  local rc=0
  rm -rf "$work/r"; mkdir -p "$work/r/scripts"
  printf '%s\n' "$3" > "$work/r/scripts/x.sh"
  python3 "$gate" --root "$work/r" > "$work/out" 2>&1 || rc=$?
  [[ "$rc" == "$2" ]] || { echo "FAIL $1: exit $rc, expected $2"; cat "$work/out"; fail=1; }
}
if [[ "$gate_cases" == 1 ]]; then
# shellcheck disable=SC2016
{
expect "globstar"            1 'shopt -s globstar nullglob'
expect "mapfile"             1 'mapfile -t a < f'
expect "readarray"           1 'x; readarray -d "" a < f'
expect "declare -A"          1 'declare -A m=()'
expect "local -A"            1 'f() { local -A m; }'
expect "local -n"            1 'f() { local -n r="$1"; }'
expect "lowercase"           1 'y="${x,,}"'
expect "uppercase"           1 'y="${x^^}"'
expect "array element case"  1 'y="${a[0],}"'
expect "@Q"                  1 'echo "${x@Q}"'
expect "negative subscript"  1 'echo "${a[-1]}"'
expect "[[ -v ]]"            1 '[[ -v x ]] && echo y'
expect ";;&"                 1 'case x in a) :;;& b) :;; esac'
expect "coproc"              1 'coproc cat'
expect "wait -n"             1 'wait -n'
expect "lastpipe"            1 'shopt -s lastpipe'
expect "BASHPID"             1 'echo "$BASHPID"'
expect "EPOCHSECONDS"        1 'echo "$EPOCHSECONDS"'
expect "|&"                  1 'make |& tee log'
expect "&>>"                 1 'make &>> log'
expect "printf %()T"         1 "printf '%(%F)T' -1"
expect "a comment"           0 '# mapfile, globstar and ${x,,} are bash 4'
expect "bash 3.2 forms"      0 'while IFS= read -r -d "" f; do a+=("$f"); done < <(find . -print0); y="$(printf %s "$x" | tr A-Z a-z)"; echo "${#a[@]} ${a[0]:-} ${x:-a,b} ${x//,/ }"'
}

# A workflow run: block is read too.
rm -rf "$work/r"; mkdir -p "$work/r/.github/workflows"
cat > "$work/r/.github/workflows/w.yml" <<'YML'
on: push
jobs:
  b:
    runs-on: macos-latest
    steps:
      - run: |
          echo ok
          n="${NAME,,}"
YML
rc=0; python3 "$gate" --root "$work/r" > "$work/out" 2>&1 || rc=$?
if [[ "$rc" != 1 ]] || ! grep -q 'w.yml: job b step 1 (run), run: line 2: case modification' "$work/out"; then
  echo "FAIL a workflow run: block with \${x,,}: exit $rc"; cat "$work/out"; fail=1
fi

# A pwsh or python step is not shell code.
cat > "$work/r/.github/workflows/w.yml" <<'YML'
on: push
jobs:
  b:
    runs-on: windows-latest
    defaults:
      run:
        shell: pwsh
    steps:
      - run: |
          $x = "${NAME,,}"
      - shell: python
        run: print("|&")
YML
python3 "$gate" --root "$work/r" > "$work/out" 2>&1 || { echo "FAIL a pwsh or python step was read as shell:"; cat "$work/out"; fail=1; }

python3 "$gate" --root "$root" > "$work/out" 2>&1 || { echo "FAIL the repository:"; cat "$work/out"; fail=1; }
fi

# Every script parses under BASH32.
for f in "$root"/scripts/*.sh "$root"/.github/actions/*/*.sh; do
  [[ -f "$f" ]] || continue
  "$sh32" -n "$f" 2> "$work/out" || { echo "FAIL $sh32 -n $f:"; cat "$work/out"; fail=1; }
done

# artifact_parts.sh split then verify, under BASH32: a file above 60 MiB in
# a subdirectory is cut into parts and put back, a hidden file kept.
t="$work/tree"; mkdir -p "$t/sub/deep"
printf 'small' > "$t/.hidden"
printf 'x' > "$t/sub/a.txt"
dd if=/dev/zero of="$t/sub/deep/big.bin" bs=1048576 count=61 2>/dev/null
printf 'tail' >> "$t/sub/deep/big.bin"
if command -v sha256sum >/dev/null; then sha=(sha256sum); else sha=(shasum -a 256); fi
want="$("${sha[@]}" < "$t/sub/deep/big.bin" | cut -d' ' -f1)"
if "$sh32" "$root/scripts/artifact_parts.sh" split "$t" > "$work/out" 2>&1; then
  [[ ! -e "$t/sub/deep/big.bin" && -f "$t/sub/deep/big.bin.split-000" && -f "$t/sub/deep/big.bin.split-001" ]] \
    || { echo "FAIL split: big.bin not cut into two parts"; ls -R "$t"; fail=1; }
  [[ -f "$t/.hidden" && -f "$t/sub/a.txt" ]] || { echo "FAIL split: a small file went missing"; fail=1; }
  (cd "$t" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do "${sha[@]}" "$f"; done) > "$work/m.sha256"
  if "$sh32" "$root/scripts/artifact_parts.sh" verify "$t" "$work/m.sha256" '\.hidden|sub/a\.txt|sub/deep/big\.bin' > "$work/out" 2>&1; then
    got="$("${sha[@]}" < "$t/sub/deep/big.bin" | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || { echo "FAIL verify: reassembled big.bin differs"; fail=1; }
    [[ ! -e "$t/sub/deep/big.bin.split-000" ]] || { echo "FAIL verify: parts left behind"; fail=1; }
  else
    echo "FAIL verify under $sh32:"; cat "$work/out"; fail=1
  fi
else
  echo "FAIL split under $sh32:"; cat "$work/out"; fail=1
fi

[[ "$fail" == 0 ]] && echo "ok: no bash 4 or 5 feature; artifact_parts.sh runs under bash $ver"
exit "$fail"
