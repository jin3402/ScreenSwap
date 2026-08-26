import AppKit

/// One level of undo for window moves.
///
/// This app rearranges real windows, so a mistaken swap scatters a dozen of them
/// with no way back. Every move records where its windows were first;
/// `MoveHistory.undo()` puts them back.
///
/// Only *moves* are recorded. Full screen has its own reverse (Backspace) and
/// quitting an app is not something an undo could honestly reverse.
enum MoveHistory {

    private(set) static var lastAction: String?
    private static var snapshot: [WindowArranger.Restoration] = []

    static var canUndo: Bool { !snapshot.isEmpty }

    /// Captures the current geometry of `windows` before they are moved.
    static func record(_ windows: [WindowInfo], action: String) {
        let movable = windows.filter { $0.isMovable }
        guard !movable.isEmpty else { return }

        snapshot = movable.map { window in
            // Read the live frame; a cached one may already be stale.
            let live = window.element.flatMap { WindowManager.frame(of: $0) } ?? window.frame
            return WindowArranger.Restoration(window: window, originalFrame: live)
        }
        lastAction = action
        Log.debug("history: recorded \(snapshot.count) windows for '\(action)'")
    }

    /// Puts the last recorded move back. Returns how many windows were restored.
    @discardableResult
    static func undo() -> Int {
        guard !snapshot.isEmpty else {
            NSSound.beep()
            return 0
        }
        let count = snapshot.count
        WindowArranger.restore(snapshot)
        Log.debug("history: undid '\(lastAction ?? "?")' (\(count) windows)")
        clear()
        return count
    }

    static func clear() {
        snapshot = []
        lastAction = nil
    }
}
