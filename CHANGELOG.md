# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Windows: the same monitor lookup as macOS. Before any DDC write, `hdrctl.exe` reads the monitor's six identity values, hashes them with SHA-256 (BCrypt), and requires a match with `win/my_monitor` and an entry in `monitor_db.json`; otherwise `on`, `off`, `toggle` and `ddc set` print `monitor unknown` and stop. The local dimming code and levels come from the database, replacing the hard-coded checks. The hash is the same as on macOS.
- Windows: `hdrctl.exe identify`, and a small JSON parser for `monitor_db.json` (no new dependencies).

### Changed

- `monitor_db.json` moved to the repo root and is shared by both builds. `mac/build.sh` and `win/build.ps1` copy it next to the binary (the copies are gitignored), and both release scripts include it in the zip.
- The macOS files moved to `mac/`: `mac/hdrctl.m`, `mac/build.sh`, `mac/release.sh`, `mac/m27p6s-hdr.sh` and `mac/monitor_db.json`. The build writes `mac/hdrctl`, and `my_monitor` goes in `mac/`. The release zip layout is unchanged.
- The README and `build.sh` suggest a symlink instead of copying `hdrctl` to `/usr/local/bin`, since a copy can't find `monitor_db.json` and `my_monitor`.

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

[Unreleased]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/allenjia-ll/hdrswitch/releases/tag/v0.1.1
