import AppKit

// ScreenSwap runs as a menu bar accessory: no Dock icon, no main window.
let arguments = Array(CommandLine.arguments.dropFirst())
let diagnosticFlags: Set<String> = ["--diagnose", "--plan-swap", "--plan-send"]

if !diagnosticFlags.isDisjoint(with: arguments) {
    // Touching NSApplication.shared initialises AppKit far enough for NSScreen,
    // without starting the event loop.
    _ = NSApplication.shared
    Diagnostics.run(arguments: arguments)
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
