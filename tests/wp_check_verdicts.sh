#!/usr/bin/env bash
# Runs real Plugin Check through the vendored ci_wp_plugin_check.sh on two
# fixtures: a clean plugin must exit 0 with a bare success report, and a plugin
# with an error must exit 4. Report tests with hand-written files missed that a
# clean plugin exited 5. Needs docker.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

for fixture in wp-check-clean wp-check-error; do
  COMPOSE_PROJECT_NAME="${fixture//-/}" bash "$root/vendor/script-helpers/scripts/ci_wp_plugin_check.sh" \
    --compose-file "$root/tests/fixtures/wp-check-stack/compose.yml" \
    --plugin-slug pc-fixture/pc-fixture.php \
    --plugin-src "$root/tests/fixtures/$fixture" \
    --plugin-src-env WP_CHECK_PLUGIN_SRC \
    --out-dir "$work/$fixture" \
    --fail-on-findings true >"$work/$fixture.log" 2>&1
  rc=$?
  report="$(cat -- "$work/$fixture/plugin-check.json" 2>/dev/null)"

  case "$fixture:$rc:$report" in
    wp-check-clean:0:Success:*) echo "clean plugin: exit 0, report: $report" ;;
    wp-check-error:4:*'"type":"ERROR"'*) echo "plugin with an error: exit 4" ;;
    *)
      echo "::error::$fixture: unexpected exit $rc; report: $report" >&2
      tail -n 20 "$work/$fixture.log" >&2
      failures=$((failures + 1))
      ;;
  esac
done

exit $((failures > 0))
