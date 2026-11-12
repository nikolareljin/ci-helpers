#!/usr/bin/env bash
# SCRIPT: lib_isolate.sh
# DESCRIPTION: Move the library checkout out of the workspace before any
#              caller step can touch it. The workflow step starts it with
#              `/usr/bin/env -i PATH=/usr/bin:/bin ... /bin/bash --noprofile
#              --norc`, so nothing a caller left in GITHUB_ENV or GITHUB_PATH
#              reaches it, and every tool here is called by absolute path.
#              Checks the checkout is at job.workflow_sha (the one git call,
#              with no hooks, no fsmonitor and no user or system config),
#              copies scripts/ and the pins files to a fresh directory under
#              RUNNER_TEMP, refuses anything that is not a regular file or a
#              directory, records a sha256 over the listing and the content,
#              makes files and directories read-only, and removes the
#              checkout. Later steps copy the copy to a fresh directory, hash
#              that, and run only from it (see docs/SECURITY.md).
#              This is defence in depth: the control is that a step holding
#              a secret or a write token runs in a job with no caller step.
# USAGE: /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" WF_SHA=<40 hex> \
#          RUNNER_TEMP=... GITHUB_OUTPUT=... /bin/bash --noprofile --norc \
#          .ci-helpers-scripts/scripts/lib_isolate.sh [<dir> --keep]
#        Run from the workspace root, in the step right after the checkout.
#        <dir> is the checkout (default .ci-helpers-scripts). --keep leaves
#        it in place, for a checkout that also holds a composite action the
#        job uses next (`uses:` only reads the workspace).
# ENVIRONMENT:
#   WF_SHA         job.workflow_sha (required).
#   RUNNER_TEMP    Parent of the copy (required).
#   GITHUB_OUTPUT  Receives lib=<copy>, hash=<64 hex> and pins=<sha256 of
#                  toolchain-pins.env> when set.
# EXIT: 0 on success, 1 on any refusal.
# ----------------------------------------------------
set -euo pipefail

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null LC_ALL=C

fail() { echo "::error::$*"; exit 1; }

src=".ci-helpers-scripts"
keep=0
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    .ci-helpers-[a-z]*) src="$arg" ;;
    *) fail "lib_isolate.sh: unknown argument '$arg'" ;;
  esac
done
[[ "$src" =~ ^\.ci-helpers-[a-z]+$ ]] || fail "lib_isolate.sh: '$src' is not a library checkout"

[[ "${WF_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail "job.workflow_sha is '${WF_SHA:-}', not a commit SHA."
[[ -n "${RUNNER_TEMP:-}" ]] || fail "RUNNER_TEMP is not set."
[[ -d "$src" && ! -L "$src" ]] || fail "$src is missing or a symlink."

git=""
for g in /usr/bin/git /mingw64/bin/git; do
  if [[ -x "$g" ]]; then git="$g"; break; fi
done
[[ -n "$git" ]] || fail "no git at /usr/bin/git or /mingw64/bin/git."
got="$("$git" -c core.fsmonitor= -c core.hooksPath=/dev/null -C "$src" rev-parse HEAD)"
[[ "$got" == "$WF_SHA" ]] || fail "checked out $got, expected $WF_SHA."

tmp_root="$RUNNER_TEMP"
if [[ -x /usr/bin/cygpath ]]; then
  tmp_root="$(/usr/bin/cygpath -u "$RUNNER_TEMP")"
fi
lib="$(/usr/bin/mktemp -d "${tmp_root}/ci-helpers-lib.XXXXXX")"
/bin/cp -RP "$src/scripts" "$lib/scripts"
for f in toolchain-pins.env scanner-pins.env; do
  if [[ -f "$src/$f" && ! -L "$src/$f" ]]; then
    /bin/cp "$src/$f" "$lib/$f"
  fi
done
if [[ "$keep" == 0 ]]; then
  /bin/rm -rf -- "${PWD:?}/$src"
fi

# Only regular files and directories: the hash reads file content, so a
# link, fifo or device would run or read something it never covered.
if [[ -n "$(cd "$lib" && /usr/bin/find . ! -type f ! -type d -print)" ]]; then
  fail "the library copy holds something other than files and directories; refusing it."
fi

# The same listing and hash every later step computes inline: each
# directory by path, then each file by content and path.
if [[ -x /usr/bin/sha256sum ]]; then h=(/usr/bin/sha256sum); else h=(/usr/bin/shasum -a 256); fi
hash="$(cd "$lib" && { /usr/bin/find . -type d -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/printf 'd %s\n'; /usr/bin/find . -type f -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 "${h[@]}"; } | "${h[@]}" | /usr/bin/cut -d' ' -f1)"
[[ "$hash" =~ ^[0-9a-f]{64}$ ]] || fail "could not hash the library copy."

# The toolchain pins alone, for a cache key that changes with them.
pins=""
if [[ -f "$lib/toolchain-pins.env" ]]; then
  pins="$("${h[@]}" < "$lib/toolchain-pins.env" | /usr/bin/cut -d' ' -f1)"
fi

# Files and directories read-only. The job's last step makes them writable
# again, so a self-hosted runner can clear its _temp.
/usr/bin/find "$lib" -exec /bin/chmod a-w {} +

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "lib=$lib"
    echo "hash=$hash"
    echo "pins=$pins"
  } >> "$GITHUB_OUTPUT"
fi
echo "ci-helpers scripts at $WF_SHA copied to $lib, sha256 $hash"
