#!/usr/bin/env bash
# SCRIPT: check_scan_output.sh
# DESCRIPTION: Refuse scanner results before a commit, push or text publication.
# USAGE: scripts/check_scan_output.sh [--staged|--push-refs <file>|--range <ref>|--tree <ref>|--file <path>|--stdin] [--remote <name>] [--repo <path>] [--max-mib <n>] [--non-blocking]
# PARAMETERS:
#   --staged          Check staged blobs, not working files.
#   --push-refs FILE  Check every outgoing commit and annotated tag.
#   --range REF       Check a revision or revision range.
#   --tree REF        Check all files at a revision.
#   --file PATH       Check a publication file; repeatable.
#   --stdin           Check publication text on stdin.
#   --remote NAME     Target remote for new refs.
#   --repo PATH       Repository, default current directory.
#   --max-mib N       Largest file or blob checked, 1..2048 MiB (default 2048,
#                     or CHECK_SCAN_OUTPUT_MAX_MIB). Above 64 MiB files are
#                     streamed; executables also have embedded data decoded.
#   --non-blocking    Exit 0 when a file above 64 MiB was not fully checked
#                     (the default when GITHUB_ACTIONS=true).
#   -h, --help        Show help.
# EXIT_CODES:
#   0 Clear; 1 prohibited output; 2 unable to check; 3 a file above 64 MiB was
#   not fully checked (warning printed; 0 with --non-blocking or in CI).
# EXAMPLE: scripts/check_scan_output.sh --staged
# ----------------------------------------------------
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for py in python3 python; do
  if command -v "$py" >/dev/null 2>&1 && (cd / && "$py" -I -c 'import sys; sys.exit(sys.version_info < (3, 8))') >/dev/null 2>&1; then
    exec "$py" -I "$script_dir/check_scan_output.py" "$@"
  fi
done
echo 'Security checks could not run. Install Python 3.8 or newer locally first.' >&2
exit 2
