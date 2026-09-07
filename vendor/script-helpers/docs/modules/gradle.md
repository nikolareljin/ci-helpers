# gradle

A thin, predictable wrapper around the Gradle wrapper.

Kept separate from the `android` module on purpose: Gradle is also used for plain
JVM host components that have no Android SDK and no APK, and those callers should
not have to import an Android toolchain to run `test`.

Every function prefers the project's own `./gradlew` over a system `gradle`,
because the wrapper pins the Gradle version and a system `gradle` does not.

Functions
---------

- `gradle_available [dir=.]`
  - Purpose: Report whether `dir` can be built — a Gradle wrapper is present, or a system `gradle` is on `PATH`.
  - Returns: 0 when Gradle is reachable; non-zero otherwise.

- `gradle_wrapper [dir=.]`
  - Purpose: Print the Gradle command to use for `dir`.
  - Returns: 0 and the absolute path to `dir/gradlew`, or the literal `gradle`; 3 when neither is available.

- `gradle_run <dir> <task...>`
  - Purpose: Run Gradle tasks in `dir`. Adds `--no-daemon`, because a daemon left running between local checks is a surprise memory cost on a laptop.
  - Args:
    - `dir` — existing project directory.
    - `task...` — one or more Gradle task names.
  - Returns: 2 for missing arguments or a non-existent directory; 3 when no Gradle is available; otherwise Gradle's own exit status.
  - Example: `gradle_run android testDebugUnitTest`

- `gradle_lint [dir=.]`
  - Purpose: Run the `lint` task.

- `gradle_test [dir=.]`
  - Purpose: Run the `test` task.

- `gradle_assemble [dir=.] [variant=Debug]`
  - Purpose: Run `assemble<Variant>`. The variant is capitalized as Gradle expects it.
  - Example: `gradle_assemble android Release`

- `gradle_clean [dir=.]`
  - Purpose: Run the `clean` task.

Environment
-----------

No environment variables are required.

Dependencies
------------

A project Gradle wrapper, or `gradle` on `PATH`. A JDK, as Gradle requires.

PowerShell
----------

`ps/lib/gradle.ps1` mirrors this module with the same function names. On Windows
the wrapper is `gradlew.bat`, and presence is tested with `Test-Path` rather than
an executable bit, which NTFS does not have.
