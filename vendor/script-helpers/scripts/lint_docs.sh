#!/usr/bin/env bash
# SCRIPT: lint_docs.sh
# DESCRIPTION: Validate docs coverage: modules, functions, the API index, the module lists in README.md and docs/README.md, every script, bin/ command and config/ file, and the module counts.
# USAGE: ./lint_docs.sh
# PARAMETERS:
#   -h, --help  Show this help and exit.
# EXIT_CODES:
#   0  Every module, function, script, command and config file is documented,
#      and the module counts are current.
#   1  At least one documentation gap (each printed on stderr).
# EXAMPLE:
#   bash scripts/lint_docs.sh
# ----------------------------------------------------
set -euo pipefail

case "${1:-}" in -h|--help) sed -n '2,/^# ----/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'; exit 0 ;; esac

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0

note()  { echo "[lint-docs] $*"; }
error() { echo "[lint-docs][ERROR] $*" >&2; failures=$((failures+1)); }

# Collect modules: lib/*.sh + helpers.sh (as module 'helpers')
lib_files=()
while IFS= read -r _sh_line; do lib_files+=("$_sh_line"); done < <(find lib -maxdepth 1 -type f -name '*.sh' | sort)
lib_files=("helpers.sh" "${lib_files[@]+"${lib_files[@]}"}")

missing_docs=()
missing_functions=()
missing_api_entries=()

api_index="docs/api.md"

# Build set of docs listed in API index.
# A newline-delimited string rather than an associative array: module names are
# a small, flat set, and this keeps the linter runnable on bash 3.2 -- which is
# what /bin/bash is on macOS, where `make lint-docs` has to pass.
api_modules=""
if [[ -f "$api_index" ]]; then
  while IFS= read -r line; do
    # Two anchored branches, not one loose pattern. The docs site needs real
    # links; the plain-text form must keep passing while anything still uses it:
    #
    #   - [name](./modules/name.md)     a link, which renders on the site
    #   - name - ./modules/name.md      plain text
    #
    # Anchored at both ends on purpose. A single permissive pattern with
    # optional brackets also matched a commented-out line, a line inside a
    # fenced block, a table cell, and prose merely mentioning `./modules/x.md`
    # -- so a worked example in this very file could satisfy the index for a
    # module that had been dropped from it. Each branch below is stricter than
    # the original pattern was, not looser.
    mod=""; target=""
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[([a-zA-Z0-9_-]+)\]\(\./modules/([a-zA-Z0-9_-]+)\.md\)[[:space:]]*$ ]]; then
      mod="${BASH_REMATCH[1]}"; target="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]([a-zA-Z0-9_-]+)[[:space:]]+-[[:space:]]+\./modules/([a-zA-Z0-9_-]+)\.md[[:space:]]*$ ]]; then
      mod="${BASH_REMATCH[1]}"; target="${BASH_REMATCH[2]}"
    fi
    if [[ -n "$mod" ]]; then
      # The name and the page it points at must agree. Without this,
      # `- [rust](./modules/gradle.md)` passed every gate: `rust` counted as
      # indexed, mkdocs --strict saw two files that both exist, and the
      # published index quietly sent the reader to the wrong page. Thirty-six
      # near-identical bracketed lines is exactly the shape that gets
      # copy-pasted wrong.
      if [[ "$mod" != "$target" ]]; then
        error "docs/api.md: '${mod}' links to ./modules/${target}.md"
      else
        api_modules="${api_modules}${mod}"$'\n'
      fi
    fi
  done < "$api_index"
fi

for f in "${lib_files[@]+"${lib_files[@]}"}"; do
  if [[ "$f" == "helpers.sh" ]]; then
    module="helpers"
  else
    module="$(basename "$f" .sh)"
  fi
  doc="docs/modules/${module}.md"

  if [[ ! -f "$doc" ]]; then
    missing_docs+=("$module")
    error "Missing module doc: $doc"
  fi

  # Check functions are mentioned in the module doc (skip internals starting with _)
  funcs=()
  while IFS= read -r _sh_line; do funcs+=("$_sh_line"); done < <(
    # The whole file: several modules are longer than 2000 lines.
    cat "$f" \
      | grep -E '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' \
      | sed -E 's/^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(\).*/\1/' \
      | sort -u
  )

  for fn in "${funcs[@]+"${funcs[@]}"}"; do
    # Skip private/internal helpers
    if [[ "$fn" == _* ]]; then continue; fi
    if [[ ! -f "$doc" ]]; then continue; fi
    # \b is a GNU extension; spelled as explicit boundaries so this linter can
    # pass on macOS, where it otherwise reports every function as undocumented.
    if ! grep -q -E "(^|[^A-Za-z0-9_])${fn}([^A-Za-z0-9_]|$)" "$doc"; then
      missing_functions+=("${module}:${fn}")
    fi
  done

  # The two module lists a reader meets first: README.md names the file,
  # docs/README.md (the site's home page) starts a list item with the name.
  if [[ -f README.md && "$f" != "helpers.sh" ]] && ! grep -q -E "(^|[^A-Za-z0-9_-])${module}\.sh" README.md; then
    error "Module missing from README.md: ${module}.sh"
  fi
  if [[ -f docs/README.md ]] && ! grep -q -E "^- ${module}( |:)" docs/README.md; then
    error "Module missing from the docs/README.md overview: ${module}"
  fi

  # Check module is listed in API index
  if [[ -f "$api_index" ]]; then
    if [[ $'\n'"$api_modules" != *$'\n'"$module"$'\n'* ]]; then
      missing_api_entries+=("$module")
    fi
  fi
done

if (( ${#missing_functions[@]} > 0 )); then
  for entry in "${missing_functions[@]+"${missing_functions[@]}"}"; do
    error "Function not referenced in docs: $entry"
  done
fi

if (( ${#missing_api_entries[@]} > 0 )); then
  for m in "${missing_api_entries[@]+"${missing_api_entries[@]}"}"; do
    error "Module missing from docs/api.md: $m"
  done
fi

# Every PowerShell module has a row in README.md's PowerShell table.
for f in ps/lib/*.ps1; do
  [[ -f "$f" && -f README.md ]] || continue
  if ! grep -q -F "| \`$(basename "$f")\`" README.md; then
    error "PowerShell module missing from the README.md table: $f"
  fi
done

# Every script, bin/ command and config/ file is named by a guide: README.md or
# a page under docs/. docs/commands.md does not count. It is generated from the
# script headers, so it names every script whether or not a guide explains it.
guides=()
[[ -f README.md ]] && guides+=("README.md")
while IFS= read -r _sh_line; do guides+=("$_sh_line"); done < <(
  find docs -type f -name '*.md' ! -path docs/commands.md 2>/dev/null | sort
)
for f in scripts/*.sh scripts/*.py scripts/*/* ps/scripts/*.ps1 bin/* config/*; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f")"
  # Bounded on both sides, so mytool.sh and tool.sh2 do not count for tool.sh.
  name_re="$(printf '%s' "$name" | sed 's/[.[\*^$+?(){}|]/\\&/g')"
  if (( ${#guides[@]} == 0 )) || ! grep -q -E "(^|[^A-Za-z0-9_-])${name_re}([^A-Za-z0-9_-]|$)" "${guides[@]}"; then
    error "Not named in README.md or any docs/ guide: $f"
  fi
done

# Published pages say what the product does now; history belongs in
# CHANGELOG.md. Only phrases that are history in every reading are matched, so
# "before the push", "the key used to sign", "the previously set path" and
# "no longer than 64 bytes" pass. docs/commands.md counts: it is built from the
# script headers.
history_re='(^|[^A-Za-z])(((it|this|that|which|they) used to|an earlier version|previously[ ,]+(it|this|that|the|a|an|there|we|you)|formerly|since this change|there was none|for years it)([^A-Za-z]|$)|no longer( [^t]| t[^h]| th[^a]|[^ A-Za-z]|$))'
history_files=()
[[ -f README.md ]] && history_files+=("README.md")
while IFS= read -r _sh_line; do history_files+=("$_sh_line"); done < <(
  find docs -type f -name '*.md' 2>/dev/null | sort
)
if (( ${#history_files[@]} > 0 )); then
  while IFS= read -r hit; do
    [[ -n "$hit" ]] && error "History in a published page (move it to CHANGELOG.md): $hit"
  done < <(grep -n -i -E "$history_re" "${history_files[@]}" /dev/null || true)
fi

# Published pages are plain ASCII prose: no em or en dash, arrow, curly quote,
# ellipsis, middle dot, non-breaking hyphen or space. The one exception is the
# literal CHANGELOG release header (`## 2026-01-02 — v1.2.3`), which
# lib/changelog.sh requires; it is blanked before the search.
typo_re=$'(\xe2\x80[\x93\x94\x98\x99\x9c\x9d\xa6\x91]|\xe2\x86[\x90-\x94]|\xc2[\xa0\xb7])'
for _typo_file in "${history_files[@]+"${history_files[@]}"}"; do
  while IFS= read -r hit; do
    [[ -n "$hit" ]] && error "Typographic character in a published page (use plain ASCII): ${_typo_file}:$hit"
  done < <(LC_ALL=C sed -E $'s/## [0-9.-]+ \xe2\x80\x94 v//g' "$_typo_file" | LC_ALL=C grep -n -E "$typo_re" || true)
done

# "N Bash modules" and "N PowerShell mirrors" must match lib/ and ps/lib/.
# Tags are stripped first: hero.svg puts the number and the words in separate
# <text> elements.
count_files() { local n=0 x; for x in "$@"; do [[ -f "$x" ]] && n=$((n+1)); done; echo "$n"; }
bash_count="$(count_files lib/*.sh)"
ps_count="$(count_files ps/lib/*.ps1)"
for f in README.md docs/README.md docs/assets/hero.svg; do
  [[ -f "$f" ]] || continue
  flat="$(sed -e 's/<[^>]*>/ /g' "$f" | tr -s ' \n\t' '   ')"
  while IFS= read -r n; do
    [[ -n "$n" && "$n" != "$bash_count" ]] && error "$f says $n Bash modules; lib/ has $bash_count"
  done < <(printf '%s\n' "$flat" | grep -o -E '[0-9]+ Bash modules?' | sed 's/ .*//')
  while IFS= read -r n; do
    [[ -n "$n" && "$n" != "$ps_count" ]] && error "$f says $n PowerShell mirrors; ps/lib/ has $ps_count"
  done < <(printf '%s\n' "$flat" | grep -o -E '[0-9]+ PowerShell mirrors?' | sed 's/ .*//')
done

if (( failures == 0 )); then
  note "Documentation coverage looks good."
else
  note "Found $failures documentation issues."
  exit 1
fi
