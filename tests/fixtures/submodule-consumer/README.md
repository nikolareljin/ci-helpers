# submodule fixture

`shared/script-helpers` is a git submodule pinned to script-helpers 0.31.0. The
self-test checks this repository out twice: once with `submodules: recursive`,
where `shared/script-helpers/VERSION` must exist, and once with the default,
where it must **not**. A fixture that only proved the passing direction would
stay green against an input that had stopped working.

The directory is `shared/`, not `vendor/`: `.gitignore` matches `vendor/` at any
depth, so `git submodule add` under that name is refused outright.

This is unrelated to `vendor/script-helpers` at the repository root — see the
comment in `.gitmodules`.
