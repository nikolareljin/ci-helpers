#!/usr/bin/env bash
# Version manifests — read and write the project version wherever a project
# happens to keep it.
#
# A phone app routinely states its version in three places at once: `pubspec.yaml`
# for Flutter, `versionName`/`versionCode` in a Gradle build file for the Play
# Store, and a `VERSION` file or `__version__` for a companion host component.
# They drift, and a release ships with two different numbers in it.
#
# Supported kinds:
#
#   pubspec       pubspec.yaml            version: 1.2.3+45
#   gradle        build.gradle[.kts]      versionName "1.2.3" / versionCode 10203
#   version_file  VERSION                 1.2.3
#   package_json  package.json            "version": "1.2.3"
#   pyproject     pyproject.toml          version = "1.2.3"
#
# Exit codes: 2 = bad arguments, 1 = the version could not be read or written.

# Usage: manifest_kind <file>; prints the manifest kind for a path, based on its
# name. Returns 2 when the name is not one this module handles.
manifest_kind() {
  local file="${1:-}"
  [[ -n "$file" ]] || { log_error "manifest_kind: need <file>"; return 2; }
  case "$(basename "$file")" in
    pubspec.yaml)                 printf 'pubspec\n' ;;
    build.gradle|build.gradle.kts) printf 'gradle\n' ;;
    VERSION)                      printf 'version_file\n' ;;
    package.json)                 printf 'package_json\n' ;;
    pyproject.toml)               printf 'pyproject\n' ;;
    *) log_error "manifest_kind: unrecognized manifest '$file'"; return 2 ;;
  esac
}

# Usage: manifest_detect [dir=.]; prints one "<kind>\t<path>" line per version
# manifest found, searching the directory and two levels of subdirectory (an app
# under `mobile/` or `android/` is the common layout). Prints nothing and
# returns 1 when none is found.
manifest_detect() {
  local dir="${1:-.}" found=0 path kind submodules=""
  [[ -d "$dir" ]] || { log_error "manifest_detect: not a directory: $dir"; return 2; }
  # Submodule paths as declared, one per line. Read with sed rather than
  # `git config -f`, so a checkout without git on PATH still gets the guard.
  if [[ -f "$dir/.gitmodules" ]]; then
    submodules="$(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' "$dir/.gitmodules" \
                  | sed -e 's/[[:space:]]*$//' -e 's|/*$||')"
  fi
  while IFS= read -r path; do
    # Build outputs and vendored trees are not this project's manifests.
    case "$path" in
      */node_modules/*|*/build/*|*/.dart_tool/*|*/vendor/*|*/.git/*) continue ;;
    esac
    # Nor is anything inside another repository: a vendored submodule such as
    # scripts/script-helpers carries its own VERSION, and a sync that rewrites
    # it corrupts the shared library for every project that pins it.
    _manifest__in_nested_repo "$dir" "$path" "$submodules" && continue
    kind="$(manifest_kind "$path" 2>/dev/null)" || continue
    printf '%s\t%s\n' "$kind" "$path"
    found=1
  done < <(find "$dir" -maxdepth 3 \
             \( -name pubspec.yaml -o -name 'build.gradle' -o -name 'build.gradle.kts' \
                -o -name VERSION -o -name package.json -o -name pyproject.toml \) \
             -type f 2>/dev/null | sort)
  [[ "$found" -eq 1 ]]
}

# Usage: _manifest__in_nested_repo <dir> <path> <submodule-paths>; true when
# <path>, found under <dir>, sits below a directory that is its own repository
# (it has a `.git` file or directory) or below a path <dir>/.gitmodules lists.
# <dir> itself is not considered: it is normally the project's own checkout.
_manifest__in_nested_repo() {
  local dir="$1" path="$2" submodules="$3" rel sub d
  rel="${path#"$dir"}"; rel="${rel#/}"
  if [[ -n "$submodules" ]]; then
    while IFS= read -r sub; do
      [[ -n "$sub" ]] || continue
      [[ "$rel" == "$sub"/* ]] && return 0
    done <<< "$submodules"
  fi
  # Walk the directories between <dir> and the file, one component at a time.
  # Parameter expansion rather than word splitting, so a `*` in a directory
  # name is not globbed.
  d="${dir%/}"
  while [[ "$rel" == */* ]]; do
    d="$d/${rel%%/*}"
    rel="${rel#*/}"
    [[ -e "$d/.git" ]] && return 0
  done
  return 1
}

# Usage: _manifest__sed_escape <text>; prints <text> escaped for use in the
# replacement side of a `s|...|...|` expression: `\`, `&` and the `|`
# delimiter are otherwise read as sed syntax, not as characters.
_manifest__sed_escape() {
  printf '%s\n' "$1" | sed 's/[\\&|]/\\&/g'
}

# Usage: manifest_read_version <file>; prints the version recorded in a manifest.
# For a pubspec the build number after `+` is dropped — that is a build counter,
# not part of the version. Returns 1 when no version is present.
manifest_read_version() {
  local file="${1:-}" kind version=""
  [[ -n "$file" ]] || { log_error "manifest_read_version: need <file>"; return 2; }
  [[ -f "$file" ]] || { log_error "manifest_read_version: not found: $file"; return 2; }
  kind="$(manifest_kind "$file")" || return 2

  case "$kind" in
    pubspec)
      version="$(sed -n 's/^version:[[:space:]]*\([0-9][^[:space:]]*\).*/\1/p' "$file" | head -n1)"
      version="${version%%+*}"
      ;;
    gradle)
      version="$(sed -n 's/.*versionName[[:space:]]*[=(]*[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n1)"
      ;;
    version_file)
      version="$(head -n1 "$file" | tr -d '[:space:]')"
      ;;
    package_json)
      version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n1)"
      ;;
    pyproject)
      version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n1)"
      ;;
  esac

  [[ -n "$version" ]] || { log_error "manifest_read_version: no version found in $file"; return 1; }
  printf '%s\n' "$version"
}

# Usage: manifest_android_version_code <version> [offset=0]; prints the integer
# Play Store versionCode for a semver string, as MAJOR*10000 + MINOR*100 + PATCH
# plus an optional offset.
#
# The Play Store requires a strictly increasing integer, and this mapping keeps
# it monotonic for any version whose minor and patch stay below 100. Returns 2
# on a non-semver input rather than emitting a wrong number — a wrong
# versionCode is rejected by the Play Store only after the upload.
manifest_android_version_code() {
  local version="${1:-}" offset="${2:-0}" major minor patch
  [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] \
    || { log_error "manifest_android_version_code: not a semver version: '${version:-<empty>}'"; return 2; }
  major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
  if [[ "$minor" -ge 100 || "$patch" -ge 100 ]]; then
    log_warn "manifest_android_version_code: minor/patch >= 100 in $version — the code is no longer monotonic"
  fi
  printf '%d\n' $(( major * 10000 + minor * 100 + patch + offset ))
}

# Usage: manifest_write_version <file> <version> [--build <n>]; set the version
# in a manifest, in place. For gradle, versionCode is recomputed from the version
# unless --build overrides it; for a pubspec, --build sets the `+n` suffix and
# an existing suffix is preserved when it is not given.
#
# A pubspec version may carry its own build number (`1.4.0+46`); it is written
# as given and replaces the existing suffix rather than being stacked onto it.
# An explicit --build still wins over it. Other kinds write the version string
# unchanged, as they always have.
#
# --build must be an integer for gradle (versionCode is one) and a semver build
# identifier (`[0-9A-Za-z-]` separated by dots) for a pubspec; anything else
# returns 2 instead of being written into the file.
#
# Writes via a temp file and moves it into place, so an interrupted write cannot
# leave a half-rewritten build file behind.
manifest_write_version() {
  local file="" version="" build="" kind tmp code
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build)
        [[ $# -ge 2 ]] || { log_error "manifest_write_version: $1 requires a value"; return 2; }
        build="$2"; shift 2 ;;
      -*) log_error "manifest_write_version: unknown option $1"; return 2 ;;
      *) if [[ -z "$file" ]]; then file="$1"; else version="$1"; fi; shift ;;
    esac
  done
  [[ -n "$file" && -n "$version" ]] || { log_error "manifest_write_version: need <file> <version>"; return 2; }
  [[ -f "$file" ]] || { log_error "manifest_write_version: not found: $file"; return 2; }
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] \
    || { log_error "manifest_write_version: not a semver version: '$version'"; return 2; }
  case "$version" in
    *$'\n'*|*$'\r'*) log_error "manifest_write_version: version contains a line break"; return 2 ;;
  esac
  kind="$(manifest_kind "$file")" || return 2

  if [[ -n "$build" ]]; then
    case "$kind" in
      gradle)
        [[ "$build" =~ ^[0-9]+$ ]] \
          || { log_error "manifest_write_version: --build must be an integer for $file: '$build'"; return 2; } ;;
      pubspec)
        [[ "$build" =~ ^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$ ]] \
          || { log_error "manifest_write_version: --build is not a valid build identifier: '$build'"; return 2; } ;;
    esac
  fi

  local esc
  tmp="$(mktemp)" || return 1

  case "$kind" in
    pubspec)
      if [[ -n "$build" ]]; then
        version="${version%%+*}"
      elif [[ "$version" != *+* ]]; then
        build="$(sed -n 's/^version:[[:space:]]*[0-9][^+[:space:]]*+\([0-9]*\).*/\1/p' "$file" | head -n1)"
      fi
      if [[ -n "$build" ]]; then
        esc="$(_manifest__sed_escape "${version}+${build}")"
      else
        esc="$(_manifest__sed_escape "$version")"
      fi
      sed "s|^version:[[:space:]]*.*|version: ${esc}|" "$file" > "$tmp"
      ;;
    gradle)
      code="${build:-$(manifest_android_version_code "$version")}" || { rm -f "$tmp"; return 2; }
      esc="$(_manifest__sed_escape "$version")"
      sed -e "s|\(versionName[[:space:]]*[=(]*[[:space:]]*\)\"[^\"]*\"|\1\"${esc}\"|" \
          -e "s|\(versionCode[[:space:]]*[=(]*[[:space:]]*\)[0-9][0-9]*|\1${code}|" \
          "$file" > "$tmp"
      ;;
    version_file)
      printf '%s\n' "$version" > "$tmp"
      ;;
    package_json)
      esc="$(_manifest__sed_escape "$version")"
      sed "s|\(\"version\"[[:space:]]*:[[:space:]]*\)\"[^\"]*\"|\1\"${esc}\"|" "$file" > "$tmp"
      ;;
    pyproject)
      esc="$(_manifest__sed_escape "$version")"
      sed "s|^\(version[[:space:]]*=[[:space:]]*\)\"[^\"]*\"|\1\"${esc}\"|" "$file" > "$tmp"
      ;;
  esac

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    log_error "manifest_write_version: rewriting $file produced an empty file — refusing to replace it"
    return 1
  fi
  # Not `cat && rm || return 1`: that reports failure when the write succeeded
  # and only the cleanup failed.
  if ! cat "$tmp" > "$file"; then
    rm -f "$tmp"
    log_error "manifest_write_version: could not write $file"
    return 1
  fi
  # A Gradle file with no versionName literal is not an error -- release flows
  # sync a whole tree and expect some -- but what was and was not written must
  # be reported accurately.
  #
  # Only a file that reads `flutter.versionName` gets a warning: that is a
  # Flutter module, and the pubspec is where its version lives. A native app
  # that takes versionName from a variable, or a root build file with no
  # android block at all, is normal and gets a debug line, not a warning that
  # names Flutter. A versionCode literal is still rewritten in either case, so
  # the message must not claim nothing was written.
  if [[ "$kind" == gradle ]] && ! manifest_read_version "$file" >/dev/null 2>&1; then
    rm -f "$tmp"
    local code_note="$version was not written there"
    if grep -q 'versionCode[[:space:]]*[=(]*[[:space:]]*[0-9]' "$file" 2>/dev/null; then
      code_note="versionCode was set to $code, but versionName $version was not written"
    fi
    if grep -q 'flutter\.versionName' "$file" 2>/dev/null; then
      log_warn "manifest: $file has no versionName literal; $code_note (a Flutter build takes it from pubspec.yaml)"
    else
      log_debug "manifest: $file has no versionName literal; $code_note"
    fi
    return 0
  fi
  rm -f "$tmp"
  log_info "manifest: $file -> $version"
}

# Usage: manifest_sync_version <dir> <version> [--build <n>]; write <version>
# into every manifest under <dir>. This is the "one release, one number"
# operation. Returns non-zero if any manifest could not be written, after
# attempting all of them — a partial sync is reported, not hidden.
manifest_sync_version() {
  local dir="" version="" build="" rc=0 kind path
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build)
        [[ $# -ge 2 ]] || { log_error "manifest_sync_version: $1 requires a value"; return 2; }
        build="$2"; shift 2 ;;
      -*) log_error "manifest_sync_version: unknown option $1"; return 2 ;;
      *) if [[ -z "$dir" ]]; then dir="$1"; else version="$1"; fi; shift ;;
    esac
  done
  [[ -n "$dir" && -n "$version" ]] || { log_error "manifest_sync_version: need <dir> <version>"; return 2; }

  local found=0
  while IFS=$'\t' read -r kind path; do
    [[ -n "$path" ]] || continue
    found=1
    if [[ -n "$build" ]]; then
      manifest_write_version "$path" "$version" --build "$build" || rc=1
    else
      manifest_write_version "$path" "$version" || rc=1
    fi
  done < <(manifest_detect "$dir")

  # The process substitution hides manifest_detect's status, so "nothing was
  # found" is counted here. Still success -- a tree with no manifest has nothing
  # to disagree with -- but said, not silent. (A <dir> that is not a directory
  # is reported by manifest_detect itself.)
  if [[ "$found" -eq 0 && -d "$dir" ]]; then
    log_info "manifest_sync_version: no version manifest found under $dir; nothing written"
  fi

  [[ "$rc" -eq 0 ]] || log_error "manifest_sync_version: one or more manifests were not updated"
  return $rc
}
