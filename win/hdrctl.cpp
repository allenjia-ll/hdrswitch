// hdrctl — toggle HDR and the monitor's local dimming of an external display
// on Windows 10/11. Windows port of hdrctl.m (macOS).
//
// HDR is switched through the display-config API (DisplayConfigSetDeviceInfo).
// Local dimming is a monitor setting changed over DDC/CI; on the KTC M27P6S it
// is vendor VCP code 0xF4: 0 = Off, 2 = Standard. Because it is a vendor code,
// the code and levels come from monitor_db.json, and the monitor's identity is
// looked up there before any write (see findMonitor).
//
// Build: build.ps1   (cl /std:c++17 hdrctl.cpp /link user32.lib dxva2.lib bcrypt.lib)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <physicalmonitorenumerationapi.h>
#include <lowlevelmonitorconfigurationapi.h>

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <errno.h>
#include <string.h>
#include <ctype.h>
#include <wctype.h>
#include <string>
#include <vector>

static const wchar_t* kDefaultDisplay = L"M27P6S";

// Identity values read over DDC/CI (see "Monitor DB" below).
static const BYTE kVcpControllerId      = 0xC8;   // display controller ID
static const BYTE kVcpFirmwareVersion   = 0xC9;   // firmware version
static const BYTE kVcpLocalDimmingRange = 0xF4;   // its max is part of the identity

// The monitor drops DDC writes while busy, especially just after an HDR switch.
static const int   kDimmingMaxAttempts = 20;
static const DWORD kDimmingRetryMs     = 500;     // 20 * 500 ms = ~10 s
static const DWORD kHdrSettleMs        = 1500;    // let the mode set finish

// Reads get no reply on a busy bus too, so they are retried as well.
static const int   kVcpReadAttempts    = 8;
static const DWORD kVcpReadRetryMs     = 250;     // 8 * 250 ms = ~2 s per code
// The identity read races the mode set from an HDR switch, which can keep the
// bus quiet for longer than an ordinary read has to wait. Give it a budget
// nearer the write path's, so "status" straight after "on" reports the real
// state instead of calling a merely busy monitor unknown.
static const int   kIdentityReadAttempts = 20;    // 20 * 250 ms = ~5 s per code

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

// Strict numeric parse, matching parseNum in mac/hdrctl.m: the whole string
// has to be a number. strtoul on its own is not enough, because it reports a
// failed parse as 0 -- and 0 is a legitimate local dimming level, so a typo
// like "ddc set 0xF4 banana" would silently switch local dimming off.
static bool parseNum(const char* str, unsigned long* out) {
    if (!str || !*str || *str == '-') return false;
    // Hex only with an explicit 0x, so a leading zero stays decimal as on macOS.
    int base = (str[0] == '0' && (str[1] == 'x' || str[1] == 'X')) ? 16 : 10;
    char* end = NULL;
    errno = 0;
    unsigned long v = strtoul(str, &end, base);
    if (errno == ERANGE || end == str || *end != '\0') return false;
    *out = v;
    return true;
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
static bool vcpGetRetry(HANDLE hMon, BYTE code, DWORD* cur, DWORD* max,
                        int attempts = kVcpReadAttempts) {
    for (int attempt = 0; attempt < attempts; attempt++) {
        if (vcpGet(hMon, code, cur, max))
            return true;
        Sleep(kVcpReadRetryMs);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Monitor DB
//
// A monitor is identified by the SHA-256 of its identity values, in this
// order, as compact JSON (the same text and hash as the macOS build):
//   {"manufacturer":"SKG","product_id":10158,"product_name":"M27P6S",
//    "display_controller_id":22021,"firmware_version":0,"local_dimming_range_max":5}
// monitor_db.json (next to hdrctl.exe) maps that hash to the identity and the
// monitor's DDC settings. my_monitor.json (next to hdrctl.exe) holds the
// monitor set up on this PC, as { "<hash>": { "identity": { ... } } }. Before
// any DDC write, the connected monitor is read, hashed, and must match
// my_monitor.json and be in the DB.
// ---------------------------------------------------------------------------

// Just enough JSON for monitor_db.json: objects, arrays, strings, numbers,
// true/false/null.
struct JsonValue {
    enum Type { Null, Bool, Number, String, Array, Object } type = Null;
    bool b = false;
    double num = 0;
    std::string str;                     // UTF-8
    std::vector<JsonValue> items;        // Array elements, or Object values
    std::vector<std::string> keys;       // Object keys, parallel to items

    const JsonValue* get(const char* key) const {
        if (type != Object) return NULL;
        for (size_t i = 0; i < keys.size(); i++)
            if (keys[i] == key) return &items[i];
        return NULL;
    }
};

class JsonParser {
public:
    explicit JsonParser(const std::string& s) : s_(s) {}

    bool parse(JsonValue* out, std::string* err) {
        bool ok = value(out, 0);
        if (ok) {
            ws();
            if (i_ != s_.size()) ok = fail("unexpected text after the JSON value");
        }
        if (!ok) *err = err_;
        return ok;
    }

private:
    const std::string& s_;
    size_t i_ = 0;
    std::string err_;

    bool fail(const char* what) {
        err_ = std::string(what) + " at byte " + std::to_string(i_);
        return false;
    }
    void ws() {
        while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r'))
            i_++;
    }
    bool lit(const char* w) {
        size_t n = strlen(w);
        if (s_.compare(i_, n, w) != 0) return false;
        i_ += n;
        return true;
    }
    bool value(JsonValue* v, int depth) {
        if (depth > 32) return fail("nested too deeply");
        ws();
        if (i_ >= s_.size()) return fail("unexpected end");
        char c = s_[i_];
        if (c == '{') return object(v, depth);
        if (c == '[') return array(v, depth);
        if (c == '"') { v->type = JsonValue::String; return stringLit(&v->str); }
        if (lit("true"))  { v->type = JsonValue::Bool; v->b = true;  return true; }
        if (lit("false")) { v->type = JsonValue::Bool; v->b = false; return true; }
        if (lit("null"))  { v->type = JsonValue::Null; return true; }
        if (c == '-' || (c >= '0' && c <= '9')) return number(v);
        return fail("unexpected character");
    }
    bool number(JsonValue* v) {
        const char* start = s_.c_str() + i_;
        char* end = NULL;
        double d = strtod(start, &end);
        if (end == start) return fail("bad number");
        i_ += (size_t)(end - start);
        v->type = JsonValue::Number;
        v->num = d;
        return true;
    }
    static void appendUtf8(std::string* out, unsigned cp) {
        if (cp < 0x80) {
            *out += (char)cp;
        } else if (cp < 0x800) {
            *out += (char)(0xC0 | (cp >> 6));
            *out += (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            *out += (char)(0xE0 | (cp >> 12));
            *out += (char)(0x80 | ((cp >> 6) & 0x3F));
            *out += (char)(0x80 | (cp & 0x3F));
        } else {
            *out += (char)(0xF0 | (cp >> 18));
            *out += (char)(0x80 | ((cp >> 12) & 0x3F));
            *out += (char)(0x80 | ((cp >> 6) & 0x3F));
            *out += (char)(0x80 | (cp & 0x3F));
        }
    }
    bool hex4(unsigned* out) {
        if (i_ + 4 > s_.size()) return fail("bad \\u escape");
        unsigned v = 0;
        for (int k = 0; k < 4; k++) {
            char h = s_[i_++];
            v <<= 4;
            if (h >= '0' && h <= '9')      v |= (unsigned)(h - '0');
            else if (h >= 'a' && h <= 'f') v |= (unsigned)(h - 'a' + 10);
            else if (h >= 'A' && h <= 'F') v |= (unsigned)(h - 'A' + 10);
            else return fail("bad \\u escape");
        }
        *out = v;
        return true;
    }
    bool stringLit(std::string* out) {
        i_++;   // opening quote
        out->clear();
        while (i_ < s_.size()) {
            unsigned char c = (unsigned char)s_[i_++];
            if (c == '"') return true;
            if (c < 0x20) return fail("control character in string");
            if (c != '\\') { *out += (char)c; continue; }
            if (i_ >= s_.size()) break;
            char e = s_[i_++];
            switch (e) {
            case '"': *out += '"'; break;
            case '\\': *out += '\\'; break;
            case '/': *out += '/'; break;
            case 'b': *out += '\b'; break;
            case 'f': *out += '\f'; break;
            case 'n': *out += '\n'; break;
            case 'r': *out += '\r'; break;
            case 't': *out += '\t'; break;
            case 'u': {
                unsigned cp = 0;
                if (!hex4(&cp)) return false;
                if (cp >= 0xD800 && cp <= 0xDBFF) {   // surrogate pair
                    unsigned lo = 0;
                    if (!lit("\\u") || !hex4(&lo) || lo < 0xDC00 || lo > 0xDFFF)
                        return fail("bad surrogate pair");
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                appendUtf8(out, cp);
                break;
            }
            default: return fail("bad escape");
            }
        }
        return fail("unterminated string");
    }
    bool array(JsonValue* v, int depth) {
        i_++;   // [
        v->type = JsonValue::Array;
        ws();
        if (i_ < s_.size() && s_[i_] == ']') { i_++; return true; }
        for (;;) {
            JsonValue item;
            if (!value(&item, depth + 1)) return false;
            v->items.push_back(item);
            ws();
            if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
            if (i_ < s_.size() && s_[i_] == ']') { i_++; return true; }
            return fail("expected , or ]");
        }
    }
    bool object(JsonValue* v, int depth) {
        i_++;   // {
        v->type = JsonValue::Object;
        ws();
        if (i_ < s_.size() && s_[i_] == '}') { i_++; return true; }
        for (;;) {
            ws();
            if (i_ >= s_.size() || s_[i_] != '"') return fail("expected a key");
            std::string key;
            if (!stringLit(&key)) return false;
            ws();
            if (i_ >= s_.size() || s_[i_] != ':') return fail("expected :");
            i_++;
            JsonValue item;
            if (!value(&item, depth + 1)) return false;
            v->keys.push_back(key);
            v->items.push_back(item);
            ws();
            if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
            if (i_ < s_.size() && s_[i_] == '}') { i_++; return true; }
            return fail("expected , or }");
        }
    }
};

// JSON string literal, escaped the way the macOS build (NSJSONSerialization)
// writes it, so both platforms hash the same text.
static std::string jsonQuote(const std::string& s) {
    std::string out = "\"";
    for (size_t i = 0; i < s.size(); i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += (char)c;
            }
        }
    }
    return out + "\"";
}

static bool sha256Hex(const std::string& data, std::string* hex) {
    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_HASH_HANDLE h = NULL;
    UCHAR digest[32];
    bool ok = BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0)) &&
              BCRYPT_SUCCESS(BCryptCreateHash(alg, &h, NULL, 0, NULL, 0, 0)) &&
              BCRYPT_SUCCESS(BCryptHashData(h, (PUCHAR)data.data(), (ULONG)data.size(), 0)) &&
              BCRYPT_SUCCESS(BCryptFinishHash(h, digest, (ULONG)sizeof(digest), 0));
    if (h) BCryptDestroyHash(h);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    if (!ok) return false;
    hex->clear();
    for (size_t i = 0; i < sizeof(digest); i++) {
        char buf[3];
        snprintf(buf, sizeof(buf), "%02x", digest[i]);
        *hex += buf;
    }
    return true;
}

static std::wstring pathNextToTool(const wchar_t* name) {
    std::vector<wchar_t> buf(MAX_PATH);
    for (;;) {
        DWORD n = GetModuleFileNameW(NULL, buf.data(), (DWORD)buf.size());
        if (n == 0) return name;
        if (n < buf.size()) {
            std::wstring p(buf.data(), n);
            size_t slash = p.find_last_of(L"\\/");
            return (slash == std::wstring::npos ? std::wstring() : p.substr(0, slash + 1)) + name;
        }
        buf.resize(buf.size() * 2);
    }
}

static bool readFile(const std::wstring& path, std::string* out) {
    FILE* f = NULL;
    if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return false;
    out->clear();
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out->append(buf, n);
    fclose(f);
    return true;
}

// Loads monitor_db.json. Returns false with *why set if it's missing or invalid.
static bool loadDB(JsonValue* db, std::string* why) {
    std::string text;
    if (!readFile(pathNextToTool(L"monitor_db.json"), &text)) {
        *why = "monitor_db.json not found next to hdrctl.exe";
        return false;
    }
    std::string err;
    if (!JsonParser(text).parse(db, &err) || db->type != JsonValue::Object) {
        *why = "monitor_db.json isn't a valid JSON object" + (err.empty() ? std::string() : ": " + err);
        return false;
    }
    return true;
}

// The six identity values, in hash order.
struct Identity {
    std::string manufacturer;
    long long productId = 0;
    std::string productName;
    long long controllerId = 0;
    long long firmware = 0;
    long long dimmingMax = 0;
};

// The canonical identity JSON that gets hashed (same text as the macOS build).
static std::string identityJson(const Identity& id) {
    char nums[200];
    snprintf(nums, sizeof(nums),
             ",\"display_controller_id\":%lld,\"firmware_version\":%lld,\"local_dimming_range_max\":%lld}",
             id.controllerId, id.firmware, id.dimmingMax);
    return "{\"manufacturer\":" + jsonQuote(id.manufacturer) +
           ",\"product_id\":" + std::to_string(id.productId) +
           ",\"product_name\":" + jsonQuote(id.productName) + nums;
}

// The connected monitor's identity. Returns false with *why set if a value can't be read.
static bool readIdentity(HANDLE hMon, const DisplayTarget& t, Identity* out, std::string* why) {
    struct { BYTE code; bool useMax; const char* what; } vcp[] = {
        { kVcpControllerId,     false, "display controller ID (VCP 0xC8)" },
        { kVcpFirmwareVersion,  false, "firmware version (VCP 0xC9)" },
        { kVcpLocalDimmingRange, true, "local dimming range max (VCP 0xF4)" },
    };
    DWORD got[3];
    for (size_t i = 0; i < 3; i++) {
        DWORD cur = 0, max = 0;
        if (!vcpGetRetry(hMon, vcp[i].code, &cur, &max, kIdentityReadAttempts)) {
            *why = std::string(vcp[i].what) + ": no reply (DDC busy? another DDC app running?)";
            return false;
        }
        got[i] = vcp[i].useMax ? max : cur;
    }
    out->manufacturer = decodeEdidMfg(t.edidMfgRaw);
    out->productId    = t.edidProductCode;
    out->productName  = narrow(t.friendlyName);
    out->controllerId = got[0];
    out->firmware     = got[1];
    out->dimmingMax   = got[2];
    return true;
}

// An identity section from my_monitor.json. Returns false if a value is missing or the wrong type.
static bool identityFromJson(const JsonValue& v, Identity* out) {
    const JsonValue* mfr  = v.get("manufacturer");
    const JsonValue* pid  = v.get("product_id");
    const JsonValue* name = v.get("product_name");
    const JsonValue* ctl  = v.get("display_controller_id");
    const JsonValue* fw   = v.get("firmware_version");
    const JsonValue* ld   = v.get("local_dimming_range_max");
    if (!mfr || mfr->type != JsonValue::String || !name || name->type != JsonValue::String ||
        !pid || pid->type != JsonValue::Number || !ctl || ctl->type != JsonValue::Number ||
        !fw || fw->type != JsonValue::Number || !ld || ld->type != JsonValue::Number)
        return false;
    out->manufacturer = mfr->str;
    out->productId    = (long long)pid->num;
    out->productName  = name->str;
    out->controllerId = (long long)ctl->num;
    out->firmware     = (long long)fw->num;
    out->dimmingMax   = (long long)ld->num;
    return true;
}

// "firmware_version is 1, my_monitor.json has 0" for each field that differs.
static std::string identityDiff(const Identity& live, const Identity& mine) {
    std::string out;
    auto add = [&out](const char* key, const std::string& a, const std::string& b) {
        if (a == b) return;
        if (!out.empty()) out += "; ";
        out += std::string(key) + " is " + a + ", my_monitor.json has " + b;
    };
    add("manufacturer", live.manufacturer, mine.manufacturer);
    add("product_id", std::to_string(live.productId), std::to_string(mine.productId));
    add("product_name", live.productName, mine.productName);
    add("display_controller_id", std::to_string(live.controllerId), std::to_string(mine.controllerId));
    add("firmware_version", std::to_string(live.firmware), std::to_string(mine.firmware));
    add("local_dimming_range_max", std::to_string(live.dimmingMax), std::to_string(mine.dimmingMax));
    return out;
}

static void stripBom(std::string* s) {
    if (s->compare(0, 3, "\xEF\xBB\xBF") == 0) s->erase(0, 3);   // UTF-8 BOM, e.g. from Notepad
}

// The hash in my_monitor.json, with its identity in *identity. Returns false with *why set if the
// file is missing or invalid, including when its key isn't the hash of its identity section.
static bool readMyMonitor(std::string* hash, Identity* identity, std::string* why) {
    std::string text, err;
    if (!readFile(pathNextToTool(L"my_monitor.json"), &text)) {
        *why = "my_monitor.json not found (run: hdrctl identify --save)";
        return false;
    }
    stripBom(&text);
    JsonValue json;
    if (!JsonParser(text).parse(&json, &err) || json.type != JsonValue::Object || json.keys.size() != 1) {
        *why = "my_monitor.json isn't valid: it must be a JSON object with one monitor (run: hdrctl identify --save)";
        return false;
    }
    const JsonValue* ident = json.items[0].get("identity");
    Identity id;
    if (!ident || !identityFromJson(*ident, &id)) {
        *why = "my_monitor.json isn't valid: its identity section is missing or incomplete (run: hdrctl identify --save)";
        return false;
    }
    std::string computed;
    if (!sha256Hex(identityJson(id), &computed) || computed != json.keys[0]) {
        *why = "my_monitor.json isn't valid: its key doesn't match its identity section (run: hdrctl identify --save)";
        return false;
    }
    *hash = json.keys[0];
    if (identity) *identity = id;
    return true;
}

// Writes my_monitor.json for this identity and removes an old one-line my_monitor file.
static bool saveMyMonitor(const Identity& id, std::string* err) {
    std::string hash;
    if (!sha256Hex(identityJson(id), &hash)) { *err = "couldn't compute SHA-256"; return false; }
    std::string text =
        "{\n  \"" + hash + "\": {\n    \"identity\": {\n"
        "      \"manufacturer\": " + jsonQuote(id.manufacturer) + ",\n"
        "      \"product_id\": " + std::to_string(id.productId) + ",\n"
        "      \"product_name\": " + jsonQuote(id.productName) + ",\n"
        "      \"display_controller_id\": " + std::to_string(id.controllerId) + ",\n"
        "      \"firmware_version\": " + std::to_string(id.firmware) + ",\n"
        "      \"local_dimming_range_max\": " + std::to_string(id.dimmingMax) + "\n"
        "    }\n  }\n}\n";
    FILE* f = NULL;
    if (_wfopen_s(&f, pathNextToTool(L"my_monitor.json").c_str(), L"wb") != 0 || !f) {
        *err = "can't open the file for writing";
        return false;
    }
    bool ok = fwrite(text.data(), 1, text.size(), f) == text.size();
    ok = (fclose(f) == 0) && ok;
    if (!ok) { *err = "write failed"; return false; }
    DeleteFileW(pathNextToTool(L"my_monitor").c_str());   // old one-line format
    return true;
}

// If my_monitor.json doesn't exist, creates it for this identity (replacing an old one-line
// my_monitor) and prints an info line.
static void ensureMyMonitor(const Identity& id) {
    std::wstring path = pathNextToTool(L"my_monitor.json");
    if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) return;
    std::wstring oldPath = pathNextToTool(L"my_monitor");
    std::string oldHash;
    bool hadOld = readFile(oldPath, &oldHash);
    if (hadOld) {
        stripBom(&oldHash);
        size_t a = oldHash.find_first_not_of(" \t\r\n"), b = oldHash.find_last_not_of(" \t\r\n");
        oldHash = a == std::string::npos ? std::string() : oldHash.substr(a, b - a + 1);
    }
    std::string err, hash;
    if (!saveMyMonitor(id, &err)) {
        warn("couldn't create %s: %s", narrow(path).c_str(), err.c_str());
        return;
    }
    sha256Hex(identityJson(id), &hash);
    if (hadOld)
        printf("Replaced %s with my_monitor.json for %s%s\n", narrow(oldPath).c_str(), id.productName.c_str(),
               oldHash == hash ? "" : (" (the old file was for a different monitor, " + oldHash + ")").c_str());
    else
        printf("Created %s for %s (%s)\n", narrow(path).c_str(), id.productName.c_str(), hash.c_str());
}

struct LocalDimming {
    BYTE code = 0;
    std::vector<std::string> names;   // lowercase
    std::vector<DWORD> values;        // parallel to names

    const DWORD* value(const char* name) const {
        for (size_t i = 0; i < names.size(); i++)
            if (names[i] == name) return &values[i];
        return NULL;
    }
    const char* name(DWORD v) const {
        for (size_t i = 0; i < values.size(); i++)
            if (values[i] == v) return names[i].c_str();
        return NULL;
    }
};

static bool parseLocalDimming(const JsonValue& entry, LocalDimming* out, std::string* why) {
    const JsonValue* settings = entry.get("settings");
    const JsonValue* ld = settings ? settings->get("local_dimming") : NULL;
    const JsonValue* vcp = ld ? ld->get("vcp") : NULL;
    const JsonValue* levels = ld ? ld->get("levels") : NULL;
    char* end = NULL;
    unsigned long code = (vcp && vcp->type == JsonValue::String) ? strtoul(vcp->str.c_str(), &end, 16) : 0;
    if (!vcp || vcp->type != JsonValue::String || end == vcp->str.c_str() || *end || code > 0xFF ||
        !levels || levels->type != JsonValue::Array) {
        *why = "monitor_db.json: settings.local_dimming needs \"vcp\" (e.g. \"0xF4\") and \"levels\"";
        return false;
    }
    out->code = (BYTE)code;
    for (size_t i = 0; i < levels->items.size(); i++) {
        const JsonValue* n = levels->items[i].get("name");
        const JsonValue* v = levels->items[i].get("value");
        if (!n || n->type != JsonValue::String || !v || v->type != JsonValue::Number ||
            v->num < 0 || v->num > 0xFFFF) {
            *why = "monitor_db.json: each local dimming level needs \"name\" and \"value\"";
            return false;
        }
        std::string name = n->str;
        for (size_t k = 0; k < name.size(); k++) name[k] = (char)tolower((unsigned char)name[k]);
        out->names.push_back(name);
        out->values.push_back((DWORD)v->num);
    }
    return true;
}

// The local dimming settings for the connected monitor, if it matches
// my_monitor.json and is in monitor_db.json. Otherwise false, with *why set.
// Creates my_monitor.json first if it doesn't exist (see ensureMyMonitor).
static bool findMonitor(HANDLE hMon, const DisplayTarget& t, LocalDimming* out, std::string* why) {
    Identity live, mine;
    std::string hash, mineHash;
    if (!readIdentity(hMon, t, &live, why)) return false;
    if (!sha256Hex(identityJson(live), &hash)) { *why = "couldn't compute SHA-256"; return false; }
    ensureMyMonitor(live);
    if (!readMyMonitor(&mineHash, &mine, why)) return false;
    if (hash != mineHash) {
        std::string diff = identityDiff(live, mine);
        *why = "connected monitor doesn't match my_monitor.json: " + (diff.empty() ? hash : diff) +
               " (if this is your monitor, run: hdrctl identify --save)";
        return false;
    }
    JsonValue db;
    if (!loadDB(&db, why)) return false;
    const JsonValue* entry = db.get(hash.c_str());
    if (!entry || entry->type != JsonValue::Object) { *why = hash + " isn't in monitor_db.json"; return false; }
    return parseLocalDimming(*entry, out, why);
}

// Same as findMonitor, but prints "monitor unknown". Call before any change.
static bool requireMonitor(HANDLE hMon, const DisplayTarget& t, LocalDimming* out) {
    std::string why;
    if (findMonitor(hMon, t, out, &why)) return true;
    fprintf(stderr, "monitor unknown: %s — not changing anything\n", why.c_str());
    return false;
}

// Write local dimming, read it back, and retry: the monitor silently drops DDC
// writes while busy. Skip the write when it is already at the target, since
// reads don't wear the monitor's memory.
static bool setLocalDimming(HANDLE hMon, BYTE code, DWORD want) {
    DWORD cur = 0;
    if (vcpGetRetry(hMon, code, &cur, NULL) && cur == want)
        return true;

    for (int attempt = 0; attempt < kDimmingMaxAttempts; attempt++) {
        vcpSet(hMon, code, want);
        Sleep(kDimmingRetryMs);
        if (vcpGet(hMon, code, &cur, NULL) && cur == want)
            return true;
    }
    warn("couldn't confirm local dimming reached %lu. Another DDC app such as "
         "ClickMonitorDDC can garble replies; quit it and rerun, or check the "
         "monitor's menu.", want);
    return false;
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
    // Read only, so an unknown monitor isn't an error.
    LocalDimming ld;
    std::string why;
    DWORD cur = 0;
    if (!findMonitor(hMon, t, &ld, &why)) {
        printf("  local dimming: monitor unknown (%s)\n", why.c_str());
    } else if (!vcpGetRetry(hMon, ld.code, &cur, NULL)) {
        printf("  local dimming: unknown (DDC read failed)\n");
    } else {
        const char* name = ld.name(cur);
        printf("  local dimming: %s (%lu)\n", name ? name : "unknown", cur);
    }
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
    LocalDimming ld;
    if (!requireMonitor(hMon, t, &ld)) {
        DestroyPhysicalMonitor(hMon);
        return 1;
    }
    const char* level = on ? "standard" : "off";
    const DWORD* want = ld.value(level);
    if (!want) {
        fprintf(stderr, "monitor_db.json has no local dimming level \"%s\" for this monitor\n", level);
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

    if (setLocalDimming(hMon, ld.code, *want))
        printf("local dimming %s\n", level);
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
        fprintf(stderr, "ddc needs a subcommand: dump, get <code>, set <code> <value>\n");
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
            unsigned long code = 0;
            if (!parseNum(argv[1], &code)) {
                fprintf(stderr, "not a number: %s\n", argv[1]);
                rc = 1;
            } else if (code > 0xFF) {
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
        // Only the local dimming levels monitor_db.json lists for this monitor
        // can be written: other codes can factory-reset the monitor, change
        // input or power, or hit vendor service settings.
        LocalDimming ld;
        unsigned long code = 0, value = 0;
        if (argc < 3) {
            fprintf(stderr, "ddc set needs a code and a value, e.g. ddc set 0xF4 2\n");
            rc = 1;
        } else if (!parseNum(argv[1], &code)) {
            fprintf(stderr, "not a number: %s\n", argv[1]);
            rc = 1;
        } else if (!parseNum(argv[2], &value)) {
            fprintf(stderr, "not a number: %s\n", argv[2]);
            rc = 1;
        } else if (!requireMonitor(hMon, t, &ld)) {
            rc = 1;
        } else {
            const char* name = (code == ld.code) ? ld.name((DWORD)value) : NULL;
            if (!name) {
                std::string ok;
                for (size_t i = 0; i < ld.names.size(); i++)
                    ok += (i ? ", " : "") + ld.names[i] + " = " + std::to_string(ld.values[i]);
                fprintf(stderr, "warning: only VCP 0x%02X with a listed level is allowed (%s) "
                        "— not changing anything\n", ld.code, ok.c_str());
                rc = 1;
            } else if (setLocalDimming(hMon, ld.code, (DWORD)value)) {
                printf("local dimming %s\n", name);
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

static int cmdIdentify(const std::wstring& displayName, bool save) {
    DisplayTarget t;
    if (!findTarget(displayName, &t)) return 1;
    HANDLE hMon = NULL;
    if (!openPhysicalMonitor(t, &hMon)) return 1;
    Identity live;
    std::string identity, hash, why;
    bool ok = readIdentity(hMon, t, &live, &why);
    DestroyPhysicalMonitor(hMon);
    if (!ok) {
        fprintf(stderr, "error: %s\n", why.c_str());
        return 1;
    }
    identity = identityJson(live);
    if (!sha256Hex(identity, &hash)) {
        fprintf(stderr, "error: couldn't compute SHA-256\n");
        return 1;
    }
    if (save) {
        std::string err;
        if (!saveMyMonitor(live, &err)) {
            fprintf(stderr, "error: couldn't write %s: %s\n", narrow(pathNextToTool(L"my_monitor.json")).c_str(), err.c_str());
            return 1;
        }
        printf("Saved %s\n", narrow(pathNextToTool(L"my_monitor.json")).c_str());
    } else {
        ensureMyMonitor(live);
    }
    std::string mine, mineWhy;
    bool haveMine = readMyMonitor(&mine, NULL, &mineWhy);
    JsonValue db;
    std::string dbWhy;
    const char* listed = !loadDB(&db, &dbWhy) ? "not listed"
                       : db.get(hash.c_str()) ? "listed" : "not listed";
    printf("Identity:        %s\n", identity.c_str());
    printf("Hash:            %s\n", hash.c_str());
    printf("monitor_db.json: %s%s%s\n", listed, dbWhy.empty() ? "" : " (", dbWhy.empty() ? "" : (dbWhy + ")").c_str());
    printf("my_monitor.json: %s\n", !haveMine ? mineWhy.c_str() : mine == hash ? "matches" : "different monitor");
    return 0;
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
"  hdrctl ddc set <code> <value>    local dimming level listed in monitor_db.json (the only DDC write allowed)\n"
"  hdrctl identify [--save]         print the monitor's identity and hash; --save rewrites my_monitor.json\n"
"\n"
"Options:\n"
"  --display <text>       part of the display name        (default: %s)\n"
"  --legacy-hdr           use the Windows 10 advanced-color API, not the\n"
"                         Windows 11 24H2+ one\n",
    narrow(kDefaultDisplay).c_str());
}

int main(int argc, char** argv) {
    SetConsoleOutputCP(CP_UTF8);

    std::wstring displayName = kDefaultDisplay;
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
    if (cmd == "identify") return cmdIdentify(displayName, rest.size() > 1 && std::string(rest[1]) == "--save");
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
