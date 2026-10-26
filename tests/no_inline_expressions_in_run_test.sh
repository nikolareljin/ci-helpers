#!/usr/bin/env bash
# SCRIPT: no_inline_expressions_in_run_test.sh
# DESCRIPTION: Run scripts take inputs through env, never as ${{ }} spliced
#              into the script, where an input such as `x; curl ...` would
#              run as code. The listed workflows carry no ${{ }} in any run
#              script. Every other workflow and composite action carries no
#              ${{ inputs.* }} in one, except a *_command input, which is code
#              by design. Files in not_yet still splice text inputs; each
#              must leave the list once it is fixed.
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
# Composite actions that still splice text inputs (E119 M4). A file here
# must still have a splice, so a fixed file cannot stay listed.
not_yet = {
    ".github/actions/pimcore-bundle-check/action.yml",
    ".github/actions/wp-plugin-check/action.yml",
}
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
    spliced = False
    for job, steps in run_steps(f):
        for s in steps:
            run = s.get("run", "")
            where = f"{f}: {job}: {s.get('name', '?')}"
            if f in strict and "${{" in run:
                bad.append(where)
            for name in (n for e in expression.findall(run)
                         for n in re.findall(r"\binputs\.(\w+)", e)):
                if f not in strict and not name.endswith("_command"):
                    spliced = True
                    if f not in not_yet:
                        bad.append(f"{where}: inputs.{name}")
    if f in not_yet and not spliced:
        bad.append(f"{f}: no text input spliced any more; remove it from not_yet")
for b in bad:
    print(f"FAIL inline expression in run: {b}")
sys.exit(1 if bad else 0)
PY
echo "ok: no inline expressions in run scripts"
