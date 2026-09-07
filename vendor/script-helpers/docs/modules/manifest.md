# manifest

Read and write the project version wherever a project happens to keep it.

A phone app routinely states its version in three places at once: `pubspec.yaml`
for Flutter, `versionName`/`versionCode` in a Gradle build file for the Play
Store, and a `VERSION` file for a companion host component. They drift, and a
release ships with two different numbers in it.

| Kind | File | Shape |
|---|---|---|
| `pubspec` | `pubspec.yaml` | `version: 1.2.3+45` |
| `gradle` | `build.gradle[.kts]` | `versionName "1.2.3"` / `versionCode 10203` |
| `version_file` | `VERSION` | `1.2.3` |
| `package_json` | `package.json` | `"version": "1.2.3"` |
| `pyproject` | `pyproject.toml` | `version = "1.2.3"` |

Functions
---------

- `manifest_kind <file>`
  - Purpose: Print the manifest kind for a path, based on its name.
  - Returns: 0 and the kind; 2 when the name is not one this module handles.

- `manifest_detect [dir=.]`
  - Purpose: Print one `<kind><TAB><path>` line per version manifest found, searching the directory and two levels down — an app under `mobile/` or `android/` is the common layout. Build outputs and vendored trees are skipped.
  - Returns: 0 when at least one was found; 1 when none was.

- `manifest_read_version <file>`
  - Purpose: Print the version recorded in a manifest. For a pubspec the build number after `+` is dropped, because that is a build counter and not part of the version.
  - Returns: 0 and the version; 2 for a missing or unrecognized file; 1 when no version is present.

- `manifest_android_version_code <version> [offset=0]`
  - Purpose: Print the integer Play Store `versionCode` for a semver string, as `MAJOR*10000 + MINOR*100 + PATCH` plus an optional offset.
  - Returns: 0 and the integer; 2 on a non-semver input, rather than emitting a wrong number — a wrong `versionCode` is rejected by the Play Store only after the upload. Warns when minor or patch reaches 100, at which point the mapping stops being monotonic.
  - Example: `manifest_android_version_code 2.11.7` prints `21107`.

- `manifest_write_version <file> <version> [--build <n>]`
  - Purpose: Set the version in a manifest, in place.
  - Args:
    - `--build` — for `gradle`, overrides the computed `versionCode`; for `pubspec`, sets the `+n` suffix. An existing pubspec suffix is preserved when this is not given.
  - Returns: 0 on success; 2 for a missing file or a non-semver version; 1 when the rewrite would produce an empty file, which is refused rather than written.
  - Note: Writes via a temp file, so an interrupted write cannot leave a half-rewritten build file behind.

- `manifest_sync_version <dir> <version> [--build <n>]`
  - Purpose: Write `version` into every manifest under `dir`. This is the "one release, one number" operation.
  - Returns: 0 when every manifest was written; non-zero if any failed, after attempting all of them — a partial sync is reported, not hidden.

Environment
-----------

No environment variables are required.

Dependencies
------------

None beyond coreutils.

Examples
--------

```bash
shlib_import manifest

manifest_detect .
# gradle	./android/app/build.gradle
# pubspec	./pubspec.yaml
# version_file	./VERSION

manifest_sync_version . 2.0.0
# pubspec keeps its +45 build number; versionCode becomes 20000
```

PowerShell
----------

`ps/lib/manifest.ps1` mirrors this module with the same function names.
`manifest_detect` returns objects with `Kind` and `Path` rather than
tab-separated text.
