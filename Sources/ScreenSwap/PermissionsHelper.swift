import AppKit
import ApplicationServices
import CoreGraphics

/// Accessibility is the only permission ScreenSwap needs: it reads and moves other
/// apps' windows through the AX API. Nothing here captures the screen.
enum PermissionsHelper {

    // MARK: - Accessibility

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Returns true when already trusted. When `prompt` is true and we are not
    /// trusted, macOS shows its own "open System Settings" alert.
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt. Used directly because the
        // constant is bridged inconsistently across SDK versions (Unmanaged<CFString>
        // in some, CFString in others).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Settings deep links

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Alerts

    /// Shown at launch when Accessibility is missing. Without it the app cannot do
    /// anything at all, so we point the user at Settings and quit.
    static func presentAccessibilityAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("ScreenSwap needs Accessibility access")
        alert.informativeText = L("ScreenSwap moves windows between your displays, which requires Accessibility permission.\n\nOpen System Settings > Privacy & Security > Accessibility, enable ScreenSwap, then launch it again.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Quit"))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }
}
