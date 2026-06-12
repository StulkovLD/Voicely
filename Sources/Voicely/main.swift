import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Hide from Dock
app.setActivationPolicy(.accessory)
app.run()
