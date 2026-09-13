# rust

Which Rust toolchain a gate compiles with.

CI installs Rust through `dtolnay/rust-toolchain@stable` — rustup's stable. A
workstation frequently also carries a distribution cargo, and on many
distributions it comes first on `PATH` and is considerably older.

That matters more than it sounds, because the failure does not name the cause:

```
error: lock file version 4 requires `-Znext-lockfile-bump`
error: failed to download `time-core v0.1.9`
feature `edition2024` is required
```

Both read as a broken lockfile. Someone chases the dependency tree while the
compiler is the problem. Worse, a local gate that says *"this is what CI would
have run"* is then saying something false — which is a gate doing harm rather
than nothing.

The same shape has bitten this fleet twice elsewhere: a snap Flutter resolving
`.dart_tool` for a project the dev SDK was building, and a distribution cargo
that could not resolve a Tauri dependency tree at all.

Written for bash 3.2: no namerefs, no associative arrays, no `${var,,}`.

Functions
---------

- `rust_toolchain_ci_uses [toolchain]`
  - Purpose: Put the named rustup toolchain's cargo first on `PATH` and export it, so a gate runs the toolchain CI runs.
  - The toolchain defaults to `RUST_TOOLCHAIN`, then `stable` — what `dtolnay/rust-toolchain@stable` installs. It is asked for **by name**: a bare `rustup which cargo` follows the developer's default or a directory override, which may be nightly, and that reopens the gap from the other side.
  - Says so when the resolved cargo differs from what `PATH` offered, naming both versions — a silent switch is its own surprise.
  - Quiet when `PATH` already offers the right one.
  - Returns: 0 on success; non-zero with an actionable message when rustup is absent or has no usable cargo. It never falls back to the older cargo silently — that would recreate the problem it exists to prevent.

- `rust_toolchain_report [toolchain]`
  - Purpose: Print which cargo would be used and what rustup offers for the named toolchain (same default), **without changing `PATH`**.
  - For a status verb, or for a gate that wants to record what it ran with.
  - Returns: 0 when a cargo is on `PATH`; non-zero when none is.

Usage
-----

```bash
source helpers.sh
shlib_import rust

rust_toolchain_ci_uses || exit 1
cargo check
```

`scripts/local_test_rust.sh` does this by default; set `RUST_TOOLCHAIN` to pin a
channel or version. Pass `--any-cargo` to opt out, for a repository that
genuinely targets the system toolchain.

`scripts/preflight.sh` inherits the requirement and cannot forward the flag, so
it skips a Rust project when rustup is absent — `cargo` on `PATH` is not the
precondition this gate actually has. `PREFLIGHT_RUST_ANY_CARGO=true` turns that
skip into a real check against `PATH`'s cargo.
