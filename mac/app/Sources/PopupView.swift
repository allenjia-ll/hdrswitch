// The popup's contents, laid out like Control Center's Displays popup: the monitor's name with a
// refresh button, a round HDR toggle tile, color profile and local dimming dropdowns, a divider, and
// Settings and Quit rows.

import AppKit
import SwiftUI

struct PopupView: View {
    @ObservedObject var model: MonitorModel
    let openSettings: () -> Void
    private let settingsRowHover = HoverState()
    private let quitRowHover = HoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(model.name)
                    .font(.system(size: 13, weight: .bold))
                if model.support == .unsupported {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .help("This monitor isn't supported. HDR Switch will only switch HDR and the color "
                              + "profile, and won't touch the monitor's local dimming setting.")
                }
                Spacer()
                if model.busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 18, height: 18)
                } else {
                    Button(action: model.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Refresh")
                }
            }
            .frame(height: 18)
            .padding(.bottom, 12)
            HStack {
                HDRTile(model: model)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                SettingRow(label: "Color profile") {
                    Dropdown(options: model.profiles, selection: model.profile.isEmpty ? "—" : model.profile,
                             select: model.selectProfile)
                        .disabled(!model.canChange)
                }
                SettingRow(label: "Local dimming") {
                    if model.support == .supported && !model.dimmingLevels.isEmpty {
                        Dropdown(options: model.dimmingLevels, selection: model.dimming, select: model.selectDimming)
                            .disabled(!model.canChange)
                    } else {
                        Text(model.dimming)   // unknown, or the monitor isn't supported
                            .padding(.leading, 10)   // lines up with the dropdown's text
                    }
                }
            }
            .padding(.top, 12)
            if let warning = model.warning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .padding(.top, 10)
            }
            Divider()
                .padding(.top, 12)
                .padding(.bottom, 6)
            Group {
                MenuRow(title: "HDR Switch Settings…", hover: settingsRowHover, action: openSettings)
                MenuRow(title: "Quit HDR Switch", hover: quitRowHover) { NSApp.terminate(nil) }
            }
            .padding(.horizontal, -8)   // text lines up with the title; the highlight extends past it
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(width: 300)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

// A round toggle with its label and state underneath, like Dark Mode / True Tone.
struct HDRTile: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        VStack(spacing: 3) {
            Button(action: model.toggleHDR) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(model.hdrOn ? .white : .primary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(model.hdrOn ? Color.accentColor : Color.primary.opacity(0.14)))
                    .opacity(model.canChange ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!model.canChange)
            .padding(.bottom, 3)
            Text("HDR")
                .font(.system(size: 12, weight: .semibold))
            Text(model.stateText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(width: 92)
    }
}

// "Label   [control]" under the HDR tile, with the labels in one column.
struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 86, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
    }
}

// A pop-up menu of `options`. The current value is listed too if it isn't one of them (e.g. a
// profile from outside the ColorSync folders), so the menu always shows what's actually set.
struct Dropdown: View {
    let options: [String]
    let selection: String
    let select: (String) -> Void

    var body: some View {
        Picker("", selection: Binding(get: { selection }, set: select)) {
            ForEach(options.contains(selection) ? options : [selection] + options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }
}

// Hover flag for a row. A class rather than @State: with the Command Line Tools (no Xcode),
// @State is a macro whose plugin isn't installed, so it doesn't compile.
final class HoverState: ObservableObject {
    @Published var hovering = false
}

// A menu-style row that highlights on hover, like "Display Settings…".
struct MenuRow: View {
    let title: String
    @ObservedObject var hover: HoverState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(hover.hovering ? Color.primary.opacity(0.1) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.hovering = $0 }
    }
}

// The translucent popup background.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
