# m27p6s-hdr

Toggle HDR, the color profile and the monitor's local dimming of an external display (default: **M27P6S**) on macOS in one command.

| Command | HDR | Color profile | Local dimming |
|---|---|---|---|
| `on`  | on  | Rec. ITU-R BT.2020-1 | Standard |
| `off` | off | Display P3 | Off |

It runs once and exits: no background app, no daemon.

> [!WARNING]
> **Use at your own risk.** This is an unofficial tool, not affiliated with or endorsed by the monitor's manufacturer or Apple. It uses private, undocumented macOS APIs (SkyLight, IOAVService) and writes a vendor-specific monitor setting (VCP 0xF4) that was found by trial, not taken from vendor documentation. It has been tested on one M27P6S on Apple Silicon only. Safety checks limit what it writes (see [Safety checks](#safety-checks)), but they can't rule out every firmware difference. A wrong setting can usually be undone with a factory reset from the monitor's own menu. The authors accept no liability for any damage, data loss or warranty issues. See [LICENSE](LICENSE).

## Files

- `hdrctl.m`: source for the `hdrctl` command-line tool
- `build.sh`: builds `hdrctl`
- `m27p6s-hdr.sh`: wrapper that calls `hdrctl` with the M27P6S defaults
- `LICENSE`: MIT

## Build

Requires Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh
# optional: sudo cp hdrctl /usr/local/bin/
```

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
