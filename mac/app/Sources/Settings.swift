// HDR Switch Settings: which color profile and local dimming level, if any, the HDR toggle sets after
// turning HDR on or off.

import SwiftUI

// One "[✓] Set … to [value]" setting. Unchecked: leave it as it is.
struct SettingRule: Equatable {
    var enabled: Bool
    var value: String
}

// Saved in settings.json in the data folder, for each monitor by its display UUID (see hdrcore.h). The
// defaults are what hdrctl on/off do. Local dimming levels are stored by their monitor_db.json name
// ("off", "standard").
enum Preferences {
    enum Rule: CaseIterable {
        case onProfile, offProfile, onDimming, offDimming, onBrightness, offBrightness

        fileprivate var state: String { [.onProfile, .onDimming, .onBrightness].contains(self) ? "hdr_on" : "hdr_off" }
        fileprivate var what: String {
            switch self {
            case .onProfile, .offProfile: return "color_profile"
            case .onDimming, .offDimming: return "local_dimming"
            case .onBrightness, .offBrightness: return "brightness"
            }
        }
        fileprivate var fallback: SettingRule {
            switch self {
            case .onProfile: return SettingRule(enabled: true, value: "Rec. ITU-R BT.2020-1")
            case .offProfile: return SettingRule(enabled: true, value: "Display P3")
            case .onDimming: return SettingRule(enabled: true, value: "standard")
            case .offDimming: return SettingRule(enabled: true, value: "off")
            case .onBrightness, .offBrightness: return SettingRule(enabled: false, value: "50")   // % ; left alone by default
            }
        }
        // The keys these settings had in the app's preferences up to 0.2.1.
        fileprivate var oldKeys: (enabled: String, value: String) {
            let state = self.state == "hdr_on" ? "hdrOn" : "hdrOff"
            let what = self.what == "color_profile" ? "Profile" : "Dimming"
            return (state + "Set" + what, state + what)
        }
    }

    static func get(_ rule: Rule, uuid: String) -> SettingRule {
        if uuid == FakeMonitor.uuid, let value = fakeRules[rule] { return value }
        var err: NSString?
        let monitor = HCLoadSettings(&err)?[uuid] as? [String: Any]
        let saved = (monitor?[rule.state] as? [String: Any])?[rule.what] as? [String: Any]
        var value = saved?["value"] as? String ?? (saved?["value"] as? NSNumber)?.stringValue ?? rule.fallback.value
        if rule == .onBrightness || rule == .offBrightness {   // also if the file was edited by hand
            value = String(min(max(Int(value) ?? Int(rule.fallback.value) ?? 50, minimumBrightness), 100))
        }
        return SettingRule(enabled: saved?["set"] as? Bool ?? rule.fallback.enabled, value: value)
    }

    static func set(_ rule: Rule, uuid: String, _ value: SettingRule) {
        if uuid == FakeMonitor.uuid { fakeRules[rule] = value; return }
        var rules = Dictionary(uniqueKeysWithValues: Rule.allCases.map { ($0, get($0, uuid: uuid)) })
        rules[rule] = value
        save(rules, uuid: uuid)
    }

    @discardableResult
    private static func save(_ rules: [Rule: SettingRule], uuid: String) -> Bool {
        var monitor: [String: [String: Any]] = [:]
        for (rule, value) in rules {
            let number = rule == .onBrightness || rule == .offBrightness ? Int(value.value) : nil   // a number in the file
            monitor[rule.state, default: [:]][rule.what] = ["set": value.enabled, "value": number.map { $0 as Any } ?? value.value]
        }
        var err: NSString?
        if HCSaveMonitorSettings(uuid, monitor, &err) { return true }
        NSLog("HDR Switch: %@", (err as String?) ?? "couldn't save settings.json")
        return false
    }

    // Up to 0.2.1 settings were in the app's preferences, as <UUID>.hdrOnProfile etc., and without the
    // UUID for monitors with none of their own. Once, when there's a monitor to give them to, moves
    // them to settings.json: for these monitors and any named in the keys.
    static func moveFromAppPreferences(connected: [String]) {
        let d = UserDefaults.standard
        guard !connected.isEmpty, let path = HCSettingsPath(), !FileManager.default.fileExists(atPath: path),
              let id = Bundle.main.bundleIdentifier, let old = d.persistentDomain(forName: id) else { return }
        let moved: [Rule] = [.onProfile, .offProfile, .onDimming, .offDimming]   // brightness came later
        let names = moved.flatMap { [$0.oldKeys.enabled, $0.oldKeys.value] }
        let ours = old.keys.filter { key in names.contains { key == $0 || key.hasSuffix("." + $0) } }
        guard !ours.isEmpty else { return }
        let named = ours.filter { $0.contains(".") }.compactMap { $0.split(separator: ".").first.map(String.init) }
        for uuid in Set(connected + named) {
            var rules: [Rule: SettingRule] = [:]
            for rule in moved {
                let keys = rule.oldKeys
                rules[rule] = SettingRule(enabled: d.object(forKey: uuid + "." + keys.enabled) as? Bool ?? d.object(forKey: keys.enabled) as? Bool ?? rule.fallback.enabled,
                                          value: d.string(forKey: uuid + "." + keys.value) ?? d.string(forKey: keys.value) ?? rule.fallback.value)
            }
            if !save(rules, uuid: uuid) { return }   // keep the old keys, to try again
        }
        ours.forEach { d.removeObject(forKey: $0) }
    }

    static let minimumBrightness = MonitorModel.lowBrightness

    private static var fakeRules: [Rule: SettingRule] = [:]   // the fake monitor's, for this launch only

    static func profile(hdrOn: Bool, uuid: String) -> SettingRule { get(hdrOn ? .onProfile : .offProfile, uuid: uuid) }
    static func dimming(hdrOn: Bool, uuid: String) -> SettingRule { get(hdrOn ? .onDimming : .offDimming, uuid: uuid) }
    static func brightness(hdrOn: Bool, uuid: String) -> SettingRule { get(hdrOn ? .onBrightness : .offBrightness, uuid: uuid) }
}

// The settings window's state. Each change is saved right away, as in macOS's own Settings windows;
// nothing applies until the next HDR switch. A class rather than @State (see HoverState).
final class SettingsModel: ObservableObject {
    struct Monitor: Equatable {
        let uuid: String
        let title: String   // the name, with part of the UUID if another monitor has the same one
    }

    @Published var onProfile = SettingRule(enabled: false, value: "") { didSet { save(.onProfile, onProfile) } }
    @Published var offProfile = SettingRule(enabled: false, value: "") { didSet { save(.offProfile, offProfile) } }
    @Published var onDimming = SettingRule(enabled: false, value: "") { didSet { save(.onDimming, onDimming) } }
    @Published var offDimming = SettingRule(enabled: false, value: "") { didSet { save(.offDimming, offDimming) } }
    @Published var onBrightness = SettingRule(enabled: false, value: "") { didSet { save(.onBrightness, onBrightness) } }
    @Published var offBrightness = SettingRule(enabled: false, value: "") { didSet { save(.offBrightness, offBrightness) } }
    private var loading = false   // showing the saved values, without writing them back
    @Published private(set) var monitors: [Monitor] = []   // the connected external displays
    @Published private(set) var selected = ""               // the UUID of the monitor shown
    @Published private(set) var profiles: [String] = []
    @Published private(set) var levels: [String] = []   // the selected monitor's levels, by value, once read
    @Published private(set) var hasDetected = false      // local_monitor_db.json exists

    private let displays: DisplayList

    init(displays: DisplayList) { self.displays = displays }

    var selectedTitle: String { monitors.first { $0.uuid == selected }?.title ?? "" }

    // Shows the saved settings, for the same monitor as before if it's still listed.
    func reload() {
        monitors = displays.monitors.map { m in
            let shared = displays.monitors.filter { $0.name == m.name }.count > 1
            return Monitor(uuid: m.uuid, title: shared ? "\(m.name) (\(m.uuid.prefix(8)))" : m.name)
        }
        profiles = HCListProfiles().compactMap { $0["name"] as? String }
        select(monitors.contains { $0.uuid == selected } ? selected : monitors.first?.uuid ?? "")
    }

    func select(_ uuid: String) {
        selected = uuid
        loading = true
        onProfile = Preferences.get(.onProfile, uuid: uuid)
        offProfile = Preferences.get(.offProfile, uuid: uuid)
        onDimming = Preferences.get(.onDimming, uuid: uuid)
        offDimming = Preferences.get(.offDimming, uuid: uuid)
        onBrightness = Preferences.get(.onBrightness, uuid: uuid)
        offBrightness = Preferences.get(.offBrightness, uuid: uuid)
        loading = false
        reloadLevels()
    }

    // The levels the popup read from the selected monitor (no DDC here, so it's instant; they arrive
    // a moment after a refresh, and this is called again then), stored by their database names.
    func reloadLevels() {
        levels = displays.monitors.first { $0.uuid == selected }?.dimmingLevels.map { $0.lowercased() } ?? []
        hasDetected = Self.hasDetectedMonitors()
    }

    private func save(_ rule: Preferences.Rule, _ value: SettingRule) {
        if !loading && !selected.isEmpty { Preferences.set(rule, uuid: selected, value) }
    }

    // The file exists, even if it's damaged or empty: the viewer says so.
    private static func hasDetectedMonitors() -> Bool {
        guard let path = HCLocalDBPath() else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}

// A window styled like the popup: the same translucent background, running under a transparent
// title bar so the window is one surface. The SwiftUI content sits below the title bar, sized to fit
// it, so build a new window when the content may have changed. Frames rather than Auto Layout: with
// a full-size content view, constraints and the hosting view's own sizing kept adding the title bar
// again.
// Near white in light mode, like the popup (its panels are then a little darker); clear in dark mode.
final class LightTint: NSView {
    override func viewDidMoveToWindow() { update() }
    override func viewDidChangeEffectiveAppearance() { update() }
    private func update() {
        wantsLayer = true
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = dark ? NSColor.clear.cgColor : NSColor.white.withAlphaComponent(0.6).cgColor
    }
}

// A window that can resize to its content after it changes (see refit()).
final class TranslucentWindow: NSWindow {
    var measure: () -> NSSize = { .zero }   // the SwiftUI content's current size

    override func cancelOperation(_ sender: Any?) { close() }   // Esc, as with the close button

    // New size for the current content, keeping the top edge where it is.
    func refit() {
        let size = measure()
        let titleBar = frame.height - contentLayoutRect.height
        let height = size.height + titleBar
        guard size != .zero, abs(height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: size.width, height: height), display: true)
    }
}

func makeTranslucentWindow<Content: View>(title: String, content: Content) -> TranslucentWindow {
    let w = TranslucentWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    w.title = title
    w.titlebarAppearsTransparent = true
    w.isMovableByWindowBackground = true
    w.isReleasedWhenClosed = false

    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    w.contentView = background
    let titleBar = w.frame.height - w.contentLayoutRect.height

    let host = NSHostingView(rootView: content)
    let size = host.fittingSize
    if #available(macOS 13.0, *) { host.sizingOptions = [] }   // the window is sized here, not by the host
    w.setFrame(NSRect(x: 0, y: 0, width: size.width, height: size.height + titleBar), display: false)
    let tint = LightTint(frame: background.bounds)   // the whole window, title bar included
    tint.autoresizingMask = [.width, .height]
    background.addSubview(tint)
    host.frame = NSRect(origin: .zero, size: size)   // the bottom of the window, below the title bar
    host.autoresizingMask = [.width, .height]
    background.addSubview(host)
    w.measure = { NSHostingView(rootView: content).fittingSize }   // a fresh host sees the content's current state
    w.center()
    return w
}

func makeSettingsWindow(model: SettingsModel, detect: @escaping () -> Void,
                        viewDetected: @escaping () -> Void, clearDetected: @escaping () -> Void) -> TranslucentWindow {
    makeTranslucentWindow(title: "HDR Switch Settings",
                          content: SettingsView(model: model, detect: detect, viewDetected: viewDetected,
                                                clearDetected: clearDetected))
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let detect: () -> Void
    let viewDetected: () -> Void
    let clearDetected: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.selected.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No external display connected")   // as in the popup
                        .font(.system(size: 13, weight: .bold))
                    Text("Connect a monitor to choose its settings.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else {
                // The settings below are for this monitor; with more than one, a menu chooses it.
                if model.monitors.count > 1 {
                    HStack {
                        Text("Monitor")
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                        Dropdown(options: model.monitors.map { $0.title }, selection: model.selectedTitle,
                                 select: { title in
                                     if let m = model.monitors.first(where: { $0.title == title }) { model.select(m.uuid) }
                                 })
                    }
                } else {
                    Text(model.selectedTitle)
                        .font(.system(size: 13, weight: .bold))
                }
                Section(title: "When HDR is turned on", profile: $model.onProfile, dimming: $model.onDimming,
                        brightness: $model.onBrightness, model: model)
                Section(title: "When HDR is turned off", profile: $model.offProfile, dimming: $model.offDimming,
                        brightness: $model.offBrightness, model: model)
                if model.levels.isEmpty {
                    Text("Local dimming isn't available: this monitor isn't supported, or it didn't answer. To add it, use Detect Monitor below.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Detect needs a connected monitor; View and Delete need a local_monitor_db.json.
            if !model.selected.isEmpty || model.hasDetected {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Monitor detection")
                        .font(.system(size: 13, weight: .bold))
                    Panel {
                        if !model.selected.isEmpty {
                            HStack(alignment: .center) {
                                Text("Find your monitor's local dimming setting and its levels, and save them to local_monitor_db.json. Run this again after updating the monitor's firmware.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Detect Monitor…", action: detect)
                            }
                        }
                        // The window refits when these appear or go.
                        if model.hasDetected {
                            if !model.selected.isEmpty { Divider().padding(.vertical, 6) }
                            HStack {
                                Spacer()
                                Button("View Detected Monitor…", action: viewDetected)
                                Button("Delete Detected Monitor…", action: clearDetected)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
    }

    private struct Section: View {
        let title: String
        @Binding var profile: SettingRule
        @Binding var dimming: SettingRule
        @Binding var brightness: SettingRule
        @ObservedObject var model: SettingsModel

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))   // like the monitor's name in the popup
                Panel {
                    RuleRow(label: "Set color profile to", rule: $profile, options: model.profiles, title: { $0 })
                    Divider().padding(.vertical, 6)
                    RuleRow(label: "Set local dimming to", rule: $dimming, options: model.levels, title: { $0.capitalized })
                        .disabled(model.levels.isEmpty)
                    Divider().padding(.vertical, 6)
                    BrightnessRow(rule: $brightness)
                        .disabled(model.levels.isEmpty)   // like local dimming, only for a supported monitor
                }
            }
        }
    }
}

// "[✓] Set brightness to    ──●── 50%": a percentage, dimmed while unchecked.
struct BrightnessRow: View {
    @Binding var rule: SettingRule

    var body: some View {
        let lowest = Double(Preferences.minimumBrightness)
        let percent = max(Double(rule.value) ?? 50, lowest)
        HStack(spacing: 8) {
            Toggle("Set brightness to", isOn: $rule.enabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            Spacer()
            Group {
                Slider(value: Binding(get: { percent }, set: { rule.value = String(Int($0.rounded())) }), in: lowest...100)
                    .controlSize(.small)
                    .frame(width: 120)
                Text("\(Int(percent))%")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .disabled(!rule.enabled)
            .opacity(rule.enabled ? 1 : 0.45)
        }
    }
}

// "[✓] Set … to        value ⌃⌄": the checkbox on the left, the popup's menu control on the right,
// dimmed while unchecked.
struct RuleRow: View {
    let label: String
    @Binding var rule: SettingRule
    let options: [String]
    let title: (String) -> String

    var body: some View {
        // The saved value is listed even if it's no longer available, so it stays visible.
        let shown = options.contains(rule.value) ? options : [rule.value] + options
        HStack(spacing: 8) {
            Toggle(label, isOn: $rule.enabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            Spacer()
            Dropdown(options: shown.map(title), selection: title(rule.value),
                     select: { chosen in if let value = shown.first(where: { title($0) == chosen }) { rule.value = value } })
                .disabled(!rule.enabled)
        }
    }
}
