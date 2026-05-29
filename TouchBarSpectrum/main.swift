import AppKit

// Programmatic launch — no storyboard / nib. The app is a background agent
// (LSUIElement); `.accessory` keeps it out of the Dock while still allowing the
// status-bar menu and a Touch Bar control-strip item.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
