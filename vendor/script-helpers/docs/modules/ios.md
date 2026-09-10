# ios

A general toolkit for **inspecting iOS devices and simulators and installing
builds** — the iOS counterpart to the [`adb`](./adb.md) module. List attached
devices and available simulators, boot/shut down simulators, install `.app`/`.ipa`
artifacts, launch apps, and build a release app or IPA with Flutter.

**macOS only.** Every function requires Apple's command-line tools (`xcrun`,
`simctl`, `xctrace`), which exist only on macOS with Xcode installed. On any
other host each function returns non-zero without stdout output, so callers
degrade cleanly. Prerequisite errors may still be written to stderr.

Provided as Bash (`lib/ios.sh`). A CI/build runner lives at `scripts/ci_ios.sh`.

CI runner
---------

Run `scripts/ci_ios.sh [--workdir <path>] [--skip-analyze] [--skip-test]
[--skip-build] [--export-plist <path>]` on a macOS host with Xcode and Flutter.
The export plist path is relative to `--workdir`. The runner exits `3` when the
Apple toolchain is unavailable, `1` for invalid arguments or a missing Flutter
executable, and otherwise propagates failures from Flutter build/test commands.

Unlike the Docker-based `ci_*.sh` wrappers (which refuse to run under `CI=true`
because they are local-only helpers), `ci_ios.sh` has no such guard: Apple's
toolchain is macOS-only, so it is meant to run both locally and in CI on a macOS
runner.

Requirements
------------

- macOS with Xcode and the command-line tools (`xcrun`, `simctl`, `xctrace`).
- `flutter` on `PATH` for `ios_build_release`.

Functions
---------

### `ios_available`

Checks for macOS and `xcrun`. It takes no arguments and returns `0` when the
Apple command-line tools are available, otherwise `1`. It produces no output.

### `ios_list_devices`

Lists attached physical iPhones and iPads as `<name> (<udid>)`, one per line.
It takes no arguments, requires `xcrun xctrace`, and returns the command status.
An empty device list is a successful empty result.

### `ios_list_simulators`

Lists available simulators as `<name> (<udid>) (<state>)`. It takes no arguments,
requires `xcrun simctl`, and returns the command status. An empty list succeeds.

### `ios_booted_simulators`

Prints one UDID per booted simulator. It takes no arguments, requires `xcrun
simctl`, and returns the command status. No booted simulators is a successful
empty result.

### `ios_boot_simulator <udid|name>`

Boots the named simulator or UDID. It returns `0` when already booted or after a
successful boot, and non-zero for missing arguments or `simctl` failures.

### `ios_shutdown_simulators`

Shuts down all booted simulators using `xcrun simctl shutdown all`. It takes no
arguments and propagates the `simctl` exit status.

### `ios_install <udid> <path.app|path.ipa>`

Installs an `.app` on a booted simulator using `simctl`, or an `.ipa` on an
attached physical device using `devicectl`. IPA installation requires Xcode 15
or newer. The `.app` artifact must be a directory and the `.ipa` artifact must
be a file; other extensions are rejected. Missing or invalid artifacts and
unavailable `devicectl` return `1`; tool installation failures are propagated.

### `ios_launch <udid> <bundle_id>`

Launches an installed simulator app using `xcrun simctl launch`. Missing
arguments return `1`; otherwise the `simctl` status is returned.

### `ios_build_release <flutter_project_dir> [export_options_plist]`

Runs `flutter pub get`, then builds a signed IPA when an export-options plist is
provided, or an unsigned iOS app otherwise. The optional plist is resolved
relative to the project directory. It requires Flutter, macOS, and Xcode and
returns non-zero for missing prerequisites, paths, or failed Flutter commands.

### `ios_resolve_device [preferred]`

Prints the simulator UDID to act on. Uses `preferred` when it is booted, else
`IOS_DEVICE`, else the only booted simulator. `preferred` may be a UDID or a
display name; a simulator that is not booted is booted first, and the result is
always resolved back to a **UDID** — `simctl install` and `simctl launch` take a
UDID (or the literal `booted`), never a display name. Returns `1` with a listing on stderr
when no simulator is booted or when more than one is — an ambiguous device is a
question for the caller rather than something to guess at, the same contract as
`flutter_resolve_device`.

### `ios_resolve_physical_device [preferred]`

Prints the UDID of an attached iPhone or iPad, accepting a UDID or a device
name and always returning a UDID. Same none/one/many discipline as
`ios_resolve_device`, but for real hardware — a signed `.ipa` installs through
`devicectl` onto a device and can never be installed on a simulator, so the two
need separate resolvers. Returns `1` when nothing is attached, when the choice
is ambiguous, or when `preferred` matches no attached device.

### `ios_bundle_id <path.app>`

Prints the `CFBundleIdentifier` of a built `.app`, read from its `Info.plist`
via `PlistBuddy` (falling back to `plutil`). `ios_launch` needs a bundle id
rather than a path, and the artifact is the only source that reflects the
flavor actually built. Returns `1` when the path is not an `.app` directory,
has no `Info.plist`, or carries no identifier.

### `ios_artifact [dir=.] [mode=simulator]`

Prints the newest matching build output, the iOS counterpart of
`android_artifact`. Modes:

- `simulator` — `build/ios/iphonesimulator/*.app`
- `device` — `build/ios/iphoneos/*.app`
- `release` / `ipa` — `build/ios/ipa/*.ipa`

Returns `1` when nothing matches and `2` for an unknown mode.

Example
-------

```bash
source helpers.sh
shlib_import ios

ios_available || { echo "not on macOS"; exit 0; }
ios_list_simulators
ios_boot_simulator "iPhone 15"
ios_build_release ./mobile ios/ExportOptions.plist

# Install and launch a debug build on a booted simulator. This is what
# `./dev deploy ios` does.
udid="$(ios_resolve_device)" || exit 1
app="$(ios_artifact ./mobile simulator)" || exit 1
ios_install "$udid" "$app"
ios_launch "$udid" "$(ios_bundle_id "$app")"
```

Note that a simulator build needs `flutter build ios --simulator`: a plain
`flutter build ios` targets a physical device and produces an `.app` that
`simctl install` cannot use.
