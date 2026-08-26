import AppKit

/// Physically rearranges real windows so they stop overlapping, and puts them back
/// afterwards.
///
/// Unlike Mission Control — which asks the window server to *draw* everyone's live
/// windows at new positions using private APIs — this genuinely moves and resizes
/// the windows through the Accessibility API. They stay live and clickable, at the
/// cost of apps re-laying out their contents while spread.
///
/// Every spread writes a restore file first. If ScreenSwap is killed while windows
/// are spread, the next launch can put them back.
enum WindowArranger {

    /// A window plus the frame it had before being spread.
    struct Restoration {
        let window: WindowInfo
        let originalFrame: CGRect
    }

    /// Disk form of the same thing, for recovering after an unclean exit.
    struct Snapshot: Codable {
        let windowID: UInt32
        let pid: Int32
        let x: Double, y: Double, width: Double, height: Double

        var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

        init(_ restoration: Restoration) {
            windowID = restoration.window.windowID
            pid = restoration.window.pid
            x = restoration.originalFrame.origin.x
            y = restoration.originalFrame.origin.y
            width = restoration.originalFrame.width
            height = restoration.originalFrame.height
        }
    }

    // MARK: - Layout

    /// Padding around the spread area, and the strip kept clear at the bottom for
    /// the overlay's key legend.
    private static let edgeInset: CGFloat = 44
    private static let legendReserve: CGFloat = 118
    private static let cellGap: CGFloat = 22

    /// Target frames that tile `windows` across `screen` without overlapping.
    ///
    /// Windows are ordered by where they already sit — top rows first, then left to
    /// right — so the spread still resembles the original arrangement.
    static func spreadFrames(for windows: [WindowInfo], on screen: NSScreen) -> [CGWindowID: CGRect] {
        guard !windows.isEmpty else { return [:] }

        let visible = DisplayManager.cgVisibleFrame(of: screen)
        // CG coordinates: y grows downward, so the legend strip comes off the bottom
        // by shortening the height.
        let area = CGRect(x: visible.minX + edgeInset,
                          y: visible.minY + edgeInset,
                          width: visible.width - edgeInset * 2,
                          height: visible.height - edgeInset - legendReserve)
        guard area.width > 80, area.height > 80 else { return [:] }

        let ordered = windows.sorted { a, b in
            if abs(a.frame.midY - b.frame.midY) > 120 { return a.frame.midY < b.frame.midY }
            return a.frame.midX < b.frame.midX
        }

        let count = ordered.count
        let targetAspect: CGFloat = 1.6
        var columns = Int(ceil(sqrt(CGFloat(count) * (area.width / max(area.height, 1)) / targetAspect)))
        columns = min(max(columns, 1), count)
        let rows = Int(ceil(CGFloat(count) / CGFloat(columns)))

        let cellWidth = (area.width - CGFloat(columns - 1) * cellGap) / CGFloat(columns)
        let cellHeight = (area.height - CGFloat(rows - 1) * cellGap) / CGFloat(rows)

        var result: [CGWindowID: CGRect] = [:]

        for (index, window) in ordered.enumerated() {
            let row = index / columns
            let column = index % columns

            // Centre a short final row so the spread stays balanced.
            let inRow = min(columns, count - row * columns)
            let rowWidth = CGFloat(inRow) * cellWidth + CGFloat(inRow - 1) * cellGap
            let rowStartX = area.minX + (area.width - rowWidth) / 2

            let cell = CGRect(x: rowStartX + CGFloat(column) * (cellWidth + cellGap),
                              y: area.minY + CGFloat(row) * (cellHeight + cellGap),
                              width: cellWidth,
                              height: cellHeight)

            // Shrink to fit the cell, never enlarge: blowing a small utility window
            // up to fill a cell would be more disorienting than leaving it small.
            let size = window.frame.size
            let scale = min(cell.width / max(size.width, 1), cell.height / max(size.height, 1), 1.0)
            let fitted = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))

            result[window.windowID] = CGRect(x: floor(cell.midX - fitted.width / 2),
                                             y: floor(cell.midY - fitted.height / 2),
                                             width: fitted.width,
                                             height: fitted.height)
        }
        return result
    }

    // MARK: - Spread & restore

    /// Moves every movable window into a non-overlapping arrangement on its own
    /// display. Returns what is needed to undo it.
    @discardableResult
    static func spread(_ windows: [WindowInfo]) -> [Restoration] {
        // Full-screen windows own their entire Space. Shrinking one into a grid cell
        // fights the window server and leaves it in a broken half-state, so they are
        // left alone — and therefore never need restoring either.
        let movable = windows.filter { $0.isMovable && !WindowManager.isFullScreen($0) }
        guard !movable.isEmpty else { return [] }

        // Snapshot before touching anything.
        var restorations: [Restoration] = []
        for window in movable {
            // Read the live frame rather than trusting the cached one.
            let live = window.element.flatMap { WindowManager.frame(of: $0) } ?? window.frame
            restorations.append(Restoration(window: window, originalFrame: live))
        }
        writePendingRestore(restorations)

        // Group by display and lay each out independently, so windows never hop
        // screens just from being spread.
        let byScreen = Dictionary(grouping: movable) { window in
            DisplayManager.screen(containingCGRect: window.frame) ?? DisplayManager.screens[0]
        }

        for (screen, screenWindows) in byScreen {
            let targets = spreadFrames(for: screenWindows, on: screen)
            for window in screenWindows {
                guard let element = window.element, let target = targets[window.windowID] else { continue }
                apply(target, to: element)
            }
        }

        return restorations
    }

    /// Puts every window back where it was.
    static func restore(_ restorations: [Restoration]) {
        for restoration in restorations {
            guard let element = restoration.window.element else { continue }
            apply(restoration.originalFrame, to: element)
        }
        clearPendingRestore()
    }

    /// Size, position, size again: resizing can nudge a window's origin, and some
    /// apps clamp a move that would push them off-screen at their current size, so
    /// the ordering matters and the second size pass settles it.
    private static func apply(_ frame: CGRect, to element: AXUIElement) {
        WindowManager.setSize(element, to: frame.size)
        WindowManager.setPosition(element, to: frame.origin)
        WindowManager.setSize(element, to: frame.size)
    }

    // MARK: - Crash recovery

    private static var restoreFileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let directory = support.appendingPathComponent("ScreenSwap", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("pending-restore.json")
    }

    private static func writePendingRestore(_ restorations: [Restoration]) {
        guard let url = restoreFileURL else { return }
        let snapshots = restorations.map(Snapshot.init)
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: url)
    }

    static func clearPendingRestore() {
        guard let url = restoreFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Windows left spread by an unclean exit, if any.
    static func pendingRestore() -> [Snapshot]? {
        guard let url = restoreFileURL,
              let data = try? Data(contentsOf: url),
              let snapshots = try? JSONDecoder().decode([Snapshot].self, from: data),
              !snapshots.isEmpty else { return nil }
        return snapshots
    }

    /// Re-matches saved snapshots against the windows currently open and restores
    /// the ones still around. Windows that have since closed are simply skipped.
    @discardableResult
    static func restoreFromDisk(_ snapshots: [Snapshot]) -> Int {
        let current = WindowManager.listAllWindows()
        var restored = 0

        for snapshot in snapshots {
            guard let match = current.first(where: { $0.windowID == snapshot.windowID && $0.pid == snapshot.pid }),
                  let element = match.element else { continue }
            apply(snapshot.frame, to: element)
            restored += 1
        }

        clearPendingRestore()
        return restored
    }
}
