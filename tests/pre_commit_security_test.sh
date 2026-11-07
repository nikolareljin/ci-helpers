#!/usr/bin/env bash
# A failed security check must stop before any later repository check.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q "$scratch"
mkdir -p "$scratch/vendor/script-helpers/scripts" "$scratch/scripts"
printf 'sec_pre_commit() { return 7; }\n' > "$scratch/vendor/script-helpers/scripts/security_hooks.sh"
printf '#!/usr/bin/env bash\ntouch "%s/later-check"\nexit 0\n' "$scratch" > "$scratch/scripts/check_release_version.sh"
chmod +x "$scratch/scripts/check_release_version.sh"
rc=0
(cd "$scratch" && bash "$root/.githooks/pre-commit") > "$scratch/output" 2>&1 || rc=$?
[[ "$rc" -eq 7 && ! -e "$scratch/later-check" ]]
printf 'PASS security refusal stops subsequent commit checks\n'
