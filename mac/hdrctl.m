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
//   hdrctl identify                  print the monitor's identity and hash
//   hdrctl detect                    find the monitor's local dimming code and levels (interactive)
//
// Options:
//   --display <text>       part of the display name, or its UUID (default: the only external display)
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
        "usage: hdrctl [--display <name|UUID>] [--hdr-profile <spec>] [--sdr-profile <spec>] <command>\n"
        "\n"
        "commands:\n"
        "  list                  list displays (with their UUIDs), HDR state and current profile\n"
        "  status                HDR state, profile and local dimming of the target display\n"
        "  on                    HDR on  + HDR profile (default: Rec. ITU-R BT.2020-1) + local dimming Standard\n"
        "  off                   HDR off + SDR profile (default: Display P3) + local dimming Off\n"
        "  toggle                flip between on and off\n"
        "  hdr on|off            change HDR only\n"
        "  profile <name|path>   change color profile only\n"
        "  ddc dump              read all monitor settings (DDC/CI VCP codes)\n"
        "  ddc get <code>        read one VCP code (e.g. 0xF4)\n"
        "  ddc set <code> <value> local dimming level listed in monitor_db.json (the only write allowed)\n"
        "  identify              print the monitor's identity and hash\n"
        "  detect                find the monitor's local dimming code and levels (interactive), save them\n"
        "                        to local_monitor_db.json, and optionally contribute them on GitHub\n"
        "\n"
        "--display picks the display by (part of) its name or its UUID; without it, the\n"
        "only external display is used.\n"
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

static IOAVServiceRef findAVService(CGDirectDisplayID d, NSDictionary **outAttrs) {
    NSString *err = nil;
    IOAVServiceRef av = HCFindAVService(d, outAttrs, &err);
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

// The level hdrctl on (or off) uses: settings.local_dimming.hdr_on / hdr_off if the entry has it
// (entries from hdrctl detect do), otherwise "standard" / "off".
static NSString *hdrLevel(NSDictionary *entry, BOOL on) {
    NSString *name = entry[@"settings"][@"local_dimming"][on ? @"hdr_on" : @"hdr_off"];
    return [name isKindOfClass:NSString.class] ? name.lowercaseString : on ? @"standard" : @"off";
}

static uint16_t levelValue(NSDictionary<NSString *, NSNumber *> *levels, NSString *name) {
    NSNumber *v = levels[name];
    if (!v) die(@"monitor_db.json has no local dimming level \"%@\" for this monitor", name);
    return v.unsignedShortValue;
}

static void printStatus(CGDirectDisplayID d, NSString *name) {
    say(@"%@  (id %u%@)", name, d, CGDisplayIsBuiltin(d) ? @", built-in" : @"");
    say(@"  UUID:          %@", HCDisplayUUID(d));
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

// --------------------------------------------------------------- detect --
// Interactive: the user sets each local dimming level in the monitor's menu, we scan every VCP code
// at each, find the one code that follows, then (after asking) write each level back for the user
// to confirm on the monitor. Saved to local_monitor_db.json. The
// scanning, candidates, report and contribution link are in the core (HCDetection and friends), so
// the menu bar app can share them; this function is the prompts and output.

static NSString *ask(NSString *prompt) {
    printf("%s", prompt.UTF8String);
    fflush(stdout);
    char buf[512];
    if (!fgets(buf, sizeof buf, stdin)) { printf("\n"); die(@"no input — detection cancelled, nothing was saved"); }
    return [@(buf) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL askYes(NSString *prompt) {
    NSString *a = ask([prompt stringByAppendingString:@" [y/N] "]).lowercaseString;
    return [a isEqualToString:@"y"] || [a isEqualToString:@"yes"];
}

static int askNumber(NSString *prompt, int lo, int hi) {
    for (;;) {
        NSString *a = ask(prompt);
        NSScanner *sc = [NSScanner scannerWithString:a];
        int n = 0;
        if ([sc scanInt:&n] && sc.isAtEnd && n >= lo && n <= hi) return n;
        say(@"Please enter a number from %d to %d.", lo, hi);
    }
}

// Picks one of names (by number or name), or the default on Return.
static NSString *askLevel(NSString *prompt, NSArray<NSString *> *names, NSString *fallback) {
    for (;;) {
        NSString *a = ask([NSString stringWithFormat:@"%@ [%@] ", prompt, fallback]).lowercaseString;
        if (!a.length) return fallback;
        int n = a.intValue;
        if (n >= 1 && n <= (int)names.count && [a isEqualToString:@(n).stringValue]) return names[n - 1];
        if ([names containsObject:a]) return a;
        say(@"Please enter one of: %@ (or its number).", [names componentsJoinedByString:@", "]);
    }
}

static int detect(CGDirectDisplayID d) {
    NSString *err = nil, *why = nil;
    NSDictionary *attrs = nil;
    IOAVServiceRef av = findAVService(d, &attrs);
    NSDictionary *identity = HCReadIdentityValues(av, attrs, &why);
    if (!identity) die(@"%@", why);
    NSString *hash = HCSHA256Hex(HCIdentityJSON(identity));
    NSDictionary *db = HCLoadDB(&err), *local = db ? HCLoadLocalDB(&err) : nil;
    if (!local) die(@"%@", err);

    say(@"Monitor: %@  (%@)", identity[@"product_name"], hash);
    if (local[hash])
        say(@"It's already in local_monitor_db.json; a new detection replaces that entry.");
    else if (db[hash])
        say(@"It's already in the shipped monitor_db.json. The result is saved to local_monitor_db.json\n"
            "and is used instead of the shipped entry on this Mac.");
    say(@"\n"
        "This finds the VCP code your monitor uses for local dimming. It only reads from the monitor\n"
        "until you confirm the result; then it writes that one code to check each level with you.\n"
        "Before starting, quit MonitorControl and other DDC apps, and keep the monitor awake.\n");

    int n = askNumber(@"How many local dimming levels does the monitor's menu have? (2-10) ", 2, 10);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        for (;;) {
            NSString *name = ask([NSString stringWithFormat:@"Name of level %d, as in the monitor's menu (e.g. Off, Low, High): ", i + 1]).lowercaseString;
            if (!name.length) { say(@"Please enter a name."); continue; }
            if ([names containsObject:name]) { say(@"\"%@\" is already used.", name); continue; }
            [names addObject:name];
            break;
        }
    }

    HCDetection *detection = [[HCDetection alloc] initWithService:av levelCount:n];
    void (^progress)(NSUInteger, NSUInteger, NSUInteger) = ^(NSUInteger pass, NSUInteger done, NSUInteger total) {
        if (pass == 1 && done == 1) say(@"  again, to rule out values that change on their own:");
        printf("\r  reading VCP codes… %lu/%lu", (unsigned long)done, (unsigned long)total);
        if (done == total) printf("\n");
        fflush(stdout);
    };
    for (int i = 0; i < n; i++) {
        ask([NSString stringWithFormat:@"\nSet local dimming to \"%@\" in the monitor's menu, close the menu, then press Return. ", names[i]]);
        if (![detection scanNextLevelWithProgress:progress])
            die(@"the monitor stopped answering over DDC (asleep?) — nothing was saved; run hdrctl detect again");
    }

    NSArray<NSNumber *> *candidates = detection.candidates;
    if (candidates.count == 0) {
        say(@"\nNo VCP code changed with local dimming. This monitor may not expose local dimming over DDC/CI,");
        say(@"or a level was skipped. Nothing was saved.");
        return 1;
    }
    NSNumber *code = candidates[0];
    if (candidates.count > 1) {
        say(@"\nMore than one VCP code changed with local dimming:");
        for (NSUInteger c = 0; c < candidates.count; c++) {
            NSMutableArray *vals = [NSMutableArray array];
            for (int i = 0; i < n; i++)
                [vals addObject:[NSString stringWithFormat:@"%@=%u", names[i], [detection valueOfCode:candidates[c].unsignedCharValue atLevel:i]]];
            say(@"  %lu. VCP 0x%02X: %@", (unsigned long)c + 1, candidates[c].unsignedIntValue, [vals componentsJoinedByString:@", "]);
        }
        int pick = askNumber([NSString stringWithFormat:@"Which one is local dimming? (1-%lu, 0 to cancel) ", (unsigned long)candidates.count],
                             0, (int)candidates.count);
        if (pick == 0) { say(@"Cancelled. Nothing was saved."); return 1; }
        code = candidates[pick - 1];
    }
    uint8_t vcp = code.unsignedCharValue;
    say(@"\nLocal dimming is VCP 0x%02X (range max %u):", vcp, [detection rangeMaxOfCode:vcp]);
    for (int i = 0; i < n; i++) say(@"  %-12s %u", names[i].UTF8String, [detection valueOfCode:vcp atLevel:i]);

    if (!askYes([NSString stringWithFormat:@"\nWrite each level to VCP 0x%02X now, so you can check it on the monitor?", vcp])) {
        say(@"Nothing was written or saved.");
        return 1;
    }
    for (int i = 0; i < n; i++) {
        HCSetDimming(av, vcp, [detection valueOfCode:vcp atLevel:i], names[i]);
        if (!askYes([NSString stringWithFormat:@"Does the monitor's menu show local dimming \"%@\" now?", names[i]])) {
            // Leave it where the user last set it.
            HCSetDimming(av, vcp, [detection valueOfCode:vcp atLevel:n - 1], names[n - 1]);
            say(@"Not saved: the levels didn't match. Run hdrctl detect again, setting each level exactly as asked.");
            return 1;
        }
    }
    // The last write was level n, which is where the user left it, so nothing needs restoring.

    say(@"");
    say(@"Levels: %@", [names componentsJoinedByString:@", "]);
    NSString *onLevel  = askLevel(@"Which level should HDR on use?", names, HCSuggestedHDRLevel(names, YES));
    NSString *offLevel = askLevel(@"Which level should HDR off use?", names, HCSuggestedHDRLevel(names, NO));

    say(@"\nOptional details for the monitor database (press Return to skip):");
    NSString *firmware = ask(@"  Firmware version shown in the monitor's menu: ");
    NSString *connection = ask(@"  Connection (e.g. USB-C, DisplayPort, HDMI): ");
    NSDictionary *report = HCDetectionReport(@"hdrctl detect", firmware, connection);
    NSDictionary *entry = HCSaveLocalMonitor(identity, vcp, [detection levelsNamed:names forCode:vcp], onLevel, offLevel, report, &err);
    if (!entry) die(@"%@", err);
    NSString *json = HCPrettyJSON(@{ hash: entry });
    say(@"\nSaved to %@:\n%@", HCLocalDBPath(), json);

    if (askYes(@"\nContribute this monitor to HDR Switch? This opens a pre-filled GitHub issue in your browser (you can review it before submitting).")) {
        NSURL *url = HCContributionURL(identity, json, @"hdrctl detect");
        if (![[NSWorkspace sharedWorkspace] openURL:url]) say(@"Couldn't open a browser. Open this link instead:\n%@", url.absoluteString);
        else say(@"Opened GitHub in your browser. If it didn't appear, use this link:\n%@", url.absoluteString);
    }
    return 0;
}

// ------------------------------------------------------------------- main --

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *needle = nil;   // the only external display
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
        // local_monitor_db.json is in ~/Library/Application Support/HDR Switch, shared with the app;
        // move an older copy from next to hdrctl there once.
        for (NSString *line in HCMigrateToolDirectoryFiles()) say(@"%@", line);
        NSString *err = nil, *why = nil;

        if ([cmd isEqualToString:@"list"]) {
            if (!HCLoadSkyLight(&err)) die(@"%@", err);
            NSArray *ds = HCAllDisplays();
            if (ds.count == 0) say(@"no displays found");
            for (NSDictionary *d in ds) printStatus([d[@"id"] unsignedIntValue], d[@"name"]);
            return 0;
        }

        NSString *name = nil;
        CGDirectDisplayID d = HCFindDisplay(needle, &name, &err);
        if (!d) die(@"%@", err);

        if ([cmd isEqualToString:@"ddc"] && args.count >= 2) {
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(d, &attrs);
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

        if ([cmd isEqualToString:@"detect"]) return detect(d);

        if ([cmd isEqualToString:@"identify"]) {
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(d, &attrs);
            NSDictionary *live = HCReadIdentityValues(av, attrs, &why);
            if (!live) die(@"%@", why);
            NSString *identity = HCIdentityJSON(live), *hash = HCSHA256Hex(identity);
            say(@"Display:         %@  (UUID %@)", name, HCDisplayUUID(d));
            say(@"Identity:        %@", identity);
            say(@"Hash:            %@", hash);
            NSDictionary *db = HCLoadDB(&err);
            if (!db) die(@"%@", err);
            NSDictionary *local = HCLoadLocalDB(&err);
            if (!local) die(@"%@", err);
            say(@"monitor_db.json: %@", local[hash] ? @"listed (local_monitor_db.json, from hdrctl detect)"
                                        : db[hash] ? @"listed" : @"not listed (to add it: hdrctl detect)");
            say(@"Data folder:     %@", HCDataDirectory());
            for (NSString *old in HCToolDirectoryLeftovers())
                say(@"note: ignoring %@; the copy in the data folder is used (delete it to tidy up)", old);
            return 0;
        }

        if (!HCLoadSkyLight(&err)) die(@"%@", err);

        if ([cmd isEqualToString:@"status"]) {
            printStatus(d, name);
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(d, &attrs);
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
            IOAVServiceRef av = findAVService(d, &attrs);
            NSDictionary<NSString *, NSNumber *> *levels = nil;
            NSDictionary *entry = requireMonitor(av, attrs);
            uint8_t code = localDimming(entry, &levels);
            NSString *levelName = hdrLevel(entry, YES);
            uint16_t level = levelValue(levels, levelName);
            if (!HCSetHDR(d, YES, &err)) die(@"%@", err);
            if (!HCSetProfile(d, p, &err)) die(@"%@", err);
            HCSetDimming(av, code, level, levelName);
            say(@"Done: %@ — HDR on", name);
        } else if ([cmd isEqualToString:@"off"] || [cmd isEqualToString:@"toggle"]) {
            NSURL *p = resolveProfile(sdrSpec);
            NSDictionary *attrs = nil;
            IOAVServiceRef av = findAVService(d, &attrs);
            NSDictionary<NSString *, NSNumber *> *levels = nil;
            NSDictionary *entry = requireMonitor(av, attrs);
            uint8_t code = localDimming(entry, &levels);
            NSString *levelName = hdrLevel(entry, NO);
            uint16_t level = levelValue(levels, levelName);
            if (!HCSetHDR(d, NO, &err)) die(@"%@", err);
            if (!HCSetProfile(d, p, &err)) die(@"%@", err);
            HCSetDimming(av, code, level, levelName);
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
