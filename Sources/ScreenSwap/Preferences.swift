import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Everything the user can configure, persisted in UserDefaults.
enum Preferences {

    /// The actions a global hotkey can be bound to.
    enum Action: String, CaseIterable {
        case overlay
        case sendLeft
        case sendRight
        case sendUp
        case sendDown
        case toggleFullScreen

        var title: String {
            switch self {
            case .overlay:   return "Open window overview"
            case .sendLeft:  return "Send window left"
            case .sendRight: return "Send window right"
            case .sendUp:    return "Send window up"
            case .sendDown:  return "Send window down"
            case .toggleFullScreen: return "Toggle full screen"
            }
        }

        var subtitle: String {
            switch self {
            case .overlay:
                return "Fan every window out to aim, select and act"
            case .sendLeft, .sendRight, .sendUp, .sendDown:
                return "Move the frontmost window one display over, without the overview"
            case .toggleFullScreen:
                return "Full screen the frontmost window, or put it back to a window"
            }
        }

        /// Direction this action sends toward, or nil for the overlay.
        var direction: Direction? {
            switch self {
            case .overlay:   return nil
            case .sendLeft:  return .left
            case .sendRight: return .right
            case .sendUp:    return .up
            case .sendDown:  return .down
            case .toggleFullScreen: return nil
            }
        }

        /// Built on ⌃⌥ so nothing collides with Control+Arrow, which is Mission
        /// Control and Spaces switching.
        ///
        /// "Send up" ships unbound on purpose: ⌃⌥↑ is the overlay, and that binding
        /// is the one thing about this app people already have in their fingers. Set
        /// it in Settings if a stacked display arrangement needs it.
        var defaultShortcut: Shortcut? {
            let controlOption = UInt32(controlKey) | UInt32(optionKey)
            switch self {
            case .overlay:   return Shortcut(keyCode: kVK_UpArrow, carbonModifiers: controlOption)
            case .sendLeft:  return Shortcut(keyCode: kVK_LeftArrow, carbonModifiers: controlOption)
            case .sendRight: return Shortcut(keyCode: kVK_RightArrow, carbonModifiers: controlOption)
            case .sendDown:  return Shortcut(keyCode: kVK_DownArrow, carbonModifiers: controlOption)
            case .sendUp:    return nil
            // A full-screen window sits on its own Space, so reaching for the
            // overview to undo it means switching Spaces first. This is the way out
            // from inside the app itself.
            case .toggleFullScreen: return Shortcut(keyCode: kVK_ANSI_F, carbonModifiers: controlOption)
            }
        }

        fileprivate var storageKey: String { "shortcut.\(rawValue)" }
    }

    // MARK: - Shortcuts

    static func shortcut(for action: Action) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: action.storageKey) else {
            return action.defaultShortcut
        }
        // An explicitly stored empty value means "unbound", which is different from
        // never having been set.
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func setShortcut(_ shortcut: Shortcut?, for action: Action) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: action.storageKey)
        } else {
            UserDefaults.standard.set(Data(), forKey: action.storageKey)
        }
        NotificationCenter.default.post(name: .screenSwapShortcutsChanged, object: nil)
    }

    static func resetShortcuts() {
        for action in Action.allCases {
            UserDefaults.standard.removeObject(forKey: action.storageKey)
        }
        NotificationCenter.default.post(name: .screenSwapShortcutsChanged, object: nil)
    }

    /// The action already using this combination, if any.
    static func conflictingAction(for shortcut: Shortcut, excluding action: Action) -> Action? {
        Action.allCases.first { candidate in
            candidate != action && self.shortcut(for: candidate) == shortcut
        }
    }

    // MARK: - Launch at login

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Fails when the bundle is not in a location launchd trusts, which
                // during development usually means "not in /Applications".
                Log.debug("launch at login \(newValue ? "register" : "unregister") failed: \(error.localizedDescription)")
            }
        }
    }
}

extension Notification.Name {
    static let screenSwapShortcutsChanged = Notification.Name("ScreenSwapShortcutsChanged")
}
