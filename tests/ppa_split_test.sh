#!/usr/bin/env bash
# SCRIPT: ppa_split_test.sh
# DESCRIPTION: ppa-deb.yml's build job stages every file the .changes names
#              with a sha256 manifest; the ppa job's verify step accepts that
#              artifact and refuses a changed, added or missing file and a
#              bad .changes name, before any key is imported. dcmd is
#              stubbed.
# USAGE: bash tests/ppa_split_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

step() {  # step <job> <name>
  python3 - "$root/.github/workflows/ppa-deb.yml" "$1" "$2" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = [s for s in d["jobs"][sys.argv[2]]["steps"] if s.get("name") == sys.argv[3]]
assert len(s) == 1, (sys.argv[2], sys.argv[3])
print(s[0]["run"])
PY
}
step build "Stage the source package" > "$work/stage.sh"
step ppa "Verify the source package against the build manifest" > "$work/verify.sh"

mkdir -p "$work/bin" "$work/src" "$work/tmp"
for f in tool_1.0-1.dsc tool_1.0-1.tar.xz tool_1.0-1_source.buildinfo tool_1.0-1_source.changes; do
  echo "$f" > "$work/src/$f"
done
cat > "$work/bin/dcmd" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$1")"
for f in tool_1.0-1.dsc tool_1.0-1.tar.xz tool_1.0-1_source.buildinfo; do echo "$d/$f"; done
echo "$1"
SH
chmod +x "$work/bin/dcmd"

: > "$work/out"
env PATH="$work/bin:$PATH" RUNNER_TEMP="$work/tmp" GITHUB_OUTPUT="$work/out" GITHUB_RUN_ID=1 \
  GITHUB_RUN_ATTEMPT=1 CHANGES="$work/src/tool_1.0-1_source.changes" bash "$work/stage.sh" >/dev/null

out_val() {
  python3 - "$work/out" "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
key = sys.argv[2]
for i, ln in enumerate(lines):
    if ln.startswith(key + "="):
        print(ln[len(key) + 1:]); break
    if ln.startswith(key + "<<"):
        d = ln[len(key) + 2:]; j = lines.index(d, i + 1)
        print("\n".join(lines[i + 1:j])); break
PY
}
manifest="$(out_val manifest)"
changes="$(out_val changes)"

verify() {  # verify <tamper: "", change, add, remove, link> [changes name]
  rm -rf "$work/tmp/ppa-in"; cp -R "$work/tmp/ppa-out" "$work/tmp/ppa-in"
  local in="$work/tmp/ppa-in"
  case "$1" in
    "") ;;
    change) echo evil > "$in/tool_1.0-1.tar.xz" ;;
    add) echo x > "$in/extra.deb" ;;
    remove) rm "$in/tool_1.0-1.dsc" ;;
    link) ln -s /etc/passwd "$in/link" ;;
  esac
  : > "$work/vout"
  env RUNNER_TEMP="$work/tmp" GITHUB_OUTPUT="$work/vout" DIR="$work/tmp/ppa-in" \
    MANIFEST="$manifest" CHANGES_NAME="${2:-$changes}" bash "$work/verify.sh" >/dev/null 2>&1
}

fail=0
[[ "$(grep -c . <<<"$manifest")" == 4 ]] || { echo "FAIL: manifest should list 4 files:"; echo "$manifest"; fail=1; }
[[ "$changes" == tool_1.0-1_source.changes ]] || { echo "FAIL: changes output is '$changes'"; fail=1; }
verify "" || { echo "FAIL: the untouched artifact was refused"; fail=1; }
grep -qx "changes=$work/tmp/ppa-in/tool_1.0-1_source.changes" "$work/vout" || { echo "FAIL: no changes path"; fail=1; }
for tamper in change add remove link; do
  if verify "$tamper"; then echo "FAIL: accepted after: $tamper"; fail=1; fi
done
if verify "" "../x.changes"; then echo "FAIL: accepted a changes name with a path"; fail=1; fi

# A symlink listed by dcmd is refused at staging.
mv "$work/src/tool_1.0-1.tar.xz" "$work/real.tar.xz"
ln -s "$work/real.tar.xz" "$work/src/tool_1.0-1.tar.xz"
if env PATH="$work/bin:$PATH" RUNNER_TEMP="$work/tmp" GITHUB_OUTPUT="$work/out2" GITHUB_RUN_ID=1 \
  GITHUB_RUN_ATTEMPT=1 CHANGES="$work/src/tool_1.0-1_source.changes" bash "$work/stage.sh" >/dev/null 2>&1; then
  echo "FAIL: staged a symlinked file"; fail=1
fi

(( fail == 0 )) && echo "ok: ppa-deb hands the source package over with a manifest the ppa job checks"
exit "$fail"
