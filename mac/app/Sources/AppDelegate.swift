// The menu bar item, the popup panel under it, and the settings window.

import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PopupPanel!
    private var settingsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var modelChanges: AnyCancellable?
    private let monitor = MonitorModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // monitor_db.json ships in the app; my_monitor.json is per user, in Application Support.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HDR Switch", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        HCSetDataDirectory(support.path)
        HCSetDBPath(Bundle.main.path(forResource: "monitor_db", ofType: "json"))
        HCSetLogger { _, message in NSLog("HDR Switch: %@", message ?? "") }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let icon = NSImage(named: "menu_icon")
            icon?.isTemplate = true   // tinted by macOS for light and dark menu bars
            button.image = icon
            button.toolTip = "HDR Switch"
            button.target = self
            button.action = #selector(togglePopup(_:))
        }
        panel = PopupPanel(content: PopupView(model: monitor, openSettings: { [weak self] in self?.openSettings() }))
        // The popup's height changes with its contents (e.g. a warning), so refit it after each change.
        modelChanges = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.panel.refit() }
        }
        // Clicking another app's window activates that app; close the popup then.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.closePopup() }
    }

    @objc private func togglePopup(_ sender: Any?) {
        panel.isVisible ? closePopup() : showPopup()
    }

    private func showPopup() {
        guard let button = statusItem.button, let window = button.window else { return }
        monitor.refresh()
        NSApp.activate(ignoringOtherApps: true)   // so hover tooltips and Esc work
        panel.show(below: window.convertToScreen(button.convert(button.bounds, to: nil)))
        // Clicks in other apps don't reach us, so watch for them to close the popup.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopup()
        }
    }

    private func closePopup() {
        panel.orderOut(nil)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    private func openSettings() {
        closePopup()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "HDR Switch Settings"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)   // a menu bar app isn't active by default
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// A borderless panel under the menu bar item, styled like Control Center's popups.
final class PopupPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient]
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }   // so hover highlights, tooltips and Esc work

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }   // Esc

    // Left edge under the menu bar item, kept on screen, 6 pt below the menu bar.
    func show(below item: NSRect) {
        guard let content = contentView else { return }
        let size = content.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: item.midX, y: item.midY)) } ?? NSScreen.main
        var x = item.minX
        if let visible = screen?.visibleFrame { x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6) }
        setFrame(NSRect(x: x, y: item.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        makeKeyAndOrderFront(nil)
        invalidateShadow()   // the shadow follows the rounded content
    }

    // New height for the current contents, keeping the top edge under the menu bar.
    func refit() {
        guard isVisible, let content = contentView else { return }
        let size = content.fittingSize
        guard size.height != frame.height else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        invalidateShadow()
    }
}
