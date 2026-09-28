# rust-crate fixture

Drives `rust.yml` and `rust-scan.yml` at their shipped defaults.

No dependencies, and `Cargo.lock` is committed: `cargo audit` reads the lock
file, and a fixture that generated one at run time would audit something
different on every run.

The crate is deliberately clippy-clean **including its tests**. That is the
point of `rust-refuses-what-it-must`: a warning placed in test code is invisible
to `cargo clippy -- -D warnings`, which is what the preset used to ship, and
fails under `--all-targets`, which is what it ships now.
