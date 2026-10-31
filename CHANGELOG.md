# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Menu bar app: a brightness slider in the panel, for supported monitors. It reads VCP `0x10` from the monitor and writes it when let go, after the same identity check as other writes. In Settings, **Set brightness to** under HDR on and HDR off sets a percentage with the HDR switch, after local dimming; it's unchecked by default. Setting less than 3% with the slider asks first (the screen can look completely dark), and Settings doesn't allow it.
- Several external monitors: the menu bar app's panel has a section for each (its name, HDR switch, color profile and local dimming), with the refresh button by the first name; it refreshes them all and looks for newly connected monitors. With none connected, the panel says so. Settings are kept for each monitor, by display UUID, with a **Monitor** menu at the top of the settings window when there's more than one connected; Detect Monitor runs on the monitor shown there. 0.2.1's one set of settings moves to the monitors connected at the first launch.
- `hdrctl list` shows each display's UUID, and marks the built-in one.
- Menu bar app: for trying the layout with two monitors, `open "HDR Switch.app" --args -fakeMonitor "<name>"` adds a made-up, unsupported monitor to the panel and Settings. Nothing is sent to it, its switch shows the color profile from its settings, and its settings are kept for that launch only.

### Changed

- Monitors are told apart by their display UUID, the one macOS keeps for each monitor, instead of by name: the app no longer looks only for a display named M27P6S, and `hdrctl` without `--display` uses the only external display (with several, `--display` takes part of a name or a UUID). DDC is sent over the connection of the display's own port, found in the IORegistry, so two identical monitors each get their own.
- macOS: `my_monitor.json` is gone, along with `hdrctl identify --save`. The hash of the connected monitor just has to be in `monitor_db.json` or `local_monitor_db.json`, which already kept out unknown monitors. An old `my_monitor.json` is ignored and can be deleted. Settings lists connected monitors only, and shows the local dimming levels the panel read from the monitor. The Windows port still uses the file.
- Menu bar app: Settings are saved in `settings.json` in `~/Library/Application Support/HDR Switch/`, keyed by display UUID, instead of the app's preferences. Settings from the app's preferences are moved there the first time the panel opens with a monitor connected. A new monitor starts from the defaults.
- Menu bar app: when local dimming isn't available, Settings suggests Detect Monitor.
- Menu bar app: with no external display connected, Settings says so instead of showing dimmed settings, and keeps View and Delete Detected Monitor if there's a `local_monitor_db.json`.
- Menu bar app: a refresh after the first skips the three identity reads, using the monitor's hash from the last time (kept in memory while the app runs), so it's quicker. Anything that can write to the monitor still reads its identity first.
- The README and Settings say to run the detection again after updating a monitor's firmware, since the hash may not change.
- Menu bar app: the settings window resizes whenever its content changes (e.g. choosing a monitor whose settings show a note), not only after a detection is saved or deleted.

- Menu bar app: the settings window starts with the name of the monitor its settings are for.
- Menu bar app: the settings window matches the panel: each section is a panel under its heading, with a separator between its rows; the checkboxes are on the left and the System Settings-style menus on the right (dimmed while unchecked). Settings, Detect Monitor and Detected Monitor are near white in light mode, like the panel.
- Menu bar app: the panel's HDR, Color profile and Local dimming rows are styled like System Settings > Displays: 13 pt labels, the controls on the right, a small switch for HDR (instead of a round icon), menus drawn as the value followed by up/down arrows in a gray circle (a rounded box around both while the mouse is over one), and two panels: HDR, then Color profile and Local dimming with a separator. In light mode the panel is near white with slightly gray panels on it, as in System Settings; in dark mode the panels are slightly lighter. The panel is a little wider (330 pt) so "Rec. ITU-R BT.2020-1" fits. The pointing-hand cursor and the "Toggle HDR" tooltip the round icon had are gone.

## [0.2.1] - 2026-10-26

The first release of the HDR Switch menu bar app, as a DMG (`hdrswitch-0.2.1-macos-arm64.dmg`), alongside
the CLI zip. The app and `hdrctl` now share `my_monitor.json` and `local_monitor_db.json` in
`~/Library/Application Support/HDR Switch/`. Windows is unchanged since 0.1.7-win and no new Windows
binary ships here.

### Added

- `mac/app/release.sh <version>`: builds the menu bar app and packages it as `dist/hdrswitch-<version>-macos-arm64.dmg` (with its SHA-256), holding `HDR Switch.app` next to an Applications shortcut. It sets the app's version, re-signs it, and checks it's arm64, targets macOS 12, has a valid signature and includes `monitor_db.json`. The CLI zip (`mac/release.sh`) is unchanged.
- macOS menu bar app (in progress), in `mac/app/`: a menu bar icon (`menu_icon`) that opens a Control Center–style panel with the monitor's name, an HDR toggle, the current color profile and local dimming setting, and an **Settings…** row, which opens an empty settings window. The toggle does the same as `hdrctl on` / `off`. For a monitor that isn't supported, the name gets an exclamation mark (with an explanation on hover) and the toggle leaves local dimming alone. `monitor_db.json` ships in the app; `my_monitor.json` is kept in `~/Library/Application Support/HDR Switch/`. Built with `mac/app/build.sh`; runs on macOS 12 or later.
- Menu bar app: color profile and local dimming dropdowns (installed RGB display profiles; the levels in `monitor_db.json`), applied when picked, and a refresh button that re-reads everything.
- Menu bar app settings window: for HDR on and for HDR off, **Set color profile to** and **Set local dimming to**, each a checkbox and a dropdown (installed RGB display profiles; the monitor's levels from `monitor_db.json`). The HDR toggle sets the chosen values after switching, or leaves them alone when unchecked. Defaults: BT.2020 and Standard for on, Display P3 and Off for off. Each change is saved right away, with no Confirm or Cancel; Esc closes the window. The window uses the popup's translucent background, running under a transparent title bar.
- Menu bar app: **Detect Monitor…** in Settings, the same detection as `hdrctl detect` as a window of steps with Back and Continue (Save, after a confirmation, on the last). The result is saved to `local_monitor_db.json` in Application Support, and the last step offers to contribute it on GitHub.
- Menu bar app: when Detect Monitor saves a monitor that's already in `local_monitor_db.json`, the confirmation lists what changes (e.g. `settings.local_dimming.hdr_on: standard → off`) and asks before replacing it. Other monitors in the file are always kept.
- Core: `HCMakeLocalMonitorEntry` (an entry without saving it) and `HCEntryDifferences` (readable changes between two entries).
- Menu bar app: **View Detected Monitor…** in Settings, shown when `local_monitor_db.json` exists: the detected monitors (a dropdown if there are several), each with its code, levels and HDR on/off levels, the entry's JSON, **Contribute on GitHub…** and **OK**.
- Menu bar app: **Delete Detected Monitor…** in Settings, shown with **View Detected Monitor…**: moves `local_monitor_db.json` to the Trash after a confirmation, so the shipped `monitor_db.json` applies again. `my_monitor.json` isn't touched. The settings window resizes to fit when these buttons appear or go.
- Core: `HCDetection` re-reads a code that misses a reply in a later scan (up to 5 times) instead of dropping it, so a flaky DDC reply can't hide the local dimming code; and `discardLevelsFrom:` lets a level be scanned again.
- Menu bar app: a **Quit HDR Switch** row at the bottom of the panel, below **Settings…** (with a gear icon) and a divider.
- Menu bar app: the pointer turns into a pointing hand over the HDR toggle while it can be clicked, and resting on it for a second shows a "Toggle HDR" tooltip.
- `HCSetDBPath`, `HCFindMonitorForIdentity` and `HCListProfiles` in `mac/core`, for the app.
- Menu bar app: if the monitor doesn't answer over DDC within 3 seconds (e.g. it's asleep), the panel shows a warning and local dimming is unknown.

### Changed

- macOS: `hdrctl` keeps `my_monitor.json` and `local_monitor_db.json` in `~/Library/Application Support/HDR Switch/`, the same files the menu bar app uses, instead of next to `hdrctl`. The first run moves existing ones there, unless it already has its own copy (which then wins; `hdrctl identify` points out the leftover). The shipped `monitor_db.json` stays next to `hdrctl`.
- `monitor_db.json`: the KTC M27P6S entry now maps all 5 local dimming levels (off 0, auto 1, low 4, standard 2, high 3), found with `hdrctl detect`, and sets `hdr_on` / `hdr_off` to standard / off (the same as before). It also records how it was detected in a `report` section.

## [0.1.8-mac] - 2026-10-25

A macOS-only release. Windows is unchanged since 0.1.7-win and no new Windows binary ships here;
`hdrctl detect` and `local_monitor_db.json` are macOS-only for now.

### Added

- macOS: `hdrctl detect` finds a monitor's local dimming VCP code and levels interactively. It asks how many levels the monitor's menu has and their names, scans every VCP code while the user sets each level, picks the code that changes with local dimming (asking if there's more than one), and only writes after the user confirms, setting each level back for them to check on the monitor. It also asks which levels `on` and `off` should use.
- `local_monitor_db.json`: monitors found with `hdrctl detect`, saved next to `hdrctl` with an optional `report` section (firmware shown in the monitor's menu, connection, OS). The core reads it together with `monitor_db.json`, and its entries override the shipped ones. `my_monitor.json` isn't changed. `hdrctl detect` offers to open a pre-filled GitHub issue with the entry so it can be added to `monitor_db.json`.
- `monitor_db.json` entries can set `settings.local_dimming.hdr_on` / `hdr_off`, the levels `on` and `off` use; without them, `on` and `off` use `standard` and `off` as before.

### Changed

- macOS: every DDC call gives up after 3 seconds (tracked per DDC connection), so a sleeping monitor no longer makes `hdrctl` hang. It prints `warning: the monitor didn't answer over DDC within 3 seconds (asleep?)` and fails as if the monitor gave no reply.

## [0.1.7-win] - 2026-10-25

A Windows-only release. The last Windows binary was 0.1.3, so this is the first
Windows build to include the monitor database from 0.1.4 and 0.1.6. macOS is
unchanged since 0.1.6 and no new macOS binary ships here.

### Fixed

- Windows: `ddc get` and `ddc set` accepted anything `strtol` could not parse as `0`. Because `0` is a listed local dimming level, `hdrctl ddc set 0xF4 banana` silently switched local dimming off and exited 0. Both arguments are now parsed strictly, as `parseNum` does on macOS, and report `not a number: <value>`. They are also checked before the monitor is read, so a bad argument changes nothing.
- Windows: `status` run straight after an HDR switch could report `monitor unknown`, because the identity read gave the DDC bus only ~2 s to answer while the write path allows ~10 s. The identity read now waits up to ~5 s per code.

### Notes

- The Windows side of 0.1.6 has now been built and tested on Windows 11 25H2 (build 26200) with a KTC M27P6S: the identity hash computed with BCrypt matches the macOS-generated `monitor_db.json` key exactly, and `identify`, `identify --save`, `my_monitor.json` creation, `list`, `status`, `on`, `off`, `toggle`, `hdr on|off` and `ddc dump|get|set` all behave as on macOS.
- Coming from the 0.1.3 Windows zip, this build also brings the 0.1.4 and 0.1.6 Windows changes: monitors are identified by the SHA-256 of their identity through `monitor_db.json` and `my_monitor.json` rather than hard-coded checks, the local dimming VCP code and its levels come from the database, and `hdrctl identify [--save]` is new. Keep `monitor_db.json` in the same folder as `hdrctl.exe`.
- Still only ever run on Windows 11. One x64 binary is intended to cover Windows 10 as well, since the newer HDR API is selected at runtime rather than linked at load time, and the Windows 10 path was exercised on Windows 11 with `--legacy-hdr`, but no Windows 10 machine has been tested.
- The color profile is still macOS-only.

## [0.1.6] - 2026-10-24

### Added

- `my_monitor.json` replaces the one-line `my_monitor` file on macOS and Windows. It holds one monitor, keyed by its hash, with an `identity` section. It's created from the connected monitor on first run (with an info line), and an old `my_monitor` is replaced automatically. A file whose key isn't the hash of its identity is rejected, and a mismatch names the fields that differ, e.g. `firmware_version is 1, my_monitor.json has 0`.
- `hdrctl identify --save` rewrites `my_monitor.json` for the connected monitor.
- Windows: the same monitor lookup as macOS. Before any DDC write, `hdrctl.exe` reads the monitor's six identity values, hashes them with SHA-256 (BCrypt), and requires a match with `win/my_monitor.json` and an entry in `monitor_db.json`; otherwise `on`, `off`, `toggle` and `ddc set` print `monitor unknown` and stop. The local dimming code and levels come from the database, replacing the hard-coded checks. The hash is the same as on macOS.
- Windows: `hdrctl.exe identify`, and a small JSON parser for `monitor_db.json` (no new dependencies).

### Changed

- macOS: the HDR, color profile, DDC/CI and monitor DB code moved from `mac/hdrctl.m` into `mac/core/hdrcore.m`, which returns errors instead of exiting, so a menu bar app can share it. The CLI's output and exit codes are unchanged, except that a DDC write that fails three times in a row no longer exits: during a read it counts as no reply, and during a set the read-back loop retries it.
- `monitor_db.json` moved to the repo root and is shared by both builds. `mac/build.sh` and `win/build.ps1` copy it next to the binary (the copies are gitignored), and both release scripts include it in the zip.
- The macOS files moved to `mac/`: `mac/hdrctl.m`, `mac/build.sh`, `mac/release.sh`, `mac/m27p6s-hdr.sh` and `mac/monitor_db.json`. The build writes `mac/hdrctl`, and `my_monitor.json` goes in `mac/`. The release zip layout is unchanged.
- The README and `build.sh` suggest a symlink instead of copying `hdrctl` to `/usr/local/bin`, since a copy can't find `monitor_db.json` and `my_monitor.json`.

### Notes

- This release ships the macOS binary only. The Windows changes above are in the source but haven't been built or tested on Windows yet; the 0.1.3 Windows zip is still the latest Windows build.

## [0.1.4] - 2026-10-24

### Added

- `monitor_db.json`: known monitors, keyed by the SHA-256 of their identity (EDID manufacturer, product ID and name, VCP `0xC8`, `0xC9` and the `0xF4` range max), with each monitor's local dimming VCP code and levels.
- `my_monitor`: the hash of the monitor set up on this Mac, created from `hdrctl identify`. It is per-user and not in the repo or the release zip.
- `hdrctl identify`, which prints the connected monitor's identity, its hash, and whether it is in `monitor_db.json` and matches `my_monitor`.

### Changed

- macOS: before any DDC write, the connected monitor is read and hashed, and must match `my_monitor` and an entry in `monitor_db.json`. Otherwise `on`, `off`, `toggle` and `ddc set` print `monitor unknown` and stop before changing anything. This replaces the hard-coded checks; the M27P6S passes the same six values as before.
- macOS: `on`, `off`, `toggle`, `ddc set` and `status` take the local dimming code and levels from `monitor_db.json`. `ddc set` accepts only a level listed for the monitor.
- The release zip includes `monitor_db.json`.

### Notes

- Windows is unchanged and still uses its built-in checks. The 0.1.3 Windows zip is the latest Windows build.

## [0.1.3] - 2026-10-23

### Added

- Windows 10/11 support in a new `win/` directory: `win/hdrctl.cpp`, built by `win/build.ps1` into `win/hdrctl.exe`, with the `win/m27p6s-hdr.ps1` wrapper. `on` and `off` switch HDR and the monitor's local dimming, using the same vendor VCP code `0xF4` and the same six safety checks as the macOS build.
- HDR on Windows is switched with the public display-config API, preferring `SET_HDR_STATE` on Windows 11 24H2+ and falling back to `SET_ADVANCED_COLOR_STATE` on older versions.
- `win/release.ps1`, which builds and packages `dist/hdrswitch-<version>-windows-x64.zip` with a SHA-256 checksum. It reads the PE header to check the binary is x64, is a console app, does not require a Windows newer than 10.0, and links the C runtime statically so no Visual C++ redistributable is needed.
- `--legacy-hdr`, which forces the Windows 10 advanced-color API on a newer Windows. `status` now also reports which of the two HDR APIs answered.

### Notes

- A single x64 binary covers Windows 10 and 11: the newer HDR API is selected at runtime, not linked at load time, and both paths were tested.
- The Windows build does not set the color profile yet, so `on` and `off` change HDR and local dimming only. The `profile`, `--hdr-profile` and `--sdr-profile` options are macOS-only for now.

## [0.1.2] - 2026-10-23

### Added

- Pre-built binary release for macOS 12 or later on Apple Silicon (`hdrswitch-0.1.2-macos-arm64.zip`).
- `release.sh` to build and package a release zip with a SHA-256 checksum.
- Requirements and install sections in the README, including how to clear the Gatekeeper quarantine flag.

### Changed

- `build.sh` now targets macOS 12, so `hdrctl` runs on macOS 12 or later instead of only the macOS version it was built on.

## [0.1.1] - 2026-10-23

### Added

- `hdrctl` command-line tool to switch HDR, the color profile and the monitor's local dimming in one command (`on`, `off`, `toggle`, `status`).
- Separate commands for each step: `hdr on|off`, `profile <name|path>`, and `ddc dump|get|set` for DDC/CI monitor settings.
- `list` command to show connected displays, their HDR state and current profile.
- `--display`, `--hdr-profile` and `--sdr-profile` options.
- `m27p6s-hdr.sh` wrapper with KTC M27P6S defaults, configurable through `DISPLAY_NAME`, `HDR_PROFILE` and `SDR_PROFILE`.
- Local dimming control for the KTC M27P6S through vendor VCP code `0xF4` (`0` = Off, `2` = Standard), with read-back and retry while the monitor is busy.
- Safety checks before any DDC write: EDID manufacturer, product ID and name, display controller ID, firmware version and the `0xF4` range must match the mapped monitor, or the tool exits without changing anything.
- `ddc set` limited to `0xF4` with values `0` or `2`.
- `build.sh` to build `hdrctl` with the Xcode Command Line Tools.

[Unreleased]: https://github.com/allenjia-ll/hdrswitch/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.8-mac...v0.2.1
[0.1.8-mac]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.7-win...v0.1.8-mac
[0.1.7-win]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.6...v0.1.7-win
[0.1.6]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.4...v0.1.6
[0.1.4]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/allenjia-ll/hdrswitch/releases/tag/v0.1.1
