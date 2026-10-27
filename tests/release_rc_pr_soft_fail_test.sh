#!/usr/bin/env bash
# release-rc-pr.yml's github-script under node with a mocked API: a known
# permission 403 fails the job by default and only warns with soft_fail.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$ROOT_DIR/.github/workflows/release-rc-pr.yml" > "$work/script.js" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(wf["jobs"]["open_pr"]["steps"][0]["with"]["script"])
PY

cat > "$work/run.js" <<'JS'
const fs = require('fs');
const body = fs.readFileSync(process.argv[2], 'utf8');
const calls = [];
const core = {
  info: m => calls.push(['info', m]),
  warning: m => calls.push(['warning', m]),
  setFailed: m => calls.push(['setFailed', m]),
};
const err = Object.assign(new Error('Resource not accessible by integration'), { status: 403 });
const github = { rest: { pulls: {
  list: async () => ({ data: [] }),
  create: async () => { throw err; },
} } };
const context = { repo: { owner: 'o', repo: 'r' }, payload: { repository: { default_branch: 'main' } } };
(async () => {
  await new (Object.getPrototypeOf(async function () {}).constructor)('github', 'context', 'core', body)(github, context, core);
  console.log(calls.map(c => c[0]).join(' '));
})().catch(e => { console.log('threw ' + e.message); });
JS

run() { HEAD_BRANCH=release/1.2.3 BASE_BRANCH=main SOFT_FAIL="$1" node "$work/run.js" "$work/script.js"; }

fail=0
for v in false ""; do
  out="$(run "$v")"
  [[ "$out" == *setFailed* && "$out" != *warning* ]] || { echo "FAIL: SOFT_FAIL='$v' gave: $out"; fail=1; }
done
out="$(run true)"
[[ "$out" == *warning* && "$out" != *setFailed* ]] || { echo "FAIL: SOFT_FAIL=true gave: $out"; fail=1; }

(( fail == 0 )) && echo "release_rc_pr_soft_fail: 403 fails by default, warns with soft_fail"
exit "$fail"
