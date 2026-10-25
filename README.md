# HDR Switch

Toggle HDR, the color profile and the monitor's local dimming of an external display (default: **M27P6S**) in one command, on macOS and Windows 10/11.

| Command | HDR | Color profile | Local dimming |
|---|---|---|---|
| `on`  | on  | Rec. ITU-R BT.2020-1 | Standard |
| `off` | off | Display P3 | Off |

On Windows the color profile isn't changed yet; `on` and `off` do HDR and local dimming only.

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

### Add your monitor (macOS)

If your monitor has local dimming that you can change in its own menu, `hdrctl detect` can find out how to control it over DDC/CI:

```sh
hdrctl --display "<part of display name>" detect
```

It asks how many local dimming levels the monitor's menu has and what they're called, then asks you to set each one in the menu while it reads every VCP code (about a minute for the first level, less for the rest). The code that changes with local dimming, and only that code, is the one it uses. Until then it only reads. After you confirm, it writes each level back so you can check it on the monitor, then asks which levels `on` and `off` should use. The result is saved to `local_monitor_db.json` next to `hdrctl` (it overrides the shipped `monitor_db.json` entry for the same monitor), and it offers to open a pre-filled GitHub issue so the monitor can be added for everyone. `my_monitor.json` isn't changed. Quit MonitorControl and other DDC apps first, and keep the monitor awake.

On Windows the same applies, except that there is no `profile` command yet, so only the HDR step is available for other monitors:

```powershell
hdrctl.exe --display "<part of display name>" hdr on
```

## Files

macOS:

- `mac/hdrctl.m`: the `hdrctl` command line (arguments, output, exit codes)
- `mac/core/hdrcore.h`, `mac/core/hdrcore.m`: HDR, color profile, DDC/CI and monitor DB code, shared by the CLI and the menu bar app
- `mac/app/`: the menu bar app (in progress): `Sources/*.swift` (`Settings.swift` holds the settings window), `Info.plist`, `Resources/menu_icon*.png`, and `build.sh`, which builds `mac/app/build/HDR Switch.app`
- `mac/build.sh`: builds `mac/hdrctl`
- `mac/release.sh`: builds and packages a binary release zip
- `mac/m27p6s-hdr.sh`: wrapper that calls `hdrctl` with the M27P6S defaults
- `mac/my_monitor.json`: your monitor, created on first run, not in the repo (see [Set up your monitor](#set-up-your-monitor-macos))

Windows:

- `win/hdrctl.cpp`: source for the `hdrctl.exe` command-line tool
- `win/build.ps1`: builds `win/hdrctl.exe`
- `win/release.ps1`: builds and packages a binary release zip
- `win/m27p6s-hdr.ps1`: wrapper that calls `hdrctl.exe` with the M27P6S defaults
- `win/my_monitor.json`: your monitor, created on first run, not in the repo (see [Set up your monitor](#set-up-your-monitor-windows))

Both:

- `monitor_db.json`: known monitors and their local dimming settings (see [Safety checks](#safety-checks)). The build scripts copy it next to `mac/hdrctl` and `win/hdrctl.exe`; edit the one at the root.
- `local_monitor_db.json`: monitors detected on this computer with `hdrctl detect` (macOS), next to `hdrctl`; not in the repo
- `CHANGELOG.md`: release history
- `LICENSE`: MIT

## Requirements

### macOS

- Apple Silicon Mac (local dimming uses IOAVService, which isn't available on Intel Macs)
- macOS 12 Monterey or later (tested on macOS 27 only)
- Xcode Command Line Tools, only to build from source (`xcode-select --install`)

### Windows

- Windows 10 1709 or later, or Windows 11 (tested on Windows 11 25H2, build 26200, only)
- A GPU driver that passes DDC/CI through, which is standard on AMD, Intel and NVIDIA desktop drivers
- Visual Studio 2017 or later (or the standalone Build Tools) with the **Desktop development with C++** workload, only to build from source
- No administrator rights needed, for either building or running

## Install

### Pre-built binary

Download `hdrswitch-<version>-macos-arm64.zip` from [Releases](https://github.com/allenjia-ll/hdrswitch/releases) and unzip it. It contains `hdrctl`, `m27p6s-hdr.sh`, `monitor_db.json`, this README, the changelog and the license.

The binary isn't notarized by Apple, so macOS blocks it the first time if the zip was downloaded in a browser. Remove the quarantine flag once, in the unzipped folder:

```sh
xattr -dr com.apple.quarantine .
```

On Windows, download `hdrswitch-<version>-windows-x64.zip` and unzip it. It
contains `hdrctl.exe`, `m27p6s-hdr.ps1`, `monitor_db.json`, this README, the
changelog and the license. The exe links the C runtime statically, so no Visual C++
redistributable is needed.

The exe isn't code-signed, so SmartScreen may warn the first time it runs if
the zip was downloaded in a browser. Either choose **More info > Run anyway**,
or clear the mark-of-the-web first, in the unzipped folder:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

### Set up your monitor (macOS)

`hdrctl` remembers your monitor in `my_monitor.json`, next to `hdrctl`. You don't need to create it: the first command that reads the monitor (`status`, `identify`, `on`, `off`, `toggle` or `ddc set`) creates it from the connected monitor and prints a line like:

```
Created /path/to/my_monitor.json for M27P6S (5e482ea7…)
```

The file holds one monitor, keyed by its hash, with the identity values the hash was made from:

```json
{
  "5e482ea7b8352801d0f5e03a99b00a6d28c0f4324052af01cff9e6f5d3002008": {
    "identity": {
      "manufacturer": "SKG",
      "product_id": 10158,
      "product_name": "M27P6S",
      "display_controller_id": 22021,
      "firmware_version": 0,
      "local_dimming_range_max": 5
    }
  }
}
```

To check it, or to switch to the monitor that's connected now:

```sh
./hdrctl identify          # should say "listed" and "matches"
./hdrctl identify --save   # rewrite my_monitor.json for the connected monitor
```

An old one-line `my_monitor` file from 0.1.4 is replaced by `my_monitor.json` automatically. If `hdrctl` is copied to another folder, copy `monitor_db.json` and `my_monitor.json` with it. A symlink to `hdrctl` works, since the files are looked up next to the real binary.

### Set up your monitor (Windows)

The same as on macOS: `win\my_monitor.json` (or the one in the unzipped release folder) is created on first run, and these check or rewrite it:

```powershell
.\hdrctl.exe identify          # should say "listed" and "matches"
.\hdrctl.exe identify --save   # rewrite my_monitor.json for the connected monitor
```

The hash is the same on both platforms, so a `my_monitor.json` from a Mac also works on Windows.

### Build from source (macOS)

```sh
mac/build.sh          # writes mac/hdrctl
# optional: sudo ln -s "$PWD/mac/hdrctl" /usr/local/bin/hdrctl
```

The build writes `mac/hdrctl` next to the source, `monitor_db.json` and `my_monitor.json`. A symlink keeps it able to find them; a copy needs both files copied with it.

### Build the menu bar app (macOS, in progress)

```sh
mac/app/build.sh                              # writes mac/app/build/HDR Switch.app
open "mac/app/build/HDR Switch.app"
```

The app lives in the menu bar only (no Dock icon). Clicking its icon opens a panel with the monitor's name, a refresh button, an HDR toggle, and dropdowns for the color profile (the installed RGB display profiles; a pick applies right away) and local dimming (the levels in `monitor_db.json`); **Settings…** opens the settings window. Refresh re-reads everything over a new DDC connection. The toggle does the same as `hdrctl on` / `off`: HDR, then the color profile, then local dimming. In Settings, "When HDR is turned on" and "When HDR is turned off" each have **Set color profile to** and **Set local dimming to**, each a checkbox and a dropdown: checked, the toggle sets that value after switching; unchecked, it leaves it alone. The local dimming levels come from `monitor_db.json` for the monitor in `my_monitor.json`. The defaults are what `hdrctl` does: BT.2020 and Standard for on, Display P3 and Off for off. **Confirm** saves the settings (per user), **Cancel** discards the edits. If the monitor isn't supported (not in `monitor_db.json`, or not the one in `my_monitor.json`), its name gets an exclamation mark, and the toggle switches HDR and the color profile only, leaving local dimming alone. If the monitor doesn't answer over DDC within 3 seconds (e.g. it's asleep), the panel shows a warning and local dimming is unknown. The app ships `monitor_db.json` inside `HDR Switch.app` and keeps `my_monitor.json` in `~/Library/Application Support/HDR Switch/`, created on first use. It also reads a `local_monitor_db.json` there (for example one from `hdrctl detect`, copied over), whose entries override the shipped ones. To quit it, choose **Quit HDR Switch** at the bottom of the panel (or `pkill -x HDRSwitch`). It's Swift (SwiftUI inside an AppKit status item, so it runs on macOS 12) built with `swiftc`; no Xcode project is needed, and it uses the same `mac/core` as the CLI.

### Build from source (Windows)

```powershell
.\win\build.ps1
```

`build.ps1` finds the MSVC toolset with `vswhere`, so it works from any shell;
it doesn't have to be a Developer Command Prompt. Both Windows scripts resolve
paths relative to themselves, so they can be run from any working directory;
the build writes `win/hdrctl.exe` next to the source. To run the scripts in a
fresh PowerShell install you may need to allow local scripts once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### Make a release

```sh
mac/release.sh 0.1.2    # writes dist/hdrswitch-0.1.2-macos-arm64.zip and its SHA-256
```

On Windows:

```powershell
.\win\release.ps1 0.1.3   # writes dist/hdrswitch-0.1.3-windows-x64.zip and its SHA-256
```

Both scripts write to `dist/` in the repository root, and both require the
version to have a section in `CHANGELOG.md`. The macOS script checks that the
binary is arm64 and targets macOS 12. The Windows script reads the PE header
and checks that the binary is x64, is a console app, does not require a
Windows newer than 10.0, and links the C runtime statically so no
redistributable is needed.

## Usage

### macOS

Run these in the unzipped release folder, or in `mac/` in a source checkout.

```sh
./m27p6s-hdr.sh on        # HDR on  + BT.2020    + local dimming Standard
./m27p6s-hdr.sh off       # HDR off + Display P3 + local dimming Off
./m27p6s-hdr.sh toggle    # flip between on and off
./m27p6s-hdr.sh status    # show HDR state, current profile and local dimming (default)
```

### Windows

```powershell
.\win\m27p6s-hdr.ps1 on       # HDR on  + local dimming Standard
.\win\m27p6s-hdr.ps1 off      # HDR off + local dimming Off
.\win\m27p6s-hdr.ps1 toggle   # flip between on and off
.\win\m27p6s-hdr.ps1 status   # show HDR state and local dimming (default)
```

The Windows build takes the same subcommands as the macOS one, minus the
color-profile ones (`profile`, `--hdr-profile`, `--sdr-profile`), which aren't
implemented yet. The commands below are written as plain `hdrctl.exe`; from the
repository root that is `.\win\hdrctl.exe`, or copy the exe somewhere on your
`PATH`:

```
hdrctl.exe list                  list displays, EDID and HDR state
hdrctl.exe status                HDR state + local dimming of the target display
hdrctl.exe on                    HDR on  + local dimming Standard
hdrctl.exe off                   HDR off + local dimming Off
hdrctl.exe toggle                flip between on/off
hdrctl.exe hdr on|off            HDR only
hdrctl.exe ddc dump              read all monitor settings (DDC/CI VCP codes)
hdrctl.exe ddc get <code>        read one VCP code, e.g. 0xF4
hdrctl.exe ddc set <code> <value> local dimming level listed in monitor_db.json (the only DDC write allowed)
hdrctl.exe identify              print the monitor's identity and hash

Options:
  --display <text>       part of the display name        (default: M27P6S)
  --legacy-hdr           use the Windows 10 advanced-color API, not the
                         Windows 11 24H2+ one
```

To bind it to a hotkey, point a shortcut at
`pwsh -WindowStyle Hidden -File C:\path\to\win\m27p6s-hdr.ps1 toggle` and set the
shortcut key in its properties.

### Both platforms

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
hdrctl ddc set <code> <value>    local dimming level listed in monitor_db.json (the only DDC write allowed)
hdrctl identify                  print the monitor's identity and hash
hdrctl detect                    find the monitor's local dimming code and levels (macOS, interactive)

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

### macOS

- **HDR** is switched through SkyLight (`SLSDisplaySetHDRModeEnabled`), a private macOS framework (macOS 11+) loaded at runtime. A future macOS update could remove or change it.
- **Color profile** is set with the public ColorSync API (`ColorSyncDeviceSetCustomProfiles`), the same setting as System Settings > Displays > Color profile. It applies to the current user.
- **Local dimming** is a monitor setting, changed over DDC/CI with IOAVService (private IOKit API, Apple Silicon only). On the M27P6S it is vendor VCP code `0xF4`: `0` = Off, `2` = Standard. This was found by dumping all codes, changing local dimming in the monitor's menu, and diffing. Other models will likely use a different code.
- The profile and DDC connection are resolved before HDR is switched, so a bad profile name or missing monitor fails without changing anything. After switching HDR, the tool waits for the display to settle, applies the profile, then sets local dimming.
- Before any DDC write (`on`, `off`, `toggle`, `ddc set`), the tool reads the monitor's identity, hashes it, and looks it up in `my_monitor.json` and `monitor_db.json`. If it isn't found, it prints `monitor unknown` and **stops without changing anything** (see [Safety checks](#safety-checks)).
- The monitor silently drops DDC writes while busy (especially just after an HDR switch), so local dimming is written, read back, and retried for up to ~10 seconds.

### Windows

The structure is the same, but every API used is public and documented, so there is no equivalent of the macOS private-framework risk.

- **HDR** is switched with `DisplayConfigSetDeviceInfo`. The tool prefers `DISPLAYCONFIG_DEVICE_INFO_SET_HDR_STATE` (Windows 11 24H2+), which controls HDR separately from wide colour gamut, and falls back to the older `SET_ADVANCED_COLOR_STATE` on Windows 10 and early Windows 11. This is the same setting as Settings > System > Display > Use HDR.
- **Display identity** comes from one `DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME` call, which returns the EDID manufacturer ID, product code and friendly name. Note that Windows reports the manufacturer ID as the raw big-endian EDID bytes, so it is byte-swapped before being decoded into letters, while the product code is already in host order.
- **Local dimming** uses the same vendor VCP code `0xF4` over DDC/CI, through the public monitor-configuration API in `dxva2.dll` (`SetVCPFeature` / `GetVCPFeatureAndVCPFeatureReply`). The DDC handle is resolved by matching the GDI device name (`\\.\DISPLAY1`) that both the display-config source and the `HMONITOR` report.
- The DDC connection is opened and the monitor looked up in `my_monitor.json` and `monitor_db.json` before HDR is switched, so a missing or unknown monitor changes nothing. After switching HDR the tool waits ~1.5 s for the mode set to finish, then writes local dimming with the same read-back-and-retry loop.
- Local dimming is read back and retried for up to ~10 seconds, as on macOS.
- **One x64 binary covers Windows 10 and 11.** The newer HDR API is not a separate exported function, only a different integer passed to the same `DisplayConfigSetDeviceInfo`, so nothing fails to resolve at load time on Windows 10; the choice happens at runtime instead. `--legacy-hdr` forces the older API, which is how the Windows 10 path can be exercised on Windows 11. `status` prints which API answered.
- DDC **reads** are retried too, for up to ~2 seconds per code. On a busy bus a read often gets no reply at all, which would otherwise make the safety checks fail when commands run back to back. A read that succeeds is never retried, so a value that comes back *wrong* still fails its check immediately rather than getting another chance at matching.

## Safety checks

0xF4 is a vendor code, so on another model or firmware it may mean something else. Before writing it, the tool reads these six values from the connected monitor, in this order:

| Identity field | M27P6S value (2026-10-23) |
|---|---|
| `manufacturer` (EDID) | `SKG` |
| `product_id` (EDID) | `10158` |
| `product_name` (EDID) | `M27P6S` |
| `display_controller_id` (VCP 0xC8) | `22021` |
| `firmware_version` (VCP 0xC9) | `0` |
| `local_dimming_range_max` (VCP 0xF4) | `5` |

Both platforms work the same way and compute the same hash.

The values are written as compact JSON in that order and hashed with SHA-256:

```
{"manufacturer":"SKG","product_id":10158,"product_name":"M27P6S","display_controller_id":22021,"firmware_version":0,"local_dimming_range_max":5}
```

The hash must equal the key in `my_monitor.json` and be a key in `monitor_db.json`. `my_monitor.json` is created from the connected monitor on first run, and its key must be the hash of its own `identity` section, so a hand-edited file is rejected rather than trusted. That entry holds the identity and the monitor's settings:

```json
"settings": {
  "local_dimming": {
    "vcp": "0xF4",
    "levels": [ { "name": "off", "value": 0 }, { "name": "standard", "value": 2 } ]
  }
}
```

`on` uses the `standard` level and `off` uses `off`. If any value can't be read, `my_monitor.json` is invalid or for a different monitor, or the hash isn't in the database, the tool prints `monitor unknown: <reason>` and exits with status 1 **before** switching HDR or the profile. `list`, `status`, `hdr`, `profile` (macOS), `identify`, `ddc get` and `ddc dump` don't write to the monitor and work on any display.

`ddc set` accepts only the local dimming code and a level listed for the monitor. Everything else is refused, because other codes can factory-reset the monitor, change input or power, or hit vendor service settings.

To add a monitor: map its local dimming code (`hdrctl ddc dump` with local dimming Off, change it in the monitor's menu, dump again, diff), run `hdrctl identify`, and add an entry under the printed hash. After a firmware update the hash may change and the tool will report `monitor unknown`; redo the mapping before adding the new hash. The firmware can't be hashed over DDC/CI. VCP 0xC9 is the only version the monitor reports, and this vendor may leave it at 0, so a firmware update could go unnoticed.

On Windows, the EDID values come from the display-config API and the VCP values from `dxva2.dll`. All six were confirmed to read identically on Windows. The hash is computed with the built-in BCrypt API, and `monitor_db.json` is read by a small JSON parser in `win/hdrctl.cpp`, so there are no extra dependencies.

Each change sends one 6-byte DDC "set" for VCP 0xF4 only, never a table of settings. The monitor's firmware decides how it saves that. If local dimming is already at the target value the write is skipped, since reads don't wear the monitor's memory. If the read gets no reply, it writes anyway. A real change usually takes 1–2 writes, up to 10 when the monitor is busy. Switching a few times a day is fine, but don't run it in a tight loop.

## Troubleshooting

- **`no connected display matches "M27P6S"`**: the monitor isn't connected to this Mac (or a KVM/switch has it on another input). Run `hdrctl list` to see display names.
- **`monitor unknown: ...`**: the reason follows. *no reply*: DDC was busy; rerun, or quit MonitorControl (macOS) or other DDC apps (Windows). *connected monitor doesn't match my_monitor.json: firmware_version is 1, my_monitor.json has 0*: the listed fields changed, usually a different monitor or new firmware; if it is your monitor, run `hdrctl identify --save`. *my_monitor.json isn't valid*: it was edited or damaged; run `hdrctl identify --save`. *isn't in monitor_db.json*: a monitor without an entry yet. Nothing was changed. See [Safety checks](#safety-checks).
- **`hdrctl` hangs with no output**: the monitor is asleep and doesn't answer DDC reads. Wake it and rerun.
- **`warning: couldn't confirm local dimming ...`**: the DDC bus is shared, and other DDC apps such as MonitorControl can garble replies. Quit them and rerun, or check the monitor's menu. `hdrctl ddc get 0xF4` shows the current value (it may need a couple of tries).
- **Wrong profile applied** (macOS): check `env | grep _PROFILE` for overrides, and `which -a hdrctl` for an older copy on your PATH.

Windows only:

- **`couldn't open a DDC/CI connection`**: the display was found but the driver wouldn't open a monitor handle. Check that DDC/CI is enabled in the monitor's own menu, and prefer a direct cable; many USB-C hubs, KVMs and DisplayPort MST hubs don't pass DDC/CI through.
- **`warning: couldn't confirm local dimming ...`**: another DDC app such as ClickMonitorDDC, Twinkle Tray or a vendor OSD utility is sharing the bus. Quit it and rerun.
- **`monitor unknown: ... no reply`**: reads are already retried for ~2 seconds per code, so if this still appears the bus is genuinely blocked. Nothing was changed. Quit other DDC apps and rerun.
- **`warning: couldn't switch HDR on`**: Windows refused the mode set. Check that `hdrctl.exe list` reports the display as HDR-capable, and that HDR isn't blocked by a system policy (`hdrctl.exe status` prints *limited by system policy* when it is).
- **`... cannot be loaded because running scripts is disabled`**: allow local scripts once with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## License

[MIT](LICENSE)
