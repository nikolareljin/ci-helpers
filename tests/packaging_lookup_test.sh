#!/usr/bin/env bash
# SCRIPT: packaging_lookup_test.sh
# DESCRIPTION: Runs the script-helpers lookup of deb-build, rpm-build and
#              homebrew-package as written, against each layout a caller can
#              have: vendor/script-helpers wins when present (as it did when the
#              workflows made the symlink), else scripts/script-helpers; neither
#              fails; and no layout gets a vendor/ it did not have.
# USAGE: bash tests/packaging_lookup_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
for wf in deb-build rpm-build homebrew-package; do
  python3 - "$root/.github/workflows/${wf}.yml" "$tmp/${wf}.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for j in d["jobs"].values() for s in j.get("steps", []) if s.get("id") == "script_helpers"]
assert len(steps) == 1, f"{sys.argv[1]}: want one step with id script_helpers"
run = steps[0]["run"]
# Only the lookup: the token and submodule lines need a real checkout.
open(sys.argv[2], "w").write("set -euo pipefail\n" + run[run.index('dir=""'):])
PY
  for layout in scripts vendor both empty-submodule neither; do
    t="$tmp/${wf}-${layout}"
    mkdir -p "$t"
    case "$layout" in
      scripts) mkdir -p "$t/scripts/script-helpers" && touch "$t/scripts/script-helpers/helpers.sh"; want="dir=scripts/script-helpers" ;;
      vendor) mkdir -p "$t/vendor/script-helpers" && touch "$t/vendor/script-helpers/helpers.sh"; want="dir=vendor/script-helpers" ;;
      both) mkdir -p "$t/scripts/script-helpers" "$t/vendor/script-helpers" && touch "$t/scripts/script-helpers/helpers.sh" "$t/vendor/script-helpers/helpers.sh"; want="dir=vendor/script-helpers" ;;
      empty-submodule) mkdir -p "$t/scripts/script-helpers"; want="error" ;;
      neither) want="error" ;;
    esac
    had_vendor=no; [[ -e "$t/vendor" ]] && had_vendor=yes
    got="$( (cd "$t" && GITHUB_OUTPUT="$t/.out" bash "$tmp/${wf}.sh" >/dev/null 2>&1 && cat "$t/.out") || echo error)"
    has_vendor=no; [[ -e "$t/vendor" ]] && has_vendor=yes
    if [[ "$got" == "$want" && "$had_vendor" == "$has_vendor" ]]; then
      echo "ok: ${wf} ${layout} -> ${got}"
    else
      echo "FAIL: ${wf} ${layout}: want ${want}, got ${got}; vendor/ before=${had_vendor} after=${has_vendor}"
      fail=1
    fi
  done
done
exit "$fail"
