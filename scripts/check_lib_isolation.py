#!/usr/bin/env python3
"""The library's scripts run only from a verified copy outside the workspace.

    python3 scripts/check_lib_isolation.py              # this repository
    python3 scripts/check_lib_isolation.py --root DIR   # a tree elsewhere

A library checkout is an `actions/checkout` step whose `path:` starts with
`.ci-helpers-`. It sits in the workspace, where a caller's build or test
step, or a container that mounts the workspace, can rewrite a script before
a later library step runs it, or plant `core.fsmonitor` in its `.git`.

Every workflow and composite action under .github (.yml or .yaml) is read
with PyYAML. In every job, and in a composite action:

  checkout   a run: that names a file under a library checkout
             (`.ci-helpers-*/scripts/`, `.ci-helpers-*/vendor/`) or under
             `$RUNNER_TEMP/ci-helpers-*` fails, except the isolate step,
             and so does an env: or with: value naming a file in a library
             checkout other than under .github/ (a pins file read later, a
             `hashFiles()` cache key);
  isolate    the isolate step runs exactly `/bin/bash --noprofile --norc
             <checkout>/scripts/lib_isolate.sh [<checkout>] [--keep]`
             and is the step right after that checkout, or right after a
             step named `Verify ...` that follows it. It carries the
             checkout's `if:`;
  copy       a run: that reads `$LIB` must take LIB and LIB_HASH from the
             env: of the step, as `${{ steps.<id>.outputs.lib }}` and
             `${{ steps.<id>.outputs.hash }}` of an isolate step earlier in
             the same job; read `$LIB` only to copy it to a fresh
             `$run_lib`; compare that copy's hash to LIB_HASH before it
             uses a file there; run a shell script as `/bin/bash` and a
             Python one as `/usr/bin/python3 -I`;
  blanks     the isolate, library and release steps set BLANKS below to ""
             in their env:, which wins over GITHUB_ENV before any shell
             starts;
  env        the isolate step and every step reading `$LIB` use
             `shell: /bin/sh -e {0}` where runs-on names a Linux or macOS
             runner (a bare name is looked up on PATH, GITHUB_PATH entries
             first), `sh` where runs-on is an expression, `bash` on Windows
             and run `set +xv`, refuse an exported BASH_FUNC_*, then
             `exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME"
             LANG=C.UTF-8 NAME="$NAME"... /bin/bash --noprofile --norc`:
             an allowlist of named variables, never BASH_ENV, SHELLOPTS,
             BASHOPTS, LD_*, GIT_*, CI_HELPERS_* and the like. Library code
             runs only in the heredoc body that bash gets with -c;
  release    a job with an isolate step ends with an always() step that
             makes the read-only copy writable again;
  git        git on a library checkout runs only in the step right after
             that checkout, before any other step can write to its .git;
             git on `$LIB` fails;
  path       a library step sources `$run_lib/scripts/lib_path.sh` before
             its first library script and never sets PATH itself;
             a step whose env: holds a secret (SECRET_VALUE, SECRET_NAME)
             sources it as `lib_path.sh secret`;
  verify     git on a library checkout runs only as `/usr/bin/env -i
             PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
             "$git" -c core.fsmonitor= -c core.hooksPath=/dev/null -C <dir>
             rev-parse HEAD`, with git set by GIT_DEF, under the absolute
             bash, with OUTER_BLANKS and no empty GIT_* variable;
  action     a `uses: ./.ci-helpers-*/...` step sets OUTER_BLANKS, and only
             the checkout's verify, isolate and library steps, other such
             actions and SHA-pinned actions run between the checkout and it;
             every composite step sets OUTER_BLANKS, names its shell by
             absolute path, calls no bare `bash "..."`, and PowerShell there
             runs with -NoProfile;
  mount      a `docker`/`podman` run: that mounts (`-v`, `--volume`,
             `--mount`) `$LIB`, `ci-helpers-lib` or a library checkout
             fails, and so does a job `container.volumes` entry naming one.

Exit 0 with nothing found, 1 with a finding, 2 on a usage or parse error.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("::error::PyYAML is required (pip install pyyaml)")
    sys.exit(2)

CHECKOUT_DIR = re.compile(r"^\.ci-helpers-[a-z]+$")
EXEC_FROM_CHECKOUT = re.compile(
    r"\.ci-helpers-[a-z]+/(?:scripts|vendor)/|RUNNER_TEMP\}?/ci-helpers-[a-z]+")
ISOLATE = re.compile(
    r"^/bin/bash --noprofile --norc (\.ci-helpers-[a-z]+)/scripts/lib_isolate\.sh"
    r"(?: (\.ci-helpers-[a-z]+))?(?: --keep)?$")
GUARD = ('case "$(/usr/bin/env)" in *BASH_FUNC_*) echo "::error::an exported shell function '
         'is in the environment; nothing runs."; exit 1 ;; esac')
EXEC_PREFIX = 'exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" LANG=C.UTF-8 '
PAIR = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="\$([A-Za-z_][A-Za-z0-9_]*)"\s+')
# Names that change how bash, the loader, Python, Perl or git behave, and
# the ones the envelope sets itself. Never passed through.
FORBIDDEN = re.compile(r"^(?:BASH_ENV|ENV|SHELLOPTS|BASHOPTS|PS4|IFS|CDPATH|GLOBIGNORE|"
                       r"BASH_FUNC.*|LD_.*|DYLD_.*|PYTHON.*|PERL.*|GIT_.*|CI_HELPERS_.*|"
                       r"PATH|HOME|LANG|LC_.*)$")
# Set to "" in the env: of every isolate, library and release step. A
# step's env: wins over GITHUB_ENV, so these never reach the outer shell
# (sh, or bash on Windows) that starts before the env -i envelope.
BLANKS = ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PS4", "LD_PRELOAD", "LD_LIBRARY_PATH",
          "LD_AUDIT", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
          "PYTHONPATH", "PYTHONSTARTUP", "PERL5LIB", "PERL5OPT", "RUBYOPT", "NODE_OPTIONS",
          "GIT_DIR", "GIT_CONFIG_PARAMETERS", "GIT_EXEC_PATH")
# The same, less the git variables, for a step that runs git or a library
# action outside the env -i envelope: an empty GIT_DIR stops git outright.
OUTER_BLANKS = tuple(k for k in BLANKS if not k.startswith("GIT_"))
BASH_C = "/bin/bash --noprofile --norc -euo pipefail -c \"$(/bin/cat <<'CI_HELPERS_RUN'"
CHECKOUT_FILE = re.compile(r"\.ci-helpers-[a-z]+/(?!\.github/)[A-Za-z0-9_]")
LIB_USE = re.compile(r"\$\{?LIB\}?/")
HASH_CHECK = re.compile(r'\[\[ "\$now" == "\$LIB_HASH" \]\]')
GIT_LINE = re.compile(r"(?:^|[;&|(\s])git(?:\s|$)")
MOUNT = re.compile(r"(?:\s-v\s|--volume|--mount)")
MOUNT_TARGET = re.compile(r"\$\{?LIB\b|ci-helpers-lib|\.ci-helpers-[a-z]+")
COPY_LINE = '/bin/cp -RP "$LIB/." "$run_lib/"'
RUN_USE = re.compile(r'\$\{?run_lib\}?/(?:scripts/|[a-z-]+pins\.env)')
STEP_REF = re.compile(r"^\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.(lib|hash)\s*\}\}$")
# The runner looks a bare shell name up on PATH with the GITHUB_PATH
# entries first, so `sh` or `bash` can be a caller's file. An absolute path
# is used as is. A Windows runner keeps `bash`: Git Bash lives under
# "C:\Program Files", and the runner splits `shell:` at the first space.
SH = "/bin/sh -e {0}"
BASH = "/bin/bash --noprofile --norc -e -o pipefail {0}"
LIB_PATH_LINE = '. "$run_lib/scripts/lib_path.sh"'
LIB_PATH_SECRET = LIB_PATH_LINE + " secret"
# A step whose env: carries one of these runs its script with PATH limited
# to the trusted links, /usr/bin and /bin (lib_path.sh secret).
SECRET_VALUE = re.compile(r"secrets\.|github\.token")
SECRET_NAME = re.compile(r"TOKEN|PASSWORD|SECRET|LICEN[CS]E|SERIAL")
GIT_DEF = 'git=/usr/bin/git; [[ -x "$git" ]] || git=/mingw64/bin/git'
GIT_ANY = re.compile(r'(?:^|[;&|(\s"`])(?:/usr/bin/|/mingw64/bin/)?(?:git|\$\{?git\}?)(?=["\s]|$)')
HARD_GIT = re.compile(r'/usr/bin/env -i PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "\$git" -c core\.fsmonitor= '
                      r'-c core\.hooksPath=/dev/null -C (\.ci-helpers-[a-z]+) rev-parse HEAD\)')
# Actions callers run on Windows runners too: their steps keep `bash` and
# pwsh, found on PATH, since no absolute path works on every runner.
CROSS_PLATFORM = {"gitleaks-scan", "gitleaks-diff", "foxguard-scan", "foxguard-diff",
                  "data-safety-scan", "publication-guard", "check-release-tag",
                  "semver-compare", "windows-sign"}
PWSH = "pwsh -NoProfile -NonInteractive -Command \". '{0}'\""
LOCAL_ACTION = re.compile(r"^\./(\.ci-helpers-[a-z]+)/")
PINNED = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")


def outer_blanks(name: str, env: dict) -> list[str]:
    errs = []
    missing = [k for k in OUTER_BLANKS if env.get(k) != ""]
    if missing:
        errs.append(f"{name}: env: must set {', '.join(missing)} to \"\"")
    empty_git = [k for k in BLANKS if k.startswith("GIT_") and env.get(k) == ""]
    if empty_git:
        errs.append(f"{name}: env: sets {', '.join(empty_git)} to \"\", which stops git; leave them out")
    return errs


def is_checkout(step: dict) -> str | None:
    uses = str(step.get("uses") or "")
    if not uses.startswith("actions/checkout@"):
        return None
    path = str((step.get("with") or {}).get("path") or "")
    return path if CHECKOUT_DIR.match(path) else None


def logical_lines(run: str) -> list[str]:
    return run.replace("\\\n", " ").splitlines()


def envelope(run: str) -> tuple[list[str], str, str | None, list[str]]:
    """Split a step's run: into the env -i allowlist, the command after it
    and, for a library step, the body bash runs. Returns problems found."""
    errs: list[str] = []
    lines = [ln.strip() for ln in run.strip().split("\n")]
    if lines[:2] != ["set +xv", GUARD]:
        errs.append("does not open with `set +xv` and the BASH_FUNC_ guard")
        return [], "", None, errs
    rest = lines[2:]
    head = ""
    while rest:
        ln = rest.pop(0)
        if ln.endswith("\\"):
            head += ln[:-1]
            continue
        head += ln
        break
    if not head.startswith(EXEC_PREFIX):
        errs.append(f"does not start through `{EXEC_PREFIX.strip()}`")
        return [], "", None, errs
    tail = head[len(EXEC_PREFIX):]
    names = []
    while True:
        m = PAIR.match(tail)
        if not m:
            break
        n, ref = m.group(1), m.group(2)
        if n == "STEP_PATH" and ref == "PATH":
            names.append(n)
        elif n != ref:
            errs.append(f"passes {n} from ${ref}; each name passes its own value")
        elif FORBIDDEN.match(n):
            errs.append(f"passes {n} into the clean environment")
        else:
            names.append(n)
        tail = tail[m.end():]
    tail = tail.strip()
    body = None
    if tail == BASH_C:
        if "CI_HELPERS_RUN" not in rest:
            errs.append("has no CI_HELPERS_RUN terminator")
        else:
            end = rest.index("CI_HELPERS_RUN")
            body = "\n".join(rest[:end])
            if [x for x in rest[end + 1:] if x] != [')"']:
                errs.append("runs something after the clean bash")
    elif rest and any(rest):
        errs.append("runs something after the exec")
    return names, tail, body, errs


def check_steps(where: str, steps: list, container: dict | None, windows: bool = False,
                dynamic: bool = False) -> list[str]:
    # A runs-on with an expression can be a Windows runner, where /bin/sh is
    # not a path the runner can start: those jobs keep the bare names.
    env_shell = "bash" if windows else ("sh" if dynamic else SH)
    git_shell = "bash" if (windows or dynamic) else BASH
    errors: list[str] = []
    checkouts: dict[int, str] = {}
    isolates: dict[str, int] = {}
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        d = is_checkout(step)
        if d:
            checkouts[i] = d

    def checkout_before(i: int) -> tuple[int, str] | None:
        if i - 1 in checkouts:
            return i - 1, checkouts[i - 1]
        prev = steps[i - 1] if i >= 1 else None
        if (i - 2 in checkouts and isinstance(prev, dict)
                and str(prev.get("name") or "").startswith("Verify")):
            return i - 2, checkouts[i - 2]
        return None

    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        name = f"{where} step {i + 1} ({step.get('name') or step.get('uses') or 'run'})"
        run = str(step.get("run") or "")
        env = step.get("env") or {}
        if not isinstance(env, dict):
            env = {}
        uses = str(step.get("uses") or "")
        if re.search(r"\.ci-helpers-[a-z]+/(?:scripts|vendor)/", uses):
            errors.append(f"{name}: uses a library file from the workspace checkout")

        shell = str(step.get("shell") or "")
        env_names, tail, body, env_errs = envelope(run) if "lib_isolate.sh" in run or "LIB" in env else ([], "", None, [])
        iso = ISOLATE.match(tail) if "lib_isolate.sh" in run else None
        if "lib_isolate.sh" in run and not iso:
            errors.append(f"{name}: lib_isolate.sh runs only inside the env -i envelope, right after its checkout")
            for e in env_errs:
                errors.append(f"{name}: {e}")
        if iso:
            for e in env_errs:
                errors.append(f"{name}: {e}")
            if shell != env_shell:
                errors.append(f"{name}: shell must be `{env_shell}` here (`{SH}` where runs-on names a Linux or macOS runner)")
            missing = [k for k in BLANKS if env.get(k) != ""]
            if missing:
                errors.append(f"{name}: env: must set {', '.join(missing)} to \"\"")
            if sorted(env_names) != ["GITHUB_OUTPUT", "RUNNER_TEMP", "WF_SHA"]:
                errors.append(f"{name}: the isolate step passes exactly WF_SHA, RUNNER_TEMP and GITHUB_OUTPUT")
            src = iso.group(2) or ".ci-helpers-scripts"
            near = checkout_before(i)
            if not near or near[1] != src or iso.group(1) != src:
                errors.append(f"{name}: lib_isolate.sh must run from {src} in the step right after its checkout")
            elif str(steps[near[0]].get("if") or "") != str(step.get("if") or ""):
                errors.append(f"{name}: the isolate step must carry its checkout's if:")
            if step.get("id"):
                isolates[str(step["id"])] = i
            else:
                errors.append(f"{name}: the isolate step needs an id: for LIB and LIB_HASH")
            continue

        if EXEC_FROM_CHECKOUT.search(run):
            errors.append(f"{name}: runs a library file from the workspace checkout, not the verified copy")
        for key in ("env", "with"):
            vals = step.get(key) if isinstance(step.get(key), dict) else {}
            for k, v in vals.items():
                if CHECKOUT_FILE.search(str(v)):
                    errors.append(f"{name}: {key}.{k} reads a file from the workspace checkout, not the verified copy")

        hardened = False
        for line in logical_lines(run):
            if not (GIT_LINE.search(line) or GIT_ANY.search(line)):
                continue
            if re.search(r"\$\{?LIB\b", line):
                errors.append(f"{name}: runs git on the library copy")
            m = re.search(r"(?:-C\s+|--git-dir[= ]|--work-tree[= ]|cd\s+)\"?(\.ci-helpers-[a-z]+)", line)
            if m:
                near = i - 1 in checkouts and checkouts[i - 1] == m.group(1)
                if not near:
                    errors.append(f"{name}: runs git on {m.group(1)} later than the step right after its checkout")
                if not HARD_GIT.search(line) or HARD_GIT.search(line).group(1) != m.group(1):
                    errors.append(f"{name}: git on {m.group(1)} runs as `/usr/bin/env -i PATH=/usr/bin:/bin "
                                  f"GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "
                                  f"\"$git\" -c core.fsmonitor= -c core.hooksPath=/dev/null -C {m.group(1)} rev-parse HEAD`")
                hardened = True
        if hardened:
            lines = [ln.strip() for ln in logical_lines(run)]
            if GIT_DEF not in lines or any(re.match(r"(?:export\s+)?git=", ln) and ln != GIT_DEF for ln in lines):
                errors.append(f"{name}: sets git only as `{GIT_DEF}`")
            if any(GIT_LINE.search(ln) for ln in lines):
                errors.append(f"{name}: runs git through PATH in the step that checks a library checkout")
            if shell != git_shell:
                errors.append(f"{name}: shell must be `{git_shell}` here (`{BASH}` where runs-on names a Linux or macOS runner)")
            errors += outer_blanks(name, env)

        # An action from a library checkout runs from the workspace: nothing
        # but the checkout's own checks, library steps and pinned actions
        # may run between the checkout and the action.
        la = LOCAL_ACTION.match(uses)
        if la:
            errors += outer_blanks(name, env)
            src = [k for k in checkouts if k < i and checkouts[k] == la.group(1)]
            if not src:
                errors.append(f"{name}: no checkout of {la.group(1)} earlier in this job")
            else:
                for k in range(max(src) + 1, i):
                    st = steps[k]
                    if not isinstance(st, dict):
                        continue
                    su = str(st.get("uses") or "")
                    sr = str(st.get("run") or "")
                    ok = (LOCAL_ACTION.match(su) or PINNED.match(su)
                          or ("lib_isolate.sh" in sr) or "LIB" in (st.get("env") or {})
                          or (str(st.get("name") or "").startswith("Verify") and GIT_DEF in sr))
                    if not ok:
                        errors.append(f"{name}: step {k + 1} ({st.get('name') or su or 'run'}) runs between the "
                                      f"checkout of {la.group(1)} and this action; check it out again right before")

        for line in logical_lines(run):
            if re.search(r"\b(?:docker|podman)\b", line) and MOUNT.search(line) and MOUNT_TARGET.search(line):
                errors.append(f"{name}: mounts the library into a container")

        if LIB_USE.search(run) or "LIB" in env:
            for e in env_errs:
                errors.append(f"{name}: {e}")
            if shell != env_shell:
                errors.append(f"{name}: shell must be `{env_shell}` here (`{SH}` where runs-on names a Linux or macOS runner)")
            missing = [k for k in BLANKS if env.get(k) != ""]
            if missing:
                errors.append(f"{name}: env: must set {', '.join(missing)} to \"\"")
            if not {"LIB", "LIB_HASH"} <= set(env_names):
                errors.append(f"{name}: LIB and LIB_HASH must pass into the clean environment")
            if body is None:
                errors.append(f"{name}: library code runs only in the clean bash's body")
                body = ""
            ids = set()
            for key, want in (("LIB", "lib"), ("LIB_HASH", "hash")):
                m = STEP_REF.match(str(env.get(key) or "").strip())
                if not m or m.group(2) != want:
                    errors.append(f"{name}: {key} must be ${{{{ steps.<isolate id>.outputs.{want} }}}} in the step env")
                else:
                    ids.add(m.group(1))
            if len(ids) == 1:
                sid = ids.pop()
                if sid not in isolates or isolates[sid] >= i:
                    errors.append(f"{name}: steps.{sid} is not an isolate step earlier in this job")
            elif ids:
                errors.append(f"{name}: LIB and LIB_HASH come from different steps")
            for line in logical_lines(body):
                if LIB_USE.search(line) and line.strip() != COPY_LINE:
                    errors.append(f"{name}: reads $LIB directly; copy it to a fresh run_lib and check that")
            first = RUN_USE.search(body)
            chk = HASH_CHECK.search(body)
            cp = body.find(COPY_LINE)
            if cp < 0 or not chk or chk.start() < cp:
                errors.append(f"{name}: does not copy $LIB to run_lib and compare its hash to LIB_HASH")
            elif first and chk.start() > first.start():
                errors.append(f"{name}: uses run_lib before comparing its hash to LIB_HASH")
            blines = [LIB_PATH_LINE if ln.strip() == LIB_PATH_SECRET else ln.strip() for ln in logical_lines(body)]
            secret = any(SECRET_VALUE.search(str(v)) or SECRET_NAME.search(k) for k, v in env.items())
            if secret and LIB_PATH_LINE in blines and LIB_PATH_SECRET not in [ln.strip() for ln in logical_lines(body)]:
                errors.append(f"{name}: holds a secret; use `{LIB_PATH_SECRET}`, which drops the step's PATH")
            if any(re.search(r"(?:^|[\s;])(?:export\s+)?PATH=", ln) for ln in blines):
                errors.append(f"{name}: sets PATH itself; `{LIB_PATH_LINE}` gives the step's PATH back")
            uses_script = [n for n, ln in enumerate(blines)
                           if '"$run_lib/scripts/' in ln and ln != LIB_PATH_LINE]
            if uses_script:
                if LIB_PATH_LINE not in blines:
                    errors.append(f"{name}: runs a library script without `{LIB_PATH_LINE}` first")
                if LIB_PATH_LINE in blines and blines.index(LIB_PATH_LINE) > uses_script[0]:
                    errors.append(f"{name}: `{LIB_PATH_LINE}` comes after the first library script")
            for line in logical_lines(body):
                if line.strip() in (LIB_PATH_LINE, LIB_PATH_SECRET):
                    continue
                if re.search(r'"\$run_lib/scripts/[^"]*\.sh"', line) and not re.search(r'(?:^|\s)/bin/bash "\$run_lib/scripts/', line):
                    errors.append(f"{name}: a library shell script runs as /bin/bash, not through PATH")
                if re.search(r'"\$run_lib/scripts/[^"]*\.py"', line) and "/usr/bin/python3 -I " not in line:
                    errors.append(f"{name}: a library Python script runs as /usr/bin/python3 -I")

    # The copies are read-only; a job that made one releases it in an
    # always() step, so a self-hosted runner can clear its _temp.
    for sid in isolates:
        ok = False
        for st in steps[isolates[sid] + 1:]:
            if not isinstance(st, dict) or "always()" not in str(st.get("if") or ""):
                continue
            env = st.get("env") if isinstance(st.get("env"), dict) else {}
            names = [k for k, v in env.items() if str(v).replace(" ", "") == "${{steps.%s.outputs.lib}}" % sid]
            text = str(st.get("run") or "")
            if names and "/bin/chmod -R u+w" in text and any(f'"${n}"' in text for n in names):
                ok = True
                if str(st.get("shell") or "") != env_shell:
                    errors.append(f"{where}: the release step's shell must be `{env_shell}`")
                missing = [k for k in BLANKS if env.get(k) != ""]
                if missing:
                    errors.append(f"{where}: the release step's env: must set {', '.join(missing)} to \"\"")
        if not ok:
            errors.append(f"{where}: no always() step makes steps.{sid}'s copy writable again for the runner's cleanup")

    if isinstance(container, dict):
        for v in container.get("volumes") or []:
            if MOUNT_TARGET.search(str(v)):
                errors.append(f"{where}: container.volumes mounts the library")
    return errors


def check_file(path: Path) -> list[str]:
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        return [f"{path}: cannot parse: {e}"]
    if not isinstance(doc, dict):
        return []
    errors: list[str] = []
    jobs = doc.get("jobs")
    if isinstance(jobs, dict):
        for jid, job in jobs.items():
            if isinstance(job, dict) and isinstance(job.get("steps"), list):
                ro = str(job.get("runs-on") or "")
                errors += check_steps(f"{path}: job {jid}", job["steps"], job.get("container"),
                                      "windows" in ro.lower() and "${{" not in ro, "${{" in ro)
    runs = doc.get("runs")
    if isinstance(runs, dict) and isinstance(runs.get("steps"), list):
        errors += check_steps(f"{path}: composite", runs["steps"], None)
        # Every composite step: an absolute shell, since the runner looks a
        # bare name up on PATH, and the blanks, since the caller's GITHUB_ENV
        # reaches it otherwise.
        for n, st in enumerate(runs["steps"]):
            if not isinstance(st, dict) or "run" not in st:
                continue
            env = st.get("env") if isinstance(st.get("env"), dict) else {}
            sh = str(st.get("shell") or "")
            if path.parent.name in CROSS_PLATFORM:
                if sh not in ("bash", PWSH):
                    errors.append(f"{path}: composite step {n + 1} ({st.get('name') or 'run'}) of an action "
                                  f"that runs on Windows uses `bash` or `{PWSH}`")
            elif not sh.startswith("/"):
                errors.append(f"{path}: composite step {n + 1} ({st.get('name') or 'run'}) runs under `{sh}`, "
                              f"which the runner looks up on PATH; give the shell by absolute path")
            if re.search(r'(?:^|[\s;&|(])bash "', str(st.get("run"))):
                errors.append(f"{path}: composite step {n + 1} ({st.get('name') or 'run'}) runs bash through PATH")
            errors += outer_blanks(f"{path}: composite step {n + 1} ({st.get('name') or 'run'})", env)
            if re.search(r"pwsh|powershell", sh, re.I) and "-NoProfile" not in sh:
                errors.append(f"{path}: composite step {n + 1} ({st.get('name') or 'run'}) runs PowerShell "
                              f"without -NoProfile")
    return errors


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=".", help="repository root (default: .)")
    args = ap.parse_args(argv)
    gh = Path(args.root) / ".github"
    if not gh.is_dir():
        print(f"::error::no .github directory under {args.root}")
        return 2
    files = sorted(p for p in gh.rglob("*") if p.suffix in (".yml", ".yaml") and p.is_file())
    errors: list[str] = []
    for p in files:
        errors += check_file(p)
    for e in errors:
        print(f"::error::{e}")
    if errors:
        print(f"{len(errors)} finding(s): library scripts must run from the verified copy (docs/SECURITY.md).")
        return 1
    print(f"ok: {len(files)} files, every library script runs from a verified copy")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
