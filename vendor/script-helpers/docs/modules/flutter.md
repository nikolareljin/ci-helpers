# flutter

Flutter project helpers — analyze, format, test, build, and device selection.

`flutter_resolve_sdk` exists because Flutter is routinely installed somewhere a
non-interactive shell's `PATH` does not reach: a snap, a tarball under `$HOME`,
or fvm. Consumer repos worked around that by pasting the same candidate-path loop
into every script that needed it. This is that loop, once.

Functions
---------

- `flutter_resolve_sdk`
  - Purpose: Print the path to a usable `flutter` executable, searching `PATH` first and then the conventional install locations. Does not modify `PATH` — the caller decides.
  - Env: `FLUTTER_ROOT` and `FLUTTER_HOME` are honoured when set.
  - Returns: 0 and the path; 3 with no output when none is found.

- `flutter_available`
  - Purpose: Report whether a `flutter` executable is resolvable.
  - Returns: 0 when it is; non-zero otherwise.

- `flutter_run_cmd <dir> <arg...>`
  - Purpose: Run the resolved `flutter` with `arg...` in `dir`. Every other function goes through here, so SDK resolution and the "not installed" message live in exactly one place.
  - Returns: 2 for missing arguments or a non-existent directory; 3 when Flutter is not found; otherwise Flutter's status.

- `flutter_pub_get [dir=.]`
  - Purpose: Fetch dependencies.

- `flutter_analyze [dir=.]`
  - Purpose: Run the static analyzer.

- `flutter_format_check [dir=.]`
  - Purpose: Fail when any Dart file is unformatted. Uses `--set-exit-if-changed`, which is what makes this a check rather than a rewrite.
  - Returns: 3 when Flutter is not found; otherwise `dart format`'s status.

- `flutter_test [dir=.] [--coverage]`
  - Purpose: Run the test suite, optionally with coverage.
  - Returns: 2 on an unknown option; otherwise Flutter's status.

- `flutter_build <apk|appbundle|ios|web|linux|macos|windows> [dir=.] [--release|--debug|--profile] [--flavor <name>]`
  - Purpose: Build an artifact. Defaults to `--release`, because a Flutter build with no mode flag is a debug build and that is rarely what a caller of a build function means.
  - Returns: 2 on an unknown target or option; otherwise Flutter's status.
  - Example: `flutter_build appbundle mobile --release --flavor prod`

- `flutter_devices [dir=.]`
  - Purpose: Print one `<id><TAB><name>` line per connected device. Parses `flutter devices --machine` with `jq` when available and falls back to the human-readable table when it is not, so this works on a machine without `jq`.
  - Returns: 3 when Flutter is not found; 1 when the device query fails.

- `flutter_resolve_device [preferred] [dir=.]`
  - Purpose: Print the device id to build against — `preferred` if it is connected, else `FLUTTER_DEVICE`, else the only connected device.
  - Returns: 0 and the id; 1 with a listing on stderr when the choice is ambiguous. An ambiguous device is a question for the caller, not a guess.

Environment
-----------

| Variable | Use |
|---|---|
| `FLUTTER_ROOT` | Preferred Flutter SDK location. |
| `FLUTTER_HOME` | Fallback SDK location. |
| `FLUTTER_DEVICE` | Default device id for `flutter_resolve_device`. |

Dependencies
------------

The Flutter SDK. `jq` is optional and only improves `flutter_devices` parsing.

Examples
--------

```bash
shlib_import flutter

flutter_pub_get mobile
flutter_analyze mobile
flutter_test mobile --coverage
flutter_build appbundle mobile --release

device="$(flutter_resolve_device)" && flutter_run_cmd mobile run -d "$device"
```

PowerShell
----------

`ps/lib/flutter.ps1` mirrors this module with the same function names.
`flutter_devices` returns objects with `Id` and `Name` rather than tab-separated
text, which is the PowerShell-native equivalent.
