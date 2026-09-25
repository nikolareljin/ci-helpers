#!/usr/bin/env bash
# SCRIPT: ci_wp_build.sh
# DESCRIPTION: Build a WordPress plugin into a deployable tree and zip, in CI or locally.
# USAGE: scripts/ci_wp_build.sh [options]
# PARAMETERS:
#   --workdir <path>              Plugin source directory (default: .).
#   --slug <name>                 Plugin directory name in the package (default: the workdir's name).
#   --version <version>           Version for the zip name (default: read from the plugin header).
#   --out-dir <path>              Where the tree and zip are written (default: build).
#   --composer-command <command>  Production dependency install. Empty skips it
#                                 (default: composer install --no-dev --optimize-autoloader --prefer-dist).
#   --asset-command <command>     Front-end build, run when package.json exists. Empty skips it
#                                 (default: npm ci && npm run build).
#   --exclude-from <path>         File of rsync-style excludes (default: .distignore when present).
#   --php-image <image>           Run the composer step in this image instead of on the host.
#                                 The image must have bash: an alpine variant fails with
#                                 exit 127 and "bash: executable file not found".
#   --node-image <image>          Run the asset step in this image instead of on the host.
#                                 Same bash requirement.
#   --docker-user <user>          User for those images, as uid:gid (default: the invoking user).
#   --zip <true|false>            Also produce <out-dir>/<slug>-<version>.zip (default: true).
#   -h, --help                    Show this help message.
# ----------------------------------------------------
#
# What ships is not what is in the repository. A plugin needs its production
# dependencies vendored, its front-end assets built, and everything that exists
# only to develop it left out: node_modules, tests, CI configuration, the
# dotfiles git needs. Doing that by hand per plugin is how two of them end up
# shipping different things.
#
# Excludes come from .distignore when the plugin has one, which is the
# convention WordPress tooling already uses, so a plugin does not learn a new
# file for this. Without one a default list is applied and named in the log,
# because a silent exclusion is worse than a wrong one.
#
# --php-image and --node-image make a build reproducible on a laptop without
# the toolchains installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { show_help "${BASH_SOURCE[0]}"; }

workdir="."
slug=""
version=""
out_dir="build"
composer_command="composer install --no-dev --optimize-autoloader --prefer-dist"
asset_command="npm ci && npm run build"
exclude_from=""
php_image=""
node_image=""
docker_user="$(id -u):$(id -g)"
make_zip="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) workdir="$2"; shift 2 ;;
    --slug) slug="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --composer-command) composer_command="$2"; shift 2 ;;
    --asset-command) asset_command="$2"; shift 2 ;;
    --exclude-from) exclude_from="$2"; shift 2 ;;
    --php-image) php_image="$2"; shift 2 ;;
    --node-image) node_image="$2"; shift 2 ;;
    --docker-user) docker_user="$2"; shift 2 ;;
    --zip) make_zip="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

[[ -d "$workdir" ]] || { log_error "--workdir does not exist: ${workdir}"; exit 2; }
abs_workdir="$(cd "$workdir" && pwd -P)"
[[ -n "$slug" ]] || slug="$(basename "$abs_workdir")"

# The slug is the directory name inside the package, and it is appended to
# --out-dir to form a path that is `rm -rf`'d. A slash walks out of the
# validated --out-dir: `--slug ../keepme` removed a sibling directory. A
# leading dash is read as an option by zip and rsync rather than as a name.
#
# Only those are refused. An earlier version demanded letters, digits, dot,
# dash and underscore, which refused a checkout in a directory called "My
# Plugin" -- correct input, rejected. A check that fires on correct input gets
# switched off.
case "$slug" in
  "" | "." | ".." | */* | -* | .* )
    log_error "--slug must be a plain directory name, with no '/' and no leading '-' or '.': ${slug}"
    exit 2 ;;
esac

# The version is appended to the zip path, which is `rm -f`'d, and reaches it
# from a plugin header this script did not write. A slash is the danger; a
# space is not, and headers do carry things like "1.0 beta".
case "$version" in
  "." | ".." | */* )
    log_error "--version must not contain a path: ${version}"
    exit 2 ;;
esac

case "$make_zip" in
  true|false ) : ;;
  * ) log_error "--zip must be true or false: ${make_zip}"; exit 2 ;;
esac

# rsync and zip are how the package is produced. Missing, they fail after the
# dependency install has already run, with "command not found" and no clue
# which step wanted them.
missing=()
command -v rsync >/dev/null 2>&1 || missing+=("rsync")
[[ "$make_zip" == "true" ]] && { command -v zip >/dev/null 2>&1 || missing+=("zip"); }
if [[ ${#missing[@]} -gt 0 ]]; then
  log_error "Missing on PATH: ${missing[*]}"
  exit 2
fi

# The staging tree is removed and rebuilt, and out_dir is caller input. Refuse
# anything that would take the source with it.
abs_out="$(mkdir -p "$out_dir" && cd "$out_dir" && pwd -P)"
if [[ "$abs_out" == "/" || "$abs_out" == "$abs_workdir" || "$abs_workdir" == "$abs_out"/* ]]; then
  log_error "--out-dir must not be the plugin directory or contain it: ${abs_out}"
  exit 2
fi

# ---------------------------------------------------------------------------
# Version. The plugin header is the source of truth: it is what WordPress
# reads, and a zip named from anything else can disagree with what installs.
# ---------------------------------------------------------------------------
read_header_version() {
  # The plugin file is the one carrying "Plugin Name:". Taking the first
  # Version: header in the directory instead picks up a bundled library's
  # header and names the zip after it -- a shim reading 0.1.0 beat the
  # plugin's 3.4.1 when this looked at *.php in glob order.
  local f candidates=()
  [[ -f "${abs_workdir}/${slug}.php" ]] && candidates=("${abs_workdir}/${slug}.php")
  for f in "${abs_workdir}"/*.php; do
    [[ -f "$f" ]] || continue
    candidates+=("$f")
  done

  local pass
  for pass in plugin any; do
    for f in ${candidates[@]+"${candidates[@]}"}; do
      if [[ "$pass" == "plugin" ]]; then
        grep -qiE '^[[:space:]]*\*?[[:space:]]*Plugin Name:' "$f" 2>/dev/null || continue
      fi
      local v
      v="$(grep -m1 -iE '^[[:space:]]*\*?[[:space:]]*Version:[[:space:]]*' "$f" 2>/dev/null \
           | sed -E 's/.*[Vv]ersion:[[:space:]]*//; s/[[:space:]]*$//')"
      if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
    done
  done
  return 1
}

if [[ -z "$version" ]]; then
  if ! version="$(read_header_version)"; then
    log_error "No Version: header found in ${abs_workdir}; pass --version."
    exit 2
  fi
  # A header is plugin input, so it gets the check --version got above.
  case "$version" in
    "." | ".." | */* )
      log_error "The Version: header is not usable in a file name: ${version}"
      exit 2 ;;
  esac
fi
log_info "Building ${slug} ${version}"

# ---------------------------------------------------------------------------
# Toolchain steps, optionally in a container so a laptop needs neither.
# ---------------------------------------------------------------------------
run_step() {   # <label> <image-or-empty> <command>
  local label="$1" image="$2" command="$3"
  [[ -n "$command" ]] || { log_info "${label}: skipped (no command)"; return 0; }

  local rc=0
  if [[ -z "$image" ]]; then
    log_info "${label} (host): ${command}"
    ( cd "$abs_workdir" && eval "$command" ) || rc=$?
    step_failed "$label" "$command" "$rc"
    return 0
  fi

  # As the invoking user, or the build leaves root-owned files in the caller's
  # repository that they cannot delete without Docker. HOME with it: a uid the
  # image does not know has no home, and composer and npm both want one.
  local user_args=()
  [[ -n "$docker_user" ]] && user_args=(-u "$docker_user" -e HOME=/tmp)
  log_info "${label} (${image}): ${command}"
  # bash -c, not -lc: a login shell sources /etc/profile and replaces PATH.
  docker run --rm -t \
    ${user_args[@]+"${user_args[@]}"} \
    -v "${abs_workdir}":/work -w /work \
    "$image" bash -c "$command" || rc=$?
  step_failed "$label" "$command" "$rc"
}

# Without this, `set -e` ends the run on the INFO line that announced the
# command and nothing says which step failed: composer exiting 3 left a log
# whose last line was "Production dependencies (host): composer install ...".
# The command's own exit code is kept, because a caller reading 3 rather than 1
# can tell a failed install from a failed build.
step_failed() {   # <label> <command> <rc>
  [[ "$3" -eq 0 ]] && return 0
  log_error "${1} failed (exit ${3}): ${2}"
  exit "$3"
}

run_step "Production dependencies" "$php_image" "$composer_command"

if [[ -f "${abs_workdir}/package.json" ]]; then
  run_step "Front-end assets" "$node_image" "$asset_command"
else
  log_info "Front-end assets: skipped (no package.json)"
fi

# ---------------------------------------------------------------------------
# Stage the tree that ships.
# ---------------------------------------------------------------------------
if [[ -z "$exclude_from" && -f "${abs_workdir}/.distignore" ]]; then
  exclude_from="${abs_workdir}/.distignore"
fi

# A floor that applies whichever list is in use. A .distignore that forgets
# .git ships the whole repository history inside the plugin, and the exclude
# file itself is not part of the plugin. Neither omission is ever intentional,
# so this is not overriding the plugin's list, it is closing an oversight.
excludes=(--exclude=".git" --exclude=".distignore")
if [[ -n "$exclude_from" ]]; then
  [[ -f "$exclude_from" ]] || { log_error "--exclude-from not found: ${exclude_from}"; exit 2; }
  log_info "Excludes from ${exclude_from}, plus .git and .distignore"
  excludes+=(--exclude-from="$exclude_from")
else
  # Named rather than silent: a reader can see what was dropped and override
  # it with a .distignore. node_modules is here because the built assets are
  # what ships, not the tree they were built from.
  default_excludes=(".git" ".github" ".gitignore" ".gitattributes" ".editorconfig"
                    ".distignore" "node_modules" "tests" "test" ".phpunit.cache"
                    ".phpunit.result.cache" "phpunit.xml" "phpunit.xml.dist"
                    "phpcs.xml" "phpcs.xml.dist" "composer.lock" "package-lock.json"
                    "build")
  log_info "No .distignore; excluding: ${default_excludes[*]}"
  for e in "${default_excludes[@]}"; do excludes+=(--exclude="$e"); done
fi

stage="${abs_out}/${slug}"
rm -rf "$stage"
mkdir -p "$stage"

# An out-dir inside the plugin is copied into the package by the rsync below:
# --out-dir dist produced dist/<slug>/dist. The default list happens to carry
# "build", so the default out-dir hides it; any other name, or a .distignore,
# does not. Exclude it by its path relative to the source, whatever it is.
if [[ "$abs_out" == "$abs_workdir"/* ]]; then
  excludes+=(--exclude="/${abs_out#"$abs_workdir"/}")
fi

# A trailing slash on the source copies its contents, not the directory.
rsync -a ${excludes[@]+"${excludes[@]}"} "${abs_workdir}/" "${stage}/"

# ---------------------------------------------------------------------------
# Symlinks. The staged tree and the zip do not represent them the same way, so
# left alone the two artifacts are different plugins:
#
#   - `zip` without -y follows a symlink and stores the target's CONTENT. A
#     link to a file outside the plugin therefore put that file's content in
#     the distributed archive, while the directory held only a link.
#   - A broken link is skipped by zip entirely, with no message. The file is
#     in the staged tree and simply absent from the archive.
#
# So: refuse a link that leaves the plugin or points at nothing, and resolve
# the rest into real files. WordPress's own installer extracts with ZipArchive,
# which writes a symlink entry as a regular file holding the target path, so a
# package containing symlinks is broken there whatever this script intends.
# ---------------------------------------------------------------------------
stage_phys="$(cd "$stage" && pwd -P)"

# readlink -f is GNU; macOS only grew it in 12.3, and this library still
# supports bash 3.2. dirname + `pwd -P` is portable and resolves `..` in the
# path by actually walking it.
resolve_existing() {   # <path> -> physical path, or non-zero when it does not exist
  local p="$1" d b
  if [[ -d "$p" ]]; then ( cd "$p" 2>/dev/null && pwd -P ); return; fi
  [[ -e "$p" ]] || return 1
  d="$(dirname "$p")"; b="$(basename "$p")"
  ( cd "$d" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$b" )
}

unsafe_links=""
have_links=0
# NUL-delimited, because a newline in a file name makes `find` print what
# looks like two paths. readlink then failed on the fragment and `set -e` ended
# the build with exit 1 and no message at all -- and a link that should have
# been refused was never examined.
while IFS= read -r -d '' link; do
  [[ -n "$link" ]] || continue
  have_links=1
  rel="${link#"$stage_phys"/}"
  if ! target="$(readlink "$link")"; then
    unsafe_links="${unsafe_links}
  ${rel} (could not be read)"
    continue
  fi
  case "$target" in
    /*) candidate="$target" ;;
    *)  candidate="$(dirname "$link")/${target}" ;;
  esac
  if ! resolved="$(resolve_existing "$candidate")" || [[ -z "$resolved" ]]; then
    unsafe_links="${unsafe_links}
  ${rel} -> ${target} (points at nothing; zip drops it silently)"
    continue
  fi
  case "$resolved" in
    "$stage_phys"/*) : ;;
    *) unsafe_links="${unsafe_links}
  ${rel} -> ${target} (outside the plugin; its content would be copied into the zip)" ;;
  esac
done < <(find "$stage_phys" -type l -print0)

if [[ -n "$unsafe_links" ]]; then
  log_error "Symlinks that cannot be packaged:${unsafe_links}"
  exit 1
fi

# Every remaining link is internal and resolves, so a second pass with -L turns
# them into regular files. Skipped entirely when there were none, which is the
# usual case, so this costs nothing for a plugin without symlinks.
if [[ "$have_links" -eq 1 ]]; then
  log_info "Resolving internal symlinks into regular files"
  rm -rf "$stage"
  mkdir -p "$stage"
  rsync -aL ${excludes[@]+"${excludes[@]}"} "${abs_workdir}/" "${stage}/"
fi

files="$(find "$stage" -type f | wc -l | tr -d ' ')"
log_info "Staged ${files} file(s) in ${stage}"

# A bash glob, not `ls`: `! ls "$stage"/*.php` is non-zero both when there is
# no PHP file and when ls itself is unavailable, so on a slim image this
# refused a package whose plugin file was sitting right there. A check that
# fires on correct input gets switched off.
shopt -s nullglob
root_php=("${stage}"/*.php)
shopt -u nullglob
if [[ ${#root_php[@]} -eq 0 ]]; then
  log_error "The staged tree has no PHP file at its root; it would not load as a plugin."
  exit 1
fi

# vendor/ is what makes the package installable without composer, which is what
# a VIP-style deploy needs. Its absence is worth saying out loud rather than
# discovering at deploy time.
if [[ -n "$composer_command" && ! -d "${stage}/vendor" ]]; then
  log_warn "No vendor/ in the staged tree: the package needs composer at its destination."
fi

# ---------------------------------------------------------------------------
# Zip, named from the header version so the archive and what installs agree.
# ---------------------------------------------------------------------------
if [[ "$make_zip" == "true" ]]; then
  zip_path="${abs_out}/${slug}-${version}.zip"
  rm -f "$zip_path"
  ( cd "$abs_out" && zip -qr "$zip_path" "$slug" )
  # du prints "4.0K<tab>path". Trimming it here rather than piping through cut
  # keeps one more tool off the dependency list, and a missing one would not
  # have failed the build: inside a command substitution it printed an empty
  # size and carried on.
  zip_size="$(du -h "$zip_path")"
  log_info "Wrote ${zip_path} (${zip_size%%[[:space:]]*})"
fi

log_info "Build complete: ${stage}"
