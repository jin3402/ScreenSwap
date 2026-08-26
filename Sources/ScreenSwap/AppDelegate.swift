import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var overlayHotkeyID: UInt32?
    private var permissionPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        setUpHotkeys()

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
        let subject = count == 1 ? "1 window was" : "\(count) windows were"
        let pronoun = count == 1 ? "it was" : "they were"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore your window layout?"
        alert.informativeText = """
        ScreenSwap quit while \(subject) spread out for the window overview, so \(pronoun) never put back.

        Restore them to where they were? If you have rearranged things since, choose Leave As Is.
        """
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Leave As Is")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let restored = WindowArranger.restoreFromDisk(snapshots)
            NSLog("[ScreenSwap] Restored \(restored)/\(count) windows after unclean exit")
        } else {
            WindowArranger.clearPendingRestore()
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
            ? "ScreenSwap — press ⌃⌥↑ for the window overview"
            : "ScreenSwap — needs Accessibility permission"
    }

    // MARK: - Hotkeys

    private func setUpHotkeys() {
        // ⌃⌥↑ — the app's single entry point.
        //
        // Deliberately *not* Control+Up: that is system Mission Control, and adding
        // Option keeps us clear of it.
        overlayHotkeyID = HotkeyManager.shared.register(
            keyCode: kVK_UpArrow,
            modifiers: [.control, .option]
        ) {
            ExposeOverlayController.shared.toggle()
        }

        if overlayHotkeyID == nil {
            presentHotkeyFailureAlert()
        }

        // Note: ⌃⌥⌘S ("swap all windows") is intentionally NOT registered as a
        // global hotkey any more. That action now lives on Enter inside the overlay.
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                     accessibilityDescription: "ScreenSwap")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()

        let overlayItem = NSMenuItem(title: "Window Overview",
                                     action: #selector(showOverlay),
                                     keyEquivalent: "")
        overlayItem.target = self
        // Display-only: the real binding is the global hotkey registered above.
        overlayItem.keyEquivalent = "\u{F700}"   // Up arrow glyph
        overlayItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(overlayItem)

        let swapItem = NSMenuItem(title: "Swap All Windows Between Displays",
                                  action: #selector(swapAllWindows),
                                  keyEquivalent: "")
        swapItem.target = self
        menu.addItem(swapItem)

        menu.addItem(.separator())

        let permissionsItem = NSMenuItem(title: "Permissions…",
                                         action: #selector(showPermissions),
                                         keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        // No "q" key equivalent: inside the overlay ⌘Q quits the *selected* app, and
        // a menu key equivalent would race the overlay for that chord.
        let quitItem = NSMenuItem(title: "Quit ScreenSwap",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "")
        menu.addItem(quitItem)

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

    @objc private func showPermissions() {
        let granted = PermissionsHelper.hasAccessibilityPermission

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "ScreenSwap Permissions"
        alert.informativeText = """
        Accessibility: \(granted ? "Granted" : "Not granted")

        ScreenSwap needs this to move windows between your displays. It is the only permission the app uses.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Close")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsHelper.openAccessibilitySettings()
        }
    }

    private func presentHotkeyFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not register ⌃⌥↑"
        alert.informativeText = """
        Another app or a system shortcut has already claimed Control+Option+Up Arrow.

        Free it up and relaunch ScreenSwap, or use the menu bar icon to open the overlay.
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
