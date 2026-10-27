// hdrcore — HDR, color profile, DDC/CI and monitor DB functions shared by the
// hdrctl command-line tool and the menu bar app (macOS).
//
// Nothing here prints or exits. Failures return NO / nil / 0 with *error set,
// and progress messages and warnings go to the logger set with HCSetLogger.
//
// HDR switching uses SkyLight (private framework, macOS 11+), loaded at runtime.
// Color profiles use the public ColorSync API (same as System Settings > Displays > Color profile).
// Local dimming is set on the monitor over DDC/CI via IOAVService (private IOKit API, Apple Silicon).

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

// ------------------------------------------------------------------ logging --

typedef NS_ENUM(NSInteger, HCLogLevel) { HCLogInfo, HCLogWarning };
void HCSetLogger(void (^logger)(HCLogLevel level, NSString *message));

// -------------------------------------------------------------- data files --
// monitor_db.json and my_monitor.json are read from this folder. Default: the folder of
// the running executable (symlinks resolved).
void HCSetDataDirectory(NSString *dir);
NSString *HCDataDirectory(void);
// monitor_db.json's path, if it isn't in the data folder (e.g. the app ships it in its Resources).
void HCSetDBPath(NSString *path);

// --------------------------------------------------------------- SkyLight --

BOOL HCLoadSkyLight(NSString **error);       // call once before the HDR functions
BOOL HCSupportsHDR(CGDirectDisplayID d);
BOOL HCIsHDR(CGDirectDisplayID d);
// Switches HDR and waits for it to take effect (up to 10 s, then 2 s to settle).
BOOL HCSetHDR(CGDirectDisplayID d, BOOL on, NSString **error);

// --------------------------------------------------------------- displays --

NSArray<NSDictionary *> *HCAllDisplays(void);   // @{ @"id": NSNumber, @"name": NSString }
// Exactly one display whose name contains needle (case-insensitive), or 0 with *error set.
CGDirectDisplayID HCFindDisplay(NSString *needle, NSString **outName, NSString **error);

// --------------------------------------------------------------- profiles --

NSString *HCCurrentProfile(CGDirectDisplayID d);
// An .icc/.icm path, or a profile name (exact match preferred, then substring).
NSURL *HCResolveProfile(NSString *spec, NSString **error);
// Installed RGB display profiles, sorted by name: @{ @"name": NSString, @"url": NSURL }.
NSArray<NSDictionary *> *HCListProfiles(void);
BOOL HCSetProfile(CGDirectDisplayID d, NSURL *url, NSString **error);

// -------------------------------------------------------------------- DDC --

typedef CFTypeRef IOAVServiceRef;
// The DDC/CI service of the external display whose name contains needle, or NULL with *error set.
// outAttrs gets the display's EDID ProductAttributes. Release the service with CFRelease.
IOAVServiceRef HCFindAVService(NSString *needle, NSDictionary **outAttrs, NSString **error);
// Every DDC call gives up after 3 s (a sleeping monitor never answers), logging one warning. A
// service with a timed-out call still running fails at once; a new one from HCFindAVService works.
// HCDDCDidTimeOut says whether a call timed out since HCDDCClearTimeout.
BOOL HCDDCDidTimeOut(void);
void HCDDCClearTimeout(void);
// Returns NO if there's no valid reply or the monitor doesn't support the code.
BOOL HCDDCGet(IOAVServiceRef av, uint8_t code, uint16_t *cur, uint16_t *max);

// -------------------------------------------------------------- monitor DB --
// A monitor is identified by the SHA-256 of its identity values, in this order, as compact JSON:
//   {"manufacturer":"SKG","product_id":10158,"product_name":"M27P6S",
//    "display_controller_id":22021,"firmware_version":0,"local_dimming_range_max":5}
// monitor_db.json maps that hash to the identity and the monitor's DDC settings; it ships with the
// tool. local_monitor_db.json (next to it) has the same format and holds monitors detected on this
// Mac (hdrctl detect); its entries override the shipped ones. my_monitor.json
// holds the monitor set up on this Mac, as { "<hash>": { "identity": { ... } } }. Before any DDC
// write, the connected monitor is read, hashed, and must match my_monitor.json and be in the DB.

// The connected monitor's identity values (the keys above), or nil with *why set if one can't be read.
NSDictionary *HCReadIdentityValues(IOAVServiceRef av, NSDictionary *attrs, NSString **why);
// The canonical identity JSON that gets hashed, or nil if a value is missing or the wrong type.
NSString *HCIdentityJSON(NSDictionary *identity);
NSString *HCSHA256Hex(NSString *s);
// monitor_db.json merged with local_monitor_db.json (local entries win), @{} if neither exists, or
// nil with *error set if one isn't valid JSON.
NSDictionary *HCLoadDB(NSString **error);
NSString *HCLocalDBPath(void);
NSDictionary *HCLoadLocalDB(NSString **error);   // just local_monitor_db.json, @{} if it doesn't exist
NSString *HCPrettyJSON(id object);                // indented, sorted keys
NSString *HCMyMonitorPath(void);
// The hash in my_monitor.json (with its identity in *identity), or nil with *why set if the file
// is missing or invalid, including when its key isn't the hash of its identity section.
NSString *HCReadMyMonitor(NSDictionary **identity, NSString **why);
// Writes my_monitor.json for this identity and removes an old one-line my_monitor file.
BOOL HCSaveMyMonitor(NSDictionary *identity, NSString **error);
// If my_monitor.json doesn't exist, creates it for this identity (replacing an old one-line
// my_monitor) and logs an info line.
void HCEnsureMyMonitor(NSDictionary *identity);
// The DB entry for the connected monitor, if it matches my_monitor.json and is in monitor_db.json.
// Creates my_monitor.json first if it doesn't exist (see HCEnsureMyMonitor).
// Otherwise nil, with *why set (monitor unknown) or *error set (monitor_db.json is invalid).
NSDictionary *HCFindMonitor(IOAVServiceRef av, NSDictionary *attrs, NSString **why, NSString **error);
// The same, for identity values already read with HCReadIdentityValues.
NSDictionary *HCFindMonitorForIdentity(NSDictionary *live, NSString **why, NSString **error);
// The local dimming VCP code from a DB entry, with its levels (name -> value) in *levels,
// or -1 with *error set if the entry is malformed.
int HCLocalDimming(NSDictionary *entry, NSDictionary<NSString *, NSNumber *> **levels, NSString **error);
NSString *HCLevelName(NSDictionary<NSString *, NSNumber *> *levels, uint16_t value);
// Writes local dimming, reads it back and retries while the monitor is busy. Skips the write if
// it's already set. Returns NO (with a warning logged) if it couldn't be confirmed.
BOOL HCSetDimming(IOAVServiceRef av, uint8_t code, uint16_t value, NSString *label);

// -------------------------------------------------------------- detection --
// Finding a monitor's local dimming code: scan every VCP code at each level the user sets in the
// monitor's menu, and look for the one code that changes with it. Scans only read.

// Reads each code (all of 0x01–0xFF if codes is nil): code -> @[ cur, max ] for those that answered.
NSDictionary<NSNumber *, NSArray<NSNumber *> *> *HCDDCScan(IOAVServiceRef av, NSArray<NSNumber *> *codes,
                                                          void (^progress)(NSUInteger done, NSUInteger total));
// Codes that are candidates for local dimming, sorted: scans[i] was taken at level i, repeat is a
// second scan at level 0. A candidate reads the same in scans[0] and repeat, answers in every scan
// with the same max, and has a different value at every level.
NSArray<NSNumber *> *HCDimmingCandidates(NSArray<NSDictionary *> *scans, NSDictionary *repeat);
// One detection run. The user sets each level in the monitor's menu, in order, and scanLevel: is
// called after each; then the candidates are known. The first level reads every code twice, to rule
// out values that change on their own; later levels re-read only the codes that answered, and a code
// that misses a reply is read again a few times rather than dropped.
@interface HCDetection : NSObject
- (instancetype)initWithService:(IOAVServiceRef)av levelCount:(NSUInteger)count;
@property (readonly) NSUInteger levelCount;
@property (readonly) NSUInteger scannedLevels;
// Scans the next level. progress gets the pass (0, then 1 for the first level's second read), the
// codes read so far in that pass and the pass's total. Returns NO if the monitor stopped answering
// over DDC (asleep?); the detection can't continue then.
- (BOOL)scanNextLevelWithProgress:(void (^)(NSUInteger pass, NSUInteger done, NSUInteger total))progress;
// Drops the scans from this level on, so they can be redone (e.g. the user went back a step).
- (void)discardLevelsFrom:(NSUInteger)level;
// After every level is scanned: the candidate codes (see HCDimmingCandidates).
@property (readonly) NSArray<NSNumber *> *candidates;
- (uint16_t)valueOfCode:(uint8_t)code atLevel:(NSUInteger)level;
- (uint16_t)rangeMaxOfCode:(uint8_t)code;
// @[ @{ @"name": names[i], @"value": value at level i }, ... ] for HCSaveLocalMonitor.
- (NSArray<NSDictionary *> *)levelsNamed:(NSArray<NSString *> *)names forCode:(uint8_t)code;
@end

// The level HDR on (or off) should use by default: "standard" / "off" if there is one, otherwise the
// last / first level.
NSString *HCSuggestedHDRLevel(NSArray<NSString *> *names, BOOL on);
// The report section for a detected entry: tool (e.g. "hdrctl detect"), OS, date, verified_by_user,
// and the optional firmware shown in the monitor's menu and connection, when not empty.
NSDictionary *HCDetectionReport(NSString *tool, NSString *firmware, NSString *connection);
// A pre-filled new-issue link on GitHub for contributing a detected entry (entryJSON: the entry
// keyed by its hash, e.g. HCPrettyJSON(@{ hash: entry })).
NSURL *HCContributionURL(NSDictionary *identity, NSString *entryJSON, NSString *tool);

// Adds (or replaces) this monitor's entry in local_monitor_db.json and returns it, or nil with *error
// set. levels: @[ @{ @"name": "off", @"value": @0 }, ... ]. hdrOn / hdrOff: the level names hdrctl
// on / off use (stored as settings.local_dimming.hdr_on / hdr_off). report: details for reviewers.
NSDictionary *HCSaveLocalMonitor(NSDictionary *identity, uint8_t code, NSArray<NSDictionary *> *levels,
                                 NSString *hdrOn, NSString *hdrOff, NSDictionary *report, NSString **error);
