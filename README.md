# HDR Switch

Toggle HDR, the color profile and the monitor's local dimming of an external display (default: **M27P6S**) on macOS in one command.

| Command | HDR | Color profile | Local dimming |
|---|---|---|---|
| `on`  | on  | Rec. ITU-R BT.2020-1 | Standard |
| `off` | off | Display P3 | Off |

It runs once and exits: no background app, no daemon.

> [!WARNING]
> **Use at your own risk.** This is an unofficial tool, not affiliated with or endorsed by the monitor's manufacturer or Apple. It uses private, undocumented macOS APIs (SkyLight, IOAVService) and writes a vendor-specific monitor setting (VCP 0xF4) that was found by trial, not taken from vendor documentation. It has been tested on one M27P6S on Apple Silicon only. Safety checks limit what it writes (see [Safety checks](#safety-checks)), but they can't rule out every firmware difference. A wrong setting can usually be undone with a factory reset from the monitor's own menu. The authors accept no liability for any damage, data loss or warranty issues. See [LICENSE](LICENSE).

## Supported monitors

- **Local dimming** is currently supported only on the **KTC M27P6S**. It uses a vendor-specific setting, and the tool checks the monitor's identity before writing it (see [Safety checks](#safety-checks)).
- **HDR switching and color profile selection** use macOS settings, not monitor settings, so they work on any display macOS supports them on. HDR needs a display that macOS reports as HDR-capable.

On other monitors, use the separate commands, since `on`, `off` and `toggle` include the M27P6S local dimming step and stop before changing anything if the monitor isn't an M27P6S:

```sh
hdrctl --display "<part of display name>" hdr on
hdrctl --display "<part of display name>" profile "Rec. ITU-R BT.2020-1"
```

Run `hdrctl list` to see display names.

## Files

- `hdrctl.m`: source for the `hdrctl` command-line tool
- `build.sh`: builds `hdrctl`
- `release.sh`: builds and packages a binary release zip
- `m27p6s-hdr.sh`: wrapper that calls `hdrctl` with the M27P6S defaults
- `CHANGELOG.md`: release history
- `LICENSE`: MIT

## Requirements

- Apple Silicon Mac (local dimming uses IOAVService, which isn't available on Intel Macs)
- macOS 12 Monterey or later (tested on macOS 27 only)
- Xcode Command Line Tools, only to build from source (`xcode-select --install`)

## Install

### Pre-built binary

Download `hdrswitch-<version>-macos-arm64.zip` from [Releases](https://github.com/allenjia-ll/hdrswitch/releases) and unzip it. It contains `hdrctl`, `m27p6s-hdr.sh`, this README, the changelog and the license.

The binary isn't notarized by Apple, so macOS blocks it the first time if the zip was downloaded in a browser. Remove the quarantine flag once, in the unzipped folder:

```sh
xattr -dr com.apple.quarantine .
```

### Build from source

```sh
./build.sh
# optional: sudo cp hdrctl /usr/local/bin/
```

### Make a release

```sh
./release.sh 0.1.2    # writes dist/hdrswitch-0.1.2-macos-arm64.zip and its SHA-256
```

The version must have a section in `CHANGELOG.md`. The script checks that the binary is arm64 and targets macOS 12.

## Usage

```sh
./m27p6s-hdr.sh on        # HDR on  + BT.2020    + local dimming Standard
./m27p6s-hdr.sh off       # HDR off + Display P3 + local dimming Off
./m27p6s-hdr.sh toggle    # flip between on and off
./m27p6s-hdr.sh status    # show HDR state, current profile and local dimming (default)
```

Or call `hdrctl` directly:

```
hdrctl list                      list displays, HDR state and current profile
hdrctl status                    HDR state + profile + local dimming of the target display
hdrctl on                        HDR on  + HDR profile + local dimming Standard
hdrctl off                       HDR off + SDR profile + local dimming Off
hdrctl toggle                    flip between on/off
hdrctl hdr on|off                HDR only
hdrctl profile <name|path>       color profile only
hdrctl ddc dump                  read all monitor settings (DDC/CI VCP codes)
hdrctl ddc get <code>            read one VCP code, e.g. 0xF4
hdrctl ddc set 0xF4 0|2          local dimming Off|Standard (the only DDC write allowed)

Options:
  --display <text>       part of the display name        (default: M27P6S)
  --hdr-profile <spec>   profile used by "on"            (default: "Rec. ITU-R BT.2020-1")
  --sdr-profile <spec>   profile used by "off"           (default: "Display P3")
```

A profile `<spec>` is either a path to an `.icc`/`.icm` file or (part of) the profile's name as shown in System Settings > Displays > Color profile. Profiles are searched in `~/Library`, `/Library` and `/System/Library` `ColorSync/Profiles`.

### Environment variables (wrapper only)

| Variable | Default |
|---|---|
| `DISPLAY_NAME` | `M27P6S` |
| `HDR_PROFILE`  | `Rec. ITU-R BT.2020-1` |
| `SDR_PROFILE`  | `Display P3` |

Example, using your own calibrated SDR profile:

```sh
SDR_PROFILE=~/Library/ColorSync/Profiles/M27P6S.icc ./m27p6s-hdr.sh off
```

## How it works

- **HDR** is switched through SkyLight (`SLSDisplaySetHDRModeEnabled`), a private macOS framework (macOS 11+) loaded at runtime. A future macOS update could remove or change it.
- **Color profile** is set with the public ColorSync API (`ColorSyncDeviceSetCustomProfiles`), the same setting as System Settings > Displays > Color profile. It applies to the current user.
- **Local dimming** is a monitor setting, changed over DDC/CI with IOAVService (private IOKit API, Apple Silicon only). On the M27P6S it is vendor VCP code `0xF4`: `0` = Off, `2` = Standard. This was found by dumping all codes, changing local dimming in the monitor's menu, and diffing. Other models will likely use a different code.
- The profile and DDC connection are resolved before HDR is switched, so a bad profile name or missing monitor fails without changing anything. After switching HDR, the tool waits for the display to settle, applies the profile, then sets local dimming.
- Before any DDC write (`on`, `off`, `toggle`, `ddc set`), the tool checks that this is the same monitor and firmware 0xF4 was mapped on, and **stops without changing anything** if not (see [Safety checks](#safety-checks)).
- The monitor silently drops DDC writes while busy (especially just after an HDR switch), so local dimming is written, read back, and retried for up to ~10 seconds.

## Safety checks

0xF4 is a vendor code, so on another model or firmware it may mean something else. Before writing it, the tool requires all of these to match the values recorded from this monitor (2026-10-23):

| Check | Expected |
|---|---|
| EDID manufacturer | `SKG` |
| EDID product ID | `10158` |
| EDID product name | `M27P6S` |
| Display controller ID (VCP 0xC8) | `22021` |
| Firmware version (VCP 0xC9) | `0` |
| Local dimming range max (VCP 0xF4) | `5` |

If any check fails or can't be read, it prints a warning and exits with status 1 **before** switching HDR or the profile. The firmware can't be hashed over DDC/CI. VCP 0xC9 is the only version the monitor reports, and this vendor may leave it at 0, so a firmware update could go unnoticed. After updating the monitor's firmware, redo the mapping: `hdrctl ddc dump` with local dimming Off, change it to Standard in the monitor's menu, dump again, diff. Then update the values in `verifyMonitor` and the `kVCP...` constants in `hdrctl.m`.

`ddc set` is limited to `0xF4` with `0` or `2`. Everything else is refused, because other codes can factory-reset the monitor, change input or power, or hit vendor service settings. `ddc get` and `ddc dump` only read and are safe.

Each change sends one 6-byte DDC "set" for VCP 0xF4 only, never a table of settings. The monitor's firmware decides how it saves that. If local dimming is already at the target value the write is skipped, since reads don't wear the monitor's memory. If the read gets no reply, it writes anyway. A real change usually takes 1–2 writes, up to 10 when the monitor is busy. Switching a few times a day is fine, but don't run it in a tight loop.

## Troubleshooting

- **`no connected display matches "M27P6S"`**: the monitor isn't connected to this Mac (or a KVM/switch has it on another input). Run `hdrctl list` to see display names.
- **`warning: couldn't verify the monitor (DDC busy? ...)`**: a check got no reply. Nothing was changed; rerun, or quit MonitorControl.
- **`warning: monitor doesn't match ...`**: a check returned a different value (other monitor, or new firmware). Nothing was changed. See [Safety checks](#safety-checks).
- **`warning: couldn't confirm local dimming ...`**: the DDC bus is shared, and other DDC apps such as MonitorControl can garble replies. Quit them and rerun, or check the monitor's menu. `hdrctl ddc get 0xF4` shows the current value (it may need a couple of tries).
- **Wrong profile applied**: check `env | grep _PROFILE` for overrides, and `which -a hdrctl` for an older copy on your PATH.

## License

[MIT](LICENSE)
