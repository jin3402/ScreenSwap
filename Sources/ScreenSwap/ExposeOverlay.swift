import AppKit
import Carbon.HIToolbox

// MARK: - Model

/// One movable window as presented in the overlay.
final class ExposeItem {
    let window: WindowInfo
    let screen: NSScreen

    /// The window's real rect in this panel's local coordinates (AppKit, y-up).
    var localFrame: CGRect = .zero
    /// The same rect in global AppKit coordinates, used for directional navigation
    /// so focus can cross from one display to the next.
    var globalFrame: CGRect = .zero
    /// 1-9 jump key, assigned globally so a number means one window across every
    /// display. nil past the ninth window.
    var jumpNumber: Int?

    init(window: WindowInfo, screen: NSScreen) {
        self.window = window
        self.screen = screen
    }

    /// Whether this window answers to a typed filter. Both the app name and the
    /// window title are searched, so "mail" finds Mail and "invoice" finds the
    /// document window that has it in the title.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return window.appName.localizedCaseInsensitiveContains(query)
            || window.title.localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Controller

/// The app's single entry point: a transparent overlay covering every display,
/// driven entirely from ⌃⌥↑.
///
/// Opening the overlay physically spreads your windows out so none of them
/// overlap (see `WindowArranger`), then draws see-through outlines over them. The
/// windows stay real and live — nothing is a screenshot — and every way of closing
/// the overlay puts them back exactly where they were.
///
/// - arrow           → move the focus cursor; never moves a window
/// - `Shift`         → tapped on its own, selects or deselects the focused window
/// - `Tab`           → raise the focused window to the front and activate it,
///                      exactly as it already is — the way out when you just want
///                      to get to work, not rearrange anything
/// - `Cmd`+arrow     → send the selected windows to the display that way
/// - `Cmd`+2/3/4     → tile the targets into an even 2/3/4-way split
/// - `Enter`         → put the selected windows into full screen
/// - `Backspace`     → take them back out of full screen
/// - `Space`         → swap all windows between the two displays
/// - `Cmd`+`Q`       → quit the apps owning the selected windows
/// - `1`-`9`         → jump the cursor straight to that window
/// - letters         → type to search by app name; the cursor follows the match
/// - `Cmd`+`Z`       → undo the last move
/// - `Esc`           → clear the search, or close when there is none
///
/// Aim first, then pick: arrows only ever move the cursor, and Shift is a discrete
/// tap that marks whatever the cursor is on. Sending is its own chord for the same
/// reason — no bare arrow should ever fling windows onto another display.
final class ExposeOverlayController: NSObject {

    static let shared = ExposeOverlayController()

    private var panels: [ExposeOverlayPanel] = []
    private var items: [ExposeItem] = []
    private var focusedIndex: Int?
    /// Insertion-ordered so the selection grows the way the user built it.
    private var selectedIndices: [Int] = []
    private var keyMonitor: Any?
    /// Typed-so-far app-name filter. Empty means not searching.
    private var searchQuery = ""
    /// Previous Shift state, so a tap can be told from a hold.
    private var shiftWasDown = false
    /// What each window looked like before being spread, so it can be put back.
    private var restorations: [WindowArranger.Restoration] = []
    /// Identifies the last key press we acted on, so an event delivered through
    /// both the local monitor and the panel's responder chain is only handled once.
    private var lastHandledKey: (timestamp: TimeInterval, keyCode: UInt16)?

    private(set) var isVisible = false

    private override init() { super.init() }

    // MARK: - Debug logging

    static var debugLogging: Bool { Log.isEnabled }
    static func debug(_ message: String) { Log.debug(message) }

    // MARK: - Presentation

    func toggle() {
        isVisible ? dismiss() : show()
    }

    func show() {
        Self.debug("show(): screens=\(DisplayManager.screens.count)")
        guard !isVisible else { return }

        guard PermissionsHelper.hasAccessibilityPermission else {
            Self.debug("aborting: no Accessibility permission")
            PermissionsHelper.presentAccessibilityAlert()
            return
        }

        var windows = WindowManager.listAllWindows()
        guard !windows.isEmpty else {
            Self.debug("aborting: no windows")
            NSSound.beep()
            return
        }

        if Self.debugLogging {
            for window in windows {
                Self.debug("win \(window.appName) id=\(window.windowID) pid=\(window.pid) cg=(\(Int(window.frame.minX)),\(Int(window.frame.minY))) \(Int(window.frame.width))x\(Int(window.frame.height)) matched=\(window.isMovable)")
                if !window.isMovable {
                    for line in WindowManager.axReport(for: window.pid) {
                        Self.debug("    ax: \(line)")
                    }
                }
            }
        }

        // Physically fan the windows out before drawing anything, then re-read where
        // they actually landed: apps with a minimum size will not have shrunk as far
        // as asked, and the outlines must match reality rather than intent.
        let spreadStart = Date()
        restorations = WindowArranger.spread(windows)
        if !restorations.isEmpty {
            windows = windows.map { window in
                guard let element = window.element,
                      let live = WindowManager.frame(of: element) else { return window }
                var updated = window
                updated.frame = live
                return updated
            }
            Self.debug(String(format: "spread %d windows in %.0f ms",
                              restorations.count, Date().timeIntervalSince(spreadStart) * 1000))
        }

        items = windows.compactMap { window in
            guard let screen = DisplayManager.screen(containingCGRect: window.frame) else { return nil }
            return ExposeItem(window: window, screen: screen)
        }
        guard !items.isEmpty else {
            Self.debug("aborting: no items")
            NSSound.beep()
            return
        }

        selectedIndices = []
        searchQuery = ""
        lastHandledKey = nil
        // Seed from the live state so opening the overlay with Shift already held
        // does not read as a tap.
        shiftWasDown = NSEvent.modifierFlags.contains(.shift)
        focusedIndex = initialFocusIndex(in: windows)

        buildPanels()
        layoutItems()

        isVisible = true
        installKeyMonitor()
        observeSystemChanges()

        NSApp.activate(ignoringOtherApps: true)
        for panel in panels {
            panel.orderFrontRegardless()
        }

        // Key goes to the display already being worked on — the one holding the
        // focused (frontmost) window — so opening the overlay never drags attention
        // to the other monitor.
        let keyScreen = focusedIndex.flatMap { $0 < items.count ? items[$0].screen : nil }
            ?? DisplayManager.screenUnderMouse()
        if let preferred = panels.first(where: { $0.targetScreen == keyScreen }) ?? panels.first {
            preferred.makeKeyAndOrderFront(nil)
        }

        // Activation is asynchronous, so isActive is still false right here; sample
        // it on the next runloop turn to get a reading that means anything.
        Self.debug("shown: items=\(items.count)")
        if Self.debugLogging {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                Self.debug("post-activate: active=\(NSApp.isActive) key=\(NSApp.keyWindow is ExposeOverlayPanel) visible=\(self?.isVisible ?? false)")
            }
        }
    }

    /// Closes the overlay and puts every window back where it was.
    func dismiss() {
        dismiss(restoringWindows: true)
    }

    /// - Parameter restoringWindows: pass false when the caller will restore itself,
    ///   which the swap and send actions do so they can act on the original layout.
    func dismiss(restoringWindows: Bool) {
        guard isVisible else { return }
        isVisible = false

        if restoringWindows {
            restoreWindows()
        }

        removeKeyMonitor()
        stopObservingSystemChanges()

        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        items = []
        focusedIndex = nil
        selectedIndices = []
    }

    /// Undoes the spread. Safe to call twice; the second call is a no-op.
    private func restoreWindows() {
        guard !restorations.isEmpty else { return }
        let start = Date()
        WindowArranger.restore(restorations)
        Self.debug(String(format: "restored %d windows in %.0f ms",
                          restorations.count, Date().timeIntervalSince(start) * 1000))
        restorations = []
    }

    private func initialFocusIndex(in windows: [WindowInfo]) -> Int? {
        if let frontID = WindowManager.frontmostWindowID(in: windows),
           let index = items.firstIndex(where: { $0.window.windowID == frontID }) {
            return index
        }
        return items.isEmpty ? nil : 0
    }

    // MARK: - Panels & layout

    private func buildPanels() {
        panels = DisplayManager.screens.map { screen in
            let panel = ExposeOverlayPanel(screen: screen)
            panel.gridView.controller = self
            return panel
        }
    }

    /// Places each item at its window's *actual* on-screen rect. There is no grid:
    /// the point of the overlay is that your real windows stay where they are.
    private func layoutItems() {
        for (index, item) in items.enumerated() {
            item.jumpNumber = index < 9 ? index + 1 : nil
        }

        for panel in panels {
            let screenItems = items.filter { $0.screen == panel.targetScreen }
            let origin = panel.targetScreen.frame.origin

            for item in screenItems {
                let global = DisplayManager.nsRect(from: item.window.frame)
                item.globalFrame = global
                item.localFrame = global.offsetBy(dx: -origin.x, dy: -origin.y)
            }

            panel.gridView.items = screenItems
            panel.gridView.needsDisplay = true
        }
    }

    private func redraw() {
        for panel in panels {
            panel.gridView.needsDisplay = true
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// Keys arriving through the panel's responder chain, as a second path
    /// alongside the local monitor. Whichever fires first consumes the event.
    func handleKeyFromPanel(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        return handle(event)
    }

    /// Only these four count as modifiers for our shortcuts.
    ///
    /// Critically **not** `.function` or `.numericPad`: macOS sets `.function` on
    /// every arrow key, so testing "no other modifiers" against the full flag set
    /// rejected every arrow press.
    private static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        // Shift is read from the event being handled, not from a separately tracked
        // global. NSEvent delivers modifier flags atomically with the key press, so
        // this cannot drift out of sync the way a flagsChanged-maintained boolean
        // can (missed key-up while another app is active, overlay opened with Shift
        // already held, and so on).
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)

        // Two delivery paths feed this method (the local monitor and the panel's
        // responder chain). Normally the monitor consumes the event first, but when
        // both fire the same press would be acted on twice — and since Shift now
        // toggles a selection, acting twice would silently undo it. Match on the
        // event's own timestamp, identical for both copies and distinct between real
        // presses. This has to sit ahead of the flagsChanged branch, which is
        // exactly where the double-toggle would happen.
        if let last = lastHandledKey,
           last.timestamp == event.timestamp,
           last.keyCode == event.keyCode {
            return event.type != .flagsChanged   // never consume modifier events
        }
        lastHandledKey = (event.timestamp, event.keyCode)

        if event.type == .flagsChanged {
            handleFlagsChanged(flags)
            return false
        }

        Self.debug("key \(event.keyCode) flags=\(flags.rawValue) selected=\(selectedIndices.count)")

        switch Int(event.keyCode) {
        case kVK_Escape:
            // Back out of the search first; only close once there is nothing to back
            // out of, so a mistyped filter does not cost you the overlay.
            if !searchQuery.isEmpty {
                setSearch("")
            } else {
                dismiss()
            }
            return true

        case kVK_ANSI_Z where flags == [.command]:
            performUndo()
            return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard flags.isEmpty else { return true }
            fullscreenTargets()
            return true

        case kVK_Tab:
            guard flags.isEmpty else { return true }
            activateFocused()
            return true

        case kVK_Space:
            guard flags.isEmpty else { return true }
            performFullSwap()
            return true

        case kVK_ANSI_Q:
            guard flags == [.command] else { return true }
            quitTargets()
            return true

        case kVK_ANSI_2 where flags == [.command]:
            quickSplit(2)
            return true

        case kVK_ANSI_3 where flags == [.command]:
            quickSplit(3)
            return true

        case kVK_ANSI_4 where flags == [.command]:
            quickSplit(4)
            return true

        case kVK_Delete:
            guard flags.isEmpty else { return true }
            // While searching, Backspace edits the query; otherwise it is the
            // reverse of Enter.
            if searchQuery.isEmpty {
                exitFullscreenTargets()
            } else {
                setSearch(String(searchQuery.dropLast()))
            }
            return true

        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard let direction = Direction(keyCode: event.keyCode) else { return true }
            // Only Shift and Command mean anything here; anything else is not ours.
            guard flags.subtracting([.shift, .command]).isEmpty else { return true }

            if flags.contains(.command) {
                // The explicit "now send it" gesture.
                guard !selectedIndices.isEmpty else {
                    NSSound.beep()
                    return true
                }
                sendSelection(direction)
            } else {
                // Always navigation, whether or not Shift happens to be held and
                // whether or not anything is selected. A bare arrow never moves a
                // window, so browsing around after selecting is safe.
                moveFocus(direction)
            }
            return true

        default:
            handleTypedKey(event, flags: flags)
            return true   // Swallow everything else so stray keys cannot leak through.
        }
    }

    /// Shift is the select key now, not a chord modifier. Only the press edge counts,
    /// so holding it down does not repeat, and releasing it does nothing.
    private func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let shiftNow = flags.contains(.shift)
        defer { shiftWasDown = shiftNow }

        if shiftNow && !shiftWasDown {
            toggleFocusedSelection(source: "shift")
        }
        redraw()
    }

    /// Adds or removes whatever the focus cursor is on.
    private func toggleFocusedSelection(source: String) {
        guard let current = focusedIndex, current < items.count else { return }
        if let position = selectedIndices.firstIndex(of: current) {
            selectedIndices.remove(at: position)
        } else {
            selectedIndices.append(current)
        }
        Self.debug("\(source) toggle -> \(selectedIndices.count) selected")
        redraw()
    }

    // MARK: - Actions

    private func performFullSwap() {
        // Put windows back first, so the swap reads the real layout rather than the
        // temporary spread one and hands back sensible positions on the far display.
        let saved = restorations
        dismiss(restoringWindows: false)
        WindowArranger.restore(saved)
        restorations = []

        let moved = WindowSwapper.swapAllWindowsBetweenTheTwoDisplays()
        Self.debug("full swap moved \(moved) windows")
    }

    /// Digits jump straight to a window; letters build up a name filter.
    ///
    /// Digits win over the filter even mid-search: app names rarely hinge on a
    /// leading number, and losing the one-key jump would cost more than it gains.
    private func handleTypedKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) {
        guard flags.isEmpty, let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return }

        if let digit = Int(characters), (1...9).contains(digit) {
            jumpToIndex(digit - 1)
            return
        }

        // Letters, digits 0, spaces inside a name, and so on.
        guard let scalar = characters.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" else { return }
        setSearch(searchQuery + characters)
    }

    /// Focus the window wearing that number. Numbers are global, so one key means
    /// one window no matter which display it is on.
    private func jumpToIndex(_ index: Int) {
        guard index < items.count else {
            NSSound.beep()
            return
        }
        focusedIndex = index
        redraw()
    }

    /// Applies a name filter and moves the cursor to the first match.
    private func setSearch(_ query: String) {
        searchQuery = query
        for panel in panels {
            panel.gridView.searchQuery = query
        }

        if !query.isEmpty {
            if let match = items.firstIndex(where: { $0.matches(query) }) {
                focusedIndex = match
            } else {
                NSSound.beep()
            }
        }
        redraw()
    }

    private func performUndo() {
        guard MoveHistory.canUndo else {
            NSSound.beep()
            return
        }
        // Put the fan-out back first, so undo writes onto real geometry rather than
        // fighting the temporary layout.
        let saved = restorations
        dismiss(restoringWindows: false)
        WindowArranger.restore(saved)
        restorations = []
        MoveHistory.undo()
    }

    /// What an action applies to: the selection when there is one, otherwise
    /// whatever the focus cursor is sitting on.
    private func currentTargets() -> [Int] {
        if !selectedIndices.isEmpty {
            return selectedIndices.filter { $0 < items.count }
        }
        if let focused = focusedIndex, focused < items.count {
            return [focused]
        }
        return []
    }

    /// Tab: bring the focused window to the front and hand it keyboard focus,
    /// completely as-is — no resize, no full screen, nothing else moves.
    ///
    /// Deliberately targets only the *focused* window, never the selection: "bring
    /// to front" only means anything for one window at a time, so this is the one
    /// action in the overlay that ignores a multi-window selection on purpose.
    private func activateFocused() {
        guard let index = focusedIndex, index < items.count else {
            NSSound.beep()
            return
        }
        let window = items[index].window

        let saved = restorations
        dismiss(restoringWindows: false)
        WindowArranger.restore(saved)
        restorations = []

        WindowManager.raise(window)
        Self.debug("activated \(window.appName)")
    }

    /// Enter: send the targets into native full screen.
    private func fullscreenTargets() {
        let targets = currentTargets()
        guard !targets.isEmpty else { return }
        let windows = targets.map { items[$0].window }

        // Restore first. A window must enter full screen from its real geometry, and
        // restoring one afterwards would fight the full-screen transition.
        let saved = restorations
        dismiss(restoringWindows: false)
        WindowArranger.restore(saved)
        restorations = []

        var succeeded = 0
        for window in windows where WindowManager.setFullScreen(window, true) {
            succeeded += 1
        }
        Self.debug("fullscreen \(succeeded)/\(windows.count)")
        if succeeded == 0 {
            // Dialogs and some non-native windows simply cannot go full screen.
            NSSound.beep()
        }
    }

    /// Backspace: take the targets back out of full screen, to normal size.
    private func exitFullscreenTargets() {
        let targets = currentTargets()
        guard !targets.isEmpty else { return }

        // Only windows actually in full screen; otherwise this silently "succeeds"
        // on ordinary windows and looks like nothing happened.
        let windows = targets.map { items[$0].window }.filter { WindowManager.isFullScreen($0) }
        guard !windows.isEmpty else {
            NSSound.beep()
            return
        }

        let saved = restorations
        dismiss(restoringWindows: false)
        WindowArranger.restore(saved)
        restorations = []

        var succeeded = 0
        for window in windows where WindowManager.setFullScreen(window, false) {
            succeeded += 1
        }
        Self.debug("exit fullscreen \(succeeded)/\(windows.count)")
        if succeeded == 0 { NSSound.beep() }
    }

    /// ⌘2 / ⌘3 / ⌘4: tile windows into an even split, so windows that were
    /// overlapping stop hiding each other.
    ///
    /// Targets the selection — grouped by display, kept in the order it was
    /// built — or, with nothing selected, every window on the display the
    /// cursor is aimed at, in front-to-back order. Windows beyond the split
    /// count stack on the last slot rather than being left untouched.
    private func quickSplit(_ count: Int) {
        let groups = resolveSplitGroups()
        guard !groups.isEmpty else {
            NSSound.beep()
            return
        }

        // Restore first: a split must place windows at their real size, not
        // whatever the temporary spread shrank them to.
        let saved = restorations
        dismiss(restoringWindows: false)
        WindowArranger.restore(saved)
        restorations = []

        let allWindows = groups.flatMap { $0.windows }
        MoveHistory.record(allWindows, action: L("%d-way split", min(max(count, 2), 4)))

        var moved = 0
        for group in groups {
            moved += QuickSplit.placeWindows(group.windows, splitCount: count, on: group.screen)
        }
        Self.debug("split \(count)-way: moved \(moved)/\(allWindows.count) windows across \(groups.count) screen(s)")
        if moved == 0 { NSSound.beep() }
    }

    /// Groups the split's targets by display: the selection (screen-grouped,
    /// kept in the order it was built) if there is one, otherwise every window
    /// on the display the cursor is currently aimed at, in front-to-back order.
    private func resolveSplitGroups() -> [(screen: NSScreen, windows: [WindowInfo])] {
        if !selectedIndices.isEmpty {
            var groups: [(screen: NSScreen, windows: [WindowInfo])] = []
            for index in selectedIndices where index < items.count {
                let item = items[index]
                if let existing = groups.firstIndex(where: { $0.screen == item.screen }) {
                    groups[existing].windows.append(item.window)
                } else {
                    groups.append((item.screen, [item.window]))
                }
            }
            return groups
        }

        // Mouse position first, not the aim cursor's screen: unlike every other
        // no-selection action here (quit, full screen, ...), which act on one
        // specific, already-highlighted window, a split with nothing selected acts
        // on an entire *display* — and the aim cursor starts wherever the frontmost
        // app happened to be before the overlay opened, not wherever the user is
        // actually looking. Requiring an arrow-navigate over to the target screen
        // first, just to split it, made the feature look broken on whichever
        // display wasn't already focused.
        guard let targetScreen = DisplayManager.screenUnderMouse()
            ?? focusedIndex.flatMap({ $0 < items.count ? items[$0].screen : nil }) else { return [] }
        let windows = items.filter { $0.screen == targetScreen }.map { $0.window }
        Self.debug("split target (no selection): \(DisplayManager.name(of: targetScreen)), \(windows.count) window(s)")
        return windows.isEmpty ? [] : [(targetScreen, windows)]
    }

    /// ⌘Q: quit the apps that own the selected windows, or the focused one
    /// when nothing is selected — the same target rule the other actions use.
    ///
    /// This is ⌘Q, not "close this window": `terminate()` sends the very same quit
    /// request the menu item does, so an app with unsaved work still gets to put up
    /// its save prompt, and quitting takes all of that app's windows with it.
    private func quitTargets() {
        let targets = currentTargets()
        guard !targets.isEmpty else { return }

        // Quitting is per application, and one app can own several selected windows.
        var pids: [pid_t] = []
        for index in targets where !pids.contains(items[index].window.pid) {
            pids.append(items[index].window.pid)
        }

        var issued: [pid_t] = []
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if app.terminate() {
                issued.append(pid)
                Self.debug("quit requested: \(app.localizedName ?? "pid \(pid)")")
            } else {
                Self.debug("quit refused by \(app.localizedName ?? "pid \(pid)")")
            }
        }

        guard !issued.isEmpty else {
            NSSound.beep()
            return
        }

        // Quitting is slower than closing a window, so give it a longer beat before
        // reconciling against reality.
        let requested = Set(issued)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.reconcileAfterQuit(pids: requested)
        }
    }

    /// Drops the windows of apps that really quit, and gets out of the way for any
    /// that did not — an app that refuses to quit is almost always showing a save
    /// prompt, which this overlay would be sitting on top of.
    private func reconcileAfterQuit(pids: Set<pid_t>) {
        guard isVisible else { return }

        let stillRunning = pids.filter { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated
        }
        let gone = pids.subtracting(stillRunning)

        if !gone.isEmpty {
            // A window belonging to a quit app must not be repositioned on restore.
            restorations.removeAll { gone.contains($0.window.pid) }
            removeItems { gone.contains($0.window.pid) }
        }

        if !stillRunning.isEmpty {
            Self.debug("quit: \(stillRunning.count) app(s) still running, likely a save prompt — stepping aside")
            dismiss()
            return
        }
        if items.isEmpty {
            dismiss()
        }
    }

    /// Removes matching items and remaps focus and selection, which are indices.
    private func removeItems(where shouldRemove: (ExposeItem) -> Bool) {
        var remaining: [ExposeItem] = []
        var indexMap: [Int: Int] = [:]

        for (old, item) in items.enumerated() {
            guard !shouldRemove(item) else { continue }
            indexMap[old] = remaining.count
            remaining.append(item)
        }

        items = remaining
        selectedIndices = selectedIndices.compactMap { indexMap[$0] }
        focusedIndex = focusedIndex.flatMap { indexMap[$0] } ?? (items.isEmpty ? nil : 0)

        // Keep the badges contiguous after windows drop out.
        for (index, item) in items.enumerated() {
            item.jumpNumber = index < 9 ? index + 1 : nil
        }
        refreshPanelItems()
        redraw()
    }

    /// Re-hands each panel the items still living on its display.
    private func refreshPanelItems() {
        for panel in panels {
            panel.gridView.items = items.filter { $0.screen == panel.targetScreen }
        }
    }

    /// Plain arrow with an empty selection: navigation only, nothing moves.
    private func moveFocus(_ direction: Direction) {
        guard let current = focusedIndex, current < items.count else {
            focusedIndex = items.isEmpty ? nil : 0
            redraw()
            return
        }
        guard let next = neighbor(of: current, direction: direction) else {
            NSSound.beep()
            return
        }
        focusedIndex = next
        redraw()
    }

    /// Plain arrow with a non-empty selection: ship those windows one display over.
    private func sendSelection(_ direction: Direction) {
        let anchorScreen = focusedIndex.flatMap { $0 < items.count ? items[$0].screen : nil }
            ?? selectedIndices.first.flatMap { $0 < items.count ? items[$0].screen : nil }

        guard let anchorScreen,
              let target = DisplayManager.screen(from: anchorScreen, direction: direction) else {
            // No display that way — refuse rather than guessing.
            NSSound.beep()
            return
        }

        let windows = selectedIndices.compactMap { index -> WindowInfo? in
            guard index < items.count else { return nil }
            return items[index].window
        }

        // Restore first: the selected windows should arrive at their normal size,
        // not the shrunken one the spread gave them.
        let saved = restorations
        dismiss(restoringWindows: false)
        WindowArranger.restore(saved)
        restorations = []

        let moved = WindowSwapper.move(windows, to: target)
        Self.debug("sent \(moved)/\(windows.count) windows \(direction.label)")
    }

    // MARK: - Directional navigation

    /// Nearest window in `direction`, measured between real window centres in
    /// global coordinates, so movement carries across display boundaries naturally.
    /// Perpendicular drift is weighted heavily to keep motion in straight lines.
    private func neighbor(of index: Int, direction: Direction) -> Int? {
        guard index < items.count else { return nil }
        let source = items[index].globalFrame

        var best: Int?
        var bestCost = CGFloat.greatestFiniteMagnitude

        for (candidateIndex, item) in items.enumerated() where candidateIndex != index {
            let dx = item.globalFrame.midX - source.midX
            let dy = item.globalFrame.midY - source.midY

            let along: CGFloat
            let across: CGFloat
            switch direction {
            case .left:
                guard dx < -1 else { continue }
                along = -dx; across = abs(dy)
            case .right:
                guard dx > 1 else { continue }
                along = dx; across = abs(dy)
            case .up:
                guard dy > 1 else { continue }      // AppKit y grows upward
                along = dy; across = abs(dx)
            case .down:
                guard dy < -1 else { continue }
                along = -dy; across = abs(dx)
            }

            let cost = along + across * 2.5
            if cost < bestCost {
                bestCost = cost
                best = candidateIndex
            }
        }
        return best
    }

    // MARK: - System changes

    private func observeSystemChanges() {
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(handleResignActive),
                           name: NSApplication.didResignActiveNotification,
                           object: nil)
        // Plugging or unplugging a display invalidates every cached frame.
        center.addObserver(self,
                           selector: #selector(handleScreenChange),
                           name: NSApplication.didChangeScreenParametersNotification,
                           object: nil)
    }

    private func stopObservingSystemChanges() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        center.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func handleResignActive() { dismiss() }
    @objc private func handleScreenChange() { dismiss() }

    // MARK: - State queries (used by the views)

    func index(of item: ExposeItem) -> Int? {
        items.firstIndex { $0 === item }
    }

    func isFocused(_ item: ExposeItem) -> Bool {
        guard let focusedIndex, focusedIndex < items.count else { return false }
        return items[focusedIndex] === item
    }

    func isSelected(_ item: ExposeItem) -> Bool {
        guard let index = index(of: item) else { return false }
        return selectedIndices.contains(index)
    }

    var selectionCount: Int { selectedIndices.count }

    // MARK: - Mouse

    /// Plain click: move the focus cursor there.
    func focusItem(_ item: ExposeItem) {
        guard let index = index(of: item) else { return }
        focusedIndex = index
        redraw()
    }

    /// Cmd+click: toggle membership in the same selection set the keyboard builds,
    /// so the two input paths stay interchangeable.
    func toggleSelection(of item: ExposeItem) {
        guard let index = index(of: item) else { return }
        if let position = selectedIndices.firstIndex(of: index) {
            selectedIndices.remove(at: position)
        } else {
            selectedIndices.append(index)
        }
        focusedIndex = index
        redraw()
    }

    /// Drop at a global point: if it landed on a different display, that one window
    /// moves there.
    func handleDrop(of item: ExposeItem, atGlobalPoint point: NSPoint) {
        guard let target = DisplayManager.screens.first(where: { $0.frame.contains(point) }) else {
            NSSound.beep()
            return
        }
        guard target != item.screen else { return }   // dropped back home: no-op

        let window = item.window
        dismiss()
        WindowManager.moveWindow(window, to: target)
    }
}

// MARK: - Panel

/// One borderless, screen-covering, **transparent** panel. Borderless windows
/// refuse key status by default, so `canBecomeKey` is overridden.
final class ExposeOverlayPanel: NSPanel {

    let targetScreen: NSScreen
    let gridView: ExposeGridView

    init(screen: NSScreen) {
        self.targetScreen = screen
        self.gridView = ExposeGridView(frame: CGRect(origin: .zero, size: screen.frame.size))

        // Plain .borderless, deliberately NOT .nonactivatingPanel: the overlay must
        // activate the app so key events are delivered.
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the Dock (20) and menu bar (24), but no higher than necessary.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false

        gridView.autoresizingMask = [.width, .height]
        gridView.screenName = DisplayManager.name(of: screen)

        contentView = gridView
        setFrame(screen.frame, display: false)
    }

    /// AppKit normally shoves a window down so it cannot cover the menu bar. That
    /// silently relocated the secondary display's panel and was why the overlay
    /// only ever appeared on one screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func keyDown(with event: NSEvent) {
        if ExposeOverlayController.shared.handleKeyFromPanel(event) { return }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        _ = ExposeOverlayController.shared.handleKeyFromPanel(event)
        super.flagsChanged(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Overlay view

/// Draws outlines over the real windows and handles mouse input.
///
/// Nothing here paints a background image. The view is see-through, so what you
/// look at is your actual desktop with your actual windows; only the focus ring,
/// selection borders, name badges and the key legend are drawn.
final class ExposeGridView: NSView {

    weak var controller: ExposeOverlayController?
    var items: [ExposeItem] = []
    var screenName: String = ""
    var searchQuery = ""

    private var mouseDownItem: ExposeItem?
    private var mouseDownLocation: NSPoint = .zero
    private var isDragging = false
    private var dragProxy: NSWindow?

    private static let cornerRadius: CGFloat = 10

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Barely-there scrim: enough to signal the overlay is live and to make the
        // outlines read, while leaving the real windows plainly visible.
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()

        // Back to front, so the frontmost window's outline ends up on top.
        for item in items.reversed() {
            draw(item)
        }
        drawFooter()
    }

    private func draw(_ item: ExposeItem) {
        let rect = item.localFrame
        guard rect.width > 8, rect.height > 8 else { return }

        let isFocused = controller?.isFocused(item) ?? false
        let isSelected = controller?.isSelected(item) ?? false
        let isMatch = item.matches(searchQuery)

        // While filtering, non-matches stay visible but recede, so the shape of the
        // screen is preserved and you can still see what you are ruling out.
        if !isMatch {
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
        }

        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
                                xRadius: Self.cornerRadius,
                                yRadius: Self.cornerRadius)

        if isSelected {
            // Lighter tint than the border deliberately: with overlapping windows a
            // strong fill on a *background* window bleeds across whatever sits in
            // front of it, making the front window look selected too. The border and
            // the corner checkmark are what actually identify the selection.
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.systemBlue.setStroke()
            path.lineWidth = 5
            path.stroke()
        } else {
            // Every candidate gets a faint outline so it is discoverable.
            NSColor.white.withAlphaComponent(0.30).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        // Focus is told apart from selection by colour *and* ring position: a white
        // ring sits outside the window's edge, where the blue border sits on it.
        if isFocused {
            NSColor.white.setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3),
                                    xRadius: Self.cornerRadius + 3,
                                    yRadius: Self.cornerRadius + 3)
            ring.lineWidth = 3
            ring.stroke()
        }

        drawBadge(for: item, in: rect, isSelected: isSelected, isFocused: isFocused,
                  number: item.jumpNumber, dimmed: !isMatch)
        if isSelected {
            drawCheckmark(in: rect)
        }
    }

    /// Checkmark pinned to a selected window's top-left corner.
    ///
    /// Unlike a tint, this is anchored to one specific window, so it stays readable
    /// when windows overlap: whichever rect the mark sits in is the selected one.
    private func drawCheckmark(in rect: NSRect) {
        let diameter: CGFloat = 26
        let origin = NSPoint(x: rect.minX + 10, y: rect.maxY - diameter - 10)
        let circle = NSRect(origin: origin, size: NSSize(width: diameter, height: diameter))
        guard rect.width > diameter + 24, rect.height > diameter + 24 else { return }

        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.white.setStroke()
        let outline = NSBezierPath(ovalIn: circle.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 2
        outline.stroke()

        let check = NSBezierPath()
        check.move(to: NSPoint(x: circle.minX + 7, y: circle.midY + 0.5))
        check.line(to: NSPoint(x: circle.midX - 1, y: circle.minY + 7.5))
        check.line(to: NSPoint(x: circle.maxX - 6, y: circle.maxY - 8))
        check.lineWidth = 2.5
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor.white.setStroke()
        check.stroke()
    }

    /// App-name badge, pinned inside the top edge of the window it labels.
    private func drawBadge(for item: ExposeItem, in rect: NSRect, isSelected: Bool,
                           isFocused: Bool, number: Int?, dimmed: Bool) {
        let name = number.map { "\($0)  \(item.window.appName)" } ?? item.window.appName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = name.size(withAttributes: attributes)
        let width = min(textSize.width + 22, max(rect.width - 12, 40))
        let height = textSize.height + 10

        var x = rect.midX - width / 2
        var y = rect.maxY - height - 14
        x = min(max(x, rect.minX + 6), max(rect.maxX - width - 6, rect.minX + 6))
        y = max(y, rect.minY + 6)
        let badge = NSRect(x: x, y: y, width: width, height: height)

        let fill: NSColor
        if isSelected {
            fill = .systemBlue
        } else if isFocused {
            fill = NSColor.black.withAlphaComponent(0.85)
        } else if dimmed {
            fill = NSColor.black.withAlphaComponent(0.5)
        } else {
            fill = NSColor.black.withAlphaComponent(0.65)
        }
        fill.setFill()
        NSBezierPath(roundedRect: badge, xRadius: height / 2, yRadius: height / 2).fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: badge.insetBy(dx: 6, dy: 0)).setClip()
        name.draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.minY + 5),
                  withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The live filter, shown above the legend while typing.
    private func drawSearchField() {
        let text = "\u{2315}  \(searchQuery)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let pill = NSRect(x: bounds.midX - size.width / 2 - 18,
                          y: 128,
                          width: size.width + 36,
                          height: size.height + 18)

        NSColor.systemBlue.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.minY + 9), withAttributes: attributes)
    }

    private func drawFooter() {
        let selectionCount = controller?.selectionCount ?? 0

        // Two lines: what acts on the target, then how to aim and get out. One line
        // stopped fitting once full screen and quit joined the set.
        let actions = "tab Activate   ·   ⌘ + arrows Send   ·   ⌘2-4 Split   ·   ↵ Full screen   ·   ⌫ Exit full screen   ·   ⌘Q Quit app   ·   space Swap all   ·   ⌘Z Undo"
        if !searchQuery.isEmpty {
            drawSearchField()
        }
        let navigation = selectionCount > 0
            ? "\(selectionCount) selected   ·   Arrows Aim   ·   ⇧ Select / deselect   ·   esc Cancel"
            : "Arrows Aim   ·   1-9 Jump   ·   Type to search   ·   ⇧ Select / deselect   ·   esc Cancel"

        let actionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let navigationAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]

        let actionSize = actions.size(withAttributes: actionAttributes)
        let navigationSize = navigation.size(withAttributes: navigationAttributes)
        let contentWidth = max(actionSize.width, navigationSize.width)
        let lineGap: CGFloat = 5

        let navigationY: CGFloat = 40
        let actionY = navigationY + navigationSize.height + lineGap

        let pill = NSRect(x: bounds.midX - contentWidth / 2 - 22,
                          y: navigationY - 12,
                          width: contentWidth + 44,
                          height: actionSize.height + navigationSize.height + lineGap + 24)
        let radius: CGFloat = 16
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let border = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()

        actions.draw(at: NSPoint(x: bounds.midX - actionSize.width / 2, y: actionY),
                     withAttributes: actionAttributes)
        navigation.draw(at: NSPoint(x: bounds.midX - navigationSize.width / 2, y: navigationY),
                        withAttributes: navigationAttributes)
    }

    // MARK: Hit testing

    /// Topmost window under the point. `items` is front-to-back, so the first hit
    /// is the one the user means when windows overlap.
    private func item(at point: NSPoint) -> ExposeItem? {
        items.first { $0.localFrame.contains(point) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownLocation = point
        isDragging = false

        guard let hit = item(at: point) else {
            mouseDownItem = nil
            return
        }
        mouseDownItem = hit

        if event.modifierFlags.contains(.command) {
            controller?.toggleSelection(of: hit)
        } else {
            controller?.focusItem(hit)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let item = mouseDownItem else { return }
        let point = convert(event.locationInWindow, from: nil)

        if !isDragging {
            let dx = point.x - mouseDownLocation.x
            let dy = point.y - mouseDownLocation.y
            guard (dx * dx + dy * dy) > 36 else { return }   // 6pt threshold
            isDragging = true
            beginDragProxy(for: item)
        }
        updateDragProxy()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            endDragProxy()
            mouseDownItem = nil
            isDragging = false
        }
        guard isDragging, let item = mouseDownItem else { return }

        // Global mouse location, so a drop on another display's panel resolves
        // correctly even though every drag event belongs to this window.
        controller?.handleDrop(of: item, atGlobalPoint: NSEvent.mouseLocation)
    }

    // MARK: Drag proxy

    /// A small name badge that follows the cursor across displays while dragging.
    private func beginDragProxy(for item: ExposeItem) {
        let name = item.window.appName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = name.size(withAttributes: attributes)
        let size = NSSize(width: textSize.width + 32, height: textSize.height + 18)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .popUpMenu
        window.ignoresMouseEvents = true
        window.alphaValue = 0.9
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let label = NSTextField(labelWithString: name)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 8, width: size.width, height: textSize.height + 2)

        let container = DragProxyView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(label)
        window.contentView = container

        dragProxy = window
        window.orderFrontRegardless()
        updateDragProxy()
    }

    private func updateDragProxy() {
        guard let dragProxy else { return }
        let location = NSEvent.mouseLocation
        let size = dragProxy.frame.size
        dragProxy.setFrameOrigin(NSPoint(x: location.x + 14, y: location.y - size.height - 14))
    }

    private func endDragProxy() {
        dragProxy?.orderOut(nil)
        dragProxy = nil
    }
}

/// Rounded blue pill behind the drag proxy's label.
private final class DragProxyView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}
