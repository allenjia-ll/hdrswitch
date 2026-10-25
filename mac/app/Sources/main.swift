// HDR Switch — menu bar app (macOS). Entry point.
//
// Runs as a menu bar item only (LSUIElement in Info.plist): no Dock icon, no main window.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
