// hdrcore — see hdrcore.h.

#import "hdrcore.h"
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>

// ------------------------------------------------------------------ logging --

static void (^gLogger)(HCLogLevel, NSString *);

void HCSetLogger(void (^logger)(HCLogLevel level, NSString *message)) { gLogger = logger; }

static void logAt(HCLogLevel level, NSString *fmt, va_list ap) NS_FORMAT_FUNCTION(2, 0);
static void logAt(HCLogLevel level, NSString *fmt, va_list ap) {
    if (gLogger) gLogger(level, [[NSString alloc] initWithFormat:fmt arguments:ap]);
}

static void logInfo(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logInfo(NSString *fmt, ...) { va_list ap; va_start(ap, fmt); logAt(HCLogInfo, fmt, ap); va_end(ap); }

static void logWarn(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logWarn(NSString *fmt, ...) { va_list ap; va_start(ap, fmt); logAt(HCLogWarning, fmt, ap); va_end(ap); }

// Sets *error and returns NO.
static BOOL fail(NSString **error, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static BOOL fail(NSString **error, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    if (error) *error = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return NO;
}

// -------------------------------------------------------------- data files --

static NSString *gDataDir;

void HCSetDataDirectory(NSString *dir) { gDataDir = dir; }

NSString *HCToolDirectory(void) {
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0 || !realpath(exe, real)) return nil;
    return @(real).stringByDeletingLastPathComponent;
}

NSString *HCDataDirectory(void) {
    if (gDataDir) return gDataDir;
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
    if (!base) return nil;
    NSString *dir = [base.path stringByAppendingPathComponent:@"HDR Switch"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

static NSString *dataPath(NSString *name) { return [HCDataDirectory() stringByAppendingPathComponent:name]; }

static NSString *gDBPath;

void HCSetDBPath(NSString *path) { gDBPath = path; }

// Before 0.2.1 the CLI kept these next to hdrctl.
static NSArray<NSString *> *toolDirectoryFiles(void) { return @[ @"my_monitor.json", @"my_monitor", @"local_monitor_db.json" ]; }

NSArray<NSString *> *HCMigrateToolDirectoryFiles(void) {
    NSString *from = HCToolDirectory(), *to = HCDataDirectory();
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *moved = [NSMutableArray array];
    if (!from || !to || [from.stringByStandardizingPath isEqualToString:to.stringByStandardizingPath]) return moved;
    for (NSString *name in toolDirectoryFiles()) {
        NSString *old = [from stringByAppendingPathComponent:name], *new = [to stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:old] || [fm fileExistsAtPath:new]) continue;
        NSError *err = nil;
        if ([fm moveItemAtPath:old toPath:new error:&err])
            [moved addObject:[NSString stringWithFormat:@"Moved %@ to %@ (shared with the HDR Switch app)", old, new]];
        else
            logWarn(@"couldn't move %@ to %@: %@", old, new, err.localizedDescription);
    }
    return moved;
}

NSArray<NSString *> *HCToolDirectoryLeftovers(void) {
    NSString *from = HCToolDirectory(), *to = HCDataDirectory();
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *left = [NSMutableArray array];
    if (!from || !to || [from.stringByStandardizingPath isEqualToString:to.stringByStandardizingPath]) return left;
    for (NSString *name in toolDirectoryFiles()) {
        NSString *old = [from stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:old] && [fm fileExistsAtPath:[to stringByAppendingPathComponent:name]]) [left addObject:old];
    }
    return left;
}

// --------------------------------------------------------------- SkyLight --

typedef int  (*SLSSetHDRFn)(CGDirectDisplayID display, bool enabled, int reserved1, int reserved2);
typedef bool (*SLSDisplayBoolFn)(CGDirectDisplayID display);

static SLSSetHDRFn      SLSSetHDR;
static SLSDisplayBoolFn SLSIsHDR;
static SLSDisplayBoolFn SLSSupportsHDR;

BOOL HCLoadSkyLight(NSString **error) {
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!h) return fail(error, @"cannot load SkyLight framework: %s", dlerror());
    SLSSetHDR      = (SLSSetHDRFn)dlsym(h, "SLSDisplaySetHDRModeEnabled");
    SLSIsHDR       = (SLSDisplayBoolFn)dlsym(h, "SLSDisplayIsHDRModeEnabled");
    SLSSupportsHDR = (SLSDisplayBoolFn)dlsym(h, "SLSDisplaySupportsHDRMode");
    if (!SLSSetHDR || !SLSIsHDR || !SLSSupportsHDR)
        return fail(error, @"this macOS version doesn't expose the expected SkyLight HDR functions");
    return YES;
}

BOOL HCSupportsHDR(CGDirectDisplayID d) { return SLSSupportsHDR(d); }
BOOL HCIsHDR(CGDirectDisplayID d)       { return SLSIsHDR(d); }

BOOL HCSetHDR(CGDirectDisplayID d, BOOL on, NSString **error) {
    if (!SLSSupportsHDR(d))
        logWarn(@"macOS doesn't report HDR support for this display in its current mode; trying anyway");
    if ((BOOL)SLSIsHDR(d) == on) { logInfo(@"HDR already %@", on ? @"on" : @"off"); return YES; }

    logInfo(@"Turning HDR %@…", on ? @"on" : @"off");
    int err = SLSSetHDR(d, on, 0, 0);
    if (err != 0) return fail(error, @"SLSDisplaySetHDRModeEnabled returned %d", err);

    for (int i = 0; i < 40 && (BOOL)SLSIsHDR(d) != on; i++) usleep(250000);   // up to 10 s
    if ((BOOL)SLSIsHDR(d) != on) return fail(error, @"HDR did not switch %@ within 10 seconds", on ? @"on" : @"off");
    sleep(2);   // let the monitor and WindowServer settle before changing the profile
    return YES;
}

// --------------------------------------------------------------- displays --

NSString *HCDisplayUUID(CGDirectDisplayID d) {
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(d);
    if (!u) return nil;
    NSString *s = CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, u));
    CFRelease(u);
    return s;
}

NSArray<NSDictionary *> *HCAllDisplays(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
        if (!n) continue;
        [out addObject:@{ @"id": n, @"name": s.localizedName ?: @"(unknown)", @"uuid": HCDisplayUUID(n.unsignedIntValue) ?: @"",
                          @"builtin": @(CGDisplayIsBuiltin(n.unsignedIntValue) != 0) }];
    }
    return out;
}

CGDirectDisplayID HCFindDisplay(NSString *spec, NSString **outName, NSString **error) {
    NSMutableArray<NSDictionary *> *hits = [NSMutableArray array];
    for (NSDictionary *d in HCAllDisplays())
        if (spec ? [d[@"uuid"] caseInsensitiveCompare:spec] == NSOrderedSame ||
                   [d[@"name"] rangeOfString:spec options:NSCaseInsensitiveSearch].location != NSNotFound
                 : ![d[@"builtin"] boolValue])
            [hits addObject:d];
    if (hits.count == 0) {
        if (spec) fail(error, @"no connected display matches \"%@\" — is it connected to this Mac? (run: hdrctl list)", spec);
        else fail(error, @"no external display is connected to this Mac (run: hdrctl list)");
        return 0;
    }
    if (hits.count > 1) {
        if (spec) fail(error, @"%lu displays match \"%@\" — use a more specific --display, or its UUID (run: hdrctl list)",
                       (unsigned long)hits.count, spec);
        else fail(error, @"%lu external displays are connected — choose one with --display <name or UUID> (run: hdrctl list)",
                  (unsigned long)hits.count);
        return 0;
    }
    if (outName) *outName = hits[0][@"name"];
    return [hits[0][@"id"] unsignedIntValue];
}

// --------------------------------------------------------------- profiles --

static NSString *profileDescription(ColorSyncProfileRef p) {
    if (!p) return nil;
    CFStringRef d = ColorSyncProfileCopyDescriptionString(p);
    return d ? CFBridgingRelease(d) : nil;
}

NSString *HCCurrentProfile(CGDirectDisplayID d) {
    ColorSyncProfileRef p = ColorSyncProfileCreateWithDisplayID(d);
    NSString *s = profileDescription(p);
    if (p) CFRelease(p);
    return s ?: @"(unknown)";
}

static NSArray<NSString *> *profileDirs(void) {
    return @[ [@"~/Library/ColorSync/Profiles" stringByExpandingTildeInPath],
              @"/Library/ColorSync/Profiles",
              @"/System/Library/ColorSync/Profiles" ];
}

// Search order: ~/Library, /Library, /System/Library ColorSync profile folders.
NSURL *HCResolveProfile(NSString *spec, NSString **error) {
    NSString *lower = spec.lowercaseString;
    if ([spec hasPrefix:@"/"] || [spec hasPrefix:@"~"] ||
        [lower hasSuffix:@".icc"] || [lower hasSuffix:@".icm"]) {
        NSString *path = spec.stringByExpandingTildeInPath;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            { fail(error, @"profile file not found: %@", path); return nil; }
        return [NSURL fileURLWithPath:path];
    }

    NSURL *partial = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in profileDirs()) {
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
    if (!partial) { fail(error, @"no installed color profile named like \"%@\"", spec); return nil; }
    return partial;
}

NSArray<NSDictionary *> *HCListProfiles(void) {
    NSMutableDictionary<NSString *, NSURL *> *byName = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in profileDirs()) {
        NSDirectoryEnumerator *e = [fm enumeratorAtURL:[NSURL fileURLWithPath:dir isDirectory:YES]
                            includingPropertiesForKeys:nil
                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                          errorHandler:nil];
        for (NSURL *url in e) {
            NSString *ext = url.pathExtension.lowercaseString;
            if (![ext isEqualToString:@"icc"] && ![ext isEqualToString:@"icm"]) continue;
            ColorSyncProfileRef p = ColorSyncProfileCreateWithURL((__bridge CFURLRef)url, NULL);
            if (!p) continue;
            NSString *desc = profileDescription(p);
            NSData *header = CFBridgingRelease(ColorSyncProfileCopyHeader(p));
            CFRelease(p);
            // ICC header: profile class at byte 12, data color space at byte 16. ColorSync returns the
            // header in host byte order, so compare them as 32-bit values: 'mntr' (display) and 'RGB '.
            uint32_t cls = 0, space = 0;
            if (header.length >= 20) { memcpy(&cls, (const char *)header.bytes + 12, 4); memcpy(&space, (const char *)header.bytes + 16, 4); }
            if (!desc || cls != 0x6D6E7472 || space != 0x52474220) continue;
            if (!byName[desc]) byName[desc] = url;   // the first folder in search order wins, as in HCResolveProfile
        }
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in [byName.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)])
        [out addObject:@{ @"name": name, @"url": byName[name] }];
    return out;
}

BOOL HCSetProfile(CGDirectDisplayID d, NSURL *url, NSString **error) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(d);
    if (!uuid) return fail(error, @"cannot get the display's ColorSync UUID");
    NSDictionary *info = @{
        (__bridge NSString *)kColorSyncDeviceDefaultProfileID: url,
        (__bridge NSString *)kColorSyncProfileUserScope: (__bridge NSString *)kCFPreferencesCurrentUser,
    };
    bool ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid,
                                               (__bridge CFDictionaryRef)info);
    CFRelease(uuid);
    if (!ok) return fail(error, @"ColorSync refused profile %@", url.path);

    // Confirm (ColorSync applies asynchronously; give it a moment).
    ColorSyncProfileRef p = ColorSyncProfileCreateWithURL((__bridge CFURLRef)url, NULL);
    NSString *want = profileDescription(p);
    if (p) CFRelease(p);
    for (int i = 0; i < 20 && want && ![HCCurrentProfile(d) isEqualToString:want]; i++) usleep(100000);
    logInfo(@"Color profile: %@", HCCurrentProfile(d));
    return YES;
}

// -------------------------------------------------------------------- DDC --
// Monitor settings (VCP codes) over DDC/CI, via IOAVService (Apple Silicon, IOKit private API).

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset,
                                   void *buf, uint32_t len);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress,
                                    void *buf, uint32_t len);

// The display's framebuffer in the IORegistry, from CoreDisplay (private): e.g.
// IOService:/AppleARMPE/arm-io@10F00000/AppleH16GFamilyIO/dispext0@84000000/IOMobileFramebufferShim.
static NSString *framebufferPath(CGDirectDisplayID d) {
    typedef CFDictionaryRef (*InfoFn)(CGDirectDisplayID);
    static InfoFn info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
        if (h) info = (InfoFn)dlsym(h, "CoreDisplay_DisplayCreateInfoDictionary");
    });
    NSDictionary *dict = info ? CFBridgingRelease(info(d)) : nil;
    NSString *path = dict[@"IODisplayLocation"];
    return [path isKindOfClass:NSString.class] ? path : nil;
}

// Each external DCPAVServiceProxy names its framebuffer in its path ("…/dispext0:dcpav-service-epic:0/
// DCPAVServiceProxy"), so it's matched to the display's framebuffer by that name.
IOAVServiceRef HCFindAVService(CGDirectDisplayID d, NSDictionary **outAttrs, NSString **error) {
    NSString *fbPath = framebufferPath(d);
    NSArray<NSString *> *parts = fbPath.pathComponents;
    NSString *fb = parts.count >= 2 ? [parts[parts.count - 2] componentsSeparatedByString:@"@"].firstObject : nil;
    if (!fb.length) { fail(error, @"can't find display %u's framebuffer in the IO registry", d); return NULL; }

    io_registry_entry_t fbEntry = IORegistryEntryFromPath(kIOMainPortDefault, fbPath.UTF8String);
    NSDictionary *attrs = nil;
    if (fbEntry) {
        attrs = CFBridgingRelease(IORegistryEntryCreateCFProperty(fbEntry, CFSTR("DisplayAttributes"), kCFAllocatorDefault, 0));
        IOObjectRelease(fbEntry);
    }

    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) != KERN_SUCCESS)
        { fail(error, @"cannot search the IO registry"); return NULL; }
    NSString *marker = [NSString stringWithFormat:@"/%@:", fb];
    IOAVServiceRef found = NULL;
    io_service_t s;
    while (!found && (s = IOIteratorNext(it))) {
        NSString *loc = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR("Location"), kCFAllocatorDefault, 0));
        io_string_t path;
        if ([loc isEqualToString:@"External"] && IORegistryEntryGetPath(s, kIOServicePlane, path) == KERN_SUCCESS &&
            [@(path) containsString:marker])
            found = IOAVServiceCreateWithService(kCFAllocatorDefault, s);
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (!found) { fail(error, @"no DDC connection to display %u (%@)", d, fb); return NULL; }
    if (outAttrs) *outAttrs = attrs[@"ProductAttributes"];
    return found;
}

// IOAVService calls block for as long as the monitor doesn't answer (e.g. while it's asleep), and
// they can't be cancelled. So each call runs on another thread and we stop waiting after 3 s. Until
// a timed-out call returns, further calls on the same service fail at once instead of piling up
// behind it. A newly created service (HCFindAVService) isn't affected, so a long-running app
// recovers by reconnecting even if a stuck call never returns.

static const int64_t kDDCTimeoutSeconds = 3;
static atomic_bool gDDCTimedOut;   // a call timed out since HCDDCClearTimeout
static NSMutableSet<NSValue *> *gStuckServices;   // services with a timed-out call still running

BOOL HCDDCDidTimeOut(void)  { return atomic_load(&gDDCTimedOut); }
void HCDDCClearTimeout(void) { atomic_store(&gDDCTimedOut, false); }

static IOReturn i2c(IOAVServiceRef av, BOOL write, uint32_t offset, uint8_t *buf, uint32_t len) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gStuckServices = [NSMutableSet set]; });
    // The block retains the service until it returns, so its address can't be reused while it's stuck.
    NSValue *key = [NSValue valueWithPointer:av];
    @synchronized (gStuckServices) {
        if ([gStuckServices containsObject:key]) { atomic_store(&gDDCTimedOut, true); return kIOReturnTimeout; }
    }
    // The block can outlive this call if it times out, so it keeps its own buffer and service reference.
    NSMutableData *data = [NSMutableData dataWithBytes:buf length:len];
    CFTypeRef service = CFRetain(av);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block IOReturn result = kIOReturnTimeout;
    __block BOOL finished = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        IOReturn r = write ? IOAVServiceWriteI2C(service, 0x37, offset, data.mutableBytes, len)
                           : IOAVServiceReadI2C(service, 0x37, offset, data.mutableBytes, len);
        @synchronized (gStuckServices) {
            result = r;
            finished = YES;
            [gStuckServices removeObject:key];
        }
        CFRelease(service);
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kDDCTimeoutSeconds * NSEC_PER_SEC)) != 0) {
        @synchronized (gStuckServices) {
            if (finished) { if (!write) memcpy(buf, data.bytes, len); return result; }   // returned just as we gave up
            [gStuckServices addObject:key];
        }
        if (!atomic_exchange(&gDDCTimedOut, true))
            logWarn(@"the monitor didn't answer over DDC within %lld seconds (asleep?)", kDDCTimeoutSeconds);
        return kIOReturnTimeout;
    }
    if (!write) memcpy(buf, data.bytes, len);
    return result;
}

// Returns NO if the write didn't go through after 3 tries (the bus is flaky).
static BOOL ddcWrite(IOAVServiceRef av, uint8_t *pkt, uint32_t len) {
    uint8_t chk = 0x6E ^ 0x51;
    for (uint32_t i = 0; i < len - 1; i++) chk ^= pkt[i];
    pkt[len - 1] = chk;
    IOReturn err = kIOReturnError;
    for (int i = 0; i < 3 && err != kIOReturnSuccess; i++) {
        usleep(10000);
        err = i2c(av, YES, 0x51, pkt, len);
        if (err == kIOReturnTimeout) break;
    }
    return err == kIOReturnSuccess;
}

// One read. Returns 1 = value, 0 = monitor says unsupported, -1 = no valid reply.
static int ddcGetOnce(IOAVServiceRef av, uint8_t code, uint16_t *cur, uint16_t *max) {
    uint8_t req[4] = { 0x82, 0x01, code, 0 };
    if (!ddcWrite(av, req, sizeof req)) return -1;
    usleep(50000);
    uint8_t r[11] = { 0 };
    if (i2c(av, NO, 0x51, r, sizeof r) != kIOReturnSuccess) return -1;
    // reply: 6E 88 02 <result> <code> <type> <maxH> <maxL> <curH> <curL> <chk>
    uint8_t chk = 0x50;
    for (int i = 0; i < 10; i++) chk ^= r[i];
    if (chk != r[10] || r[1] != 0x88 || r[2] != 0x02 || r[4] != code) return -1;
    if (r[3] != 0) return 0;
    *max = r[6] << 8 | r[7];
    *cur = r[8] << 8 | r[9];
    return 1;
}

// Needs two identical replies in a row, since other DDC apps (e.g. MonitorControl) can garble the bus.
BOOL HCDDCGet(IOAVServiceRef av, uint8_t code, uint16_t *cur, uint16_t *max) {
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

static BOOL ddcSet(IOAVServiceRef av, uint8_t code, uint16_t value) {
    uint8_t pkt[6] = { 0x84, 0x03, code, value >> 8, value & 0xFF, 0 };
    return ddcWrite(av, pkt, sizeof pkt);
}

// -------------------------------------------------------------- monitor DB --

static NSString *jsonString(NSString *s) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:s
                    options:NSJSONWritingFragmentsAllowed | NSJSONWritingWithoutEscapingSlashes error:NULL];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

// Identity fields, in hash order.
static NSArray<NSString *> *identityKeys(void) {
    return @[ @"manufacturer", @"product_id", @"product_name",
              @"display_controller_id", @"firmware_version", @"local_dimming_range_max" ];
}

NSDictionary *HCReadIdentityValues(IOAVServiceRef av, NSDictionary *attrs, NSString **why) {
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
            ok = HCDDCGet(av, vcp[i].code, &cur, &max);
        }
        if (!ok) { *why = [NSString stringWithFormat:@"%s: no reply (DDC busy? quit MonitorControl and retry)", vcp[i].what]; return nil; }
        got[i] = vcp[i].useMax ? max : cur;
    }
    return @{ @"manufacturer": mfr, @"product_id": @(pid.longLongValue), @"product_name": product,
              @"display_controller_id": @(got[0]), @"firmware_version": @(got[1]), @"local_dimming_range_max": @(got[2]) };
}

NSString *HCIdentityJSON(NSDictionary *identity) {
    NSString *mfr = identity[@"manufacturer"], *product = identity[@"product_name"];
    NSNumber *pid = identity[@"product_id"], *ctl = identity[@"display_controller_id"],
             *fw = identity[@"firmware_version"], *ld = identity[@"local_dimming_range_max"];
    if (![mfr isKindOfClass:NSString.class] || ![product isKindOfClass:NSString.class] ||
        ![pid isKindOfClass:NSNumber.class] || ![ctl isKindOfClass:NSNumber.class] ||
        ![fw isKindOfClass:NSNumber.class] || ![ld isKindOfClass:NSNumber.class]) return nil;
    return [NSString stringWithFormat:@"{\"manufacturer\":%@,\"product_id\":%lld,\"product_name\":%@,"
                                       "\"display_controller_id\":%lld,\"firmware_version\":%lld,\"local_dimming_range_max\":%lld}",
            jsonString(mfr), pid.longLongValue, jsonString(product),
            ctl.longLongValue, fw.longLongValue, ld.longLongValue];
}

NSString *HCSHA256Hex(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", h[i]];
    return hex;
}

// @{} if the file doesn't exist, nil with *error set if it isn't a JSON object.
static NSDictionary *loadJSONObject(NSString *path, NSString **error) {
    NSData *d = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!d) return @{};
    NSError *err = nil;
    id db = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
    if (![db isKindOfClass:NSDictionary.class])
        { fail(error, @"%@ isn't a valid JSON object: %@", path, err.localizedDescription ?: @""); return nil; }
    return db;
}

NSString *HCLocalDBPath(void) { return dataPath(@"local_monitor_db.json"); }

NSDictionary *HCLoadLocalDB(NSString **error) { return loadJSONObject(HCLocalDBPath(), error); }

NSDictionary *HCLoadDB(NSString **error) {
    NSDictionary *shipped = loadJSONObject(gDBPath ?: [HCToolDirectory() stringByAppendingPathComponent:@"monitor_db.json"], error);
    NSDictionary *local = shipped ? HCLoadLocalDB(error) : nil;
    if (!local) return nil;
    NSMutableDictionary *db = [shipped mutableCopy];
    [db addEntriesFromDictionary:local];   // a detected monitor overrides the shipped entry
    return db;
}

NSString *HCPrettyJSON(id object) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:object
                    options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                      error:NULL];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

NSDictionary *HCMakeLocalMonitorEntry(NSDictionary *identity, uint8_t code, NSArray<NSDictionary *> *levels,
                                      NSString *hdrOn, NSString *hdrOff, NSDictionary *report) {
    return @{
        @"identity": identity,
        @"settings": @{ @"local_dimming": @{ @"vcp": [NSString stringWithFormat:@"0x%02X", code], @"levels": levels,
                                             @"hdr_on": hdrOn, @"hdr_off": hdrOff } },
        @"report": report ?: @{},
    };
}

// Leaf values by dotted key path. A list of levels reads as "off 0, standard 2"; other lists as JSON.
static void flattenEntry(id value, NSString *path, NSMutableDictionary<NSString *, NSString *> *out) {
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in value) flattenEntry(value[key], path.length ? [path stringByAppendingFormat:@".%@", key] : [key description], out);
    } else if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *levels = [NSMutableArray array];
        for (NSDictionary *l in value)
            if ([l isKindOfClass:NSDictionary.class] && l[@"name"] && l[@"value"]) [levels addObject:[NSString stringWithFormat:@"%@ %@", l[@"name"], l[@"value"]]];
        if (levels.count == [value count]) out[path] = [levels componentsJoinedByString:@", "];
        else {
            NSData *d = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
            out[path] = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : [value description];
        }
    } else if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        out[path] = [value boolValue] ? @"true" : @"false";
    } else {
        out[path] = [value description];
    }
}

NSArray<NSString *> *HCEntryDifferences(NSDictionary *old, NSDictionary *new) {
    NSMutableDictionary *a = [NSMutableDictionary dictionary], *b = [NSMutableDictionary dictionary];
    flattenEntry(old ?: @{}, @"", a);
    flattenEntry(new ?: @{}, @"", b);
    NSMutableSet *keys = [NSMutableSet setWithArray:a.allKeys];
    [keys addObjectsFromArray:b.allKeys];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in [keys.allObjects sortedArrayUsingSelector:@selector(compare:)])
        if (![a[k] isEqual:b[k]]) [out addObject:[NSString stringWithFormat:@"%@: %@ → %@", k, a[k] ?: @"(none)", b[k] ?: @"(none)"]];
    return out;
}

NSDictionary *HCSaveLocalMonitor(NSDictionary *identity, uint8_t code, NSArray<NSDictionary *> *levels,
                                 NSString *hdrOn, NSString *hdrOff, NSDictionary *report, NSString **error) {
    NSString *canonical = HCIdentityJSON(identity), *path = HCLocalDBPath();
    if (!canonical) { fail(error, @"incomplete identity"); return nil; }
    if (!path) { fail(error, @"can't find the data folder (~/Library/Application Support/HDR Switch)"); return nil; }
    NSDictionary *existing = HCLoadLocalDB(error);
    if (!existing) return nil;
    NSDictionary *entry = HCMakeLocalMonitorEntry(identity, code, levels, hdrOn, hdrOff, report);
    // Only this monitor's key changes; other monitors in the file are kept.
    NSMutableDictionary *db = [existing mutableCopy];
    db[HCSHA256Hex(canonical)] = entry;
    NSString *text = HCPrettyJSON(db);
    NSError *err = nil;
    if (!text || ![[text stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        fail(error, @"couldn't write %@: %@", path, err.localizedDescription ?: @"not valid JSON");
        return nil;
    }
    return entry;
}

NSString *HCMyMonitorPath(void) { return dataPath(@"my_monitor.json"); }

// The file up to 0.2.1: one monitor, keyed by its hash, { "<hash>": { "identity": { ... } } }.
static BOOL isOneMonitorFile(NSDictionary *json) {
    NSDictionary *entry = json.allValues.firstObject;
    return json.count == 1 && [json.allKeys.firstObject length] == 64 &&
           [entry isKindOfClass:NSDictionary.class] && !entry[@"hash"];
}

// my_monitor.json: @{} if it doesn't exist, or nil with *why set if it isn't a JSON object.
static NSDictionary *readMyMonitors(NSString **why) {
    NSString *path = HCMyMonitorPath();
    NSData *d = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!d) return @{};
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) {
        *why = @"my_monitor.json isn't valid: it must be a JSON object (run: hdrctl identify --save)";
        return nil;
    }
    return json;
}

NSString *HCReadMyMonitor(NSString *uuid, NSDictionary **identity, NSString **why) {
    NSDictionary *json = readMyMonitors(why);
    if (!json) return nil;
    BOOL oneMonitor = isOneMonitorFile(json);
    NSDictionary *entry = oneMonitor ? json.allValues.firstObject : uuid ? json[uuid] : nil;
    if (![entry isKindOfClass:NSDictionary.class]) {
        *why = json.count ? [NSString stringWithFormat:@"my_monitor.json has no monitor for display %@ (run: hdrctl identify --save)", uuid]
                          : @"my_monitor.json not found (run: hdrctl identify --save)";
        return nil;
    }
    NSString *hash = oneMonitor ? json.allKeys.firstObject : entry[@"hash"];
    NSDictionary *ident = entry[@"identity"];
    NSString *canonical = [ident isKindOfClass:NSDictionary.class] ? HCIdentityJSON(ident) : nil;
    if (!canonical) {
        *why = @"my_monitor.json isn't valid: an identity section is missing or incomplete (run: hdrctl identify --save)";
        return nil;
    }
    if (![hash isKindOfClass:NSString.class] || ![HCSHA256Hex(canonical) isEqualToString:hash]) {
        *why = @"my_monitor.json isn't valid: a hash doesn't match its identity section (run: hdrctl identify --save)";
        return nil;
    }
    if (identity) *identity = ident;
    return hash;
}

NSDictionary<NSString *, NSDictionary *> *HCMyMonitors(void) {
    NSString *why = nil;
    NSDictionary *json = readMyMonitors(&why);
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (!json || isOneMonitorFile(json)) return out;
    for (NSString *uuid in json) {
        NSDictionary *identity = nil;
        if (HCReadMyMonitor(uuid, &identity, &why)) out[uuid] = identity;
    }
    return out;
}

BOOL HCSaveMyMonitor(NSString *uuid, NSDictionary *identity, NSString **error) {
    NSString *canonical = HCIdentityJSON(identity), *path = HCMyMonitorPath(), *why = nil;
    if (!canonical) return fail(error, @"incomplete identity");
    if (!uuid.length) return fail(error, @"the display has no UUID");
    if (!path) return fail(error, @"can't find the data folder (~/Library/Application Support/HDR Switch)");
    NSDictionary *json = readMyMonitors(&why);   // an invalid or one-monitor file is replaced
    NSMutableDictionary *all = json && !isOneMonitorFile(json) ? [json mutableCopy] : [NSMutableDictionary dictionary];
    all[uuid] = @{ @"hash": HCSHA256Hex(canonical), @"identity": identity };
    NSError *err = nil;
    if (![[HCPrettyJSON(all) stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err])
        return fail(error, @"%@", err.localizedDescription);
    [[NSFileManager defaultManager] removeItemAtPath:dataPath(@"my_monitor") error:NULL];   // old one-line format
    return YES;
}

void HCEnsureMyMonitor(NSString *uuid, NSDictionary *identity) {
    NSString *path = HCMyMonitorPath(), *why = nil;
    NSDictionary *json = readMyMonitors(&why);
    if (!path || !json || !uuid.length) return;   // HCReadMyMonitor reports an invalid file
    NSString *hash = HCSHA256Hex(HCIdentityJSON(identity));
    BOOL oneMonitor = isOneMonitorFile(json);
    if (oneMonitor ? ![json.allKeys.firstObject isEqualToString:hash] : json[uuid] != nil) return;
    NSString *oldPath = dataPath(@"my_monitor");
    NSString *oldHash = json.count ? nil : [[NSString stringWithContentsOfFile:oldPath encoding:NSUTF8StringEncoding error:NULL]
                                            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *err = nil;
    if (!HCSaveMyMonitor(uuid, identity, &err)) { logWarn(@"couldn't update %@: %@", path, err); return; }
    if (oneMonitor)
        logInfo(@"Updated %@ to list monitors by display: %@ is on display %@", path, identity[@"product_name"], uuid);
    else if (oldHash)
        logInfo(@"Replaced %@ with my_monitor.json for %@%@", oldPath, identity[@"product_name"],
                [oldHash isEqualToString:hash] ? @""
                    : [NSString stringWithFormat:@" (the old file was for a different monitor, %@)", oldHash]);
    else
        logInfo(@"%@ %@ for %@ on display %@ (%@)", json.count ? @"Added to" : @"Created", path,
                identity[@"product_name"], uuid, hash);
}

// "firmware_version is 1, my_monitor.json has 0" for each field that differs.
static NSString *identityDiff(NSDictionary *live, NSDictionary *mine) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in identityKeys())
        if (![live[k] isEqual:mine[k]])
            [out addObject:[NSString stringWithFormat:@"%@ is %@, my_monitor.json has %@", k, live[k], mine[k]]];
    return out.count ? [out componentsJoinedByString:@"; "] : nil;
}

NSDictionary *HCFindMonitor(IOAVServiceRef av, NSDictionary *attrs, NSString *uuid, NSString **why, NSString **error) {
    NSDictionary *live = HCReadIdentityValues(av, attrs, why);
    return live ? HCFindMonitorForIdentity(live, uuid, why, error) : nil;
}

NSDictionary *HCFindMonitorForIdentity(NSDictionary *live, NSString *uuid, NSString **why, NSString **error) {
    NSString *hash = HCSHA256Hex(HCIdentityJSON(live));
    HCEnsureMyMonitor(uuid, live);
    NSDictionary *mineIdentity = nil;
    NSString *mine = HCReadMyMonitor(uuid, &mineIdentity, why);
    if (!mine) return nil;
    if (![hash isEqualToString:mine]) {
        *why = [NSString stringWithFormat:@"connected monitor doesn't match my_monitor.json: %@ "
                                           "(if this is your monitor, run: hdrctl identify --save)",
                identityDiff(live, mineIdentity) ?: hash];
        return nil;
    }
    NSDictionary *db = HCLoadDB(error);
    if (!db) return nil;
    NSDictionary *entry = db[hash];
    if (![entry isKindOfClass:NSDictionary.class]) {
        *why = [NSString stringWithFormat:@"%@ isn't in monitor_db.json or local_monitor_db.json (to add it: hdrctl detect)", hash];
        return nil;
    }
    return entry;
}

int HCLocalDimming(NSDictionary *entry, NSDictionary<NSString *, NSNumber *> **levels, NSString **error) {
    NSDictionary *ld = entry[@"settings"][@"local_dimming"];
    NSString *vcp = [ld isKindOfClass:NSDictionary.class] ? ld[@"vcp"] : nil;
    NSArray *list = [ld isKindOfClass:NSDictionary.class] ? ld[@"levels"] : nil;
    unsigned code = 0;
    if (![vcp isKindOfClass:NSString.class] || ![[NSScanner scannerWithString:vcp] scanHexInt:&code] ||
        code > 0xFF || ![list isKindOfClass:NSArray.class]) {
        fail(error, @"monitor_db.json: settings.local_dimming needs \"vcp\" (e.g. \"0xF4\") and \"levels\"");
        return -1;
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSDictionary *l in list) {
        if (![l isKindOfClass:NSDictionary.class] || ![l[@"name"] isKindOfClass:NSString.class] ||
            ![l[@"value"] isKindOfClass:NSNumber.class]) {
            fail(error, @"monitor_db.json: each local dimming level needs \"name\" and \"value\"");
            return -1;
        }
        out[[l[@"name"] lowercaseString]] = l[@"value"];
    }
    *levels = out;
    return (int)code;
}

NSString *HCLevelName(NSDictionary<NSString *, NSNumber *> *levels, uint16_t value) {
    for (NSString *n in levels) if (levels[n].unsignedShortValue == value) return n;
    return nil;
}

BOOL HCSetDimming(IOAVServiceRef av, uint8_t code, uint16_t value, NSString *label) {
    uint16_t cur = 0xFFFF;
    // Skip the write (and the monitor's settings-memory wear) if it's already set; reads don't wear it.
    if (HCDDCGet(av, code, &cur, NULL) && cur == value) { logInfo(@"Local dimming already %@", label); return YES; }
    // The monitor silently drops writes while busy (e.g. right after an HDR switch): write, verify, repeat.
    for (int i = 0; i < 10; i++) {
        ddcSet(av, code, value);
        sleep(1);
        if (HCDDCGet(av, code, &cur, NULL) && cur == value) { logInfo(@"Local dimming: %@", label); return YES; }
    }
    logWarn(@"couldn't confirm local dimming is %@ (DDC busy? quit MonitorControl and retry)", label);
    return NO;
}

// -------------------------------------------------------------- detection --

NSDictionary<NSNumber *, NSArray<NSNumber *> *> *HCDDCScan(IOAVServiceRef av, NSArray<NSNumber *> *codes,
                                                          void (^progress)(NSUInteger done, NSUInteger total)) {
    if (!codes) {
        NSMutableArray *all = [NSMutableArray array];
        for (unsigned c = 0x01; c <= 0xFF; c++) [all addObject:@(c)];
        codes = all;
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < codes.count; i++) {
        uint16_t cur = 0, max = 0;
        if (HCDDCGet(av, codes[i].unsignedCharValue, &cur, &max)) out[codes[i]] = @[ @(cur), @(max) ];
        if (progress) progress(i + 1, codes.count);
    }
    return out;
}

NSArray<NSNumber *> *HCDimmingCandidates(NSArray<NSDictionary *> *scans, NSDictionary *repeat) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSNumber *code in [[scans.firstObject allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        // Must read the same twice with nothing changed, so codes that drift on their own are out.
        if (![repeat[code] isEqual:scans.firstObject[code]]) continue;
        NSMutableSet *values = [NSMutableSet set];
        BOOL ok = YES;
        for (NSDictionary *scan in scans) {
            NSArray *v = scan[code];
            if (!v || ![v[1] isEqual:scans.firstObject[code][1]]) { ok = NO; break; }   // answered, same range
            [values addObject:v[0]];
        }
        if (ok && values.count == scans.count) [out addObject:code];   // a different value at every level
    }
    return out;
}

@implementation HCDetection {
    IOAVServiceRef _av;
    NSMutableArray<NSDictionary *> *_scans;
    NSDictionary *_repeat;
}

- (instancetype)initWithService:(IOAVServiceRef)av levelCount:(NSUInteger)count {
    if ((self = [super init])) {
        _av = CFRetain(av);
        _levelCount = count;
        _scans = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc { CFRelease(_av); }

- (NSUInteger)scannedLevels { return _scans.count; }

// A code that answered in the first scan but not in this one most likely missed a reply (the bus is
// flaky), and dropping it would rule out the real local dimming code. So re-read those a few times.
- (NSDictionary *)withMissedCodesReread:(NSDictionary *)scan {
    NSMutableDictionary *out = [scan mutableCopy];
    for (NSNumber *code in _scans.firstObject ?: @{}) {
        for (int t = 0; t < 5 && !out[code] && !HCDDCDidTimeOut(); t++) {
            usleep(300000);
            uint16_t cur = 0, max = 0;
            if (HCDDCGet(_av, code.unsignedCharValue, &cur, &max)) out[code] = @[ @(cur), @(max) ];
        }
    }
    return out;
}

- (BOOL)scanNextLevelWithProgress:(void (^)(NSUInteger, NSUInteger, NSUInteger))progress {
    if (_scans.count >= _levelCount) return NO;
    HCDDCClearTimeout();
    if (_scans.count == 0) {
        [_scans addObject:HCDDCScan(_av, nil, ^(NSUInteger done, NSUInteger total) { if (progress) progress(0, done, total); })];
        _repeat = [self withMissedCodesReread:HCDDCScan(_av, [_scans[0] allKeys], ^(NSUInteger done, NSUInteger total) {
            if (progress) progress(1, done, total);
        })];
    } else {
        [_scans addObject:[self withMissedCodesReread:HCDDCScan(_av, [_scans[0] allKeys], ^(NSUInteger done, NSUInteger total) {
            if (progress) progress(0, done, total);
        })]];
    }
    return !HCDDCDidTimeOut();
}

- (void)discardLevelsFrom:(NSUInteger)level {
    if (level < _scans.count) [_scans removeObjectsInRange:NSMakeRange(level, _scans.count - level)];
    if (level == 0) _repeat = nil;
}

- (NSArray<NSNumber *> *)candidates {
    return _scans.count == _levelCount ? HCDimmingCandidates(_scans, _repeat) : @[];
}

- (uint16_t)valueOfCode:(uint8_t)code atLevel:(NSUInteger)level {
    return [_scans[level][@(code)][0] unsignedShortValue];
}

- (uint16_t)rangeMaxOfCode:(uint8_t)code {
    return [_scans[0][@(code)][1] unsignedShortValue];
}

- (NSArray<NSDictionary *> *)levelsNamed:(NSArray<NSString *> *)names forCode:(uint8_t)code {
    NSMutableArray *levels = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count && i < _scans.count; i++)
        [levels addObject:@{ @"name": names[i], @"value": _scans[i][@(code)][0] }];
    return levels;
}

@end

NSString *HCSuggestedHDRLevel(NSArray<NSString *> *names, BOOL on) {
    NSString *preferred = on ? @"standard" : @"off";
    return [names containsObject:preferred] ? preferred : on ? names.lastObject : names.firstObject;
}

NSDictionary *HCDetectionReport(NSString *tool, NSString *firmware, NSString *connection) {
    NSMutableDictionary *report = [@{ @"tool": tool,
                                      @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
                                      @"verified_by_user": @YES,
                                      @"detected": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]] } mutableCopy];
    if (firmware.length) report[@"osd_firmware"] = firmware;
    if (connection.length) report[@"connection"] = connection;
    return report;
}

static NSString *percentEncode(NSString *s) {
    NSMutableCharacterSet *ok = [NSMutableCharacterSet alphanumericCharacterSet];
    [ok addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:ok];
}

NSURL *HCContributionURL(NSDictionary *identity, NSString *entryJSON, NSString *tool) {
    NSString *title = [NSString stringWithFormat:@"Monitor: %@ (%@)", identity[@"product_name"], identity[@"manufacturer"]];
    NSString *body = [NSString stringWithFormat:@"Detected with `%@`. Entry for `monitor_db.json`:\n\n```json\n%@\n```\n", tool, entryJSON];
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/allenjia-ll/hdrswitch/issues/new?title=%@&body=%@",
                                 percentEncode(title), percentEncode(body)]];
}

