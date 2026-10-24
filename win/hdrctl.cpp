// hdrctl — toggle HDR and the monitor's local dimming of an external display
// on Windows 10/11. Windows port of hdrctl.m (macOS).
//
// HDR is switched through the display-config API (DisplayConfigSetDeviceInfo).
// Local dimming is a monitor setting changed over DDC/CI; on the KTC M27P6S it
// is vendor VCP code 0xF4: 0 = Off, 2 = Standard. Because 0xF4 is a vendor
// code, the monitor's identity is verified before any write (see verifyMonitor).
//
// Build: build.ps1   (cl /std:c++17 hdrctl.cpp /link user32.lib dxva2.lib)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <physicalmonitorenumerationapi.h>
#include <lowlevelmonitorconfigurationapi.h>

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <wctype.h>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Values recorded from this monitor (2026-10-23). 0xF4 is a vendor code, so on
// another model or firmware it may mean something else. Every one of these must
// match before the tool writes it. See README "Safety checks".
// ---------------------------------------------------------------------------

static const char*    kExpectedEdidMfg     = "SKG";
static const unsigned kExpectedEdidProduct = 10158;
static const wchar_t* kExpectedEdidName    = L"M27P6S";

static const BYTE  kVcpControllerId     = 0xC8;   // display controller ID
static const DWORD kExpectedControllerId = 22021;
static const BYTE  kVcpFirmwareVersion  = 0xC9;   // firmware version
static const DWORD kExpectedFirmware    = 0;
static const BYTE  kVcpLocalDimming     = 0xF4;   // vendor: local dimming
static const DWORD kExpectedDimmingMax  = 5;

static const DWORD kDimmingOff      = 0;
static const DWORD kDimmingStandard = 2;

// The monitor drops DDC writes while busy, especially just after an HDR switch.
static const int   kDimmingMaxAttempts = 20;
static const DWORD kDimmingRetryMs     = 500;     // 20 * 500 ms = ~10 s
static const DWORD kHdrSettleMs        = 1500;    // let the mode set finish

// Reads get no reply on a busy bus too, so they are retried as well.
static const int   kVcpReadAttempts    = 8;
static const DWORD kVcpReadRetryMs     = 250;     // 8 * 250 ms = ~2 s per code

// ---------------------------------------------------------------------------
// Display-config device-info types. 15 and 16 are Windows 11 24H2+; they are
// declared here rather than taken from the SDK so this builds against older
// SDKs too, and we fall back to 9/10 at runtime on Windows 10.
// ---------------------------------------------------------------------------

enum {
    kGetAdvancedColorInfo  = 9,
    kSetAdvancedColorState = 10,
    kGetAdvancedColorInfo2 = 15,
    kSetHdrState           = 16,
};

struct AdvancedColorInfo {              // type 9, 32 bytes
    DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    UINT32 value;
    UINT32 colorEncoding;
    UINT32 bitsPerColorChannel;
};

struct AdvancedColorInfo2 {             // type 15, 36 bytes
    DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    UINT32 value;
    UINT32 colorEncoding;
    UINT32 bitsPerColorChannel;
    UINT32 activeColorMode;             // 0 = SDR, 1 = WCG, 2 = HDR
};

struct SetAdvancedColorStateRequest {   // type 10, 24 bytes
    DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    UINT32 value;                       // bit 0: enableAdvancedColor
};

struct SetHdrStateRequest {             // type 16, 24 bytes
    DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    UINT32 value;                       // bit 0: enableHdr
};

// AdvancedColorInfo bits
#define ACI_SUPPORTED(v)        (((v) >> 0) & 1)
#define ACI_ENABLED(v)          (((v) >> 1) & 1)
#define ACI_FORCE_DISABLED(v)   (((v) >> 3) & 1)

// AdvancedColorInfo2 bits
#define ACI2_SUPPORTED(v)       (((v) >> 0) & 1)
#define ACI2_ACTIVE(v)          (((v) >> 1) & 1)
#define ACI2_BY_POLICY(v)       (((v) >> 3) & 1)
#define ACI2_HDR_SUPPORTED(v)   (((v) >> 4) & 1)
#define ACI2_HDR_USER_ENABLED(v)(((v) >> 5) & 1)

// Force the pre-24H2 advanced-colour API even when the modern one is
// available. Only useful for exercising the Windows 10 code path on a newer
// Windows, and as an escape hatch if the modern call misbehaves.
static bool g_forceLegacyHdr = false;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

static std::string narrow(const std::wstring& w) {
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), NULL, 0, NULL, NULL);
    std::string s((size_t)n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, NULL, NULL);
    return s;
}

static std::wstring widen(const char* s) {
    if (!s || !*s) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    std::wstring w((size_t)(n > 0 ? n - 1 : 0), L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

static std::wstring lower(std::wstring s) {
    for (size_t i = 0; i < s.size(); i++) s[i] = (wchar_t)towlower(s[i]);
    return s;
}

// Case-insensitive substring match, like the macOS tool's --display matching.
static bool icontains(const std::wstring& haystack, const std::wstring& needle) {
    if (needle.empty()) return true;
    return lower(haystack).find(lower(needle)) != std::wstring::npos;
}

// EDID manufacturer ID: three 5-bit letters, 'A' = 1. Windows reports the raw
// big-endian EDID bytes, so swap before decoding. (The product code, by
// contrast, is already host order.)
static std::string decodeEdidMfg(UINT16 raw) {
    UINT16 v = (UINT16)(((raw & 0xFF) << 8) | (raw >> 8));
    char s[4];
    s[0] = (char)('A' + ((v >> 10) & 0x1F) - 1);
    s[1] = (char)('A' + ((v >> 5)  & 0x1F) - 1);
    s[2] = (char)('A' + ((v >> 0)  & 0x1F) - 1);
    s[3] = '\0';
    return std::string(s);
}

static void warn(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "warning: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

// ---------------------------------------------------------------------------
// Display enumeration
// ---------------------------------------------------------------------------

struct DisplayTarget {
    LUID         adapterId;
    UINT32       targetId;
    UINT32       sourceId;
    std::wstring friendlyName;
    std::wstring gdiDeviceName;   // e.g. "\\.\DISPLAY1", links to the HMONITOR
    UINT16       edidMfgRaw;
    UINT16       edidProductCode;
};

static bool enumTargets(std::vector<DisplayTarget>* out) {
    UINT32 nPath = 0, nMode = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &nPath, &nMode) != ERROR_SUCCESS)
        return false;

    std::vector<DISPLAYCONFIG_PATH_INFO> paths(nPath);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(nMode);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &nPath, paths.data(),
                           &nMode, modes.data(), NULL) != ERROR_SUCCESS)
        return false;
    paths.resize(nPath);

    for (size_t i = 0; i < paths.size(); i++) {
        DisplayTarget t;
        t.adapterId = paths[i].targetInfo.adapterId;
        t.targetId  = paths[i].targetInfo.id;
        t.sourceId  = paths[i].sourceInfo.id;

        DISPLAYCONFIG_TARGET_DEVICE_NAME tn;
        ZeroMemory(&tn, sizeof(tn));
        tn.header.type      = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        tn.header.size      = sizeof(tn);
        tn.header.adapterId = paths[i].targetInfo.adapterId;
        tn.header.id        = paths[i].targetInfo.id;
        if (DisplayConfigGetDeviceInfo(&tn.header) != ERROR_SUCCESS)
            continue;
        t.friendlyName    = tn.monitorFriendlyDeviceName;
        t.edidMfgRaw      = tn.edidManufactureId;
        t.edidProductCode = tn.edidProductCodeId;

        DISPLAYCONFIG_SOURCE_DEVICE_NAME sn;
        ZeroMemory(&sn, sizeof(sn));
        sn.header.type      = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        sn.header.size      = sizeof(sn);
        sn.header.adapterId = paths[i].sourceInfo.adapterId;
        sn.header.id        = paths[i].sourceInfo.id;
        if (DisplayConfigGetDeviceInfo(&sn.header) == ERROR_SUCCESS)
            t.gdiDeviceName = sn.viewGdiDeviceName;

        out->push_back(t);
    }
    return true;
}

static bool findTarget(const std::wstring& nameFragment, DisplayTarget* out) {
    std::vector<DisplayTarget> targets;
    if (!enumTargets(&targets)) {
        warn("couldn't query the display configuration");
        return false;
    }
    for (size_t i = 0; i < targets.size(); i++) {
        if (icontains(targets[i].friendlyName, nameFragment)) {
            *out = targets[i];
            return true;
        }
    }
    fprintf(stderr, "no connected display matches \"%s\"\n",
            narrow(nameFragment).c_str());
    fprintf(stderr, "run \"hdrctl list\" to see display names\n");
    return false;
}

// ---------------------------------------------------------------------------
// HDR state
// ---------------------------------------------------------------------------

struct HdrState {
    bool supported;
    bool enabled;
    bool forcedOffByPolicy;
    bool usedModernApi;
    UINT32 activeColorMode;   // only meaningful when usedModernApi
};

// Prefer the Windows 11 24H2+ API, which separates HDR from wide colour gamut;
// fall back to the legacy advanced-colour API on Windows 10 and early 11.
static bool getHdrState(const DisplayTarget& t, HdrState* out) {
    ZeroMemory(out, sizeof(*out));

    AdvancedColorInfo2 a2;
    ZeroMemory(&a2, sizeof(a2));
    a2.header.type      = (DISPLAYCONFIG_DEVICE_INFO_TYPE)kGetAdvancedColorInfo2;
    a2.header.size      = sizeof(a2);
    a2.header.adapterId = t.adapterId;
    a2.header.id        = t.targetId;
    if (!g_forceLegacyHdr && DisplayConfigGetDeviceInfo(&a2.header) == ERROR_SUCCESS) {
        out->supported         = ACI2_HDR_SUPPORTED(a2.value) != 0;
        out->enabled           = ACI2_HDR_USER_ENABLED(a2.value) != 0;
        out->forcedOffByPolicy = ACI2_BY_POLICY(a2.value) != 0;
        out->activeColorMode   = a2.activeColorMode;
        out->usedModernApi     = true;
        return true;
    }

    AdvancedColorInfo a1;
    ZeroMemory(&a1, sizeof(a1));
    a1.header.type      = (DISPLAYCONFIG_DEVICE_INFO_TYPE)kGetAdvancedColorInfo;
    a1.header.size      = sizeof(a1);
    a1.header.adapterId = t.adapterId;
    a1.header.id        = t.targetId;
    if (DisplayConfigGetDeviceInfo(&a1.header) == ERROR_SUCCESS) {
        out->supported         = ACI_SUPPORTED(a1.value) != 0;
        out->enabled           = ACI_ENABLED(a1.value) != 0;
        out->forcedOffByPolicy = ACI_FORCE_DISABLED(a1.value) != 0;
        out->usedModernApi     = false;
        return true;
    }
    return false;
}

static bool setHdrState(const DisplayTarget& t, bool on) {
    SetHdrStateRequest req;
    ZeroMemory(&req, sizeof(req));
    req.header.type      = (DISPLAYCONFIG_DEVICE_INFO_TYPE)kSetHdrState;
    req.header.size      = sizeof(req);
    req.header.adapterId = t.adapterId;
    req.header.id        = t.targetId;
    req.value            = on ? 1 : 0;
    if (!g_forceLegacyHdr && DisplayConfigSetDeviceInfo(&req.header) == ERROR_SUCCESS)
        return true;

    SetAdvancedColorStateRequest legacy;
    ZeroMemory(&legacy, sizeof(legacy));
    legacy.header.type      = (DISPLAYCONFIG_DEVICE_INFO_TYPE)kSetAdvancedColorState;
    legacy.header.size      = sizeof(legacy);
    legacy.header.adapterId = t.adapterId;
    legacy.header.id        = t.targetId;
    legacy.value            = on ? 1 : 0;
    return DisplayConfigSetDeviceInfo(&legacy.header) == ERROR_SUCCESS;
}

// ---------------------------------------------------------------------------
// DDC/CI
// ---------------------------------------------------------------------------

struct MonitorHandles {
    std::vector<HMONITOR> list;
};

static BOOL CALLBACK collectMonitor(HMONITOR h, HDC, LPRECT, LPARAM data) {
    ((MonitorHandles*)data)->list.push_back(h);
    return TRUE;
}

// Resolve the DDC/CI handle for a target by matching the GDI device name that
// both the display-config source and the HMONITOR report.
static bool openPhysicalMonitor(const DisplayTarget& t, HANDLE* out) {
    MonitorHandles mons;
    EnumDisplayMonitors(NULL, NULL, collectMonitor, (LPARAM)&mons);

    for (size_t i = 0; i < mons.list.size(); i++) {
        MONITORINFOEXW mi;
        ZeroMemory(&mi, sizeof(mi));
        mi.cbSize = sizeof(mi);
        if (!GetMonitorInfoW(mons.list[i], (MONITORINFO*)&mi))
            continue;
        if (t.gdiDeviceName != mi.szDevice)
            continue;

        DWORD n = 0;
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(mons.list[i], &n) || n == 0)
            continue;
        std::vector<PHYSICAL_MONITOR> pm(n);
        if (!GetPhysicalMonitorsFromHMONITOR(mons.list[i], n, pm.data()))
            continue;
        if (n > 1)
            warn("%u physical monitors share %s (mirroring?); using the first",
                 n, narrow(t.gdiDeviceName).c_str());
        // Keep the first, release the rest.
        for (DWORD k = 1; k < n; k++)
            DestroyPhysicalMonitor(pm[k].hPhysicalMonitor);
        *out = pm[0].hPhysicalMonitor;
        return true;
    }
    fprintf(stderr, "couldn't open a DDC/CI connection to \"%s\"\n",
            narrow(t.friendlyName).c_str());
    return false;
}

static bool vcpGet(HANDLE hMon, BYTE code, DWORD* cur, DWORD* max) {
    MC_VCP_CODE_TYPE type;
    DWORD c = 0, m = 0;
    if (!GetVCPFeatureAndVCPFeatureReply(hMon, code, &type, &c, &m))
        return false;
    if (cur) *cur = c;
    if (max) *max = m;
    return true;
}

static bool vcpSet(HANDLE hMon, BYTE code, DWORD value) {
    return SetVCPFeature(hMon, code, value) != FALSE;
}

// A DDC read often gets no reply at all while the monitor is busy, which it is
// for a while after an HDR switch and when commands run back to back. Retry
// those. A read that *succeeds* is never retried: a value that comes back wrong
// has to fail its check immediately, not get a second chance at matching.
static bool vcpGetRetry(HANDLE hMon, BYTE code, DWORD* cur, DWORD* max) {
    for (int attempt = 0; attempt < kVcpReadAttempts; attempt++) {
        if (vcpGet(hMon, code, cur, max))
            return true;
        Sleep(kVcpReadRetryMs);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Safety checks — all must pass before 0xF4 is written
// ---------------------------------------------------------------------------

static bool verifyMonitor(HANDLE hMon, const DisplayTarget& t) {
    std::string mfg = decodeEdidMfg(t.edidMfgRaw);
    if (mfg != kExpectedEdidMfg) {
        warn("monitor doesn't match: EDID manufacturer is \"%s\", expected \"%s\". "
             "Nothing was changed.", mfg.c_str(), kExpectedEdidMfg);
        return false;
    }
    if (t.edidProductCode != kExpectedEdidProduct) {
        warn("monitor doesn't match: EDID product ID is %u, expected %u. "
             "Nothing was changed.", t.edidProductCode, kExpectedEdidProduct);
        return false;
    }
    if (t.friendlyName != kExpectedEdidName) {
        warn("monitor doesn't match: EDID product name is \"%s\", expected \"%s\". "
             "Nothing was changed.",
             narrow(t.friendlyName).c_str(), narrow(kExpectedEdidName).c_str());
        return false;
    }

    DWORD cur = 0, max = 0;
    if (!vcpGetRetry(hMon, kVcpControllerId, &cur, NULL)) {
        warn("couldn't verify the monitor (DDC busy? another DDC app running?). "
             "Nothing was changed.");
        return false;
    }
    if (cur != kExpectedControllerId) {
        warn("monitor doesn't match: controller ID (VCP 0x%02X) is %lu, expected %lu. "
             "Nothing was changed.", kVcpControllerId, cur, kExpectedControllerId);
        return false;
    }
    if (!vcpGetRetry(hMon, kVcpFirmwareVersion, &cur, NULL)) {
        warn("couldn't verify the monitor (DDC busy? another DDC app running?). "
             "Nothing was changed.");
        return false;
    }
    if (cur != kExpectedFirmware) {
        warn("monitor doesn't match: firmware version (VCP 0x%02X) is %lu, expected %lu. "
             "Nothing was changed.", kVcpFirmwareVersion, cur, kExpectedFirmware);
        return false;
    }
    if (!vcpGetRetry(hMon, kVcpLocalDimming, &cur, &max)) {
        warn("couldn't verify the monitor (DDC busy? another DDC app running?). "
             "Nothing was changed.");
        return false;
    }
    if (max != kExpectedDimmingMax) {
        warn("monitor doesn't match: local dimming range max (VCP 0x%02X) is %lu, "
             "expected %lu. Nothing was changed.",
             kVcpLocalDimming, max, kExpectedDimmingMax);
        return false;
    }
    return true;
}

// Write local dimming, read it back, and retry: the monitor silently drops DDC
// writes while busy. Skip the write when it is already at the target, since
// reads don't wear the monitor's memory.
static bool setLocalDimming(HANDLE hMon, DWORD want) {
    DWORD cur = 0;
    if (vcpGetRetry(hMon, kVcpLocalDimming, &cur, NULL) && cur == want)
        return true;

    for (int attempt = 0; attempt < kDimmingMaxAttempts; attempt++) {
        vcpSet(hMon, kVcpLocalDimming, want);
        Sleep(kDimmingRetryMs);
        if (vcpGet(hMon, kVcpLocalDimming, &cur, NULL) && cur == want)
            return true;
    }
    warn("couldn't confirm local dimming reached %lu. Another DDC app such as "
         "ClickMonitorDDC can garble replies; quit it and rerun, or check the "
         "monitor's menu.", want);
    return false;
}

static const char* dimmingName(DWORD v) {
    if (v == kDimmingOff)      return "Off";
    if (v == kDimmingStandard) return "Standard";
    return "unknown";
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

static int cmdList() {
    std::vector<DisplayTarget> targets;
    if (!enumTargets(&targets)) {
        warn("couldn't query the display configuration");
        return 1;
    }
    if (targets.empty()) {
        printf("no active displays\n");
        return 0;
    }
    for (size_t i = 0; i < targets.size(); i++) {
        const DisplayTarget& t = targets[i];
        HdrState hs;
        bool ok = getHdrState(t, &hs);
        printf("%s  (%s)\n", narrow(t.friendlyName).c_str(),
               narrow(t.gdiDeviceName).c_str());
        printf("    EDID: %s %u\n", decodeEdidMfg(t.edidMfgRaw).c_str(),
               t.edidProductCode);
        if (!ok) {
            printf("    HDR:  unknown (couldn't read advanced colour info)\n");
        } else if (!hs.supported) {
            printf("    HDR:  not supported by this display\n");
        } else {
            printf("    HDR:  %s%s\n", hs.enabled ? "on" : "off",
                   hs.forcedOffByPolicy ? " (limited by system policy)" : "");
        }
    }
    return 0;
}

static int cmdStatus(const std::wstring& displayName) {
    DisplayTarget t;
    if (!findTarget(displayName, &t)) return 1;

    printf("%s  (%s)\n", narrow(t.friendlyName).c_str(),
           narrow(t.gdiDeviceName).c_str());

    HdrState hs;
    if (!getHdrState(t, &hs)) {
        printf("  HDR:           unknown\n");
    } else if (!hs.supported) {
        printf("  HDR:           not supported by this display\n");
    } else {
        printf("  HDR:           %s%s\n", hs.enabled ? "on" : "off",
               hs.forcedOffByPolicy ? " (limited by system policy)" : "");
        if (hs.usedModernApi) {
            const char* mode = hs.activeColorMode == 2 ? "HDR"
                             : hs.activeColorMode == 1 ? "WCG" : "SDR";
            printf("  active mode:   %s\n", mode);
        }
        printf("  color api:     %s\n",
               hs.usedModernApi ? "SET_HDR_STATE (Windows 11 24H2+)"
                                : "SET_ADVANCED_COLOR_STATE (Windows 10 / early 11)");
    }

    HANDLE hMon = NULL;
    if (!openPhysicalMonitor(t, &hMon)) return 1;
    DWORD cur = 0, max = 0;
    if (vcpGetRetry(hMon, kVcpLocalDimming, &cur, &max))
        printf("  local dimming: %s (%lu)\n", dimmingName(cur), cur);
    else
        printf("  local dimming: unknown (DDC read failed)\n");
    DestroyPhysicalMonitor(hMon);
    return 0;
}

// Resolve the display and DDC connection and verify the monitor *before*
// switching HDR, so a missing monitor or a failed check changes nothing.
static int applyState(const std::wstring& displayName, bool on) {
    DisplayTarget t;
    if (!findTarget(displayName, &t)) return 1;

    HdrState hs;
    if (getHdrState(t, &hs) && !hs.supported)
        warn("%s isn't reported as HDR-capable; switching anyway",
             narrow(t.friendlyName).c_str());

    HANDLE hMon = NULL;
    if (!openPhysicalMonitor(t, &hMon)) return 1;
    if (!verifyMonitor(hMon, t)) {
        DestroyPhysicalMonitor(hMon);
        return 1;
    }

    int rc = 0;
    if (!setHdrState(t, on)) {
        warn("couldn't switch HDR %s", on ? "on" : "off");
        rc = 1;
    } else {
        printf("HDR %s\n", on ? "on" : "off");
    }

    Sleep(kHdrSettleMs);

    DWORD want = on ? kDimmingStandard : kDimmingOff;
    if (setLocalDimming(hMon, want))
        printf("local dimming %s\n", dimmingName(want));
    else
        rc = 1;

    DestroyPhysicalMonitor(hMon);
    return rc;
}

static int cmdToggle(const std::wstring& displayName) {
    DisplayTarget t;
    if (!findTarget(displayName, &t)) return 1;
    HdrState hs;
    if (!getHdrState(t, &hs)) {
        warn("couldn't read the current HDR state");
        return 1;
    }
    return applyState(displayName, !hs.enabled);
}

static int cmdHdrOnly(const std::wstring& displayName, bool on) {
    DisplayTarget t;
    if (!findTarget(displayName, &t)) return 1;
    if (!setHdrState(t, on)) {
        warn("couldn't switch HDR %s", on ? "on" : "off");
        return 1;
    }
    printf("HDR %s\n", on ? "on" : "off");
    return 0;
}

static int cmdDdc(const std::wstring& displayName, int argc, char** argv) {
    if (argc < 1) {
        fprintf(stderr, "ddc needs a subcommand: dump, get <code>, set 0xF4 0|2\n");
        return 1;
    }
    DisplayTarget t;
    if (!findTarget(displayName, &t)) return 1;
    HANDLE hMon = NULL;
    if (!openPhysicalMonitor(t, &hMon)) return 1;

    int rc = 0;
    std::string sub = argv[0];

    if (sub == "dump") {
        printf("reading all VCP codes from %s (this takes a while)\n",
               narrow(t.friendlyName).c_str());
        for (int code = 0; code <= 0xFF; code++) {
            DWORD cur = 0, max = 0;
            if (vcpGet(hMon, (BYTE)code, &cur, &max))
                printf("  0x%02X  current=%lu  max=%lu\n", code, cur, max);
        }
    } else if (sub == "get") {
        if (argc < 2) {
            fprintf(stderr, "ddc get needs a VCP code, e.g. 0xF4\n");
            rc = 1;
        } else {
            long code = strtol(argv[1], NULL, 0);
            if (code < 0 || code > 0xFF) {
                fprintf(stderr, "VCP code out of range: %s\n", argv[1]);
                rc = 1;
            } else {
                DWORD cur = 0, max = 0;
                if (vcpGetRetry(hMon, (BYTE)code, &cur, &max)) {
                    printf("0x%02lX  current=%lu  max=%lu\n", code, cur, max);
                } else {
                    warn("no reply for VCP 0x%02lX (DDC busy? try again)", code);
                    rc = 1;
                }
            }
        }
    } else if (sub == "set") {
        // Deliberately limited: other codes can factory-reset the monitor,
        // change input or power, or hit vendor service settings.
        if (argc < 3) {
            fprintf(stderr, "ddc set needs a code and a value, e.g. ddc set 0xF4 2\n");
            rc = 1;
        } else {
            long code  = strtol(argv[1], NULL, 0);
            long value = strtol(argv[2], NULL, 0);
            if (code != kVcpLocalDimming) {
                fprintf(stderr, "refusing to write VCP 0x%02lX; only 0x%02X "
                        "(local dimming) is allowed\n", code, kVcpLocalDimming);
                rc = 1;
            } else if (value != (long)kDimmingOff && value != (long)kDimmingStandard) {
                fprintf(stderr, "refusing value %ld for VCP 0x%02X; only %lu (Off) "
                        "and %lu (Standard) are allowed\n",
                        value, kVcpLocalDimming, kDimmingOff, kDimmingStandard);
                rc = 1;
            } else if (!verifyMonitor(hMon, t)) {
                rc = 1;
            } else if (setLocalDimming(hMon, (DWORD)value)) {
                printf("local dimming %s\n", dimmingName((DWORD)value));
            } else {
                rc = 1;
            }
        }
    } else {
        fprintf(stderr, "unknown ddc subcommand \"%s\"\n", sub.c_str());
        rc = 1;
    }

    DestroyPhysicalMonitor(hMon);
    return rc;
}

static void usage() {
    printf(
"hdrctl — toggle HDR and the monitor's local dimming (Windows 10/11)\n"
"\n"
"  hdrctl list                      list displays, EDID and HDR state\n"
"  hdrctl status                    HDR state + local dimming of the target display\n"
"  hdrctl on                        HDR on  + local dimming Standard\n"
"  hdrctl off                       HDR off + local dimming Off\n"
"  hdrctl toggle                    flip between on/off\n"
"  hdrctl hdr on|off                HDR only\n"
"  hdrctl ddc dump                  read all monitor settings (DDC/CI VCP codes)\n"
"  hdrctl ddc get <code>            read one VCP code, e.g. 0xF4\n"
"  hdrctl ddc set 0xF4 0|2          local dimming Off|Standard (the only DDC write allowed)\n"
"\n"
"Options:\n"
"  --display <text>       part of the display name        (default: %s)\n"
"  --legacy-hdr           use the Windows 10 advanced-color API, not the\n"
"                         Windows 11 24H2+ one\n",
    narrow(kExpectedEdidName).c_str());
}

int main(int argc, char** argv) {
    SetConsoleOutputCP(CP_UTF8);

    std::wstring displayName = kExpectedEdidName;
    std::vector<char*> rest;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--display") {
            if (i + 1 >= argc) {
                fprintf(stderr, "--display needs a value\n");
                return 1;
            }
            displayName = widen(argv[++i]);
        } else if (a == "--legacy-hdr") {
            g_forceLegacyHdr = true;
        } else if (a == "-h" || a == "--help" || a == "help") {
            usage();
            return 0;
        } else {
            rest.push_back(argv[i]);
        }
    }

    if (rest.empty()) {
        return cmdStatus(displayName);
    }

    std::string cmd = rest[0];
    if (cmd == "list")   return cmdList();
    if (cmd == "status") return cmdStatus(displayName);
    if (cmd == "on")     return applyState(displayName, true);
    if (cmd == "off")    return applyState(displayName, false);
    if (cmd == "toggle") return cmdToggle(displayName);
    if (cmd == "hdr") {
        if (rest.size() < 2) {
            fprintf(stderr, "hdr needs on or off\n");
            return 1;
        }
        std::string v = rest[1];
        if (v == "on")  return cmdHdrOnly(displayName, true);
        if (v == "off") return cmdHdrOnly(displayName, false);
        fprintf(stderr, "hdr needs on or off, got \"%s\"\n", v.c_str());
        return 1;
    }
    if (cmd == "ddc")
        return cmdDdc(displayName, (int)rest.size() - 1, rest.data() + 1);

    fprintf(stderr, "unknown command \"%s\"\n\n", cmd.c_str());
    usage();
    return 1;
}
