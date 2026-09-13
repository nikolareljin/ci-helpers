#!/usr/bin/env bash
# SCRIPT: rust_test.sh
# DESCRIPTION: Tests for lib/rust.sh -- resolving the Rust toolchain CI uses rather than PATH's first cargo.
# USAGE: ./tests/rust_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/rust_test.sh
# ----------------------------------------------------
#
# rustup and both cargos are stubs in a temporary directory. Nothing here
# installs a toolchain, reaches the network, or compiles anything.
#
# The behaviour worth pinning is the one that looks fine until it does not: a
# gate claiming "this is what CI would have run" while running an older
# distribution cargo. Its symptom is a lockfile error, so the failure points
# away from the cause.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[rust_test] $*"; }
error() { echo "[rust_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[rust_test]   ok  $*"; }

tmp="$(mktemp -d)"
# shellcheck disable=SC2317
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import rust

mkdir -p "$tmp/distro" "$tmp/rustup-toolchain" "$tmp/bin"

cat > "$tmp/distro/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo 1.75.0 (distribution)"
EOF
cat > "$tmp/rustup-toolchain/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo 1.96.0 (rustup)"
EOF
# The stub answers only for the named toolchain, and its *default* toolchain
# is a nightly with its own cargo -- so a resolver that asks a bare
# `rustup which cargo` gets the nightly, and the test below catches it.
mkdir -p "$tmp/nightly"
cat > "$tmp/nightly/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo 1.99.0-nightly (rustup default)"
EOF
cat > "$tmp/bin/rustup" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "which" ] && [ "\$2" = "--toolchain" ]; then
  case "\$3" in
    stable) echo "$tmp/rustup-toolchain/cargo" ;;
    *) exit 1 ;;
  esac
elif [ "\$1" = "which" ]; then
  echo "$tmp/nightly/cargo"
fi
EOF
chmod +x "$tmp/distro/cargo" "$tmp/rustup-toolchain/cargo" "$tmp/nightly/cargo" "$tmp/bin/rustup"

original_path="$PATH"
# The stubs are `#!/usr/bin/env bash`, so the restricted PATH each case sets
# must still contain wherever *this* bash lives: /bin on macOS, /usr/bin on
# Ubuntu, /usr/local/bin in the bash:3.2 image. Without it the stubs fail to
# exec and every case that needs one to run reads as "no usable cargo".
bash_dir="$(dirname "$BASH")"

note "a shadowing distribution cargo is stepped over"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  rust_toolchain_ci_uses >"$tmp/out" 2>&1
  resolved="$(command -v cargo)"
  [[ "$resolved" == "$tmp/rustup-toolchain/cargo" ]]
); then
  ok "cargo resolves to rustup's, not PATH's first"
else
  error "expected rustup's cargo to win, got: $(cat "$tmp/out" 2>/dev/null)"
fi

note "it says so, rather than switching silently"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  rust_toolchain_ci_uses >"$tmp/out" 2>&1
  grep -q "1.96.0" "$tmp/out" && grep -q "1.75.0" "$tmp/out"
); then
  ok "both versions named, so the switch is visible"
else
  error "expected both cargo versions in the message: $(cat "$tmp/out" 2>/dev/null)"
fi

note "diagnostics go to stderr, stdout stays for the caller"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  out="$(rust_toolchain_ci_uses 2>/dev/null)"
  [[ -z "$out" ]]
); then
  ok "nothing on stdout even when a switch is reported"
else
  error "expected an empty stdout"
fi

note "no message when PATH already offers the right one"
if (
  PATH="$tmp/rustup-toolchain:$tmp/bin:/usr/bin:/bin:$bash_dir"
  rust_toolchain_ci_uses >"$tmp/out" 2>&1
  [[ ! -s "$tmp/out" ]]
); then
  ok "quiet when there is nothing to report"
else
  error "expected no output, got: $(cat "$tmp/out" 2>/dev/null)"
fi

note "no rustup is an actionable refusal, not a silent fallback"
if (
  PATH="$tmp/distro:/usr/bin:/bin:$bash_dir"
  ! rust_toolchain_ci_uses >"$tmp/out" 2>&1
  grep -q "rustup" "$tmp/out"
); then
  ok "returns non-zero and names rustup"
else
  error "expected a non-zero return naming rustup: $(cat "$tmp/out" 2>/dev/null)"
fi

note "rustup present but with no usable cargo is also refused"
cat > "$tmp/bin/rustup" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/bin/rustup"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  ! rust_toolchain_ci_uses >"$tmp/out" 2>&1
  grep -q "toolchain install stable" "$tmp/out"
); then
  ok "says how to fix it"
else
  error "expected install instructions: $(cat "$tmp/out" 2>/dev/null)"
fi

note "a nightly default toolchain does not leak through"
cat > "$tmp/bin/rustup" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "which" ] && [ "\$2" = "--toolchain" ]; then
  case "\$3" in
    stable) echo "$tmp/rustup-toolchain/cargo" ;;
    *) exit 1 ;;
  esac
elif [ "\$1" = "which" ]; then
  echo "$tmp/nightly/cargo"
fi
EOF
chmod +x "$tmp/bin/rustup"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  rust_toolchain_ci_uses >"$tmp/out" 2>&1
  [[ "$(command -v cargo)" == "$tmp/rustup-toolchain/cargo" ]]
); then
  ok "stable is asked for by name, not whatever rustup defaults to"
else
  error "expected stable's cargo, got: $(command -v cargo 2>/dev/null) / $(cat "$tmp/out" 2>/dev/null)"
fi

note "a toolchain rustup does not have is refused by name"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  ! rust_toolchain_ci_uses 1.80.0 >"$tmp/out" 2>&1
  grep -q "toolchain install 1.80.0" "$tmp/out"
); then
  ok "names the missing toolchain in the fix"
else
  error "expected an install hint for 1.80.0: $(cat "$tmp/out" 2>/dev/null)"
fi

note "a rustup dir already on PATH, but behind the distro cargo, is moved to the front"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir:$tmp/rustup-toolchain"
  rust_toolchain_ci_uses >/dev/null 2>&1
  [[ "$(command -v cargo)" == "$tmp/rustup-toolchain/cargo" ]]
); then
  ok "later on PATH is not good enough; it is first now"
else
  error "expected rustup's cargo to win over a distro cargo earlier on PATH, got: $(command -v cargo)"
fi

note "a cargo already in the command hash table is not what runs afterwards"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  hash -r; hash cargo                                   # the distro cargo is now hashed
  rust_toolchain_ci_uses >/dev/null 2>&1
  [[ "$(cargo)" == *"(rustup)"* ]]                      # executed by name, not resolved by hand
); then
  ok "the hash table is cleared with the PATH change"
else
  error "expected the rustup cargo to run after the switch, got: $(cargo 2>&1)"
fi

note "an empty PATH becomes the directory alone, with no trailing colon"
# shellcheck disable=SC2030,SC2031  # PATH is deliberately set and read inside the subshell
if (
  # shellcheck disable=SC2123
  PATH=""
  _rust_path_prepend "$tmp/rustup-toolchain"
  [[ "$PATH" == "$tmp/rustup-toolchain" ]]
); then
  ok "no trailing colon, so the working directory never joins PATH"
else
  error "expected PATH to be exactly the toolchain dir after prepending to an empty PATH"
fi

note "prepending to a non-empty PATH keeps the rest, once"
# shellcheck disable=SC2030,SC2031
if (
  PATH="/usr/bin:/bin"
  _rust_path_prepend "$tmp/rustup-toolchain"
  _rust_path_prepend "$tmp/rustup-toolchain"
  [[ "$PATH" == "$tmp/rustup-toolchain:/usr/bin:/bin" ]]
); then
  ok "first, then unchanged"
else
  error "expected dir:/usr/bin:/bin"
fi

note "calling it twice does not grow PATH"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  rust_toolchain_ci_uses >/dev/null 2>&1
  once="$PATH"
  rust_toolchain_ci_uses >/dev/null 2>&1
  [[ "$PATH" == "$once" ]]
); then
  ok "the prepend is idempotent"
else
  error "PATH grew on the second call"
fi

note "a cargo that exists but will not run is still named"
if (
  set +e   # the call is expected to fail; errexit must not skip the restore below
  chmod -x "$tmp/rustup-toolchain/cargo"
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  rust_toolchain_ci_uses >"$tmp/out" 2>&1
  status=$?
  chmod +x "$tmp/rustup-toolchain/cargo"
  # -x is checked before any message, so this is the refusal path; the
  # message must still carry the path rather than an empty version.
  [[ $status -ne 0 ]] && grep -q "toolchain install" "$tmp/out"
); then
  ok "refused, with the fix named"
else
  error "expected a refusal naming the fix: $(cat "$tmp/out" 2>/dev/null)"
fi

note "a missing cargo is reported on stderr, not in the report"
if (
  # An empty PATH directory: the case is "no cargo anywhere", this path
  # runs no stub, and wherever bash lives (/usr/bin on Ubuntu) may also
  # hold a distribution cargo.
  set +e   # the call is expected to fail; capture its status, do not exit on it
  mkdir -p "$tmp/empty"
  # shellcheck disable=SC2123  # an empty search path is the point of this case
  PATH="$tmp/empty"
  hash -r   # the hash table is inherited by the subshell and would answer for cargo
  out="$(rust_toolchain_report 2>"$tmp/err")"; status=$?
  # Builtins only from here: with PATH empty there is no grep to call.
  err="$(<"$tmp/err")"
  [[ $status -ne 0 && -z "$out" && "$err" == *"no cargo"* ]]
); then
  ok "non-zero, empty stdout, reason on stderr"
else
  error "expected the missing-cargo error on stderr with empty stdout"
fi

note "the report does not change PATH"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin:$bash_dir"
  rust_toolchain_report >"$tmp/out" 2>&1
  [[ "$(command -v cargo)" == "$tmp/distro/cargo" ]]
); then
  ok "report is read-only"
else
  error "rust_toolchain_report must not modify PATH"
fi

PATH="$original_path"

if [[ $failures -gt 0 ]]; then
  echo "[rust_test] $failures failure(s)" >&2
  exit 1
fi
echo "[rust_test] all checks passed"
