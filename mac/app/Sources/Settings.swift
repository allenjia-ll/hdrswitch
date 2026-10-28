// HDR Switch Settings: which color profile and local dimming level, if any, the HDR toggle sets after
// turning HDR on or off.

import SwiftUI

// One "[✓] Set … to [value]" setting. Unchecked: leave it as it is.
struct SettingRule: Equatable {
    var enabled: Bool
    var value: String
}

// Saved per user in the app's preferences, for each monitor by its display UUID. The defaults are
// what hdrctl on/off do. Local dimming levels are stored by their monitor_db.json name ("off", "standard").
enum Preferences {
    enum Rule {
        case onProfile, offProfile, onDimming, offDimming

        // Keys: <UUID>.hdrOnSetProfile / <UUID>.hdrOnProfile, …SetDimming / …Dimming, and the same for hdrOff.
        fileprivate var state: String { self == .onProfile || self == .onDimming ? "hdrOn" : "hdrOff" }
        fileprivate var what: String { self == .onProfile || self == .offProfile ? "Profile" : "Dimming" }
        fileprivate var fallback: SettingRule {
            switch self {
            case .onProfile: return SettingRule(enabled: true, value: "Rec. ITU-R BT.2020-1")
            case .offProfile: return SettingRule(enabled: true, value: "Display P3")
            case .onDimming: return SettingRule(enabled: true, value: "standard")
            case .offDimming: return SettingRule(enabled: true, value: "off")
            }
        }
    }

    // A monitor without its own settings gets those saved without a UUID, which held the one
    // monitor's settings up to 0.2.1, then the defaults.
    static func get(_ rule: Rule, uuid: String) -> SettingRule {
        if uuid == FakeMonitor.uuid, let value = fakeRules[rule] { return value }
        let d = UserDefaults.standard
        func value<T>(_ key: String) -> T? { d.object(forKey: uuid + "." + key) as? T ?? d.object(forKey: key) as? T }
        return SettingRule(enabled: value(rule.state + "Set" + rule.what) ?? rule.fallback.enabled,
                           value: value(rule.state + rule.what) ?? rule.fallback.value)
    }

    static func set(_ rule: Rule, uuid: String, _ value: SettingRule) {
        if uuid == FakeMonitor.uuid { fakeRules[rule] = value; return }
        UserDefaults.standard.set(value.enabled, forKey: uuid + "." + rule.state + "Set" + rule.what)
        UserDefaults.standard.set(value.value, forKey: uuid + "." + rule.state + rule.what)
    }

    private static var fakeRules: [Rule: SettingRule] = [:]   // the fake monitor's, for this launch only

    static func profile(hdrOn: Bool, uuid: String) -> SettingRule { get(hdrOn ? .onProfile : .offProfile, uuid: uuid) }
    static func dimming(hdrOn: Bool, uuid: String) -> SettingRule { get(hdrOn ? .onDimming : .offDimming, uuid: uuid) }
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
    private var loading = false   // showing the saved values, without writing them back
    @Published private(set) var monitors: [Monitor] = []   // connected first, then the others set up on this Mac
    @Published private(set) var selected = ""               // the UUID of the monitor shown
    @Published private(set) var profiles: [String] = []
    @Published private(set) var levels: [String] = []   // the selected monitor's levels, by value
    @Published private(set) var hasDetected = false      // local_monitor_db.json exists

    var selectedTitle: String { monitors.first { $0.uuid == selected }?.title ?? "No monitor" }

    // Shows the saved settings, for the same monitor as before if it's still listed.
    func reload() {
        monitors = Self.listMonitors()
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
        loading = false
        reloadLevels()
    }

    // After a detection is saved or deleted: the selected monitor's levels may have changed.
    func reloadLevels() {
        levels = Self.levels(uuid: selected)
        hasDetected = Self.hasDetectedMonitors()
    }

    private func save(_ rule: Preferences.Rule, _ value: SettingRule) {
        if !loading && !selected.isEmpty { Preferences.set(rule, uuid: selected, value) }
    }

    // The connected external displays, then the monitors in my_monitor.json that aren't connected.
    private static func listMonitors() -> [Monitor] {
        var named: [(uuid: String, name: String)] = HCAllDisplays().compactMap { d in
            guard !((d["builtin"] as? Bool) ?? false), let uuid = d["uuid"] as? String, !uuid.isEmpty else { return nil }
            return (uuid, d["name"] as? String ?? "Display")
        }
        for (uuid, identity) in HCMyMonitors().sorted(by: { $0.key < $1.key }) where !named.contains(where: { $0.uuid == uuid }) {
            named.append((uuid, identity["product_name"] as? String ?? "Monitor"))
        }
        if let name = FakeMonitor.name { named.append((FakeMonitor.uuid, name)) }
        return named.map { m in
            let shared = named.filter { $0.name == m.name }.count > 1
            return Monitor(uuid: m.uuid, title: shared ? "\(m.name) (\(m.uuid.prefix(8)))" : m.name)
        }
    }

    // The file exists, even if it's damaged or empty: the viewer says so.
    private static func hasDetectedMonitors() -> Bool {
        guard let path = HCLocalDBPath() else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // The local dimming levels in monitor_db.json for the monitor my_monitor.json has on this display.
    // No DDC, so it's instant; empty if that monitor isn't set up yet or isn't supported.
    private static func levels(uuid: String) -> [String] {
        var why: NSString?, err: NSString?, levels: NSDictionary?
        guard !uuid.isEmpty, let hash = HCReadMyMonitor(uuid, nil, &why) as String?,
              let entry = HCLoadDB(&err)?[hash] as? [AnyHashable: Any],
              HCLocalDimming(entry, &levels, &err) >= 0,
              let named = levels as? [String: NSNumber] else { return [] }
        return named.sorted { $0.value.intValue < $1.value.intValue }.map { $0.key }
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
            Group {
                Section(title: "When HDR is turned on", profile: $model.onProfile, dimming: $model.onDimming, model: model)
                Section(title: "When HDR is turned off", profile: $model.offProfile, dimming: $model.offDimming, model: model)
            }
            .disabled(model.selected.isEmpty)
            if model.selected.isEmpty {
                Text("Connect a monitor to choose its settings.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if model.levels.isEmpty {
                Text("Local dimming isn't available: this monitor isn't supported, or hasn't been set up yet. Open the HDR Switch menu with it connected, or use Detect Monitor below.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Monitor detection")
                    .font(.system(size: 13, weight: .bold))
                Panel {
                    HStack(alignment: .center) {
                        Text("Find your monitor's local dimming setting and its levels, and save them to local_monitor_db.json.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Detect Monitor…", action: detect)
                            .disabled(model.selected.isEmpty)
                    }
                    // Only when there's a local_monitor_db.json. The window refits when this appears or goes.
                    if model.hasDetected {
                        Divider().padding(.vertical, 6)
                        HStack {
                            Spacer()
                            Button("View Detected Monitor…", action: viewDetected)
                            Button("Delete Detected Monitor…", action: clearDetected)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private struct Section: View {
        let title: String
        @Binding var profile: SettingRule
        @Binding var dimming: SettingRule
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
                }
            }
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
