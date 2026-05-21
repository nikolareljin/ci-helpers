#!/usr/bin/env bash
# SCRIPT: lint_docs.sh
# DESCRIPTION: Validate docs coverage and API index consistency for script-helpers modules.
# USAGE: ./lint_docs.sh
# PARAMETERS: No required parameters.
# EXAMPLE: ./lint_docs.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0

note()  { echo "[lint-docs] $*"; }
error() { echo "[lint-docs][ERROR] $*" >&2; failures=$((failures+1)); }

# Collect modules: lib/*.sh + helpers.sh (as module 'helpers')
mapfile -t lib_files < <(find lib -maxdepth 1 -type f -name '*.sh' | sort)
lib_files=("helpers.sh" "${lib_files[@]}")

missing_docs=()
missing_functions=()
missing_api_entries=()

api_index="docs/api.md"

# Build set of docs listed in API index
declare -A api_modules=()
if [[ -f "$api_index" ]]; then
  while IFS= read -r line; do
    # Match lines like: - name — ./modules/name.md OR - name — ./modules/name.md
    if [[ "$line" =~ \-\ ([a-zA-Z0-9_-]+)[[:space:]]+\—?[[:space:]]+\./modules/([a-zA-Z0-9_-]+)\.md ]]; then
      mod="${BASH_REMATCH[1]}"; api_modules["$mod"]=1
    fi
  done < "$api_index"
fi

for f in "${lib_files[@]}"; do
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
  # Extract function names from the file (first 500 lines is enough for these small modules)
  mapfile -t funcs < <(sed -n '1,500p' "$f" | \
    grep -E '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' | \
    sed -E 's/^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(\).*/\1/' | \
    sort -u)

  for fn in "${funcs[@]}"; do
    # Skip private/internal helpers
    if [[ "$fn" == _* ]]; then continue; fi
    if [[ ! -f "$doc" ]]; then continue; fi
    if ! grep -q -E "\b${fn}\b" "$doc"; then
      missing_functions+=("${module}:${fn}")
    fi
  done

  # Check module is listed in API index
  if [[ -f "$api_index" ]]; then
    if [[ -z "${api_modules[$module]:-}" ]]; then
      missing_api_entries+=("$module")
    fi
  fi
done

if (( ${#missing_functions[@]} > 0 )); then
  for entry in "${missing_functions[@]}"; do
    error "Function not referenced in docs: $entry"
  done
fi

if (( ${#missing_api_entries[@]} > 0 )); then
  for m in "${missing_api_entries[@]}"; do
    error "Module missing from docs/api.md: $m"
  done
fi

if (( failures == 0 )); then
  note "Documentation coverage looks good."
else
  note "Found $failures documentation issues."
  exit 1
fi
