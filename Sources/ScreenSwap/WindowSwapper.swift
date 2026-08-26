import AppKit

/// Bulk window moves across displays.
enum WindowSwapper {

    /// Swaps every window between the two active displays: everything on A goes to
    /// B and everything on B goes to A, each keeping its relative position.
    ///
    /// Returns the number of windows actually moved.
    @discardableResult
    static func swapAllWindowsBetweenTheTwoDisplays() -> Int {
        let screens = DisplayManager.screens
        guard screens.count >= 2 else {
            NSSound.beep()
            return 0
        }

        // With more than two displays, "the two displays" means the primary and the
        // largest secondary — the laptop-plus-monitor case this app is built for.
        let primary = DisplayManager.primaryScreen ?? screens[0]
        let secondary = screens
            .filter { $0 != primary }
            .max { a, b in (a.frame.width * a.frame.height) < (b.frame.width * b.frame.height) }

        guard let secondary else { return 0 }
        return swapAllWindows(between: primary, and: secondary)
    }

    /// Swaps windows between two specific displays.
    @discardableResult
    static func swapAllWindows(between first: NSScreen, and second: NSScreen) -> Int {
        let windows = WindowManager.listAllWindows().filter { $0.isMovable }

        // Snapshot the assignment *before* moving anything, otherwise windows moved
        // to the far display get picked up again and bounce straight back.
        var toSecond: [WindowInfo] = []
        var toFirst: [WindowInfo] = []

        for window in windows {
            guard let home = DisplayManager.screen(containingCGRect: window.frame) else { continue }
            if home == first {
                toSecond.append(window)
            } else if home == second {
                toFirst.append(window)
            }
        }

        let all = WindowManager.listAllWindows()
        Log.debug("swap: \(all.count) windows on screen, \(windows.count) movable")
        for window in all where !window.isMovable {
            Log.debug("  skipped (not movable): \(window.appName)")
        }
        Log.debug("  \(DisplayManager.name(of: first)) -> \(DisplayManager.name(of: second)): "
                  + toSecond.map { $0.appName }.joined(separator: ", "))
        Log.debug("  \(DisplayManager.name(of: second)) -> \(DisplayManager.name(of: first)): "
                  + toFirst.map { $0.appName }.joined(separator: ", "))

        var moved = 0
        for window in toSecond {
            if WindowManager.moveWindow(window, to: second) {
                moved += 1
            } else {
                Log.debug("  move FAILED: \(window.appName) -> \(DisplayManager.name(of: second))")
            }
        }
        for window in toFirst {
            if WindowManager.moveWindow(window, to: first) {
                moved += 1
            } else {
                Log.debug("  move FAILED: \(window.appName) -> \(DisplayManager.name(of: first))")
            }
        }
        Log.debug("swap: moved \(moved)/\(toSecond.count + toFirst.count)")

        if moved == 0 { NSSound.beep() }
        return moved
    }

    /// Sends an explicit set of windows to one display. Used by the overlay's
    /// arrow-key "send selection" action.
    @discardableResult
    static func move(_ windows: [WindowInfo], to screen: NSScreen) -> Int {
        var moved = 0
        for window in windows where WindowManager.moveWindow(window, to: screen) { moved += 1 }
        return moved
    }
}
