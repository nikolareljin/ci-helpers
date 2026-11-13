#!/usr/bin/env bash
# SCRIPT: install-publication-hooks.sh
# DESCRIPTION: Install mandatory outbound hooks for every Git clone in a CI job.
# USAGE: scripts/install-publication-hooks.sh --ci
# PARAMETERS:
#   --ci  Require a CI runner, external RUNNER_TEMP, GITHUB_ENV and GITHUB_PATH.
# EXIT_CODES:
#   0 Installed; 1 refused; 2 usage error. No diagnostics are published.
# EXAMPLE: bash scripts/install-publication-hooks.sh --ci
# ----------------------------------------------------
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
[[ "${1:-}" == --ci && $# -eq 1 ]] || exit 2
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/security_notice.sh"
fail() { security_notice Security; exit 1; }
[[ -n "${CI:-}" && -n "${RUNNER_TEMP:-}" && -n "${GITHUB_ENV:-}" && -n "${GITHUB_PATH:-}" ]] || fail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
py="$(security_python)" || fail
umask 077
log="$(mktemp "${RUNNER_TEMP}/security-install.XXXXXX")" || fail
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -f -- "$log"; fi' EXIT
stage="$("$py" -I -c '
import os, pathlib, shutil, subprocess, sys, tempfile
root, runner = (str(pathlib.Path(p).resolve()) for p in sys.argv[1:])
if "\n" in runner or "\r" in runner: sys.exit(1)
env = {k: v for k,v in os.environ.items() if not k.startswith("GIT_")}
p = subprocess.run(["git", "-C", runner, "rev-parse", "--is-inside-work-tree"], capture_output=True, env=env)
if p.returncode == 0 and p.stdout.strip() == b"true": sys.exit(1)
stage = pathlib.Path(tempfile.mkdtemp(prefix="publication-hooks-", dir=runner))
shutil.copytree(root + "/lib", stage / "lib")
shutil.copy2(root + "/helpers.sh", stage / "helpers.sh")
(stage / "scripts").mkdir()
for name in ("publication-hook.sh", "check_scan_output.sh", "check_scan_output.py", "check_sensitive.sh", "check_publication.sh", "guard_gh.py", "security_notice.sh"):
    shutil.copy2(root + "/scripts/" + name, stage / "scripts" / name)
(stage / "hooks").mkdir()
for hook in ("pre-push", "pre-commit", "commit-msg"):
    path = stage / "hooks" / hook
    script = (stage / "scripts/publication-hook.sh").as_posix().replace("\x27", "\x27\\\x27\x27")
    scratch = stage.as_posix().replace("\x27", "\x27\\\x27\x27")
    path.write_bytes(("#!/usr/bin/env bash\nexport TMPDIR=\x27" + scratch + "\x27\nexec bash \x27" + script + "\x27 " + hook + " \"$@\"\n").encode("utf-8"))
    path.chmod(0o700)
sys.stdout.buffer.write((stage.as_posix() + "\n").encode("utf-8"))
' "$root" "$RUNNER_TEMP" 2>"$log")" || fail
bin="${GITLEAKS_BIN:-}"
if [[ -z "$bin" ]]; then
  # Pinned installation is explicit here; no caller code controls its rules.
  export SCRIPT_HELPERS_DIR="$stage"
  if ! bin="$(
    exec 2>"$log"
    # shellcheck source=/dev/null
    source "$stage/helpers.sh"
    shlib_import logging foxguard gitleaks
    gitleaks_bin >/dev/null 2>&1 || gitleaks_install >&2
    gitleaks_bin
  )"; then fail; fi
fi
[[ -x "$bin" ]] || fail
real_gh="$(command -v gh)" || fail
if ! "$py" -I -c '
import pathlib, shlex, sys
stage, real, credential, interpreter = sys.argv[1:]
stage, real, credential, interpreter = (pathlib.Path(p).as_posix() for p in (stage, real, credential, interpreter))
folder = pathlib.Path(stage) / "bin"
folder.mkdir()
path = folder / "gh"
path.write_bytes(("#!/usr/bin/env bash\nexport TMPDIR=" + shlex.quote(stage) + "\nexport GITLEAKS_BIN=" + shlex.quote(credential) + "\nexec " + shlex.quote(interpreter) + " -I " + shlex.quote(stage + "/scripts/guard_gh.py") + " " + shlex.quote(real) + " \"$@\"\n").encode("utf-8"))
path.chmod(0o700)
' "$stage" "$real_gh" "$bin" "$py" >"$log" 2>&1; then fail; fi
printf '%s/bin\n' "$stage" >> "$GITHUB_PATH" || fail
count="${GIT_CONFIG_COUNT:-0}"
[[ "$count" =~ ^[0-9]+$ ]] || fail
{
  printf 'GIT_CONFIG_COUNT=%s\n' "$((count + 1))"
  printf 'GIT_CONFIG_KEY_%s=core.hooksPath\n' "$count"
  printf 'GIT_CONFIG_VALUE_%s=%s/hooks\n' "$count" "$stage"
  printf 'GITLEAKS_BIN=%s\n' "$bin"
} >> "$GITHUB_ENV" || fail
