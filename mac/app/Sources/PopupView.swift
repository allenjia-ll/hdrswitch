// The popup's contents, laid out like Control Center's Displays popup: the monitor's name, a round
// HDR toggle tile, the current color profile and local dimming, a divider, and a settings row.

import AppKit
import SwiftUI

struct PopupView: View {
    @ObservedObject var model: MonitorModel
    let openSettings: () -> Void
    private let settingsRowHover = HoverState()

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
            }
            .padding(.bottom, 12)
            HStack {
                HDRTile(model: model)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                InfoLine(label: "Color profile", value: model.profile.isEmpty ? "—" : model.profile)
                InfoLine(label: "Local dimming", value: model.dimming)
            }
            .padding(.top, 10)
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
            MenuRow(title: "HDR Switch Settings…", hover: settingsRowHover, action: openSettings)
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
                    .opacity(model.canToggle ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!model.canToggle)
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

// "Label: value" under the HDR tile.
struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label + ":").foregroundColor(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11))
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

// Empty for now.
struct SettingsView: View {
    var body: some View {
        Color.clear.frame(width: 480, height: 320)
    }
}
