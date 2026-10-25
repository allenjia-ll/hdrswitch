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

// The window's edits, saved only on Confirm. A class rather than @State (see HoverState).
final class SettingsModel: ObservableObject {
    @Published var onProfile = Preferences.onProfile
    @Published var offProfile = Preferences.offProfile
    @Published var onDimming = Preferences.onDimming
    @Published var offDimming = Preferences.offDimming
    @Published private(set) var profiles: [String] = []
    @Published private(set) var levels: [String] = []   // the set-up monitor's levels, by value

    // Shows the saved settings, dropping any unconfirmed edits.
    func reload() {
        onProfile = Preferences.onProfile
        offProfile = Preferences.offProfile
        onDimming = Preferences.onDimming
        offDimming = Preferences.offDimming
        profiles = HCListProfiles().compactMap { $0["name"] as? String }
        levels = Self.setUpMonitorLevels()
    }

    func confirm() {
        Preferences.onProfile = onProfile
        Preferences.offProfile = offProfile
        Preferences.onDimming = onDimming
        Preferences.offDimming = offDimming
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

// The settings window, styled like the popup: the same translucent background, running under a
// transparent title bar so the window is one surface. The SwiftUI content sits below the title bar,
// sized to fit it, so build a new window when the content may have changed (e.g. the "isn't
// available" note). Frames rather than Auto Layout: with a full-size content view, constraints and
// the hosting view's own sizing kept adding the title bar again.
func makeSettingsWindow(model: SettingsModel, close: @escaping () -> Void) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                     styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    w.title = "HDR Switch Settings"
    w.titlebarAppearsTransparent = true
    w.isMovableByWindowBackground = true
    w.isReleasedWhenClosed = false

    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    w.contentView = background
    let titleBar = w.frame.height - w.contentLayoutRect.height

    let host = NSHostingView(rootView: SettingsView(model: model, close: close))
    let size = host.fittingSize
    if #available(macOS 13.0, *) { host.sizingOptions = [] }   // the window is sized here, not by the host
    w.setFrame(NSRect(x: 0, y: 0, width: size.width, height: size.height + titleBar), display: false)
    host.frame = NSRect(origin: .zero, size: size)   // the bottom of the window, below the title bar
    host.autoresizingMask = [.width, .height]
    background.addSubview(host)
    w.center()
    return w
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Section(title: "When HDR is turned on", profile: $model.onProfile, dimming: $model.onDimming, model: model)
            Section(title: "When HDR is turned off", profile: $model.offProfile, dimming: $model.offDimming, model: model)
            if model.levels.isEmpty {
                Text("Local dimming isn't available: no supported monitor is set up yet. Open the HDR Switch menu with your monitor connected first.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Confirm") { model.confirm(); close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
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
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))   // like the monitor's name in the popup
                RuleRow(label: "Set color profile to", rule: $profile, options: model.profiles, title: { $0 })
                RuleRow(label: "Set local dimming to", rule: $dimming, options: model.levels, title: { $0.capitalized })
                    .disabled(model.levels.isEmpty)
            }
        }
    }
}

// "[✓] Set … to [value ▾]"; the dropdown is greyed out while unchecked.
struct RuleRow: View {
    let label: String
    @Binding var rule: SettingRule
    let options: [String]
    let title: (String) -> String

    var body: some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: $rule.enabled)
                .toggleStyle(.checkbox)
                .frame(width: 160, alignment: .leading)   // dropdowns line up across rows
            Picker("", selection: $rule.value) {
                // The saved value is listed even if it's no longer available, so it stays visible.
                ForEach(options.contains(rule.value) ? options : [rule.value] + options, id: \.self) {
                    Text(title($0)).tag($0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!rule.enabled)
        }
    }
}
