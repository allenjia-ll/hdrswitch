# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/allenjia-ll/hdrswitch/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/allenjia-ll/hdrswitch/releases/tag/v0.1.1
