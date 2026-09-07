# adb

A general toolkit for **inspecting and debugging Android devices** over USB via
the Android Debug Bridge (`adb`): list devices with their OS/API/IP, install
APKs, copy files to/from a device, run shell commands, and read logcat/status.

Everything is **multi-device safe** — functions target a device with
`adb -s <serial>` rather than a bare `adb shell`, which errors with *more than one
device* once a second device is attached. Every function no-ops when `adb` is
missing — the Bash functions return non-zero, the PowerShell functions return
`$false` / `$null` / nothing — so callers degrade cleanly.

Available in both Bash (`lib/adb.sh`) and PowerShell (`ps/lib/adb.ps1`) with the
same function names. A ready-to-use CLI wrapper lives at `scripts/adb_tool.sh`.

Requirements
------------

- `adb` (Android platform-tools) on `PATH`.

Functions
---------

Discovery
- `adb_available` — 0 if `adb` is on `PATH`.
- `adb_ready_serials` — serials of *ready* devices, one per line (skips header +
  offline/unauthorized).

Device info
- `adb_getprop <serial> <prop>` — read a system property.
- `adb_device_model <serial>` — `ro.product.model`.
- `adb_android_version <serial>` — Android OS release (e.g. `9`).
- `adb_device_api <serial>` — supported API / SDK level (e.g. `28`).
- `adb_device_ip <serial> [iface=wlan0]` — IPv4 on an interface (Wi-Fi by default;
  pass e.g. `rmnet_data0` for cellular).
- `adb_list_devices [iface=wlan0]` — a `SERIAL  MODEL  ANDROID  API  IP` table for
  every ready device.

Shell / debugging
- `adb_shell <serial> <cmd...>` — run a shell command on a device.
- `adb_logcat <serial> [regex]` — dump the logcat buffer (`-d`), optionally
  filtered to lines matching `regex`. For a live tail use `adb -s <serial> logcat`.
- `adb_clear_logcat <serial>` — clear the logcat buffer.

File transfer
- `adb_push <serial> <local> <remote>` — copy a file/dir **to** the device.
- `adb_pull <serial> <remote> [local=.]` — copy a file/dir **from** the device.

Apps
- `adb_install <serial> <apk> [--user <id>] [adb install args...]` — (re)install
  an APK (`-r`). `--user` defaults to `0`, the device owner, and is passed
  through to adb. Returns 2 when it is not a number.
- `adb_installed_for_user <serial> <package> [user=0]` — is the package visible
  to that user? Returns 0 yes, 1 no, 3 when the shell may not query that user at
  all, printing `pm list users` to stderr.
- `adb_install_verified <serial> <apk> <package> [--user <id>] [args...]` —
  install, then confirm it landed. Returns 0 only when both hold; 4 when the
  install reported success but the package is not visible to the target user.
- `adb_install_all <apk> [adb install args...]` — install to **every** ready
  device; continues past failures, returns non-zero if any failed.
- `adb_uninstall <serial> <package>` — uninstall an app package.

### Why `--user` is pinned, and why the check exists

An unqualified `adb install` can land a package in a profile the shell cannot
subsequently read. On a device with a work profile or Samsung Secure Folder:

```
$ adb install -r app-debug.apk
Success
$ adb shell pm list packages | grep myapp
Error: java.lang.SecurityException: Shell does not have permission to
access user 150
```

The app is then absent from the launcher, cannot be started by `am start`, and
`pm list packages --user 0` does not list it — while the deploy script has
already reported success and exited zero. Every signal says the install worked,
so the symptom reads as an app fault rather than a deploy fault.

Pinning `--user` prevents the common case. Verifying afterwards prevents the
class, which is why `adb_install_verified` exists and why a deploy path should
call it rather than `adb_install`. An installer's exit code asserts that adb
accepted the command, not that the app is usable.

Status
- `adb_battery_level <serial>` — battery percent (0–100).
- `adb_screen_on <serial>` — 0 = on, 1 = off, 2 = unknown.
- `adb_device_status <serial>` — a status block: model, Android + API, battery,
  screen, Wi-Fi IP.

CLI — `scripts/adb_tool.sh`
---------------------------

A thin dispatcher so the helpers are usable straight from the shell:

```bash
scripts/adb_tool.sh list                       # serial, model, OS, API, IP
scripts/adb_tool.sh status <serial>
scripts/adb_tool.sh install <serial> app.apk
scripts/adb_tool.sh install-all app.apk        # all attached devices
scripts/adb_tool.sh push <serial> ./f /sdcard/f
scripts/adb_tool.sh pull <serial> /sdcard/f ./f
scripts/adb_tool.sh logcat <serial> 'MyTag|crash'
scripts/adb_tool.sh --help
```

Examples (library)
------------------

```bash
source helpers.sh
shlib_import adb

adb_list_devices                                  # table of attached phones

for s in $(adb_ready_serials); do
  echo "$(adb_device_model "$s") — Android $(adb_android_version "$s") (API $(adb_device_api "$s")) @ $(adb_device_ip "$s")"
done

adb_install_all ./app-debug.apk                   # roll out a build everywhere
```

```powershell
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers adb
adb_list_devices | Format-Table -AutoSize
adb_device_status (adb_ready_serials | Select-Object -First 1)
```

## Wireless adb (adb over Wi-Fi)

Address comes from **`DEV_DEVICE`** — the dev-cli convention (`templates/dev-cli`)
for which device, and what `--device` sets. For a wireless device the id *is*
`ip:port`, so one variable covers both "which device" and "where to connect".
A USB serial there has no colon and is correctly not treated as an address.
`ANDROID_DEVICE_IP` / `ANDROID_DEVICE_PORT` remain supported as an explicit split
form. `load_env` (`lib/env.sh`) puts them in scope from a project's gitignored
`.env`.

```bash
shlib_import adb env
load_env .env

# Attach before an Android command. Safe to call every time — it returns 0 when
# the device is already attached. If it cannot connect, show the recovery hint
# and preserve the failure for callers running with `set -e`.
adb_wireless_connect || { adb_wireless_recovery_hint; exit 1; }

adb_wireless_addr            # -> 203.0.113.10:5555
adb_wireless_attached "$(adb_wireless_addr)"
adb_wireless_disconnect
```

First-time handover, with the phone on USB. `adb_wireless_setup` reads the
device's Wi-Fi address, switches it to tcpip, connects, and prints the address
so it can be stored:

```bash
addr="$(adb_wireless_setup)" \
  && adb_wireless_write_env .env "${addr%:*}" "${addr##*:}"
```

| function | notes |
|---|---|
| `adb_wireless_addr` | `DEV_DEVICE` first, else `ANDROID_DEVICE_IP`/`_PORT`; port defaults to `5555` |
| `adb_wireless_attached <addr>` | state column must be exactly `device` — `offline` and `unauthorized` are not attached |
| `adb_wireless_connect [addr]` | confirms against `adb devices`; `adb connect` exits 0 on a bare TCP handshake and cannot be trusted |
| `adb_wireless_disconnect [addr]` | always returns 0 |
| `adb_wireless_enable <serial> [port]` | `adb tcpip` on a USB device — the step that needs the cable |
| `adb_wireless_setup [serial] [port] [iface]` | discover + enable + connect; prints `ip:port` |
| `adb_wireless_write_env <file> <ip> [port]` | upserts `DEV_DEVICE`, leaving the rest of the file alone |
| `adb_wireless_recovery_hint [port]` | what to do after a reboot drops tcpip mode |
| `adb_wireless_valid_host <value>` | true for an IPv4 address or hostname |
| `adb_wireless_valid_port <value>` | true for 1–65535 |

`adb_wireless_write_env` validates with `adb_wireless_valid_host` and
`adb_wireless_valid_port` before writing, and both are public so a caller can
fail earlier with its own message. This is a security boundary: an env file is
**sourced** by whatever reads it, so a newline in the value injects an extra
line that then executes. The value is not always hand-typed — `adb_wireless_setup`
takes it from `adb shell ip ...`, i.e. from whatever the attached device prints.

**tcpip mode does not survive a reboot**, and Android 11+ "Wireless debugging"
uses a **random port per session**. Both failures look like a wrong address, so
`adb_wireless_recovery_hint` exists to say so at the point of failure.

**Keep the address out of tracked files.** `scripts/check_no_private_ips.sh`
fails on any RFC 1918 literal in the git index; run it from a project's own test
gate.
