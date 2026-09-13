#!/usr/bin/env bash
# SCRIPT: dev_shim_test.sh
# DESCRIPTION: Tests which bash the ./dev shim selects.
# USAGE: bash tests/dev_shim_test.sh
# ----------------------------------------------------
#
# The shim exists because `exec bash` resolves bash from PATH and discards the
# file's own `#!/usr/bin/env bash`, which on macOS means /bin/bash 3.2. Its
# selection rule is easy to regress and impossible to notice from Linux, where
# every candidate is bash 5.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=0
note()  { echo "[dev_shim_test] $*"; }
error() { echo "[dev_shim_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A stand-in interpreter: answers the version probe, and otherwise reports that
# it was the one chosen to run the CLI.
make_fake() {
  local path="$1" version="$2"
  # env sh, not /bin/sh: the portability gate bans a hardcoded interpreter path
  # anywhere in the tree, including one a script writes into a file, and a test
  # fixture is not an exception worth carving out.
  cat > "$path" <<EOF
#!/usr/bin/env sh
if [ "\$1" = "-c" ]; then printf '%s\n' "$version"; exit 0; fi
echo "SELECTED $version"
EOF
  chmod +x "$path"
}

# The shipped shim, with only its candidate list replaced, so the version
# comparison under test is the real one.
shim="$tmp/dev"
sed -e 's|^for _dev_c in .*|for _dev_c in $DEV_TEST_CANDIDATES; do|' \
    -e '/^ *"\$(command -v bash 2>\/dev\/null)" \/bin\/bash; do$/d' \
    templates/dev-cli/dev > "$shim"
chmod +x "$shim"
mkdir -p "$tmp/scripts"; : > "$tmp/scripts/cli.sh"

if ! grep -q 'DEV_TEST_CANDIDATES' "$shim"; then
  error "could not rewrite the candidate list; the shim's loop header changed"
  echo "[dev_shim_test] $failures check(s) failed."; exit 1
fi

run_shim() { DEV_TEST_CANDIDATES="$*" "$shim" 2>&1; }

make_fake "$tmp/b30" "3.0"
make_fake "$tmp/b31" "3.1"
make_fake "$tmp/b32" "3.2"
make_fake "$tmp/b50" "5.2"

expect_sel() {
  local label="$1" want="$2"; shift 2
  local got; got="$(run_shim "$@")"
  if [[ "$got" == "SELECTED $want" ]]; then note "$label"; else error "$label: want 'SELECTED $want', got '$got'"; fi
}

# bash 4+ is preferred wherever it appears in the list.
expect_sel "prefers bash 4+ over 3.2"            5.2 "$tmp/b32 $tmp/b50"
expect_sel "prefers bash 4+ regardless of order" 5.2 "$tmp/b50 $tmp/b32"

# 3.2 is supported, so it is a valid fallback when nothing newer exists.
expect_sel "falls back to 3.2"                   3.2 "$tmp/b32"

# helpers.sh requires 3.2. Committing to 3.0 or 3.1 would fail a moment later,
# after the interpreter had already been chosen.
got="$(run_shim "$tmp/b30 $tmp/b31")"
case "$got" in
  *"need 3.2 or newer"*) note "refuses bash 3.0 and 3.1 rather than selecting them" ;;
  *) error "a pre-3.2 bash was selected: $got" ;;
esac

expect_sel "skips 3.1 and takes the 3.2"         3.2 "$tmp/b31 $tmp/b32"

# A candidate that is not bash at all must not derail the search.
printf '#!/usr/bin/env sh\necho not-a-bash\n' > "$tmp/junk"; chmod +x "$tmp/junk"
expect_sel "ignores a candidate with no version" 5.2 "$tmp/junk $tmp/b50"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
