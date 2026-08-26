import AppKit
import Carbon.HIToolbox

/// A click-to-record shortcut field.
///
/// While recording it swallows every key press through a local monitor, because a
/// combination like ⌘Q would otherwise be eaten by the menu bar before the view
/// ever sees it.
final class ShortcutRecorderView: NSView {

    var shortcut: Shortcut? {
        didSet { needsDisplay = true }
    }

    /// Called with the new value, or nil when cleared. Return false to reject it.
    var onChange: ((Shortcut?) -> Bool)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = "Type a shortcut…"
            color = .controlAccentColor
        } else if let shortcut {
            text = shortcut.displayString
            color = .labelColor
        } else {
            text = "Click to set"
            color = .secondaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isRecording ? .regular : .medium),
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                  withAttributes: attributes)
    }

    // MARK: - Recording

    override func mouseDown(with event: NSEvent) {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .keyDown {
                self.capture(event)
            }
            return nil   // consume, so nothing else acts on the combination
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)

        // Escape abandons; Delete clears the binding.
        if keyCode == kVK_Escape {
            stopRecording()
            return
        }
        if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            stopRecording()
            if onChange?(nil) == true { shortcut = nil }
            return
        }

        let candidate = Shortcut(keyCode: keyCode,
                                 flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        guard candidate.isValid else {
            // A bare key would hijack that key everywhere on the system.
            NSSound.beep()
            return
        }

        stopRecording()
        if onChange?(candidate) == true {
            shortcut = candidate
        }
    }
}
