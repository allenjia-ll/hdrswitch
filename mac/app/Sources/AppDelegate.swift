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
    private var uninstallWindow: NSWindow?
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
        panel = PopupPanel(content: PopupView(displays: displays, openSettings: { [weak self] in self?.openSettings() },
                                              openAbout: { [weak self] in self?.openAbout() }))
        // The popup's height changes with its contents (e.g. a warning, or another monitor), so refit it
        // after each change.
        modelChanges = displays.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.panel.refit()
                self?.settings.reloadLevels()   // Settings shows the levels read from the monitor
                self?.tellAboutUnsupportedMonitors()
            }
        }
        // The same for the settings window, e.g. when another monitor's settings show a note.
        settingsChanges = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsWindow?.refit() }
        }
        // Clicking another app's window activates that app; close the popup then.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.closePopup() }
        // After launching finishes, so the menu bar icon the welcome points to is there.
        DispatchQueue.main.async { [weak self] in
            self?.welcomeOnFirstRun()
            self?.displays.refresh()   // finds out now whether a monitor is unsupported, without waiting for a click
        }
    }

    // The app has no window or Dock icon, so the first time it's opened it looks like nothing happened.
    private func welcomeOnFirstRun() {
        let key = "welcomeShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "HDR Switch is running"
        alert.informativeText = "Click its icon in the menu bar to switch HDR and adjust your monitor.\n\n"
            + "HDR Switch is an unofficial tool that changes monitor settings directly. Use it at your own risk."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // The first time a monitor turns out not to be in the database, says so and where to add it.
    private func tellAboutUnsupportedMonitors() {
        let key = "unsupportedMonitorsToldAbout"
        var told = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard let monitor = displays.monitors.first(where: { $0.support == .unsupported && !told.contains($0.uuid) }) else { return }
        told.append(monitor.uuid)
        UserDefaults.standard.set(told, forKey: key)
        let alert = NSAlert()
        alert.messageText = "\(monitor.name) isn't in HDR Switch's database"
        alert.informativeText = "HDR and the color profile work, but local dimming and brightness don't. To add this monitor, "
            + "open Settings and choose Detect Monitor."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)   // above the popup
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSettings(for: monitor.uuid) }
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

    private func openSettings(for uuid: String? = nil) {
        closePopup()
        settings.reload()   // the saved settings (changes in the window are saved as they're made)
        if let uuid = uuid { settings.select(uuid) }
        // A new window each time (unless it's open), sized to the current content.
        if settingsWindow?.isVisible != true {
            settingsWindow = makeSettingsWindow(model: settings,
                                                detect: { [weak self] in self?.openDetection() },
                                                viewDetected: { [weak self] in self?.openDetected() },
                                                clearDetected: { [weak self] in self?.clearDetected() },
                                                uninstall: { [weak self] in self?.uninstall() })
        }
        NSApp.activate(ignoringOtherApps: true)   // a menu bar app isn't active by default
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // macOS's standard About panel: the name, icon, version and copyright come from Info.plist.
    private func openAbout() {
        closePopup()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let text = "Switches HDR on your external monitors in one click, along with the color profile, local dimming "
            + "and brightness you choose in Settings.\n\n"
            + "An unofficial tool, not affiliated with or endorsed by Apple or any monitor's manufacturer. It changes "
            + "monitor settings using private macOS APIs and DDC/CI. Use it at your own risk.\n\n"
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center])
        let link = "https://github.com/allenjia-ll/hdrswitch"
        credits.append(NSAttributedString(string: link, attributes: [.font: NSFont.systemFont(ofSize: 11), .link: link,
                                                                     .paragraphStyle: center]))
        NSApp.activate(ignoringOtherApps: true)   // a menu bar app isn't active by default
        // No build number: it would show in brackets after the version.
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .version: ""])
    }

    // Detect Monitor, from Settings, for the monitor Settings shows. A new run each time, unless one is open.
    private func openDetection() {
        if detectionWindow?.isVisible != true {
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

    // Uninstall HDR Switch…, from Settings: asks in a window of its own, with the data checkbox. It's not
    // an NSAlert because an accessory checkbox there didn't appear on screen in the installed app.
    private func uninstall() {
        if uninstallWindow?.isVisible != true {
            let choice = UninstallChoice()
            uninstallWindow = makeTranslucentWindow(title: "Uninstall HDR Switch",
                                                    content: UninstallView(choice: choice, cancel: { [weak self] in
                                                        self?.uninstallWindow?.close()
                                                    }, uninstall: { [weak self] in
                                                        self?.uninstallWindow?.close()
                                                        self?.runUninstall(deleteData: choice.deleteData)
                                                    }))
        }
        NSApp.activate(ignoringOtherApps: true)
        uninstallWindow?.makeKeyAndOrderFront(nil)
    }

    // Runs uninstall.sh, which needs no password, then quits: the app is gone from disk.
    private func runUninstall(deleteData: Bool) {
        guard let script = Bundle.main.path(forResource: "uninstall", ofType: "sh") else { return }
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script] + (deleteData ? ["--delete-data"] : [])
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
        guard process.terminationStatus != 0 else { NSApp.terminate(nil); return }
        let failed = NSAlert()
        failed.messageText = "Couldn't uninstall HDR Switch"
        failed.informativeText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown error."
        failed.runModal()
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
