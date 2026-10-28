// State of the external monitors shown in the popup, backed by mac/core/hdrcore.

import Combine
import Foundation

// All DDC work (popup refresh and changes, monitor detection) runs here, one thing at a time, since
// overlapping DDC requests garble each other's replies.
let ddcQueue = DispatchQueue(label: "HDR Switch DDC")

// For testing the layout with more than one monitor: `open "HDR Switch.app" --args -fakeMonitor "DELL U2725QE"`
// adds a made-up, unsupported monitor after the real ones, in the popup and Settings. Nothing is sent
// to it; its switch and profile menu only change what's shown (the switch shows the profile from its
// settings), and its settings are kept in memory, not saved. The argument lasts for that launch only.
enum FakeMonitor {
    static let uuid = "FAKE-MONITOR"
    static let name = UserDefaults.standard.string(forKey: "fakeMonitor")
}

// The connected external displays, one MonitorModel each, kept by display UUID.
final class DisplayList: ObservableObject {
    @Published private(set) var monitors: [MonitorModel] = []
    private var changes: [AnyCancellable] = []

    // Finds the external displays (NSScreen, so on the main thread) and re-reads each.
    func refresh() {
        let displays = HCAllDisplays().filter { !(($0["builtin"] as? Bool) ?? false) }
        let old = Dictionary(monitors.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        monitors = displays.compactMap { d in
            guard let uuid = d["uuid"] as? String, !uuid.isEmpty else { return nil }
            return old[uuid] ?? MonitorModel(uuid: uuid, name: d["name"] as? String ?? "Display")
        }
        if let name = FakeMonitor.name { monitors.append(old[FakeMonitor.uuid] ?? MonitorModel(uuid: FakeMonitor.uuid, name: name)) }
        // A change in any monitor is a change in the list (the popup refits to it).
        changes = monitors.map { $0.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
        monitors.forEach { $0.refresh() }
    }
}

final class MonitorModel: ObservableObject {
    enum Support { case unknown, supported, unsupported }

    let uuid: String   // the display's, which macOS keeps for this monitor
    @Published private(set) var name: String
    @Published private(set) var connected = false
    @Published private(set) var hdrOn = false
    @Published private(set) var profile = ""
    @Published private(set) var profiles: [String] = []          // installed RGB display profiles
    @Published private(set) var support = Support.unknown
    @Published private(set) var dimming = "Unknown"
    @Published private(set) var dimmingLevels: [String] = []     // from monitor_db.json, by value
    @Published private(set) var switching = false                // HDR toggle running
    @Published private(set) var busy = false                     // any lookup or change running
    @Published private(set) var warning: String?

    private var skyLightLoaded: Bool { Self.skyLightError == nil }
    private var profileURLs: [String: URL] = [:]
    private let work = ddcQueue

    // Loaded once for all monitors: nil, or why HDR can't be switched.
    private static let skyLightError: String? = {
        var err: NSString?
        return HCLoadSkyLight(&err) ? nil : (err as String?) ?? "Can't load SkyLight, so HDR can't be switched."
    }()

    init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
        warning = Self.skyLightError
    }

    private var isFake: Bool { uuid == FakeMonitor.uuid }

    var canChange: Bool { skyLightLoaded && connected && !busy }

    // Re-reads everything. Local dimming needs DDC reads, so it runs on `work`, over a new DDC
    // connection each time.
    func refresh() {
        if isFake {
            connected = true
            support = .unsupported
            profiles = HCListProfiles().compactMap { $0["name"] as? String }
            if profile.isEmpty { profile = "Display P3" }
            return
        }
        guard skyLightLoaded, !busy, let d = findDisplay() else { return }
        hdrOn = HCIsHDR(d)
        profile = HCCurrentProfile(d)
        if support != .unsupported { dimming = "…" }
        run(d, warnIfSkipped: nil) { _ in nil }
    }

    // The same steps as hdrctl on/off: HDR, then the color profile and the local dimming level from
    // Settings (each unless unchecked). Local dimming is skipped if the monitor isn't supported.
    func toggleHDR() {
        if isFake {
            hdrOn.toggle()
            let rule = Preferences.profile(hdrOn: hdrOn, uuid: uuid)
            if rule.enabled { profile = rule.value }
            return
        }
        guard canChange, let d = findDisplay() else { return }
        let on = !HCIsHDR(d)
        let profileRule = Preferences.profile(hdrOn: on, uuid: uuid), dimmingRule = Preferences.dimming(hdrOn: on, uuid: uuid)
        switching = true
        let skipped = dimmingRule.enabled ? Self.notChanged : nil   // nothing to skip if unchecked
        run(d, warnIfSkipped: skipped) { lookup in
            var err: NSString?
            // Resolve both first, so a missing profile or level fails before anything changes.
            var url: URL?
            if profileRule.enabled {
                url = HCResolveProfile(profileRule.value, &err)
                if url == nil { return err as String? }
            }
            var level: NSNumber?
            if dimmingRule.enabled, let dim = lookup.dimming {
                level = dim.levels[dimmingRule.value]
                if level == nil {
                    return "\"\(dimmingRule.value.capitalized)\" isn't one of this monitor's local dimming levels. Check HDR Switch Settings."
                }
            }
            if !HCSetHDR(d, on, &err) { return err as String? }
            if let url = url, !HCSetProfile(d, url, &err) { return err as String? }
            if let dim = lookup.dimming, let level = level,
               !HCSetDimming(dim.av, dim.code, level.uint16Value, dimmingRule.value) {
                return Self.notConfirmed
            }
            return nil
        }
    }

    // Applies the profile now, like `hdrctl profile`. The HDR toggle uses the profiles from Settings.
    func selectProfile(_ name: String) {
        if isFake { profile = name; return }
        guard canChange, name != profile, let url = profileURLs[name], let d = findDisplay() else { return }
        profile = name
        run(d, warnIfSkipped: nil) { _ in
            var err: NSString?
            return HCSetProfile(d, url, &err) ? nil : err as String?
        }
    }

    // Writes one of the monitor's local dimming levels from monitor_db.json.
    func selectDimming(_ level: String) {
        guard canChange, level != dimming, support == .supported, let d = findDisplay() else { return }
        dimming = level
        run(d, warnIfSkipped: Self.notChanged) { lookup in
            guard let dim = lookup.dimming, let value = dim.levels[level.lowercased()] else { return nil }
            return HCSetDimming(dim.av, dim.code, value.uint16Value, level.lowercased()) ? nil : Self.notConfirmed
        }
    }

    static let timeoutWarning = "The monitor didn't respond within 3 seconds, so its local dimming setting is unknown."
    static let timeoutNotChanged = "The monitor didn't respond within 3 seconds, so its local dimming setting wasn't changed."
    static let noReplyWarning = "The monitor didn't answer over DDC, so its local dimming setting is unknown. Try Refresh."
    static let notChanged = "The monitor didn't answer over DDC, so its local dimming setting wasn't changed. Try again in a moment."
    static let notConfirmed = "Couldn't confirm the local dimming change. Another DDC app (e.g. MonitorControl) may be using the monitor."

    // MARK: - Private

    // Runs `change` on `work` after looking up the monitor (before anything changes, like hdrctl),
    // then reads everything back. `change` returns a problem to show, or nil. `warnIfSkipped` is
    // shown if the monitor couldn't be reached, so local dimming wasn't touched.
    private func run(_ d: CGDirectDisplayID, warnIfSkipped: String?, _ change: @escaping (Lookup) -> String?) {
        busy = true
        warning = nil
        work.async {
            HCDDCClearTimeout()
            let lookup = self.lookUpDimming(d)
            let problem = change(lookup)
            let snapshot = self.snapshot(d, lookup)
            let profiles = HCListProfiles().compactMap { p -> (String, URL)? in
                guard let name = p["name"] as? String, let url = p["url"] as? URL else { return nil }
                return (name, url)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.switching = false
                self.profileURLs = Dictionary(profiles, uniquingKeysWith: { a, _ in a })
                self.profiles = profiles.map { $0.0 }
                self.apply(snapshot)
                if let problem = problem {
                    self.warning = problem
                } else if case .unreachable = lookup, let skipped = warnIfSkipped {
                    self.warning = snapshot.timedOut ? Self.timeoutNotChanged : skipped
                } else if snapshot.unreachable {
                    self.warning = snapshot.timedOut ? Self.timeoutWarning : Self.noReplyWarning
                }
            }
        }
    }

    // The display's current ID (it can change when the monitor reconnects), found by its UUID.
    private func findDisplay() -> CGDirectDisplayID? {
        var found: NSString?, err: NSString?
        let d = HCFindDisplay(uuid, &found, &err)   // NSScreen, so on the main thread
        connected = d != 0
        if let found = found as String? { name = found }
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

    // Local dimming settings for the monitor, if it's in monitor_db.json and matches its display's
    // entry in my_monitor.json (added on first use). Blocking DDC reads, so only on `work`.
    private func lookUpDimming(_ d: CGDirectDisplayID) -> Lookup {
        var attrs: NSDictionary?, why: NSString?, err: NSString?
        guard let av = HCFindAVService(d, &attrs, &err)?.takeRetainedValue() else {
            NSLog("HDR Switch: %@", (err as String?) ?? "no DDC connection")
            return .unreachable
        }
        guard let live = HCReadIdentityValues(av, attrs as? [AnyHashable: Any], &why) else {
            NSLog("HDR Switch: %@", (why as String?) ?? "couldn't read the monitor's identity")
            return .unreachable
        }
        guard let entry = HCFindMonitorForIdentity(live, uuid, &why, &err) else {
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
        let levels: [String]
        let unreachable: Bool   // DDC didn't answer (or timed out), so local dimming is unknown
        let timedOut: Bool
    }

    private func snapshot(_ d: CGDirectDisplayID, _ lookup: Lookup) -> Snapshot {
        var level = "Unknown"
        var levels: [String] = []
        if let dim = lookup.dimming {
            levels = dim.levels.sorted { $0.value.intValue < $1.value.intValue }.map { $0.key.capitalized }
            var cur: UInt16 = 0
            // Right after a change the monitor is busy for a moment, so retry like the identity reads.
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
        let unreachable = timedOut || support == .unknown || (support == .supported && level == "Unknown")
        return Snapshot(hdrOn: HCIsHDR(d), profile: HCCurrentProfile(d), support: support, dimming: level,
                        levels: levels, unreachable: unreachable, timedOut: timedOut)
    }

    private func apply(_ s: Snapshot) {
        hdrOn = s.hdrOn
        profile = s.profile
        support = s.support
        dimming = s.dimming
        dimmingLevels = s.levels
    }
}
