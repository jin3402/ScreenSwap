import AppKit
import Carbon.HIToolbox

/// A global hotkey: a virtual key code plus Carbon modifier flags.
///
/// Carbon's flags are stored rather than AppKit's because `RegisterEventHotKey`
/// wants them; `modifierFlags` converts for display and for recording.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var carbonModifiers: UInt32

    init(keyCode: Int, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(keyCode: Int, flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        self.carbonModifiers = carbon
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey)  != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(cmdKey)     != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey)   != 0 { flags.insert(.shift) }
        return flags
    }

    var hotkeyModifiers: HotkeyManager.Modifiers {
        HotkeyManager.Modifiers(rawValue: carbonModifiers)
    }

    /// At least one of control/option/command. A bare key, or shift alone, would
    /// swallow ordinary typing system-wide.
    var isValid: Bool {
        let required = UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        return carbonModifiers & required != 0
    }

    // MARK: - Display

    /// Menu-style rendering, e.g. "⌃⌥↑".
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    static func keyName(for keyCode: Int) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let character = characterForKeyCode(keyCode) { return character.uppercased() }
        return "Key \(keyCode)"
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Space: "Space", kVK_Tab: "⇥",
        kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12"
    ]

    /// Resolves a key code through the *current* keyboard layout, so the label
    /// matches what is printed on the user's keys rather than assuming US QWERTY.
    private static func characterForKeyCode(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }

            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)

            let status = UCKeyTranslate(layout,
                                        UInt16(keyCode),
                                        UInt16(kUCKeyActionDisplay),
                                        0,                       // no modifiers: the bare key label
                                        UInt32(LMGetKbdType()),
                                        UInt32(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        characters.count,
                                        &length,
                                        &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
