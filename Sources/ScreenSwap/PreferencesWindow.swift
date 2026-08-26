import AppKit

/// The settings window: one recorder per action, plus launch at login.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    private var recorders: [Preferences.Action: ShortcutRecorderView] = [:]
    private var conflictLabel: NSTextField?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L("ScreenSwap Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        refresh()
        // An accessory app has to activate explicitly or the window opens behind
        // whatever the user was in.
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 420))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])

        stack.addArrangedSubview(heading(L("Shortcuts")))

        for action in Preferences.Action.allCases {
            stack.addArrangedSubview(row(for: action))
        }

        let conflict = NSTextField(labelWithString: "")
        conflict.font = .systemFont(ofSize: 11)
        conflict.textColor = .systemRed
        stack.addArrangedSubview(conflict)
        conflictLabel = conflict

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading(L("General")))

        let launch = NSButton(checkboxWithTitle: L("Launch ScreenSwap at login"),
                              target: self,
                              action: #selector(toggleLaunchAtLogin(_:)))
        launch.state = Preferences.launchAtLogin ? .on : .off
        launch.identifier = NSUserInterfaceItemIdentifier("launchAtLogin")
        stack.addArrangedSubview(launch)

        let hint = NSTextField(labelWithString: L("Click a shortcut to change it. Press ⌫ while recording to unbind, esc to cancel.\nEvery shortcut needs at least one of ⌃ ⌥ ⌘."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let reset = NSButton(title: L("Restore Defaults"), target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        window.contentView = content
    }

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 432).isActive = true
        return line
    }

    private func row(for action: Preferences.Action) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let title = NSTextField(labelWithString: L(action.title))
        title.font = .systemFont(ofSize: 13)
        let subtitle = NSTextField(labelWithString: L(action.subtitle))
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        labels.addArrangedSubview(title)
        labels.addArrangedSubview(subtitle)

        let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 140, height: 26))
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 140).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 26).isActive = true
        recorder.shortcut = Preferences.shortcut(for: action)
        recorder.onChange = { [weak self] shortcut in
            self?.apply(shortcut, to: action) ?? false
        }
        recorders[action] = recorder

        row.addArrangedSubview(labels)
        row.addArrangedSubview(NSView())   // spacer
        row.addArrangedSubview(recorder)
        row.widthAnchor.constraint(equalToConstant: 432).isActive = true
        return row
    }

    // MARK: - Actions

    /// Returns false to reject the change, which leaves the recorder as it was.
    private func apply(_ shortcut: Shortcut?, to action: Preferences.Action) -> Bool {
        if let shortcut, let clash = Preferences.conflictingAction(for: shortcut, excluding: action) {
            conflictLabel?.stringValue = L("%@ is already used by “%@”.", shortcut.displayString, L(clash.title))
            NSSound.beep()
            return false
        }

        conflictLabel?.stringValue = ""
        Preferences.setShortcut(shortcut, for: action)

        // Registration can still fail if another app holds the combination
        // system-wide, and only trying tells us.
        DispatchQueue.main.async { [weak self] in
            if let failed = AppDelegate.shared?.unavailableShortcutActions(), failed.contains(action) {
                self?.conflictLabel?.stringValue =
                    L("Another app is already using %@.", shortcut?.displayString ?? L("that shortcut"))
            }
        }
        return true
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        Preferences.launchAtLogin = sender.state == .on
        // Re-read: registration can be refused, and the checkbox must not lie.
        sender.state = Preferences.launchAtLogin ? .on : .off
        if sender.state == .off && Preferences.launchAtLogin == false {
            conflictLabel?.stringValue = ""
        }
    }

    @objc private func resetDefaults() {
        Preferences.resetShortcuts()
        conflictLabel?.stringValue = ""
        refresh()
    }

    private func refresh() {
        for (action, recorder) in recorders {
            recorder.shortcut = Preferences.shortcut(for: action)
        }
        if let launch = window?.contentView?.viewWithIdentifier("launchAtLogin") as? NSButton {
            launch.state = Preferences.launchAtLogin ? .on : .off
        }
    }
}

private extension NSView {
    func viewWithIdentifier(_ identifier: String) -> NSView? {
        if self.identifier?.rawValue == identifier { return self }
        for subview in subviews {
            if let found = subview.viewWithIdentifier(identifier) { return found }
        }
        return nil
    }
}
