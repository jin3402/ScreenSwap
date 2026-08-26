import AppKit

/// A read-only cheat sheet of every shortcut.
///
/// The global section reads live from `Preferences`, so it always shows what is
/// actually bound rather than the defaults.
final class ShortcutGuideWindowController: NSWindowController {

    static let shared = ShortcutGuideWindowController()

    private var stack: NSStackView?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L("ScreenSwap Shortcuts")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        rebuild()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: 460)
        ])

        scroll.documentView = document
        window.contentView = scroll
        self.stack = stack
    }

    private func rebuild() {
        guard let stack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        stack.addArrangedSubview(heading(L("Global")))
        for action in Preferences.Action.allCases {
            let keys = Preferences.shortcut(for: action)?.displayString ?? L("Not set")
            stack.addArrangedSubview(row(keys: keys,
                                         description: L(action.title),
                                         muted: Preferences.shortcut(for: action) == nil))
        }

        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(heading(L("Inside the overview")))

        let entries: [(String, String)] = [
            (L("Arrows"),   L("Aim the focus cursor (never moves a window)")),
            ("⇧",           L("Select or deselect the focused window")),
            ("⌘ + ←→↑↓",    L("Send the selection to that display")),
            ("↵",           L("Full screen")),
            ("⌫",           L("Exit full screen")),
            ("⌘Q",          L("Quit the selected window's app")),
            ("space",       L("Swap all windows between displays")),
            ("1–9",         L("Jump straight to a window")),
            (L("Type letters"), L("Search by app name or title")),
            ("⌘Z",          L("Undo the last move")),
            ("esc",         L("Clear the search, or close"))
        ]
        for (keys, description) in entries {
            stack.addArrangedSubview(row(keys: keys, description: description, muted: false))
        }

        stack.addArrangedSubview(spacer(10))
        let note = NSTextField(wrappingLabelWithString:
            L("Every action applies to the selection, or to the focused window when nothing is selected."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(note)
    }

    // MARK: - Pieces

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func row(keys: String, description: String, muted: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 14

        let keyLabel = NSTextField(labelWithString: keys)
        // Monospaced digits keep the key column from jittering between rows.
        keyLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        keyLabel.textColor = muted ? .tertiaryLabelColor : .labelColor
        keyLabel.alignment = .right
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSTextField(labelWithString: description)
        text.font = .systemFont(ofSize: 13)
        text.textColor = muted ? .tertiaryLabelColor : .secondaryLabelColor

        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(text)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 416).isActive = true
        return row
    }
}
