// hdrctl — toggle HDR and set the color profile of an external display on macOS.
//
// Runs once and exits: no background app, no daemon, nothing else touched.
//
//   hdrctl list                      list displays, HDR state and current profile
//   hdrctl status                    HDR state + profile + local dimming of the target display
//   hdrctl on                        HDR on  + HDR profile  (default: "Rec. ITU-R BT.2020-1") + local dimming Standard
//   hdrctl off                       HDR off + SDR profile  (default: "Display P3") + local dimming Off
//   hdrctl toggle                    flip between on/off
//   hdrctl hdr on|off                HDR only
//   hdrctl profile <name|path>       color profile only
//   hdrctl ddc dump|get <code>       read monitor settings (DDC/CI VCP codes)
//   hdrctl ddc set <code> <value>    local dimming level listed in monitor_db.json (the only DDC write allowed)
//   hdrctl identify                  print the monitor's identity and hash (for my_monitor / monitor_db.json)
//
// Options:
//   --display <text>       part of the display name (default: M27P6S)
//   --hdr-profile <spec>   profile description or .icc path used by "on"  (default: "Rec. ITU-R BT.2020-1")
//   --sdr-profile <spec>   profile description or .icc path used by "off" (default: "Display P3")
//
// HDR switching uses SkyLight (private framework, macOS 11+), loaded at runtime.
// Color profiles use the public ColorSync API (same as System Settings > Displays > Color profile).
// Local dimming is set on the monitor over DDC/CI via IOAVService (private IOKit API, Apple Silicon).
//
// Build: clang -fobjc-arc -O2 -Wall -framework AppKit -framework ApplicationServices -framework IOKit hdrctl.m -o hdrctl

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <unistd.h>

typedef int  (*SLSSetHDRFn)(CGDirectDisplayID display, bool enabled, int reserved1, int reserved2);
typedef bool (*SLSDisplayBoolFn)(CGDirectDisplayID display);

static SLSSetHDRFn      SLSSetHDR;
static SLSDisplayBoolFn SLSIsHDR;
static SLSDisplayBoolFn SLSSupportsHDR;

// ------------------------------------------------------------------ output --

static void die(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void die(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "error: %s\n", s.UTF8String);
    exit(1);
}

static void say(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", s.UTF8String);
    fflush(stdout);
}

static void usage(int code) {
    printf(
        "usage: hdrctl [--display <name>] [--hdr-profile <spec>] [--sdr-profile <spec>] <command>\n"
        "\n"
        "commands:\n"
        "  list                  list displays, HDR state and current profile\n"
        "  status                HDR state, profile and local dimming of the target display\n"
        "  on                    HDR on  + HDR profile (default: Rec. ITU-R BT.2020-1) + local dimming Standard\n"
        "  off                   HDR off + SDR profile (default: Display P3) + local dimming Off\n"
        "  toggle                flip between on and off\n"
        "  hdr on|off            change HDR only\n"
        "  profile <name|path>   change color profile only\n"
        "  ddc dump              read all monitor settings (DDC/CI VCP codes)\n"
        "  ddc get <code>        read one VCP code (e.g. 0xF4)\n"
        "  ddc set <code> <value> local dimming level listed in monitor_db.json (the only write allowed)\n"
        "  identify              print the monitor's identity and hash (for my_monitor / monitor_db.json)\n"
        "\n"
        "A profile <spec> is either a path to an .icc/.icm file or (part of) the\n"
        "profile's name as shown in System Settings > Displays > Color profile.\n");
    exit(code);
}

// --------------------------------------------------------------- SkyLight --

static void loadSkyLight(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!h) die(@"cannot load SkyLight framework: %s", dlerror());
    SLSSetHDR      = (SLSSetHDRFn)dlsym(h, "SLSDisplaySetHDRModeEnabled");
    SLSIsHDR       = (SLSDisplayBoolFn)dlsym(h, "SLSDisplayIsHDRModeEnabled");
    SLSSupportsHDR = (SLSDisplayBoolFn)dlsym(h, "SLSDisplaySupportsHDRMode");
    if (!SLSSetHDR || !SLSIsHDR || !SLSSupportsHDR)
        die(@"this macOS version doesn't expose the expected SkyLight HDR functions");
}

// --------------------------------------------------------------- displays --

static NSArray<NSDictionary *> *allDisplays(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
        if (!n) continue;
        [out addObject:@{ @"id": n, @"name": s.localizedName ?: @"(unknown)" }];
    }
    return out;
}

static CGDirectDisplayID findDisplay(NSString *needle, NSString **outName) {
    NSMutableArray<NSDictionary *> *hits = [NSMutableArray array];
    for (NSDictionary *d in allDisplays())
        if ([d[@"name"] rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
            [hits addObject:d];
    if (hits.count == 0)
        die(@"no connected display matches \"%@\" — is it connected to this Mac? (run: hdrctl list)", needle);
    if (hits.count > 1)
        die(@"%lu displays match \"%@\" — use a more specific --display", (unsigned long)hits.count, needle);
    if (outName) *outName = hits[0][@"name"];
    return [hits[0][@"id"] unsignedIntValue];
}

// --------------------------------------------------------------- profiles --

static NSString *profileDescription(ColorSyncProfileRef p) {
    if (!p) return nil;
    CFStringRef d = ColorSyncProfileCopyDescriptionString(p);
    return d ? CFBridgingRelease(d) : nil;
}

static NSString *currentProfile(CGDirectDisplayID d) {
    ColorSyncProfileRef p = ColorSyncProfileCreateWithDisplayID(d);
    NSString *s = profileDescription(p);
    if (p) CFRelease(p);
    return s ?: @"(unknown)";
}

// Accepts an .icc/.icm path, or a profile name (exact match preferred, then substring).
// Search order: ~/Library, /Library, /System/Library ColorSync profile folders.
static NSURL *resolveProfile(NSString *spec) {
    NSString *lower = spec.lowercaseString;
    if ([spec hasPrefix:@"/"] || [spec hasPrefix:@"~"] ||
        [lower hasSuffix:@".icc"] || [lower hasSuffix:@".icm"]) {
        NSString *path = spec.stringByExpandingTildeInPath;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            die(@"profile file not found: %@", path);
        return [NSURL fileURLWithPath:path];
    }

    NSArray *dirs = @[ [@"~/Library/ColorSync/Profiles" stringByExpandingTildeInPath],
                       @"/Library/ColorSync/Profiles",
                       @"/System/Library/ColorSync/Profiles" ];
    NSURL *partial = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        NSDirectoryEnumerator *e = [fm enumeratorAtURL:[NSURL fileURLWithPath:dir isDirectory:YES]
                            includingPropertiesForKeys:nil
                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                          errorHandler:nil];
        for (NSURL *url in e) {
            NSString *ext = url.pathExtension.lowercaseString;
            if (![ext isEqualToString:@"icc"] && ![ext isEqualToString:@"icm"]) continue;
            ColorSyncProfileRef p = ColorSyncProfileCreateWithURL((__bridge CFURLRef)url, NULL);
            NSString *desc = profileDescription(p);
            if (p) CFRelease(p);
            if (!desc) continue;
            if ([desc caseInsensitiveCompare:spec] == NSOrderedSame) return url;
            if (!partial && [desc rangeOfString:spec options:NSCaseInsensitiveSearch].location != NSNotFound)
                partial = url;
        }
    }
    if (!partial) die(@"no installed color profile named like \"%@\"", spec);
    return partial;
}

static void setProfile(CGDirectDisplayID d, NSURL *url) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(d);
    if (!uuid) die(@"cannot get the display's ColorSync UUID");
    NSDictionary *info = @{
        (__bridge NSString *)kColorSyncDeviceDefaultProfileID: url,
        (__bridge NSString *)kColorSyncProfileUserScope: (__bridge NSString *)kCFPreferencesCurrentUser,
    };
    bool ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid,
                                               (__bridge CFDictionaryRef)info);
    CFRelease(uuid);
    if (!ok) die(@"ColorSync refused profile %@", url.path);

    // Confirm (ColorSync applies asynchronously; give it a moment).
    ColorSyncProfileRef p = ColorSyncProfileCreateWithURL((__bridge CFURLRef)url, NULL);
    NSString *want = profileDescription(p);
    if (p) CFRelease(p);
    for (int i = 0; i < 20 && want && ![currentProfile(d) isEqualToString:want]; i++) usleep(100000);
    say(@"Color profile: %@", currentProfile(d));
}

// -------------------------------------------------------------------- HDR --

static void setHDR(CGDirectDisplayID d, BOOL on) {
    if (!SLSSupportsHDR(d))
        fprintf(stderr, "warning: macOS doesn't report HDR support for this display "
                        "in its current mode; trying anyway\n");
    if ((BOOL)SLSIsHDR(d) == on) { say(@"HDR already %@", on ? @"on" : @"off"); return; }

    say(@"Turning HDR %@…", on ? @"on" : @"off");
    int err = SLSSetHDR(d, on, 0, 0);
    if (err != 0) die(@"SLSDisplaySetHDRModeEnabled returned %d", err);

    for (int i = 0; i < 40 && (BOOL)SLSIsHDR(d) != on; i++) usleep(250000);   // up to 10 s
    if ((BOOL)SLSIsHDR(d) != on) die(@"HDR did not switch %@ within 10 seconds", on ? @"on" : @"off");
    sleep(2);   // let the monitor and WindowServer settle before changing the profile
}

static void printStatus(CGDirectDisplayID d, NSString *name) {
    say(@"%@  (id %u)", name, d);
    say(@"  HDR supported: %@", SLSSupportsHDR(d) ? @"yes" : @"no");
    say(@"  HDR enabled:   %@", SLSIsHDR(d) ? @"on" : @"off");
    say(@"  Color profile: %@", currentProfile(d));
}

// -------------------------------------------------------------------- DDC --
// Monitor settings (VCP codes) over DDC/CI, via IOAVService (Apple Silicon, IOKit private API).

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset,
                                   void *buf, uint32_t len);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress,
                                    void *buf, uint32_t len);

// Walk the IOService plane: each external DCPAVServiceProxy belongs to the framebuffer seen before it.
// outAttrs gets the display's EDID ProductAttributes (ManufacturerID, ProductID, ProductName, ...).
static IOAVServiceRef findAVService(NSString *needle, NSDictionary **outAttrs) {
    io_iterator_t it;
    if (IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS)
        die(@"cannot iterate the IO registry");
    IOAVServiceRef found = NULL;
    NSDictionary *lastAttrs = nil;
    io_service_t s;
    while (!found && (s = IOIteratorNext(it))) {
        io_name_t cls;
        IOObjectGetClass(s, cls);
        if (!strcmp(cls, "IOMobileFramebufferShim") || !strcmp(cls, "AppleCLCD2")) {
            NSDictionary *attrs = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR("DisplayAttributes"), kCFAllocatorDefault, 0));
            if (attrs[@"ProductAttributes"][@"ProductName"]) lastAttrs = attrs[@"ProductAttributes"];
        } else if (!strcmp(cls, "DCPAVServiceProxy")) {
            NSString *loc = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR("Location"), kCFAllocatorDefault, 0));
            if ([loc isEqualToString:@"External"] && lastAttrs &&
                [lastAttrs[@"ProductName"] rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
                found = IOAVServiceCreateWithService(kCFAllocatorDefault, s);
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (!found) die(@"no DDC connection to a display matching \"%@\"", needle);
    if (outAttrs) *outAttrs = lastAttrs;
    return found;
}

static void ddcWrite(IOAVServiceRef av, uint8_t *pkt, uint32_t len) {
    uint8_t chk = 0x6E ^ 0x51;
    for (uint32_t i = 0; i < len - 1; i++) chk ^= pkt[i];
    pkt[len - 1] = chk;
    IOReturn err = kIOReturnError;
    for (int i = 0; i < 3 && err != kIOReturnSuccess; i++) {   // the bus is flaky; retry
        usleep(10000);
        err = IOAVServiceWriteI2C(av, 0x37, 0x51, pkt, len);
    }
    if (err != kIOReturnSuccess) die(@"DDC write failed (0x%x)", err);
}

// One read. Returns 1 = value, 0 = monitor says unsupported, -1 = no valid reply.
static int ddcGetOnce(IOAVServiceRef av, uint8_t code, uint16_t *cur, uint16_t *max) {
    uint8_t req[4] = { 0x82, 0x01, code, 0 };
    ddcWrite(av, req, sizeof req);
    usleep(50000);
    uint8_t r[11] = { 0 };
    if (IOAVServiceReadI2C(av, 0x37, 0x51, r, sizeof r) != kIOReturnSuccess) return -1;
    // reply: 6E 88 02 <result> <code> <type> <maxH> <maxL> <curH> <curL> <chk>
    uint8_t chk = 0x50;
    for (int i = 0; i < 10; i++) chk ^= r[i];
    if (chk != r[10] || r[1] != 0x88 || r[2] != 0x02 || r[4] != code) return -1;
    if (r[3] != 0) return 0;
    *max = r[6] << 8 | r[7];
    *cur = r[8] << 8 | r[9];
    return 1;
}

// Returns NO if the monitor doesn't support the code. Needs two identical replies in a row,
// since other DDC apps (e.g. MonitorControl) can garble the bus.
static BOOL ddcGet(IOAVServiceRef av, uint8_t code, uint16_t *cur, uint16_t *max) {
    int prev = -1; uint16_t pc = 0, pm = 0;
    for (int attempt = 0; attempt < 6; attempt++) {
        uint16_t c = 0, m = 0;
        int got = ddcGetOnce(av, code, &c, &m);
        if (got < 0) { prev = -1; continue; }
        if (got == prev && c == pc && m == pm) {
            if (got && cur) *cur = c;
            if (got && max) *max = m;
            return got == 1;
        }
        prev = got; pc = c; pm = m;
    }
    return NO;
}

static void ddcSet(IOAVServiceRef av, uint8_t code, uint16_t value) {
    uint8_t pkt[6] = { 0x84, 0x03, code, value >> 8, value & 0xFF, 0 };
    ddcWrite(av, pkt, sizeof pkt);
}

// -------------------------------------------------------------- monitor DB --
// A monitor is identified by the SHA-256 of its identity values, in this order, as compact JSON:
//   {"manufacturer":"SKG","product_id":10158,"product_name":"M27P6S",
//    "display_controller_id":22021,"firmware_version":0,"local_dimming_range_max":5}
// monitor_db.json (next to hdrctl) maps that hash to the identity and the monitor's DDC settings.
// my_monitor (next to hdrctl) holds the hash of the monitor set up on this Mac. Before any DDC
// write, the connected monitor is read, hashed, and must match my_monitor and be in the DB.

static NSString *pathNextToTool(NSString *name) {
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0 || !realpath(exe, real)) die(@"can't find hdrctl's own path");
    return [@(real).stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
}

static NSString *jsonString(NSString *s) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:s
                    options:NSJSONWritingFragmentsAllowed | NSJSONWritingWithoutEscapingSlashes error:NULL];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

// The canonical identity JSON of the connected monitor, or nil with *why set if a value can't be read.
static NSString *readIdentity(IOAVServiceRef av, NSDictionary *attrs, NSString **why) {
    NSString *mfr = attrs[@"ManufacturerID"], *product = attrs[@"ProductName"];
    NSNumber *pid = attrs[@"ProductID"];
    if (![mfr isKindOfClass:NSString.class] || ![product isKindOfClass:NSString.class] ||
        ![pid isKindOfClass:NSNumber.class]) { *why = @"EDID manufacturer, product ID or name not available"; return nil; }

    struct { uint8_t code; BOOL useMax; const char *what; } vcp[] = {
        { 0xC8, NO,  "display controller ID (VCP 0xC8)" },
        { 0xC9, NO,  "firmware version (VCP 0xC9)" },
        { 0xF4, YES, "local dimming range max (VCP 0xF4)" },
    };
    unsigned got[3];
    for (size_t i = 0; i < 3; i++) {
        uint16_t cur = 0, max = 0;
        BOOL ok = NO;
        for (int t = 0; t < 10 && !ok; t++) {   // bus is flaky and failures come in bursts
            if (t) usleep(300000);
            ok = ddcGet(av, vcp[i].code, &cur, &max);
        }
        if (!ok) { *why = [NSString stringWithFormat:@"%s: no reply (DDC busy? quit MonitorControl and retry)", vcp[i].what]; return nil; }
        got[i] = vcp[i].useMax ? max : cur;
    }
    return [NSString stringWithFormat:@"{\"manufacturer\":%@,\"product_id\":%lld,\"product_name\":%@,"
                                       "\"display_controller_id\":%u,\"firmware_version\":%u,\"local_dimming_range_max\":%u}",
            jsonString(mfr), pid.longLongValue, jsonString(product), got[0], got[1], got[2]];
}

static NSString *sha256Hex(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", h[i]];
    return hex;
}

static NSDictionary *loadDB(void) {
    NSString *path = pathNextToTool(@"monitor_db.json");
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    NSError *err = nil;
    id db = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
    if (![db isKindOfClass:NSDictionary.class]) die(@"%@ isn't a valid JSON object: %@", path, err.localizedDescription ?: @"");
    return db;
}

static NSString *readMyMonitor(void) {
    NSString *s = [NSString stringWithContentsOfFile:pathNextToTool(@"my_monitor") encoding:NSUTF8StringEncoding error:NULL];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// The DB entry for the connected monitor, if it matches my_monitor and is in monitor_db.json.
// Otherwise nil, with *why set.
static NSDictionary *findMonitor(IOAVServiceRef av, NSDictionary *attrs, NSString **why) {
    NSString *identity = readIdentity(av, attrs, why);
    if (!identity) return nil;
    NSString *hash = sha256Hex(identity), *mine = readMyMonitor();
    if (!mine.length) { *why = @"my_monitor not found next to hdrctl (see hdrctl identify)"; return nil; }
    if (![hash isEqualToString:mine]) { *why = [NSString stringWithFormat:@"connected monitor is %@, my_monitor is %@", hash, mine]; return nil; }
    NSDictionary *entry = loadDB()[hash];
    if (![entry isKindOfClass:NSDictionary.class]) { *why = [NSString stringWithFormat:@"%@ isn't in monitor_db.json", hash]; return nil; }
    return entry;
}

// Same as findMonitor, but prints "monitor unknown" and exits if there's no match. Call before any change.
static NSDictionary *requireMonitor(IOAVServiceRef av, NSDictionary *attrs) {
    NSString *why = nil;
    NSDictionary *entry = findMonitor(av, attrs, &why);
    if (entry) return entry;
    fprintf(stderr, "monitor unknown: %s — not changing anything\n", why.UTF8String);
    exit(1);
}

// The local dimming VCP code from a DB entry, with its levels (name -> value) in *levels.
static uint8_t localDimming(NSDictionary *entry, NSDictionary<NSString *, NSNumber *> **levels) {
    NSDictionary *ld = entry[@"settings"][@"local_dimming"];
    NSString *vcp = [ld isKindOfClass:NSDictionary.class] ? ld[@"vcp"] : nil;
    NSArray *list = [ld isKindOfClass:NSDictionary.class] ? ld[@"levels"] : nil;
    unsigned code = 0;
    if (![vcp isKindOfClass:NSString.class] || ![[NSScanner scannerWithString:vcp] scanHexInt:&code] ||
        code > 0xFF || ![list isKindOfClass:NSArray.class])
        die(@"monitor_db.json: settings.local_dimming needs \"vcp\" (e.g. \"0xF4\") and \"levels\"");
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSDictionary *l in list) {
        if (![l isKindOfClass:NSDictionary.class] || ![l[@"name"] isKindOfClass:NSString.class] ||
            ![l[@"value"] isKindOfClass:NSNumber.class])
            die(@"monitor_db.json: each local dimming level needs \"name\" and \"value\"");
        out[[l[@"name"] lowercaseString]] = l[@"value"];
    }
    *levels = out;
    return (uint8_t)code;
}

static uint16_t levelValue(NSDictionary<NSString *, NSNumber *> *levels, NSString *name) {
    NSNumber *v = levels[name];
    if (!v) die(@"monitor_db.json has no local dimming level \"%@\" for this monitor", name);
    return v.unsignedShortValue;
}

static NSString *levelName(NSDictionary<NSString *, NSNumber *> *levels, uint16_t value) {
    for (NSString *n in levels) if (levels[n].unsignedShortValue == value) return n;
    return nil;
}

static void setDimming(IOAVServiceRef av, uint8_t code, uint16_t value, NSString *label) {
    uint16_t cur = 0xFFFF;
    // Skip the write (and the monitor's settings-memory wear) if it's already set; reads don't wear it.
    if (ddcGet(av, code, &cur, NULL) && cur == value) { say(@"Local dimming already %@", label); return; }
    // The monitor silently drops writes while busy (e.g. right after an HDR switch): write, verify, repeat.
    for (int i = 0; i < 10; i++) {
        ddcSet(av, code, value);
        sleep(1);
        if (ddcGet(av, code, &cur, NULL) && cur == value) { say(@"Local dimming: %@", label); return; }
    }
    fprintf(stderr, "warning: couldn't confirm local dimming is %s (DDC busy? quit MonitorControl and retry)\n",
            label.UTF8String);
}

static unsigned parseNum(NSString *s) {
    unsigned v = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    BOOL ok = [s.lowercaseString hasPrefix:@"0x"] ? [sc scanHexInt:&v] : [sc scanInt:(int *)&v];
    if (!ok || !sc.isAtEnd) die(@"not a number: %@", s);
    return v;
}

// ------------------------------------------------------------------- main --

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *needle = @"M27P6S";
        NSString *hdrSpec = @"Rec. ITU-R BT.2020-1";
        NSString *sdrSpec = @"Display P3";
        NSMutableArray<NSString *> *args = [NSMutableArray array];

        for (int i = 1; i < argc; i++) {
            NSString *a = @(argv[i]);
            if ([a isEqualToString:@"--display"] && i + 1 < argc)          needle  = @(argv[++i]);
            else if ([a isEqualToString:@"--hdr-profile"] && i + 1 < argc) hdrSpec = @(argv[++i]);
            else if ([a isEqualToString:@"--sdr-profile"] && i + 1 < argc) sdrSpec = @(argv[++i]);
            else if ([a isEqualToString:@"-h"] || [a isEqualToString:@"--help"]) usage(0);
            else [args addObject:a];
        }
        NSString *cmd = args.firstObject;
        if (!cmd || [cmd isEqualToString:@"help"]) usage(cmd ? 0 : 1);

        if ([cmd isEqualToString:@"ddc"] && args.count >= 2) {
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(needle, &attrs);
            NSString *sub = args[1];
            uint16_t cur, max;
            if ([sub isEqualToString:@"dump"]) {
                for (unsigned c = 0x01; c <= 0xFF; c++)
                    if (ddcGet(av, c, &cur, &max)) say(@"0x%02X  %u  (max %u)", c, cur, max);
            } else if ([sub isEqualToString:@"get"] && args.count == 3) {
                unsigned c = parseNum(args[2]);
                if (!ddcGet(av, c, &cur, &max)) die(@"monitor didn't answer VCP 0x%02X", c);
                say(@"0x%02X  %u  (max %u)", c, cur, max);
            } else if ([sub isEqualToString:@"set"] && args.count == 4) {
                // Only the local dimming levels monitor_db.json lists for this monitor can be written.
                unsigned c = parseNum(args[2]), v = parseNum(args[3]);
                NSDictionary<NSString *, NSNumber *> *levels = nil;
                uint8_t code = localDimming(requireMonitor(av, attrs), &levels);
                NSString *label = c == code ? levelName(levels, v) : nil;
                if (!label) {
                    NSMutableArray *ok = [NSMutableArray array];
                    for (NSString *n in levels) [ok addObject:[NSString stringWithFormat:@"%@ = %@", n, levels[n]]];
                    fprintf(stderr, "warning: only VCP 0x%02X with a listed level is allowed (%s) — not changing anything\n",
                            code, [ok componentsJoinedByString:@", "].UTF8String);
                    return 1;
                }
                setDimming(av, code, v, label);
            } else usage(1);
            return 0;
        }

        if ([cmd isEqualToString:@"identify"]) {
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(needle, &attrs);
            NSString *why = nil, *identity = readIdentity(av, attrs, &why);
            if (!identity) die(@"%@", why);
            NSString *hash = sha256Hex(identity), *mine = readMyMonitor();
            say(@"Identity:        %@", identity);
            say(@"Hash:            %@", hash);
            say(@"monitor_db.json: %@", loadDB()[hash] ? @"listed" : @"not listed");
            say(@"my_monitor:      %@", !mine.length ? @"not found" : [mine isEqualToString:hash] ? @"matches" : @"different monitor");
            return 0;
        }

        loadSkyLight();

        if ([cmd isEqualToString:@"list"]) {
            NSArray *ds = allDisplays();
            if (ds.count == 0) say(@"no displays found");
            for (NSDictionary *d in ds) printStatus([d[@"id"] unsignedIntValue], d[@"name"]);
            return 0;
        }

        NSString *name = nil;
        CGDirectDisplayID d = findDisplay(needle, &name);

        if ([cmd isEqualToString:@"status"]) {
            printStatus(d, name);
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(needle, &attrs);
            NSString *why = nil;
            NSDictionary *entry = findMonitor(av, attrs, &why);   // read only, so an unknown monitor isn't an error
            NSDictionary<NSString *, NSNumber *> *levels = nil;
            uint8_t code = entry ? localDimming(entry, &levels) : 0;
            uint16_t cur = 0;
            if (!entry) say(@"  Local dimming: monitor unknown (%@)", why);
            else if (!ddcGet(av, code, &cur, NULL)) say(@"  Local dimming: (no reply over DDC — try again)");
            else say(@"  Local dimming: %@", levelName(levels, cur)
                                                ?: [NSString stringWithFormat:@"unknown (VCP 0x%02X = %u)", code, cur]);
        } else if ([cmd isEqualToString:@"on"] ||
                   ([cmd isEqualToString:@"toggle"] && !SLSIsHDR(d))) {
            NSURL *p = resolveProfile(hdrSpec);          // resolve and verify first, so we fail before switching
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(needle, &attrs);
            NSDictionary<NSString *, NSNumber *> *levels = nil;
            uint8_t code = localDimming(requireMonitor(av, attrs), &levels);
            uint16_t level = levelValue(levels, @"standard");
            setHDR(d, YES);
            setProfile(d, p);
            setDimming(av, code, level, @"standard");
            say(@"Done: %@ — HDR on", name);
        } else if ([cmd isEqualToString:@"off"] || [cmd isEqualToString:@"toggle"]) {
            NSURL *p = resolveProfile(sdrSpec);
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(needle, &attrs);
            NSDictionary<NSString *, NSNumber *> *levels = nil;
            uint8_t code = localDimming(requireMonitor(av, attrs), &levels);
            uint16_t level = levelValue(levels, @"off");
            setHDR(d, NO);
            setProfile(d, p);
            setDimming(av, code, level, @"off");
            say(@"Done: %@ — HDR off", name);
        } else if ([cmd isEqualToString:@"hdr"] && args.count == 2) {
            NSString *v = args[1].lowercaseString;
            if (![v isEqualToString:@"on"] && ![v isEqualToString:@"off"]) usage(1);
            setHDR(d, [v isEqualToString:@"on"]);
            say(@"HDR: %@", SLSIsHDR(d) ? @"on" : @"off");
        } else if ([cmd isEqualToString:@"profile"] && args.count == 2) {
            setProfile(d, resolveProfile(args[1]));
        } else {
            usage(1);
        }
    }
    return 0;
}
