import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    static private(set) var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var permissionPollTimer: Timer?
    /// Actions whose shortcut could not be registered, usually because another app
    /// already owns the combination.
    private var failedActions: Set<Preferences.Action> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        setUpHotkeys()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(setUpHotkeys),
                                               name: .screenSwapShortcutsChanged,
                                               object: nil)

        // Accessibility gates every window operation. Registering the hotkey first
        // means the app is usable the instant permission lands.
        // Needs Accessibility to move anything, so this waits until it is granted.
        if PermissionsHelper.hasAccessibilityPermission {
            offerPendingRestore()
        }

        if !PermissionsHelper.hasAccessibilityPermission {
            // This both prompts *and* registers the app in the Accessibility list,
            // so the user has something to toggle when they get to System Settings.
            PermissionsHelper.ensureAccessibilityPermission(prompt: true)
            startPermissionPolling()
        } else {
            updateStatusItemAppearance()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave windows spread out because the app went away.
        ExposeOverlayController.shared.dismiss()
        permissionPollTimer?.invalidate()
        HotkeyManager.shared.unregisterAll()
    }

    // MARK: - Crash recovery

    /// The overlay physically rearranges windows and puts them back on close. If it
    /// was killed in between, a restore file is left behind describing where every
    /// window belonged.
    private func offerPendingRestore() {
        guard let snapshots = WindowArranger.pendingRestore() else { return }

        let count = snapshots.count
        let subject = count == 1 ? L("1 window was") : L("%d windows were", count)
        let pronoun = count == 1 ? L("it was") : L("they were")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Restore your window layout?")
        alert.informativeText = L("ScreenSwap quit while %@ spread out for the window overview, so %@ never put back.\n\nRestore them to where they were? If you have rearranged things since, choose Leave As Is.", subject, pronoun)
        alert.addButton(withTitle: L("Restore"))
        alert.addButton(withTitle: L("Leave As Is"))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let restored = WindowArranger.restoreFromDisk(snapshots)
            NSLog("[ScreenSwap] Restored \(restored)/\(count) windows after unclean exit")
        } else {
            WindowArranger.clearPendingRestore()
        }
    }

    // MARK: - Menu

    /// Refreshed each time the menu opens, so shortcut hints and the undo item stay
    /// truthful after the user edits settings or performs a move.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(showOverlay):
                item.setShortcutHint(base: L("Window Overview"),
                                     shortcut: Preferences.shortcut(for: .overlay))
            case #selector(undoLastMove):
                item.isEnabled = MoveHistory.canUndo
                item.title = MoveHistory.lastAction.map { L("Undo %@", $0) } ?? L("Undo Last Move")
            default:
                break
            }
        }
    }

    // MARK: - Permission polling

    /// Watches for Accessibility being granted so the user does not have to relaunch.
    /// AXIsProcessTrusted() reflects the change live once the checkbox is ticked.
    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard PermissionsHelper.hasAccessibilityPermission else { return }
            timer.invalidate()
            DispatchQueue.main.async {
                self?.permissionPollTimer = nil
                self?.updateStatusItemAppearance()
                self?.offerPendingRestore()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    /// Dims the menu bar icon while the app cannot actually do anything.
    private func updateStatusItemAppearance() {
        let granted = PermissionsHelper.hasAccessibilityPermission
        statusItem?.button?.alphaValue = granted ? 1.0 : 0.4
        statusItem?.button?.toolTip = granted
            ? L("ScreenSwap — press %@ for the window overview",
                Preferences.shortcut(for: .overlay)?.displayString ?? L("the overlay shortcut"))
            : L("ScreenSwap — needs Accessibility permission")
    }

    // MARK: - Hotkeys

    /// (Re-)registers every configured shortcut. Safe to call again after the user
    /// edits one; everything is torn down and rebuilt.
    @objc private func setUpHotkeys() {
        HotkeyManager.shared.unregisterAll()
        failedActions = []

        for action in Preferences.Action.allCases {
            guard let shortcut = Preferences.shortcut(for: action) else { continue }

            let registered = HotkeyManager.shared.register(keyCode: shortcut.keyCode,
                                                           modifiers: shortcut.hotkeyModifiers) {
                AppDelegate.perform(action)
            }
            if registered == nil {
                failedActions.insert(action)
                Log.debug("hotkey unavailable for \(action.rawValue): \(shortcut.displayString)")
            }
        }

        if !failedActions.isEmpty {
            presentHotkeyFailureAlert()
        }
        updateStatusItemAppearance()
    }

    func unavailableShortcutActions() -> Set<Preferences.Action> { failedActions }

    private static func perform(_ action: Preferences.Action) {
        switch action {
        case .overlay:
            ExposeOverlayController.shared.toggle()
        case .toggleFullScreen:
            WindowSwapper.toggleFullScreenOfFocusedWindow()
        case .sendLeft, .sendRight, .sendUp, .sendDown:
            guard let direction = action.direction else { return }
            // Straight to the point: no overlay, no fan-out, just move the window.
            WindowSwapper.moveFocusedWindow(direction)
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                     accessibilityDescription: "ScreenSwap")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()

        let overlayItem = NSMenuItem(title: L("Window Overview"),
                                     action: #selector(showOverlay),
                                     keyEquivalent: "")
        overlayItem.target = self
        menu.addItem(overlayItem)

        let swapItem = NSMenuItem(title: L("Swap All Windows Between Displays"),
                                  action: #selector(swapAllWindows),
                                  keyEquivalent: "")
        swapItem.target = self
        menu.addItem(swapItem)

        let undoItem = NSMenuItem(title: L("Undo Last Move"),
                                  action: #selector(undoLastMove),
                                  keyEquivalent: "")
        undoItem.target = self
        menu.addItem(undoItem)

        menu.addItem(.separator())

        let guideItem = NSMenuItem(title: L("Shortcut Guide…"),
                                   action: #selector(showShortcutGuide),
                                   keyEquivalent: "")
        guideItem.target = self
        menu.addItem(guideItem)

        let settingsItem = NSMenuItem(title: L("Settings…"),
                                      action: #selector(showSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissionsItem = NSMenuItem(title: L("Permissions…"),
                                         action: #selector(showPermissions),
                                         keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        // No "q" key equivalent: inside the overlay ⌘Q quits the *selected* app, and
        // a menu key equivalent would race the overlay for that chord.
        let quitItem = NSMenuItem(title: L("Quit ScreenSwap"),
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "")
        menu.addItem(quitItem)

        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusItemAppearance()
    }

    // MARK: - Menu actions

    @objc private func showOverlay() {
        ExposeOverlayController.shared.show()
    }

    @objc private func swapAllWindows() {
        WindowSwapper.swapAllWindowsBetweenTheTwoDisplays()
    }

    @objc private func undoLastMove() {
        MoveHistory.undo()
    }

    @objc private func showShortcutGuide() {
        ShortcutGuideWindowController.shared.show()
    }

    @objc private func showSettings() {
        PreferencesWindowController.shared.show()
    }

    @objc private func showPermissions() {
        let granted = PermissionsHelper.hasAccessibilityPermission

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("ScreenSwap Permissions")
        alert.informativeText = L("Accessibility: %@", granted ? L("Granted") : L("Not granted"))
            + "\n\n"
            + L("ScreenSwap needs this to move windows between your displays. It is the only permission the app uses.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Close"))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsHelper.openAccessibilitySettings()
        }
    }

    private func presentHotkeyFailureAlert() {
        let names = failedActions
            .map { "\(L($0.title)) (\(Preferences.shortcut(for: $0)?.displayString ?? "?"))" }
            .sorted()
            .joined(separator: "\n")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Some shortcuts are unavailable")
        alert.informativeText = L("Another app or a system shortcut already claims:\n\n%@\n\nPick different combinations in Settings, or free them up and relaunch.", names)
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            PreferencesWindowController.shared.show()
        }
    }
}

private extension NSMenuItem {
    /// Shows a shortcut next to a menu item without letting AppKit claim it: these
    /// are global hotkeys, and a real key equivalent would fire twice.
    ///
    /// The base title must be passed in rather than read from `title`: setting
    /// `attributedTitle` writes through to `title`, so rebuilding from it appended
    /// another copy of the shortcut every time the menu opened.
    func setShortcutHint(base: String, shortcut: Shortcut?) {
        guard let shortcut else {
            attributedTitle = nil
            title = base
            return
        }
        let text = NSMutableAttributedString(string: base + "   ")
        text.append(NSAttributedString(string: shortcut.displayString, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        attributedTitle = text
    }
}
