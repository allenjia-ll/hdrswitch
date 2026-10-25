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
// Monitor DB
//
// A monitor is identified by the SHA-256 of its identity values, in this
// order, as compact JSON (the same text and hash as the macOS build):
//   {"manufacturer":"SKG","product_id":10158,"product_name":"M27P6S",
//    "display_controller_id":22021,"firmware_version":0,"local_dimming_range_max":5}
// monitor_db.json (next to hdrctl.exe) maps that hash to the identity and the
// monitor's DDC settings. my_monitor (next to hdrctl.exe) holds the hash of
// the monitor set up on this PC. Before any DDC write, the connected monitor
// is read, hashed, and must match my_monitor and be in the DB.
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

static std::string readMyMonitor() {
    std::string s;
    if (!readFile(pathNextToTool(L"my_monitor"), &s)) return std::string();
    if (s.compare(0, 3, "\xEF\xBB\xBF") == 0) s.erase(0, 3);   // UTF-8 BOM, e.g. from Notepad
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return std::string();
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
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

// The canonical identity JSON of the connected monitor. Returns false with
// *why set if a value can't be read.
static bool readIdentity(HANDLE hMon, const DisplayTarget& t, std::string* identity, std::string* why) {
    struct { BYTE code; bool useMax; const char* what; } vcp[] = {
        { kVcpControllerId,     false, "display controller ID (VCP 0xC8)" },
        { kVcpFirmwareVersion,  false, "firmware version (VCP 0xC9)" },
        { kVcpLocalDimmingRange, true, "local dimming range max (VCP 0xF4)" },
    };
    DWORD got[3];
    for (size_t i = 0; i < 3; i++) {
        DWORD cur = 0, max = 0;
        if (!vcpGetRetry(hMon, vcp[i].code, &cur, &max)) {
            *why = std::string(vcp[i].what) + ": no reply (DDC busy? another DDC app running?)";
            return false;
        }
        got[i] = vcp[i].useMax ? max : cur;
    }
    char nums[160];
    snprintf(nums, sizeof(nums),
             ",\"display_controller_id\":%lu,\"firmware_version\":%lu,\"local_dimming_range_max\":%lu}",
             got[0], got[1], got[2]);
    *identity = "{\"manufacturer\":" + jsonQuote(decodeEdidMfg(t.edidMfgRaw)) +
                ",\"product_id\":" + std::to_string(t.edidProductCode) +
                ",\"product_name\":" + jsonQuote(narrow(t.friendlyName)) + nums;
    return true;
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
// my_monitor and is in monitor_db.json. Otherwise false, with *why set.
static bool findMonitor(HANDLE hMon, const DisplayTarget& t, LocalDimming* out, std::string* why) {
    std::string identity, hash;
    if (!readIdentity(hMon, t, &identity, why)) return false;
    if (!sha256Hex(identity, &hash)) { *why = "couldn't compute SHA-256"; return false; }
    std::string mine = readMyMonitor();
    if (mine.empty()) { *why = "my_monitor not found next to hdrctl.exe (see hdrctl identify)"; return false; }
    if (hash != mine) { *why = "connected monitor is " + hash + ", my_monitor is " + mine; return false; }
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
        // Only the local dimming levels monitor_db.json lists for this monitor
        // can be written: other codes can factory-reset the monitor, change
        // input or power, or hit vendor service settings.
        LocalDimming ld;
        if (argc < 3) {
            fprintf(stderr, "ddc set needs a code and a value, e.g. ddc set 0xF4 2\n");
            rc = 1;
        } else if (!requireMonitor(hMon, t, &ld)) {
            rc = 1;
        } else {
            long code  = strtol(argv[1], NULL, 0);
            long value = strtol(argv[2], NULL, 0);
            const char* name = (code == (long)ld.code && value >= 0) ? ld.name((DWORD)value) : NULL;
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

static int cmdIdentify(const std::wstring& displayName) {
    DisplayTarget t;
    if (!findTarget(displayName, &t)) return 1;
    HANDLE hMon = NULL;
    if (!openPhysicalMonitor(t, &hMon)) return 1;
    std::string identity, hash, why;
    bool ok = readIdentity(hMon, t, &identity, &why);
    DestroyPhysicalMonitor(hMon);
    if (!ok) {
        fprintf(stderr, "error: %s\n", why.c_str());
        return 1;
    }
    if (!sha256Hex(identity, &hash)) {
        fprintf(stderr, "error: couldn't compute SHA-256\n");
        return 1;
    }
    JsonValue db;
    std::string dbWhy;
    const char* listed = !loadDB(&db, &dbWhy) ? "not listed"
                       : db.get(hash.c_str()) ? "listed" : "not listed";
    std::string mine = readMyMonitor();
    printf("Identity:        %s\n", identity.c_str());
    printf("Hash:            %s\n", hash.c_str());
    printf("monitor_db.json: %s%s%s\n", listed, dbWhy.empty() ? "" : " (", dbWhy.empty() ? "" : (dbWhy + ")").c_str());
    printf("my_monitor:      %s\n", mine.empty() ? "not found" : mine == hash ? "matches" : "different monitor");
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
"  hdrctl identify                  print the monitor's identity and hash (for my_monitor / monitor_db.json)\n"
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
    if (cmd == "identify") return cmdIdentify(displayName);
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
