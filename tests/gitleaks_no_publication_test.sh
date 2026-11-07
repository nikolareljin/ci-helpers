#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -I "$root/tests/gitleaks_no_publication_test.py"
