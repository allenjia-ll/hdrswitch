// HDR Switch Settings: which color profile and local dimming level, if any, the HDR toggle sets after
// turning HDR on or off.

import SwiftUI

// One "[✓] Set … to [value]" setting. Unchecked: leave it as it is.
struct SettingRule: Equatable {
    var enabled: Bool
    var value: String
}

// Saved per user in the app's preferences. The defaults are what hdrctl on/off do. Local dimming
// levels are stored by their monitor_db.json name ("off", "standard").
enum Preferences {
    static var onProfile: SettingRule {
        get { load("hdrOn", "Profile", default: SettingRule(enabled: true, value: "Rec. ITU-R BT.2020-1")) }
        set { save(newValue, "hdrOn", "Profile") }
    }
    static var offProfile: SettingRule {
        get { load("hdrOff", "Profile", default: SettingRule(enabled: true, value: "Display P3")) }
        set { save(newValue, "hdrOff", "Profile") }
    }
    static var onDimming: SettingRule {
        get { load("hdrOn", "Dimming", default: SettingRule(enabled: true, value: "standard")) }
        set { save(newValue, "hdrOn", "Dimming") }
    }
    static var offDimming: SettingRule {
        get { load("hdrOff", "Dimming", default: SettingRule(enabled: true, value: "off")) }
        set { save(newValue, "hdrOff", "Dimming") }
    }

    static func profile(hdrOn: Bool) -> SettingRule { hdrOn ? onProfile : offProfile }
    static func dimming(hdrOn: Bool) -> SettingRule { hdrOn ? onDimming : offDimming }

    // Keys: hdrOnSetProfile / hdrOnProfile, hdrOnSetDimming / hdrOnDimming, and the same for hdrOff.
    private static func load(_ state: String, _ what: String, default rule: SettingRule) -> SettingRule {
        let d = UserDefaults.standard
        return SettingRule(enabled: d.object(forKey: state + "Set" + what) as? Bool ?? rule.enabled,
                           value: d.string(forKey: state + what) ?? rule.value)
    }

    private static func save(_ rule: SettingRule, _ state: String, _ what: String) {
        UserDefaults.standard.set(rule.enabled, forKey: state + "Set" + what)
        UserDefaults.standard.set(rule.value, forKey: state + what)
    }
}

// The settings window's state. Each change is saved right away, as in macOS's own Settings windows;
// nothing applies until the next HDR switch. A class rather than @State (see HoverState).
final class SettingsModel: ObservableObject {
    @Published var onProfile = Preferences.onProfile { didSet { if !loading { Preferences.onProfile = onProfile } } }
    @Published var offProfile = Preferences.offProfile { didSet { if !loading { Preferences.offProfile = offProfile } } }
    @Published var onDimming = Preferences.onDimming { didSet { if !loading { Preferences.onDimming = onDimming } } }
    @Published var offDimming = Preferences.offDimming { didSet { if !loading { Preferences.offDimming = offDimming } } }
    private var loading = false   // reload() shows the saved values without writing them back
    @Published private(set) var profiles: [String] = []
    @Published private(set) var levels: [String] = []   // the set-up monitor's levels, by value
    @Published private(set) var hasDetected = false      // local_monitor_db.json exists
    @Published private(set) var monitorName = MonitorModel.displayName   // the monitor these settings are for

    // Shows the saved settings.
    func reload() {
        loading = true
        onProfile = Preferences.onProfile
        offProfile = Preferences.offProfile
        onDimming = Preferences.onDimming
        offDimming = Preferences.offDimming
        loading = false
        profiles = HCListProfiles().compactMap { $0["name"] as? String }
        levels = Self.setUpMonitorLevels()
        hasDetected = Self.hasDetectedMonitors()
        monitorName = Self.setUpMonitorName()
    }

    // After a detection is saved or deleted: the set-up monitor's levels may have changed.
    func reloadLevels() {
        levels = Self.setUpMonitorLevels()
        hasDetected = Self.hasDetectedMonitors()
        monitorName = Self.setUpMonitorName()
    }

    // The monitor in my_monitor.json, or the display the app looks for if none is set up yet.
    private static func setUpMonitorName() -> String {
        var identity: NSDictionary?, why: NSString?
        guard HCReadMyMonitor(&identity, &why) != nil, let name = identity?["product_name"] as? String, !name.isEmpty
        else { return MonitorModel.displayName }
        return name
    }

    // The file exists, even if it's damaged or empty: the viewer says so.
    private static func hasDetectedMonitors() -> Bool {
        guard let path = HCLocalDBPath() else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // The local dimming levels in monitor_db.json for the monitor in my_monitor.json. No DDC, so
    // it's instant; empty if no supported monitor is set up yet.
    private static func setUpMonitorLevels() -> [String] {
        var why: NSString?, err: NSString?, levels: NSDictionary?
        guard let hash = HCReadMyMonitor(nil, &why) as String?,
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
            Text(model.monitorName)   // the settings below are for this monitor
                .font(.system(size: 13, weight: .bold))
            Section(title: "When HDR is turned on", profile: $model.onProfile, dimming: $model.onDimming, model: model)
            Section(title: "When HDR is turned off", profile: $model.offProfile, dimming: $model.offDimming, model: model)
            if model.levels.isEmpty {
                Text("Local dimming isn't available: no supported monitor is set up yet. Open the HDR Switch menu with your monitor connected first.")
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
