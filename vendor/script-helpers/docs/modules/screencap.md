# screencap

Screenshots and screen video off a phone, tablet, emulator or simulator — for
README media, store listings and bug reports.

One surface, two backends, chosen by platform:

| Platform | Stills | Video |
|---|---|---|
| `android` | `adb exec-out screencap` | `adb shell screenrecord` + `adb pull` |
| `ios` | `xcrun simctl io screenshot` | `xcrun simctl io recordVideo` |

Two limits belong to the device, not to this module, and are reported rather than
hidden:

- `screenrecord` caps a single clip at **180 seconds** and records no audio.
  `screencap_record` splits longer requests into chunks and concatenates them, so
  a 300-second request produces 300 seconds rather than a silent 180. Chunking
  needs `ffmpeg`; without it a longer request is refused rather than truncated.
- A **physical iOS device cannot be recorded** without Xcode driving it. That
  returns 3 with an explanation instead of appearing to succeed.

This module depends on `adb` and `ios`, and loads both itself if the caller did
not ask for them.

Functions
---------

- `screencap_available`
  - Purpose: Report whether at least one backend can capture — `adb` with a ready device, or a booted iOS simulator.
  - Returns: 0 when capture is possible; 1 otherwise.

- `screencap_shot [--device <id>] [--platform android|ios] [--out <path>]`
  - Purpose: Capture a single PNG. With no arguments, targets the only connected device.
  - Args:
    - `--device` — adb serial or simulator UDID. Inferred when exactly one device is present.
    - `--platform` — required only when both an Android device and an iOS simulator are present.
    - `--out` — destination; defaults to `docs/screenshots/<UTC-timestamp>-<device>.png`.
  - Returns: 0 and the path written, so it can be piped into a docs step; 2 when the target is ambiguous; 3 when no device is available; 1 on a capture failure.
  - Example: `screencap_shot --device R5CRC2WANMT --out docs/img/home.png`

- `screencap_record [--device <id>] [--platform android|ios] [--out <path>] [--seconds <n>] [--size <WxH>] [--bitrate <bps>] [--gif]`
  - Purpose: Capture screen video. Defaults to 30 seconds. `--gif` also writes a `.gif` beside the video.
  - Returns: 0 and the path to the video; 2 on bad arguments or an ambiguous target; 3 when no device is available, or when a >180s Android clip is requested without `ffmpeg`, or for a physical iOS device.
  - Example: `screencap_record --seconds 20 --gif`

- `screencap_record_stop [device]`
  - Purpose: Stop an in-flight recording started outside `screencap_record`'s own timed wait. Safe to call when nothing is recording.
  - Returns: 0 always.

- `screencap_frame <video> <out.png> [--at <seconds>]`
  - Purpose: Extract a still frame from a recording, for a README image taken from a demo clip. Defaults to 1 second in, because frame zero is often a blank or transitioning screen.
  - Returns: 0 and the path written; 2 on bad arguments; 3 when `ffmpeg` is not installed; 1 on an extraction failure.

- `screencap_gif <video> <out.gif> [--fps <n>] [--width <px>]`
  - Purpose: Convert a recording to a GIF suitable for a README. Two-pass with a generated palette, because a single-pass GIF from video is visibly dithered. Defaults to 12 fps and 480px wide, which keeps a short clip under a couple of megabytes.
  - Returns: 0 and the path written; 2 on bad arguments; 3 when `ffmpeg` is not installed; 1 on a conversion failure.

Environment
-----------

| Variable | Use |
|---|---|
| `SCREENCAP_DIR` | Output directory for generated names. Defaults to `docs/screenshots`. |

Dependencies
------------

`adb` for Android. macOS with Xcode for iOS simulators. `ffmpeg` for
`screencap_frame`, `screencap_gif`, and for Android clips over 180 seconds.

Examples
--------

```bash
shlib_import screencap

# A screenshot for the README.
screencap_shot --out docs/img/home-screen.png

# A 20-second demo clip, plus a GIF for the README and a still for the store.
video="$(screencap_record --seconds 20 --gif)"
screencap_frame "$video" docs/img/hero.png --at 3
```

PowerShell
----------

`ps/lib/screencap.ps1` mirrors this module with the same function names. On
Windows only the Android backend is available, because `simctl` is macOS-only.
The Android still capture streams the process's raw stdout to the file, since a
PowerShell pipeline would corrupt the PNG.
