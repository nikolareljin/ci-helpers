# android

Android build, SDK, emulator and signing utilities — the build-side counterpart
to the `adb` module, which owns everything that happens on an already-running
device.

| Module | Owns |
|---|---|
| `adb` | Devices that exist — install, logcat, push/pull, properties |
| `android` | Getting there — SDK, Gradle build, AVDs, emulators, signing |
| `gradle` | The build tool — wrapper resolution, task invocation |

This module depends on `gradle` and `adb`, and loads both itself if the caller
did not ask for them, so `shlib_import android` is sufficient on its own.

Functions
---------

- `android_sdk_root`
  - Purpose: Print the Android SDK root, honouring `ANDROID_SDK_ROOT`, then `ANDROID_HOME`, then `~/Android/Sdk` and `~/Library/Android/sdk`.
  - Returns: 0 and the path; 3 with no output when none exists.

- `android_available`
  - Purpose: Report whether an Android SDK root is resolvable.
  - Returns: 0 when it is; non-zero otherwise.

- `android_sdk_tool <name>`
  - Purpose: Print the path to an SDK tool (`sdkmanager`, `avdmanager`, `emulator`, `apksigner`, `zipalign`, `adb`), searching the SDK's several layouts and then `PATH`. Versioned `build-tools` directories are searched newest first.
  - Returns: 0 and the path; 2 for a missing argument; 3 when not found.

- `android_ensure_sdk [api=34] [build_tools=34.0.0]`
  - Purpose: Accept SDK licenses and install `platform-tools`, the platform for `api`, and the given build-tools. Idempotent — `sdkmanager` skips anything already present.
  - Returns: 3 when `sdkmanager` is not installed, since bootstrapping the bootstrapper is a deliberate human step; otherwise `sdkmanager`'s status.

- `android_gradlew <dir> <task...>`
  - Purpose: Run Gradle tasks in an Android project with `ANDROID_HOME` and `ANDROID_SDK_ROOT` exported for the build.
  - The export is the point. The Android Gradle plugin resolves the SDK from those variables or from a `local.properties` `sdk.dir`, and neither is reliably set in a plain shell — so a build that works in an IDE fails from a script with `SDK location not found`, which reads as a project fault rather than an environment one. An already-set value is respected.

- `android_build [dir=.] [debug|release] [apk|aab]`
  - Purpose: Assemble an APK or bundle an AAB. This is the one spelling of the debug/release toggle.
  - Returns: 2 on an unknown variant or format; otherwise Gradle's status.
  - Example: `android_build android release aab`

- `android_artifact [dir=.] [debug|release] [apk|aab]`
  - Purpose: Print the path to the most recently built artifact for that variant.
  - Returns: 0 and the path; 1 when none exists, so a caller can tell "not built yet" from "built and here it is".

- `android_package_name [dir=.] [artifact]`
  - Purpose: Print the application id. Read from the built artifact with `aapt2`/`aapt` when one is available, since that is the only source that accounts for `applicationIdSuffix` and product flavors; otherwise parsed out of the Gradle build file.
  - Returns: 0 and the package name; 1 when neither source works — a caller that needs a package name should say so rather than guess one.
  - Used by the `deploy` verb to feed `adb_install_verified`, which is what turns a silent work-profile install into one line of output.

- `android_sign <artifact> [--keystore <path>] [--base64-env <VAR>] [--storepass <pw>] [--alias <name>] [--keypass <pw>] [--allow-unsigned]`
  - Purpose: Sign an APK or AAB with `apksigner` when available, otherwise `jarsigner`. The keystore comes from a file, or is base64-decoded out of the named environment variable into a temp file that is removed on return.
  - Args:
    - `--base64-env VAR` — name of an environment variable holding a base64 keystore, the CI-shaped secret.
    - `--allow-unsigned` — a missing keystore becomes a warning and success rather than a failure: the debug-signed fallback that lets a local build proceed without release credentials.
  - Env: `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` supply defaults.
  - Returns: 2 on bad arguments; 3 when no signer tool is available; otherwise the signer's status.
  - Example: `android_sign app.aab --base64-env ANDROID_KEYSTORE_BASE64 --alias upload`

- `android_avd_list`
  - Purpose: Print the name of each defined AVD, one per line.
  - Returns: 3 when `avdmanager` is not available.

- `android_avd_create <name> [api=34] [abi=x86_64]`
  - Purpose: Create an AVD if it does not already exist.
  - Dependencies: The matching system image must be installed — `system-images;android-<api>;google_apis;<abi>`.
  - Returns: 2 for a missing name; 3 when `avdmanager` is not available.

- `android_emulator_start <avd> [--no-window] [--wait <seconds>]`
  - Purpose: Start an emulator in the background and wait for it to report boot completion. Prints the serial of the booted emulator.
  - Returns: 0 and the serial; 1 if it does not boot within `--wait` (default 180); 3 when the emulator binary is not available.

- `android_emulator_stop [serial]`
  - Purpose: Stop one emulator, or every running emulator when no serial is given.
  - Returns: 3 when `adb` is unavailable; 0 otherwise, including when nothing was running.

Environment
-----------

| Variable | Use |
|---|---|
| `ANDROID_SDK_ROOT` | Preferred SDK location. |
| `ANDROID_HOME` | Fallback SDK location. |
| `ANDROID_KEYSTORE_PASSWORD` | Default `--storepass` for `android_sign`. |
| `ANDROID_KEY_ALIAS` | Default `--alias` for `android_sign`. |
| `ANDROID_KEY_PASSWORD` | Default `--keypass`; falls back to the store password. |

Dependencies
------------

The Android SDK command-line tools. `apksigner` or `jarsigner` for signing. A
project Gradle wrapper for building.

Examples
--------

```bash
shlib_import android

android_ensure_sdk 34 34.0.0
android_build android release aab
android_sign "$(android_artifact android release aab)" \
  --base64-env ANDROID_KEYSTORE_BASE64 --alias upload

serial="$(android_emulator_start Pixel_10 --no-window)"
android_emulator_stop "$serial"
```

PowerShell
----------

`ps/lib/android.ps1` mirrors this module with the same function names. SDK tools
resolve through their `.bat`/`.exe` names on Windows, and `android_sign` takes
`-Keystore`, `-Base64Env` and `-AllowUnsigned` as PowerShell parameters.
