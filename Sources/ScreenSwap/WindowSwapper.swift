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

    /// Swaps windows between two specific displays. A group landing on a screen
    /// where they were overlapping each other gets tiled into a split instead of
    /// each window keeping its old (overlapped) relative position — see `place`.
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

        MoveHistory.record(toSecond + toFirst, action: L("swap all windows"))

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
        moved += place(toSecond, on: second)
        moved += place(toFirst, on: first)
        Log.debug("swap: moved \(moved)/\(toSecond.count + toFirst.count)")

        if moved == 0 { NSSound.beep() }
        return moved
    }

    /// Places a group of windows arriving on `screen`.
    ///
    /// If they were overlapping each other on their way in, they land tiled
    /// into an up-to-4-way split instead — a pile of overlapping windows would
    /// otherwise just re-pile itself on the other display, which is exactly the
    /// "keeps the overlapped state" behaviour a full swap should fix. Windows
    /// that were already side by side keep their own proportional position, so
    /// a deliberate custom layout swaps over unchanged.
    private static func place(_ windows: [WindowInfo], on screen: NSScreen) -> Int {
        guard !windows.isEmpty else { return 0 }

        if windows.count >= 2 && QuickSplit.windowsOverlapSignificantly(windows) {
            let splitCount = min(windows.count, 4)
            let count = QuickSplit.placeWindows(windows, splitCount: splitCount, on: screen)
            Log.debug("  \(DisplayManager.name(of: screen)): overlapping, \(splitCount)-way split (\(count) placed)")
            return count
        }

        var moved = 0
        for window in windows {
            if WindowManager.moveWindow(window, to: screen) {
                moved += 1
            } else {
                Log.debug("  move FAILED: \(window.appName) -> \(DisplayManager.name(of: screen))")
            }
        }
        return moved
    }

    /// Sends an explicit set of windows to one display. Used by the overlay's
    /// ⌘+arrow "send selection" action.
    @discardableResult
    static func move(_ windows: [WindowInfo], to screen: NSScreen) -> Int {
        MoveHistory.record(windows, action: L("send to %@", DisplayManager.name(of: screen)))
        var moved = 0
        for window in windows where WindowManager.moveWindow(window, to: screen) { moved += 1 }
        return moved
    }

    /// Puts the frontmost window into full screen, or takes it back out.
    ///
    /// Deliberately a toggle rather than two actions: a full-screen window owns its
    /// whole Space, so the only sensible thing to do to it is undo that, and one key
    /// covering both directions is one less thing to remember.
    @discardableResult
    static func toggleFullScreenOfFocusedWindow() -> Bool {
        guard PermissionsHelper.hasAccessibilityPermission else {
            PermissionsHelper.presentAccessibilityAlert()
            return false
        }

        let windows = WindowManager.listAllWindows()
        guard let frontID = WindowManager.frontmostWindowID(in: windows),
              let window = windows.first(where: { $0.windowID == frontID }),
              window.isMovable else {
            Log.debug("toggle full screen: no usable frontmost window")
            NSSound.beep()
            return false
        }

        let wasFullScreen = WindowManager.isFullScreen(window)
        let changed = WindowManager.setFullScreen(window, !wasFullScreen)
        Log.debug("toggle full screen: \(window.appName) \(wasFullScreen ? "exit" : "enter") \(changed ? "ok" : "FAILED")")
        if !changed {
            // Dialogs and some non-native windows expose no writable full-screen state.
            NSSound.beep()
        }
        return changed
    }

    /// Moves the frontmost window one display over without opening the overlay.
    ///
    /// This is the common case by a wide margin — "put this one over there" — and
    /// going through the overview for it means fanning every window out and back
    /// just to move one. Bound to ⌃⌥arrow by default.
    @discardableResult
    static func moveFocusedWindow(_ direction: Direction) -> Bool {
        guard PermissionsHelper.hasAccessibilityPermission else {
            PermissionsHelper.presentAccessibilityAlert()
            return false
        }

        let windows = WindowManager.listAllWindows()
        guard let frontID = WindowManager.frontmostWindowID(in: windows),
              let window = windows.first(where: { $0.windowID == frontID }),
              window.isMovable else {
            Log.debug("quick move \(direction.label): no movable frontmost window")
            NSSound.beep()
            return false
        }

        guard let home = DisplayManager.screen(containingCGRect: window.frame),
              let target = DisplayManager.screen(from: home, direction: direction) else {
            Log.debug("quick move \(direction.label): no display that way")
            NSSound.beep()
            return false
        }

        MoveHistory.record([window], action: L("send %@ %@", window.appName, direction.localizedLabel))
        let moved = WindowManager.moveWindow(window, to: target)
        Log.debug("quick move \(direction.label): \(window.appName) -> \(DisplayManager.name(of: target)) \(moved ? "ok" : "FAILED")")
        if !moved { NSSound.beep() }
        return moved
    }
}
