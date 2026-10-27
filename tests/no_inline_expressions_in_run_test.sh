#!/usr/bin/env bash
# SCRIPT: no_inline_expressions_in_run_test.sh
# DESCRIPTION: Run scripts take inputs through env, never as ${{ }} spliced
#              into the script, where an input such as `x; curl ...` would
#              run as code. The listed workflows carry no ${{ }} in any run
#              script or shell. Every other workflow and composite action
#              names inputs in no run script or shell in any form (inputs.x,
#              inputs['x'], toJSON(inputs)), except inputs.<name>_command,
#              which is code by design.
# USAGE: bash tests/no_inline_expressions_in_run_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import glob, re, sys, yaml
root = sys.argv[1]
strict = [
    ".github/workflows/ppa-deb.yml",
    ".github/workflows/deb-build.yml",
    ".github/workflows/rpm-build.yml",
    ".github/workflows/homebrew-package.yml",
    ".github/workflows/wp-plugin-check.yml",
    ".github/workflows/rust-release.yml",
    ".github/workflows/pimcore-bundle-check.yml",
    ".github/workflows/docker-scan.yml",
    ".github/workflows/flutter-release.yml",
    ".github/workflows/fpc-release.yml",
]
# Each ${{ ... }} in full, so a format('{0}', inputs.x) is read whole.
expression = re.compile(r"\$\{\{(.*?)\}\}", re.S)

def run_steps(f):
    d = yaml.safe_load(open(f"{root}/{f}"))
    if "runs" in d:
        yield "action", d["runs"].get("steps", [])
    for job, j in (d.get("jobs") or {}).items():
        yield job, j.get("steps", [])

files = sorted(f for pattern in (".github/workflows/*.y*ml",
                                 ".github/actions/*/action.y*ml")
               for f in glob.glob(pattern, root_dir=root))
assert set(strict) <= set(files), set(strict) - set(files)
bad = []
for f in files:
    for job, steps in run_steps(f):
        for s in steps:
            # shell: is spliced the same way: `shell: bash -c "${{ ... }} {0}"`.
            run = f'{s.get("run", "")}\n{s.get("shell", "")}'
            where = f"{f}: {job}: {s.get('name', '?')}"
            if f in strict and "${{" in run:
                bad.append(where)
            # Every reference to inputs, in any form: .name, ['name'], or the
            # whole object. Only inputs.<name>_command is allowed.
            for ref in (r for e in expression.findall(run)
                        for r in re.findall(r"\binputs\b(?:\.\w+|\s*\[[^\]]*\])?", e)):
                if f not in strict and not re.fullmatch(r"inputs\.\w+_command", ref):
                    bad.append(f"{where}: {ref}")
for b in bad:
    print(f"FAIL inline expression in run: {b}")
sys.exit(1 if bad else 0)
PY
echo "ok: no inline expressions in run scripts"
