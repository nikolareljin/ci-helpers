#!/usr/bin/env bash
# Rust toolchain resolution: run a gate against the toolchain CI uses, not
# whatever PATH happens to offer first.
#
# CI installs Rust with dtolnay/rust-toolchain@stable, which is rustup's
# stable. A workstation frequently also has a distribution cargo, and on many
# distributions it comes first on PATH and is years older. The failure that
# produces does not look like a toolchain problem:
#
#     error: lock file version 4 requires `-Znext-lockfile-bump`
#     error: failed to download `time-core v0.1.9`
#     feature `edition2024` is required
#
# Both read as a broken lockfile. A gate that claims "this is what CI would
# have run" while running a different compiler is worse than no gate, which is
# ADR-0027 rule 5 in the fleet that produced this library.
#
# Written for bash 3.2: no namerefs, no associative arrays, no ${var,,}.

# Usage: _rust_path_prepend <dir>
#
# Put <dir> first on PATH unless it already is, and export it. On an empty
# PATH the result is <dir> alone: a trailing colon would put the working
# directory on the search path, which is how ./cargo gets run by accident.
_rust_path_prepend() {
  local dir="$1"
  case "$PATH" in
    "$dir"|"$dir:"*) ;;
    *) PATH="$dir${PATH:+:$PATH}" ;;
  esac
  export PATH
}

# Usage: rust_toolchain_ci_uses [toolchain]
#
# Puts the named rustup toolchain's cargo first on PATH and exports it. The
# toolchain defaults to RUST_TOOLCHAIN, then "stable" -- the channel CI's
# dtolnay/rust-toolchain@stable installs. It is named on purpose: a bare
# `rustup which cargo` follows the developer's default or a directory
# override, which may be nightly, and that reintroduces the gap this exists
# to close from the other side.
#
# Says so when the result differs from what PATH offered, because a silent
# switch is its own surprise. Returns non-zero, with an actionable message,
# when rustup cannot supply that toolchain.
rust_toolchain_ci_uses() {
  local toolchain="${1:-${RUST_TOOLCHAIN:-stable}}"
  local rustup_cargo on_path

  if ! command -v rustup >/dev/null 2>&1; then
    echo "[rust] rustup is not installed; CI compiles with rustup's $toolchain." >&2
    echo "[rust] Install it from https://rustup.rs, then: rustup toolchain install $toolchain" >&2
    return 1
  fi

  rustup_cargo="$(rustup which --toolchain "$toolchain" cargo 2>/dev/null || true)"
  if [[ -z "$rustup_cargo" || ! -x "$rustup_cargo" ]]; then
    echo "[rust] rustup has no usable cargo for '$toolchain'. Run: rustup toolchain install $toolchain" >&2
    return 1
  fi

  on_path="$(command -v cargo 2>/dev/null || true)"
  # Diagnostics go to stderr, like the refusals above: a caller may be keeping
  # stdout for the command output it is about to capture.
  if [[ "$on_path" != "$rustup_cargo" ]]; then
    echo "[rust] using $("$rustup_cargo" --version 2>/dev/null || echo "a cargo that will not run, at $rustup_cargo") from rustup ($toolchain)" >&2
    if [[ -n "$on_path" ]]; then
      echo "[rust] (PATH offered $("$on_path" --version 2>/dev/null || echo 'an unusable cargo'), which is not what CI compiles with)" >&2
    fi
  fi

  # First on PATH, not merely on it: a machine with rustup installed the
  # usual way already has ~/.cargo/bin somewhere on PATH, behind the
  # distribution cargo that is the whole problem. So the test is "is it the
  # first segment"; only then is there nothing to do. Calling twice is still
  # a no-op, since after the first call it is first.
  # Parameter expansion, not dirname: on an empty PATH there is no dirname.
  _rust_path_prepend "${rustup_cargo%/*}"
  # A cargo already run in this shell is in the command hash table, and the
  # table wins over PATH. Without this a gate could still execute the old one.
  hash -r
}

# Usage: rust_toolchain_report [toolchain]
#
# Prints which cargo would be used and what rustup offers for the named
# toolchain, without changing PATH. For a status verb, or a gate that wants to
# say what it ran with afterwards.
rust_toolchain_report() {
  local cargo_path
  cargo_path="$(command -v cargo 2>/dev/null || true)"
  if [[ -z "$cargo_path" ]]; then
    # The report is stdout; a missing cargo is an error, and goes where errors go.
    echo "[rust] no cargo on PATH" >&2
    return 1
  fi
  echo "[rust] cargo: $cargo_path ($("$cargo_path" --version 2>/dev/null || echo 'version unavailable'))"
  if command -v rustup >/dev/null 2>&1; then
    local toolchain="${1:-${RUST_TOOLCHAIN:-stable}}"
    echo "[rust] rustup $toolchain: $(rustup which --toolchain "$toolchain" cargo 2>/dev/null || echo 'not installed')"
  else
    echo "[rust] rustup: not installed"
  fi
}
