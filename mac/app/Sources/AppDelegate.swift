// The menu bar item, the popup panel under it, and the settings window.

import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PopupPanel!
    private var settingsWindow: TranslucentWindow?
    private var detectionWindow: NSWindow?
    private var detectedWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var modelChanges: AnyCancellable?
    private var settingsChanges: AnyCancellable?
    private let displays = DisplayList()
    private lazy var settings = SettingsModel(displays: displays)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // monitor_db.json ships in the app. local_monitor_db.json is in the core's data folder,
        // ~/Library/Application Support/HDR Switch, shared with hdrctl.
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
        panel = PopupPanel(content: PopupView(displays: displays, openSettings: { [weak self] in self?.openSettings() }))
        // The popup's height changes with its contents (e.g. a warning, or another monitor), so refit it
        // after each change.
        modelChanges = displays.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.panel.refit()
                self?.settings.reloadLevels()   // Settings shows the levels read from the monitor
            }
        }
        // The same for the settings window, e.g. when another monitor's settings show a note.
        settingsChanges = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsWindow?.refit() }
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
        displays.refresh()
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
        settings.reload()   // the saved settings (changes in the window are saved as they're made)
        // A new window each time (unless it's open), sized to the current content.
        if settingsWindow?.isVisible != true {
            settingsWindow = makeSettingsWindow(model: settings,
                                                detect: { [weak self] in self?.openDetection() },
                                                viewDetected: { [weak self] in self?.openDetected() },
                                                clearDetected: { [weak self] in self?.clearDetected() })
        }
        NSApp.activate(ignoringOtherApps: true)   // a menu bar app isn't active by default
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // Detect Monitor, from Settings, for the monitor Settings shows. A new run each time, unless one is open.
    private func openDetection() {
        if detectionWindow?.isVisible != true {
            guard !settings.selected.isEmpty else { return }
            let model = DetectionModel(uuid: settings.selected, name: settings.selectedTitle,
                                       onSaved: { [weak self] in self?.detectedMonitorsChanged() })
            detectionWindow = makeTranslucentWindow(title: "Detect Monitor",
                                                    content: DetectionView(model: model, close: { [weak self] in
                                                        self?.detectionWindow?.close()
                                                    }))
            model.start()
        }
        NSApp.activate(ignoringOtherApps: true)
        detectionWindow?.makeKeyAndOrderFront(nil)
    }

    // Delete Detected Monitor, from Settings: moves local_monitor_db.json to the Trash after asking, so
    // the shipped monitor_db.json applies again.
    private func clearDetected() {
        guard let path = HCLocalDBPath(), FileManager.default.fileExists(atPath: path) else {
            detectedMonitorsChanged()
            return
        }
        var err: NSString?
        let count = HCLoadLocalDB(&err)?.count ?? 0
        let alert = NSAlert()
        alert.messageText = "Delete detected monitors?"
        alert.informativeText = (count == 1 ? "The detected monitor in local_monitor_db.json" :
                                    count > 1 ? "The \(count) detected monitors in local_monitor_db.json" : "local_monitor_db.json")
            + " will be moved to the Trash. HDR Switch then uses the shipped monitor_db.json for "
            + (count == 1 ? "that monitor." : "these monitors.")
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't move local_monitor_db.json to the Trash"
            failed.informativeText = error.localizedDescription
            failed.runModal()
        }
        detectedWindow?.close()   // it would show a file that's gone
        detectedMonitorsChanged()
    }

    // local_monitor_db.json was saved or cleared: read the monitors again, since their levels may
    // have changed, which updates Settings (its window refits to them).
    private func detectedMonitorsChanged() {
        displays.refresh()
        settings.reloadLevels()
    }

    // View Detected Monitor, from Settings: what's in local_monitor_db.json. Reread each time it opens.
    private func openDetected() {
        if detectedWindow?.isVisible != true {
            detectedWindow = makeTranslucentWindow(title: "Detected Monitor",
                                                   content: DetectedMonitorView(model: DetectedMonitorModel(), close: { [weak self] in
                                                       self?.detectedWindow?.close()
                                                   }))
        }
        NSApp.activate(ignoringOtherApps: true)
        detectedWindow?.makeKeyAndOrderFront(nil)
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
