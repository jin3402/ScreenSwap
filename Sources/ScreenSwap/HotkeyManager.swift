import AppKit
import Carbon.HIToolbox

/// Global hotkeys via the Carbon Hot Key API.
///
/// Carbon is still the only supported way to grab a system-wide hotkey without
/// running an event tap (which needs Accessibility permission *and* sees every
/// keystroke). We install exactly one application-level event handler and fan out
/// to per-hotkey closures by id.
final class HotkeyManager {

    static let shared = HotkeyManager()

    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let control = Modifiers(rawValue: UInt32(controlKey))
        static let option  = Modifiers(rawValue: UInt32(optionKey))
        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let shift   = Modifiers(rawValue: UInt32(shiftKey))
    }

    /// Four-char code identifying our hotkeys: 'SSWP'.
    private static let signature: OSType = 0x53535750

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    // MARK: - Registration

    /// Registers a global hotkey. Returns an id usable with `unregister(id:)`, or
    /// nil if the combination is already claimed by another app or the system.
    @discardableResult
    func register(keyCode: Int, modifiers: Modifiers, handler: @escaping () -> Void) -> UInt32? {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode),
                                         modifiers.rawValue,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)

        guard status == noErr, let ref else {
            NSLog("[ScreenSwap] Failed to register hotkey (keyCode: \(keyCode), status: \(status))")
            return nil
        }

        hotKeyRefs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(id: UInt32) {
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeValue(forKey: id)
        handlers.removeValue(forKey: id)
    }

    func unregisterAll() {
        for id in Array(hotKeyRefs.keys) { unregister(id: id) }
    }

    // MARK: - Dispatch

    fileprivate func handle(id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         screenSwapHotKeyHandler,
                                         1,
                                         &eventType,
                                         nil,
                                         &eventHandlerRef)
        if status != noErr {
            NSLog("[ScreenSwap] InstallEventHandler failed with status \(status)")
        }
    }
}

/// Carbon calls back into a plain C function pointer, so this must be a global,
/// non-capturing function matching `EventHandlerUPP` exactly:
/// `(EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus`.
private func screenSwapHotKeyHandler(_ callRef: EventHandlerCallRef?,
                                     _ event: EventRef?,
                                     _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return status }

    let id = hotKeyID.id
    // Hop to the main queue: handlers touch AppKit.
    DispatchQueue.main.async {
        HotkeyManager.shared.handle(id: id)
    }
    return noErr
}
