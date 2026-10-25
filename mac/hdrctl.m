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
//   hdrctl identify [--save]         print the monitor's identity and hash; --save rewrites my_monitor.json
//
// Options:
//   --display <text>       part of the display name (default: M27P6S)
//   --hdr-profile <spec>   profile description or .icc path used by "on"  (default: "Rec. ITU-R BT.2020-1")
//   --sdr-profile <spec>   profile description or .icc path used by "off" (default: "Display P3")
//
// The HDR, profile, DDC and monitor DB code is in core/hdrcore.m, shared with the menu bar app.
// This file is the command line: argument parsing, output and exit codes.
//
// Build: mac/build.sh, or: clang -fobjc-arc -O2 -Wall -framework AppKit -framework ApplicationServices -framework IOKit hdrctl.m core/hdrcore.m -o hdrctl

#import "core/hdrcore.h"

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
        "  identify [--save]     print the monitor's identity and hash; --save rewrites my_monitor.json\n"
        "\n"
        "A profile <spec> is either a path to an .icc/.icm file or (part of) the\n"
        "profile's name as shown in System Settings > Displays > Color profile.\n");
    exit(code);
}

// ---------------------------------------------------------------- helpers --
// Thin wrappers that turn core errors into "error: ..." and exit 1, as the CLI always has.

static NSURL *resolveProfile(NSString *spec) {
    NSString *err = nil;
    NSURL *url = HCResolveProfile(spec, &err);
    if (!url) die(@"%@", err);
    return url;
}

static IOAVServiceRef findAVService(NSString *needle, NSDictionary **outAttrs) {
    NSString *err = nil;
    IOAVServiceRef av = HCFindAVService(needle, outAttrs, &err);
    if (!av) die(@"%@", err);
    return av;
}

// The DB entry for the connected monitor, or prints "monitor unknown" and exits. Call before any change.
static NSDictionary *requireMonitor(IOAVServiceRef av, NSDictionary *attrs) {
    NSString *why = nil, *err = nil;
    NSDictionary *entry = HCFindMonitor(av, attrs, &why, &err);
    if (entry) return entry;
    if (err) die(@"%@", err);
    fprintf(stderr, "monitor unknown: %s — not changing anything\n", why.UTF8String);
    exit(1);
}

static uint8_t localDimming(NSDictionary *entry, NSDictionary<NSString *, NSNumber *> **levels) {
    NSString *err = nil;
    int code = HCLocalDimming(entry, levels, &err);
    if (code < 0) die(@"%@", err);
    return (uint8_t)code;
}

static uint16_t levelValue(NSDictionary<NSString *, NSNumber *> *levels, NSString *name) {
    NSNumber *v = levels[name];
    if (!v) die(@"monitor_db.json has no local dimming level \"%@\" for this monitor", name);
    return v.unsignedShortValue;
}

static void printStatus(CGDirectDisplayID d, NSString *name) {
    say(@"%@  (id %u)", name, d);
    say(@"  HDR supported: %@", HCSupportsHDR(d) ? @"yes" : @"no");
    say(@"  HDR enabled:   %@", HCIsHDR(d) ? @"on" : @"off");
    say(@"  Color profile: %@", HCCurrentProfile(d));
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

        HCSetLogger(^(HCLogLevel level, NSString *message) {
            if (level == HCLogWarning) fprintf(stderr, "warning: %s\n", message.UTF8String);
            else say(@"%@", message);
        });
        NSString *err = nil, *why = nil;

        if ([cmd isEqualToString:@"ddc"] && args.count >= 2) {
            NSDictionary *attrs = nil;
            IOAVServiceRef av = HCFindAVService(needle, &attrs, &err);
            if (!av) die(@"%@", err);
            NSString *sub = args[1];
            uint16_t cur, max;
            if ([sub isEqualToString:@"dump"]) {
                for (unsigned c = 0x01; c <= 0xFF; c++)
                    if (HCDDCGet(av, c, &cur, &max)) say(@"0x%02X  %u  (max %u)", c, cur, max);
            } else if ([sub isEqualToString:@"get"] && args.count == 3) {
                unsigned c = parseNum(args[2]);
                if (!HCDDCGet(av, c, &cur, &max)) die(@"monitor didn't answer VCP 0x%02X", c);
                say(@"0x%02X  %u  (max %u)", c, cur, max);
            } else if ([sub isEqualToString:@"set"] && args.count == 4) {
                // Only the local dimming levels monitor_db.json lists for this monitor can be written.
                unsigned c = parseNum(args[2]), v = parseNum(args[3]);
                NSDictionary<NSString *, NSNumber *> *levels = nil;
                uint8_t code = localDimming(requireMonitor(av, attrs), &levels);
                NSString *label = c == code ? HCLevelName(levels, v) : nil;
                if (!label) {
                    NSMutableArray *ok = [NSMutableArray array];
                    for (NSString *n in levels) [ok addObject:[NSString stringWithFormat:@"%@ = %@", n, levels[n]]];
                    fprintf(stderr, "warning: only VCP 0x%02X with a listed level is allowed (%s) — not changing anything\n",
                            code, [ok componentsJoinedByString:@", "].UTF8String);
                    return 1;
                }
                HCSetDimming(av, code, v, label);
            } else usage(1);
            return 0;
        }

        if ([cmd isEqualToString:@"identify"]) {
            NSDictionary *attrs = nil;
            IOAVServiceRef av = HCFindAVService(needle, &attrs, &err);
            if (!av) die(@"%@", err);
            NSDictionary *live = HCReadIdentityValues(av, attrs, &why);
            if (!live) die(@"%@", why);
            NSString *identity = HCIdentityJSON(live), *hash = HCSHA256Hex(identity);
            if ([args containsObject:@"--save"]) {
                if (!HCSaveMyMonitor(live, &err)) die(@"couldn't write %@: %@", HCMyMonitorPath(), err);
                say(@"Saved %@", HCMyMonitorPath());
            } else {
                HCEnsureMyMonitor(live);
            }
            NSString *mineWhy = nil, *mine = HCReadMyMonitor(NULL, &mineWhy);
            say(@"Identity:        %@", identity);
            say(@"Hash:            %@", hash);
            NSDictionary *db = HCLoadDB(&err);
            if (!db) die(@"%@", err);
            say(@"monitor_db.json: %@", db[hash] ? @"listed" : @"not listed");
            say(@"my_monitor.json: %@", !mine ? mineWhy : [mine isEqualToString:hash] ? @"matches" : @"different monitor");
            return 0;
        }

        if (!HCLoadSkyLight(&err)) die(@"%@", err);

        if ([cmd isEqualToString:@"list"]) {
            NSArray *ds = HCAllDisplays();
            if (ds.count == 0) say(@"no displays found");
            for (NSDictionary *d in ds) printStatus([d[@"id"] unsignedIntValue], d[@"name"]);
            return 0;
        }

        NSString *name = nil;
        CGDirectDisplayID d = HCFindDisplay(needle, &name, &err);
        if (!d) die(@"%@", err);

        if ([cmd isEqualToString:@"status"]) {
            printStatus(d, name);
            NSDictionary *attrs = nil;
            IOAVServiceRef av = HCFindAVService(needle, &attrs, &err);
            if (!av) die(@"%@", err);
            NSDictionary *entry = HCFindMonitor(av, attrs, &why, &err);   // read only, so an unknown monitor isn't an error
            if (!entry && err) die(@"%@", err);
            NSDictionary<NSString *, NSNumber *> *levels = nil;
            uint8_t code = entry ? localDimming(entry, &levels) : 0;
            uint16_t cur = 0;
            if (!entry) say(@"  Local dimming: monitor unknown (%@)", why);
            else if (!HCDDCGet(av, code, &cur, NULL)) say(@"  Local dimming: (no reply over DDC — try again)");
            else say(@"  Local dimming: %@", HCLevelName(levels, cur)
                                                ?: [NSString stringWithFormat:@"unknown (VCP 0x%02X = %u)", code, cur]);
        } else if ([cmd isEqualToString:@"on"] ||
                   ([cmd isEqualToString:@"toggle"] && !HCIsHDR(d))) {
            NSURL *p = resolveProfile(hdrSpec);          // resolve and verify first, so we fail before switching
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(needle, &attrs);
            NSDictionary<NSString *, NSNumber *> *levels = nil;
            uint8_t code = localDimming(requireMonitor(av, attrs), &levels);
            uint16_t level = levelValue(levels, @"standard");
            if (!HCSetHDR(d, YES, &err)) die(@"%@", err);
            if (!HCSetProfile(d, p, &err)) die(@"%@", err);
            HCSetDimming(av, code, level, @"standard");
            say(@"Done: %@ — HDR on", name);
        } else if ([cmd isEqualToString:@"off"] || [cmd isEqualToString:@"toggle"]) {
            NSURL *p = resolveProfile(sdrSpec);
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(needle, &attrs);
            NSDictionary<NSString *, NSNumber *> *levels = nil;
            uint8_t code = localDimming(requireMonitor(av, attrs), &levels);
            uint16_t level = levelValue(levels, @"off");
            if (!HCSetHDR(d, NO, &err)) die(@"%@", err);
            if (!HCSetProfile(d, p, &err)) die(@"%@", err);
            HCSetDimming(av, code, level, @"off");
            say(@"Done: %@ — HDR off", name);
        } else if ([cmd isEqualToString:@"hdr"] && args.count == 2) {
            NSString *v = args[1].lowercaseString;
            if (![v isEqualToString:@"on"] && ![v isEqualToString:@"off"]) usage(1);
            if (!HCSetHDR(d, [v isEqualToString:@"on"], &err)) die(@"%@", err);
            say(@"HDR: %@", HCIsHDR(d) ? @"on" : @"off");
        } else if ([cmd isEqualToString:@"profile"] && args.count == 2) {
            if (!HCSetProfile(d, resolveProfile(args[1]), &err)) die(@"%@", err);
        } else {
            usage(1);
        }
    }
    return 0;
}
