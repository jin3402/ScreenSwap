import AppKit

/// A read-only cheat sheet of every shortcut.
///
/// The global section reads live from `Preferences`, so it always shows what is
/// actually bound rather than the defaults.
final class ShortcutGuideWindowController: NSWindowController {

    static let shared = ShortcutGuideWindowController()

    private let stack = NSStackView()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L("ScreenSwap Shortcuts")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        // Deliberately no NSScrollView. The list is a fixed length that fits any
        // display, and an auto-laid-out document view inside a scroll view needs
        // careful setup to get a height at all — it silently rendered blank.
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        rebuild()

        // Size to whatever the content actually needs, so a longer translation or an
        // extra row cannot clip.
        let fitting = stack.fittingSize
        Log.debug("shortcut guide: \(stack.arrangedSubviews.count) rows, fitting \(fitting)")
        if fitting.height > 0 {
            window?.setContentSize(NSSize(width: max(fitting.width, 460), height: fitting.height))
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        stack.addArrangedSubview(heading(L("Global")))
        for action in Preferences.Action.allCases {
            let shortcut = Preferences.shortcut(for: action)
            stack.addArrangedSubview(row(keys: shortcut?.displayString ?? L("Not set"),
                                         description: L(action.title),
                                         muted: shortcut == nil))
        }

        stack.addArrangedSubview(spacer(12))
        stack.addArrangedSubview(heading(L("Inside the overview")))

        let entries: [(String, String)] = [
            (L("Arrows"),       L("Aim the focus cursor (never moves a window)")),
            ("⇧",               L("Select or deselect the focused window")),
            ("⌘ + ←→↑↓",        L("Send the selection to that display")),
            ("⌘2 / ⌘3 / ⌘4",    L("Split into 2, 3, or 4 tiles")),
            ("↵",               L("Full screen")),
            ("⌫",               L("Exit full screen")),
            ("⌘Q",              L("Quit the selected window's app")),
            ("space",           L("Swap all windows between displays")),
            ("1–9",             L("Jump straight to a window")),
            (L("Type letters"), L("Search by app name or title")),
            ("⌘Z",              L("Undo the last move")),
            ("esc",             L("Clear the search, or close"))
        ]
        for (keys, description) in entries {
            stack.addArrangedSubview(row(keys: keys, description: description, muted: false))
        }

        stack.addArrangedSubview(spacer(12))
        stack.addArrangedSubview(note(L("Every action applies to the selection, or to the focused window when nothing is selected.")))
    }

    // MARK: - Pieces

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 416).isActive = true
        return label
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func row(keys: String, description: String, muted: Bool) -> NSView {
        let keyLabel = NSTextField(labelWithString: keys)
        keyLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        keyLabel.textColor = muted ? .tertiaryLabelColor : .labelColor
        keyLabel.alignment = .right
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(labelWithString: description)
        text.font = .systemFont(ofSize: 13)
        text.textColor = muted ? .tertiaryLabelColor : .secondaryLabelColor
        text.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(keyLabel)
        row.addSubview(text)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 416),

            keyLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            keyLabel.widthAnchor.constraint(equalToConstant: 104),
            keyLabel.topAnchor.constraint(equalTo: row.topAnchor),
            keyLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor),

            text.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 14),
            text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            text.firstBaselineAnchor.constraint(equalTo: keyLabel.firstBaselineAnchor)
        ])
        return row
    }
}
