#!/usr/bin/env bash
# package_publish.sh - Helpers for Debian package builds and PPA publishing.

_pkg_log_info() {
  if declare -F log_info >/dev/null 2>&1; then
    log_info "$*"
  else
    echo "[INFO] $*" >&2
  fi
}

_pkg_log_error() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$*"
  else
    echo "[ERROR] $*" >&2
  fi
}

# Usage: pkg_require_cmds <cmd> [cmd...]
pkg_require_cmds() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      _pkg_log_error "Missing required command: $cmd"
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    return 2
  fi
  return 0
}

# Usage: pkg_run_prebuild <command>
pkg_run_prebuild() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then
    _pkg_log_info "Running prebuild: $cmd"
    bash -lc "$cmd"
  fi
}

# Usage: pkg_set_series <series>
pkg_set_series() {
  local series="${1:-}"
  if [[ -n "$series" ]]; then
    pkg_require_cmds dch || return 2
    dch --distribution "$series" --no-auto-nmu "Automated PPA build"
  fi
}

# Usage: pkg_build_deb_artifacts <repo_dir> <prebuild_cmd> <build_cmd>
pkg_build_deb_artifacts() {
  local repo_dir="$1" prebuild_cmd="$2" build_cmd="$3"
  cd "$repo_dir" || return 1
  pkg_run_prebuild "$prebuild_cmd"
  if [[ -n "$build_cmd" ]]; then
    _pkg_log_info "Running build: $build_cmd"
    bash -lc "$build_cmd"
  else
    pkg_require_cmds dpkg-buildpackage || return 2
    dpkg-buildpackage -us -uc
  fi
}

# Usage: pkg_build_source_package <repo_dir> <prebuild_cmd> <build_cmd> <series> <key_id>
pkg_build_source_package() {
  local repo_dir="$1" prebuild_cmd="$2" build_cmd="$3" series="$4" key_id="$5"
  if [[ -z "$build_cmd" ]] && [[ -z "${PPA_GPG_PASSPHRASE:-}" ]]; then
    _pkg_log_error "PPA_GPG_PASSPHRASE is required for signing"
    return 2
  fi
  pkg_require_cmds debuild gpg || return 2
  cd "$repo_dir" || return 1
  pkg_run_prebuild "$prebuild_cmd"
  pkg_set_series "$series"
  if [[ -n "$build_cmd" ]]; then
    _pkg_log_info "Running build: $build_cmd"
    bash -lc "$build_cmd"
  else
    # The passphrase goes to gpg in a 0600 file rather than on its command
    # line, where every local user can read it from the process list for as
    # long as the build runs. A file also survives a passphrase with spaces,
    # which the sign command's word splitting did not. Removed on every path
    # out, including a failed build under `set -e` and an INT or TERM.
    local pass_file rc=0 sig="" old_int old_term
    pass_file="$(_pkg__pass_file)" || return 1
    printf '%s' "${PPA_GPG_PASSPHRASE}" > "$pass_file" || { rm -f "$pass_file"; return 1; }

    # Any trap the caller had is saved and put back afterwards. The handler
    # removes the file at once and remembers the signal; it is re-delivered
    # once the caller's traps are restored, so the caller still sees it.
    old_int="$(trap -p INT)"; old_term="$(trap -p TERM)"
    trap 'rm -f "$pass_file"; sig=INT' INT
    trap 'rm -f "$pass_file"; sig=TERM' TERM

    if debuild -S -sa -k"$key_id" -p"gpg --batch --pinentry-mode loopback --passphrase-file ${pass_file}"; then
      rc=0
    else
      rc=$?
    fi
    rm -f "$pass_file"

    if [[ -n "$old_int" ]]; then eval "$old_int"; else trap - INT; fi
    if [[ -n "$old_term" ]]; then eval "$old_term"; else trap - TERM; fi

    if [[ -n "$sig" ]]; then
      if [[ "$sig" == INT ]]; then rc=130; else rc=143; fi
      # $$ is this shell only outside a subshell; inside one it would signal
      # the parent, so a subshell gets the conventional status instead.
      if [[ "${BASH_SUBSHELL:-0}" -eq 0 ]]; then
        kill -s "$sig" "$$"
      fi
    fi
    return $rc
  fi
}

# Usage: _pkg__pass_file; create the 0600 passphrase file and print its path.
#
# The path is spliced into the sign command, which is word-split before it is
# run, so it must contain nothing a shell would split or expand. When TMPDIR
# does (a space in a home directory is enough), the file is made in /tmp
# instead.
_pkg__pass_file() {
  local f
  f="$(mktemp 2>/dev/null)" || f=""
  case "$f" in
    ""|*[!A-Za-z0-9/._+-]*)
      [[ -n "$f" ]] && rm -f "$f"
      f="$(mktemp /tmp/pkg-pass.XXXXXX 2>/dev/null)" || f=""
      case "$f" in
        ""|*[!A-Za-z0-9/._+-]*)
          [[ -n "$f" ]] && rm -f "$f"
          _pkg_log_error "Could not create a passphrase file at a path the sign command can use (TMPDIR='${TMPDIR:-}')"
          return 1 ;;
      esac ;;
  esac
  chmod 600 "$f" || { rm -f "$f"; return 1; }
  printf '%s\n' "$f"
}

# Usage: pkg_find_changes_file <repo_dir>
#
# The parent directory is shared: a CI workspace or a packaging directory holds
# every project's builds, so "the first *.changes there" can be another
# package, which is then uploaded. The package's own
# <Source>_<Version>_source.changes, named from debian/changelog, is preferred.
#
# When the source name is known, only that package's files (<Source>_*.changes)
# are considered: a lone .changes belonging to another package is refused, not
# uploaded. Only when debian/changelog cannot be read is a lone *.changes of
# any name taken. More than one candidate is an error rather than a guess.
pkg_find_changes_file() {
  local repo_dir="$1"
  local changes_file src_name="" version pattern='*.changes' count
  if [[ -f "$repo_dir/debian/changelog" ]] && command -v dpkg-parsechangelog >/dev/null 2>&1; then
    src_name="$(dpkg-parsechangelog -l "$repo_dir/debian/changelog" -S Source 2>/dev/null || true)"
    version="$(dpkg-parsechangelog -l "$repo_dir/debian/changelog" -S Version 2>/dev/null || true)"
    # The epoch is not part of a Debian file name.
    version="${version#*:}"
    if [[ -n "$src_name" && -n "$version" && -f "$repo_dir/../${src_name}_${version}_source.changes" ]]; then
      echo "$repo_dir/../${src_name}_${version}_source.changes"
      return 0
    fi
  fi
  # A source name is [a-z0-9.+-], none of which is a find(1) pattern character.
  [[ -n "$src_name" ]] && pattern="${src_name}_*.changes"
  changes_file="$(find "$repo_dir/.." -maxdepth 1 -type f -name "$pattern" 2>/dev/null || true)"
  if [[ -z "$changes_file" ]]; then
    if [[ -n "$src_name" ]] \
       && [[ -n "$(find "$repo_dir/.." -maxdepth 1 -type f -name '*.changes' 2>/dev/null || true)" ]]; then
      _pkg_log_error "No .changes file for source package '$src_name' next to $repo_dir; refusing to take another package's:"
      find "$repo_dir/.." -maxdepth 1 -type f -name '*.changes' >&2 2>/dev/null || true
      return 1
    fi
    _pkg_log_error "No .changes file found."
    return 1
  fi
  count="$(printf '%s\n' "$changes_file" | wc -l | tr -d '[:space:]')"
  if [[ "$count" -ne 1 ]]; then
    if [[ -n "$src_name" ]]; then
      _pkg_log_error "Found $count ${src_name}_*.changes files next to $repo_dir and none is ${src_name}_${version}_source.changes; refusing to pick one:"
    else
      _pkg_log_error "Found $count .changes files next to $repo_dir and none named for this package; refusing to pick one:"
    fi
    printf '%s\n' "$changes_file" >&2
    return 1
  fi
  echo "$changes_file"
}

# Usage: pkg_upload_ppa <ppa_target> <changes_file>
pkg_upload_ppa() {
  local ppa_target="$1" changes_file="$2"
  pkg_require_cmds dput || return 2
  dput "$ppa_target" "$changes_file"
}
