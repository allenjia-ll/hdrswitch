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
// monitor_db.json and my_monitor are read from this folder. Default: the folder of
// the running executable (symlinks resolved).
void HCSetDataDirectory(NSString *dir);
NSString *HCDataDirectory(void);

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
BOOL HCSetProfile(CGDirectDisplayID d, NSURL *url, NSString **error);

// -------------------------------------------------------------------- DDC --

typedef CFTypeRef IOAVServiceRef;
// The DDC/CI service of the external display whose name contains needle, or NULL with *error set.
// outAttrs gets the display's EDID ProductAttributes. Release the service with CFRelease.
IOAVServiceRef HCFindAVService(NSString *needle, NSDictionary **outAttrs, NSString **error);
// Returns NO if there's no valid reply or the monitor doesn't support the code.
BOOL HCDDCGet(IOAVServiceRef av, uint8_t code, uint16_t *cur, uint16_t *max);

// -------------------------------------------------------------- monitor DB --
// A monitor is identified by the SHA-256 of its identity values, in this order, as compact JSON:
//   {"manufacturer":"SKG","product_id":10158,"product_name":"M27P6S",
//    "display_controller_id":22021,"firmware_version":0,"local_dimming_range_max":5}
// monitor_db.json maps that hash to the identity and the monitor's DDC settings. my_monitor holds
// the hash of the monitor set up on this Mac. Before any DDC write, the connected monitor is read,
// hashed, and must match my_monitor and be in the DB.

// The canonical identity JSON of the connected monitor, or nil with *why set if a value can't be read.
NSString *HCReadIdentity(IOAVServiceRef av, NSDictionary *attrs, NSString **why);
NSString *HCSHA256Hex(NSString *s);
// The DB, @{} if monitor_db.json doesn't exist, or nil with *error set if it isn't valid JSON.
NSDictionary *HCLoadDB(NSString **error);
NSString *HCReadMyMonitor(void);   // trimmed contents of my_monitor, or nil
// The DB entry for the connected monitor, if it matches my_monitor and is in monitor_db.json.
// Otherwise nil, with *why set (monitor unknown) or *error set (monitor_db.json is invalid).
NSDictionary *HCFindMonitor(IOAVServiceRef av, NSDictionary *attrs, NSString **why, NSString **error);
// The local dimming VCP code from a DB entry, with its levels (name -> value) in *levels,
// or -1 with *error set if the entry is malformed.
int HCLocalDimming(NSDictionary *entry, NSDictionary<NSString *, NSNumber *> **levels, NSString **error);
NSString *HCLevelName(NSDictionary<NSString *, NSNumber *> *levels, uint16_t value);
// Writes local dimming, reads it back and retries while the monitor is busy. Skips the write if
// it's already set. Returns NO (with a warning logged) if it couldn't be confirmed.
BOOL HCSetDimming(IOAVServiceRef av, uint8_t code, uint16_t value, NSString *label);
