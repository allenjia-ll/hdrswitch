// State of the monitor shown in the popup, backed by mac/core/hdrcore.

import Foundation

final class MonitorModel: ObservableObject {
    // The same defaults as hdrctl.
    static let displayName = "M27P6S"
    static let hdrProfile = "Rec. ITU-R BT.2020-1"
    static let sdrProfile = "Display P3"

    enum Support { case unknown, supported, unsupported }

    @Published private(set) var name = MonitorModel.displayName
    @Published private(set) var connected = false
    @Published private(set) var hdrOn = false
    @Published private(set) var profile = ""
    @Published private(set) var support = Support.unknown
    @Published private(set) var dimming = "Unknown"
    @Published private(set) var switching = false
    @Published private(set) var warning: String?

    private let skyLightLoaded: Bool
    private let work = DispatchQueue(label: "HDR Switch work")   // one switch or DDC lookup at a time

    init() {
        var err: NSString?
        skyLightLoaded = HCLoadSkyLight(&err)
        if !skyLightLoaded { warning = (err as String?) ?? "Can't load SkyLight, so HDR can't be switched." }
    }

    var canToggle: Bool { skyLightLoaded && connected && !switching }

    var stateText: String {
        if switching { return "Switching…" }
        if !connected { return "Not connected" }
        return hdrOn ? "On" : "Off"
    }

    // HDR state and profile are cheap; local dimming needs DDC reads, so it's filled in from `work`.
    func refresh() {
        guard skyLightLoaded, !switching, let d = findDisplay() else { return }
        hdrOn = HCIsHDR(d)
        profile = HCCurrentProfile(d)
        if support != .unsupported { dimming = "…" }
        work.async {
            HCDDCClearTimeout()
            let snapshot = self.snapshot(d, self.lookUpDimming())
            DispatchQueue.main.async {
                self.apply(snapshot)
                self.warning = snapshot.timedOut ? Self.timeoutWarning
                             : snapshot.unreachable ? Self.noReplyWarning : nil
            }
        }
    }

    // The same steps as hdrctl on/off: HDR, then the color profile, then local dimming, which is
    // skipped if the monitor isn't supported. Switching takes ~12 s, so it runs on `work`.
    func toggleHDR() {
        guard canToggle, let d = findDisplay() else { return }
        let on = !HCIsHDR(d)
        switching = true
        warning = nil
        work.async {
            HCDDCClearTimeout()
            var err: NSString?
            var problem: String?
            let lookup = self.lookUpDimming()   // before changing anything, like hdrctl
            if let url = HCResolveProfile(on ? Self.hdrProfile : Self.sdrProfile, &err) {
                if !HCSetHDR(d, on, &err) {
                    problem = err as String?
                } else if !HCSetProfile(d, url, &err) {
                    problem = err as String?
                } else if let dim = lookup.dimming, let level = dim.levels[on ? "standard" : "off"],
                          !HCSetDimming(dim.av, dim.code, level.uint16Value, on ? "standard" : "off") {
                    problem = "Couldn't confirm the local dimming change. Another DDC app (e.g. MonitorControl) may be using the monitor."
                }
            } else {
                problem = err as String?
            }
            let snapshot = self.snapshot(d, lookup)
            let skipped = { if case .unreachable = lookup { return true } else { return false } }()
            DispatchQueue.main.async {
                self.switching = false
                self.apply(snapshot)
                self.warning = problem
                    ?? (snapshot.timedOut ? (skipped ? Self.timeoutWarningAfterSwitch : Self.timeoutWarning)
                        : skipped ? Self.noReplyWarningAfterSwitch
                        : snapshot.unreachable ? Self.noReplyWarning : nil)
            }
        }
    }

    static let timeoutWarning =
        "The monitor didn't respond within 3 seconds, so its local dimming setting is unknown."
    static let timeoutWarningAfterSwitch =
        "The monitor didn't respond within 3 seconds, so its local dimming setting wasn't changed."
    static let noReplyWarning =
        "The monitor didn't answer over DDC, so its local dimming setting is unknown. Try again in a moment."
    static let noReplyWarningAfterSwitch =
        "The monitor didn't answer over DDC, so its local dimming setting wasn't changed. Try again in a moment."

    // MARK: - Private

    private func findDisplay() -> CGDirectDisplayID? {
        var found: NSString?, err: NSString?
        let d = HCFindDisplay(Self.displayName, &found, &err)   // NSScreen, so on the main thread
        connected = d != 0
        name = (found as String?) ?? Self.displayName
        if !connected { hdrOn = false; profile = ""; dimming = "Unknown" }
        return connected ? d : nil
    }

    private struct Dimming {
        let av: AnyObject
        let code: UInt8
        let levels: [String: NSNumber]
    }

    private enum Lookup {
        case supported(Dimming)
        case unsupported   // read fine, but not in monitor_db.json or not my_monitor.json
        case unreachable   // no DDC connection, no reply, or timed out

        var dimming: Dimming? { if case .supported(let d) = self { return d } else { return nil } }
    }

    // Local dimming settings for the connected monitor, if it's in monitor_db.json and matches
    // my_monitor.json (created on first run). Blocking DDC reads, so only on `work`.
    private func lookUpDimming() -> Lookup {
        var attrs: NSDictionary?, why: NSString?, err: NSString?
        guard let av = HCFindAVService(Self.displayName, &attrs, &err)?.takeRetainedValue() else {
            NSLog("HDR Switch: %@", (err as String?) ?? "no DDC connection")
            return .unreachable
        }
        guard let live = HCReadIdentityValues(av, attrs as? [AnyHashable: Any], &why) else {
            NSLog("HDR Switch: %@", (why as String?) ?? "couldn't read the monitor's identity")
            return .unreachable
        }
        guard let entry = HCFindMonitorForIdentity(live, &why, &err) else {
            NSLog("HDR Switch: monitor unknown: %@", ((err ?? why) as String?) ?? "")
            return .unsupported
        }
        var levels: NSDictionary?
        let code = HCLocalDimming(entry, &levels, &err)
        guard code >= 0, let named = levels as? [String: NSNumber] else {
            NSLog("HDR Switch: %@", (err as String?) ?? "bad local dimming entry")
            return .unsupported
        }
        return .supported(Dimming(av: av, code: UInt8(code), levels: named))
    }

    private struct Snapshot {
        let hdrOn: Bool
        let profile: String
        let support: Support
        let dimming: String
        let unreachable: Bool   // DDC didn't answer (or timed out), so local dimming is unknown
        let timedOut: Bool
    }

    private func snapshot(_ d: CGDirectDisplayID, _ lookup: Lookup) -> Snapshot {
        var level = "Unknown"
        if let dim = lookup.dimming {
            var cur: UInt16 = 0
            // Right after an HDR switch the monitor is busy for a moment, so retry like the identity reads.
            for attempt in 0..<10 where !HCDDCDidTimeOut() {
                if attempt > 0 { usleep(300_000) }
                if HCDDCGet(dim.av, dim.code, &cur, nil) {
                    level = HCLevelName(dim.levels, cur)?.capitalized ?? "Unknown (\(cur))"
                    break
                }
            }
        }
        let timedOut = HCDDCDidTimeOut()
        let support: Support
        switch lookup {
        case .supported: support = .supported
        case .unsupported: support = .unsupported
        case .unreachable: support = .unknown   // says nothing about whether it's supported
        }
        let unreachable = timedOut || (support == .unknown) || (support == .supported && level == "Unknown")
        return Snapshot(hdrOn: HCIsHDR(d), profile: HCCurrentProfile(d), support: support, dimming: level,
                        unreachable: unreachable, timedOut: timedOut)
    }

    private func apply(_ s: Snapshot) {
        hdrOn = s.hdrOn
        profile = s.profile
        support = s.support
        dimming = s.dimming
    }
}
