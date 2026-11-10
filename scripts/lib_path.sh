# shellcheck shell=bash
# SCRIPT: lib_path.sh
# DESCRIPTION: Sourced by a library step, after the copy's hash check and
#              before it runs a script from the copy. Gives the script the
#              step's PATH back (toolchains live there) behind a fresh
#              directory of links to the system copies of the tools that
#              carry tokens, keys or downloads, so a GITHUB_PATH entry a
#              caller step added cannot shadow them.
# USAGE: . "$run_lib/scripts/lib_path.sh" [secret]
#        secret: for a step that holds a token, password or licence
#        (github_release.sh, docker_login.sh, unity_test.sh). PATH is then
#        the links, /usr/bin and /bin only; the step's PATH is dropped.
# ENVIRONMENT:
#   run_lib    The checked copy (required); the links go in $run_lib/.trusted-bin.
#   STEP_PATH  The step's PATH as the runner set it (required).
# NOTES: On a Windows runner (Git Bash) PATH is the step's PATH unchanged.
#        A tool with no copy in /usr/bin or /bin (gh on macOS, for one)
#        still resolves through STEP_PATH. So does every other tool,
#        python3, node, php and the rest, because a toolchain step put the
#        right version there.
# ----------------------------------------------------

[[ -n "${run_lib:-}" && -d "$run_lib" ]] || { echo "::error::lib_path.sh: no run_lib."; exit 1; }
[[ -n "${STEP_PATH:-}" ]] || { echo "::error::lib_path.sh: no STEP_PATH."; exit 1; }
# Git Bash on Windows: ln -s copies a file there, and the outer shell is
# found on PATH anyway (docs/SECURITY.md); keep the step's PATH as it is.
if [[ -x /usr/bin/cygpath ]]; then
  if [[ "${1:-}" == secret ]]; then export PATH="/usr/bin:/bin:/mingw64/bin"; else export PATH="$STEP_PATH"; fi
  return 0
fi
lib_path_bin="$run_lib/.trusted-bin"
/bin/mkdir "$lib_path_bin"
for lib_path_tool in git gh curl wget tar gzip xz unzip zip sha256sum shasum \
    gpg openssl ssh scp docker cosign; do
  for lib_path_dir in /usr/bin /bin; do
    if [[ -x "$lib_path_dir/$lib_path_tool" && ! -d "$lib_path_dir/$lib_path_tool" ]]; then
      /bin/ln -s "$lib_path_dir/$lib_path_tool" "$lib_path_bin/$lib_path_tool"
      break
    fi
  done
done
/bin/chmod a-w "$lib_path_bin"
if [[ "${1:-}" == secret ]]; then
  export PATH="$lib_path_bin:/usr/bin:/bin"
else
  export PATH="$lib_path_bin:$STEP_PATH"
fi
unset lib_path_bin lib_path_tool lib_path_dir
