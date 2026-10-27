// The popup's contents, laid out like Control Center's Displays popup: the monitor's name with a
// refresh button, an HDR switch and the color profile and local dimming dropdowns, a divider, and
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
            // Two panels, as in System Settings > Displays: HDR, then the color profile and local dimming.
            Panel {
                SettingRow(label: "HDR") { HDRSwitch(model: model) }
            }
            .padding(.bottom, 8)
            Panel {
                SettingRow(label: "Color profile") {
                    Dropdown(options: model.profiles, selection: model.profile.isEmpty ? "—" : model.profile,
                             select: model.selectProfile)
                        .disabled(!model.canChange)
                }
                Divider().padding(.vertical, 6)
                SettingRow(label: "Local dimming") {
                    if model.support == .supported && !model.dimmingLevels.isEmpty {
                        Dropdown(options: model.dimmingLevels, selection: model.dimming, select: model.selectDimming)
                            .disabled(!model.canChange)
                    } else {
                        Text(model.dimming)   // unknown, or the monitor isn't supported
                            .font(.system(size: 13))
                            .padding(.trailing, 26)   // ends where a dropdown's text would (before its arrows: 6 + 18 + 2)
                    }
                }
            }
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
            // As in the design: "⚙ Settings…", a divider, then "Quit HDR Switch". The rows' text lines up
            // with the title, and their hover highlight extends past it.
            MenuRow(title: "Settings…", systemImage: "gearshape", hover: settingsRowHover, action: openSettings)
                .padding(.horizontal, -8)
            Divider()
                .padding(.vertical, 6)
            MenuRow(title: "Quit HDR Switch", hover: quitRowHover) { NSApp.terminate(nil) }
                .padding(.horizontal, -8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(width: 330)   // room for "Rec. ITU-R BT.2020-1" beside the labels, in the panels
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

// The HDR switch, in the same row style as the dropdowns. While a switch is running it shows where
// it's going (the refresh spinner says it's busy); it's disabled when it can't be used.
struct HDRSwitch: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        Toggle("", isOn: Binding(get: { model.switching ? !model.hdrOn : model.hdrOn },
                                 set: { _ in model.toggleHDR() }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)   // 36 x 16 pt, the size System Settings uses
            .disabled(!model.canChange)
    }
}

// A rounded panel a little lighter than the popup, holding rows, like System Settings' groups.
struct Panel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)   // panels are the popup's width
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.5)))
    }
}

// "Label   [control]", with the labels in one column. Labels as in System Settings > Displays
// (13 pt, primary text); the controls keep their small size.
struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 96, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)   // controls on the right, as in System Settings
        }
        .font(.system(size: 11))
    }
}

// A pop-up menu of `options`, drawn like System Settings' menus: the value, then the up/down arrows
// in a small gray circle. Clicking opens a standard menu with the current value checked and placed
// over the control. The current value is listed too if it isn't one of the options (e.g. a profile
// from outside the ColorSync folders), so the menu always shows what's actually set. A custom
// control because SwiftUI's Picker and Menu don't draw this style before macOS 13 (and Menu
// rearranges a custom label).
struct Dropdown: View {
    let options: [String]
    let selection: String
    let select: (String) -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        MenuButton(options: options.contains(selection) ? options : [selection] + options,
                   selection: selection, select: select, enabled: isEnabled)
            .fixedSize()
            .opacity(isEnabled ? 1 : 0.45)
    }

    // The value and the arrows, as drawn on the control: the arrows in a gray circle, or, while the
    // mouse is over it, a rounded box around the whole thing. The same size either way.
    struct Face: View {
        let title: String
        var hovered = false
        var body: some View {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .trailing)   // longer profile names shorten in the middle
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(hovered ? 0 : 0.08)))
            }
            .padding(.leading, 8)
            .padding(.trailing, 2)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(hovered ? 0.08 : 0)))
        }
    }

    private struct MenuButton: NSViewRepresentable {
        let options: [String]
        let selection: String
        let select: (String) -> Void
        let enabled: Bool

        func makeNSView(context: Context) -> ButtonView { ButtonView() }
        func updateNSView(_ view: ButtonView, context: Context) {
            view.configure(options: options, selection: selection, select: select, enabled: enabled)
        }
    }

    final class ButtonView: NSView {
        private let face = NSHostingView(rootView: Face(title: ""))
        private var options: [String] = []
        private var selection = ""
        private var select: (String) -> Void = { _ in }
        private var enabled = true
        private var hovered = false { didSet { if hovered != oldValue { redraw() } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            face.translatesAutoresizingMaskIntoConstraints = false
            addSubview(face)
            NSLayoutConstraint.activate([
                face.leadingAnchor.constraint(equalTo: leadingAnchor), face.trailingAnchor.constraint(equalTo: trailingAnchor),
                face.topAnchor.constraint(equalTo: topAnchor), face.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        func configure(options: [String], selection: String, select: @escaping (String) -> Void, enabled: Bool) {
            self.options = options
            self.select = select
            self.enabled = enabled
            if !enabled { hovered = false }
            if selection != self.selection {
                self.selection = selection
                redraw()
                invalidateIntrinsicContentSize()
            }
        }

        private func redraw() { face.rootView = Face(title: selection, hovered: hovered) }

        // Always active, because SwiftUI's hover (and AppKit's default tracking) only works in the
        // active app, and macOS doesn't always let a menu bar app activate.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                           owner: self))
        }
        override func mouseEntered(with event: NSEvent) { hovered = enabled }
        override func mouseExited(with event: NSEvent) { hovered = false }

        override var intrinsicContentSize: NSSize { face.fittingSize }
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }   // clicks come here

        override func mouseDown(with event: NSEvent) {
            guard enabled else { return }
            let menu = NSMenu()
            for option in options {
                let item = NSMenuItem(title: option, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.state = option == selection ? .on : .off
                menu.addItem(item)
            }
            // Like a native pop-up button: the current item opens over the control's text.
            menu.popUp(positioning: menu.item(withTitle: selection), at: NSPoint(x: -6, y: bounds.height - 1), in: self)
            hovered = false   // the mouse left while the menu was open
        }

        @objc private func choose(_ item: NSMenuItem) { select(item.title) }
    }
}

// Hover flag for a row. A class rather than @State: with the Command Line Tools (no Xcode),
// @State is a macro whose plugin isn't installed, so it doesn't compile.
final class HoverState: ObservableObject {
    @Published var hovering = false
}

// A menu-style row that highlights on hover, like "Display Settings…", with an optional icon in front.
struct MenuRow: View {
    let title: String
    var systemImage: String? = nil
    @ObservedObject var hover: HoverState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
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
