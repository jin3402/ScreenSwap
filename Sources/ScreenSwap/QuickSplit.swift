import AppKit

/// Tiles a set of windows into an even 2/3/4-way split on one display, so
/// windows that were overlapping each other stop hiding one another.
///
///   2-way: left half / right half
///   3-way: top half, full width / bottom-left quarter / bottom-right quarter
///   4-way: four quadrants, filling the display
///
/// Windows beyond the slot count stack on the last slot rather than being left
/// wherever they were — the point is that nothing stays stranded off the grid.
///
/// This only computes geometry and writes frames. Callers own their own
/// `MoveHistory` recording: both the overlay's manual ⌘2/3/4 and the swap-all
/// action call this, and each wants exactly one undo entry covering everything
/// it moved, not one per display.
enum QuickSplit {

    /// Exactly `min(max(splitCount, 2), 4)` target rects, in CG coordinates
    /// (origin top-left, y down — see `DisplayManager`), tiling `screen`'s
    /// visible area edge to edge.
    static func slotFrames(count: Int, on screen: NSScreen) -> [CGRect] {
        let n = min(max(count, 2), 4)
        let area = DisplayManager.cgVisibleFrame(of: screen)
        guard area.width > 0, area.height > 0 else { return [] }

        let halfWidth = area.width / 2
        let halfHeight = area.height / 2
        let left = area.minX, top = area.minY
        let right = area.minX + halfWidth, bottom = area.minY + halfHeight

        switch n {
        case 2:
            return [
                CGRect(x: left, y: top, width: halfWidth, height: area.height),
                CGRect(x: right, y: top, width: halfWidth, height: area.height)
            ]
        case 3:
            return [
                CGRect(x: left, y: top, width: area.width, height: halfHeight),
                CGRect(x: left, y: bottom, width: halfWidth, height: halfHeight),
                CGRect(x: right, y: bottom, width: halfWidth, height: halfHeight)
            ]
        default:   // 4
            return [
                CGRect(x: left, y: top, width: halfWidth, height: halfHeight),
                CGRect(x: right, y: top, width: halfWidth, height: halfHeight),
                CGRect(x: left, y: bottom, width: halfWidth, height: halfHeight),
                CGRect(x: right, y: bottom, width: halfWidth, height: halfHeight)
            ]
        }
    }

    /// Whether `windows` overlap each other enough to justify auto-splitting
    /// rather than preserving each one's individual relative position.
    ///
    /// The threshold (30% of the smaller window's area) is deliberately
    /// generous: two windows nudged slightly apart but still mostly stacked
    /// should still count as "overlapping" here, since the point is rescuing
    /// windows that are hard to pick apart, not detecting exact congruence.
    static func windowsOverlapSignificantly(_ windows: [WindowInfo]) -> Bool {
        guard windows.count >= 2 else { return false }
        for i in 0..<windows.count {
            let a = windows[i].frame
            let areaA = a.width * a.height
            guard areaA > 0 else { continue }
            for j in (i + 1)..<windows.count {
                let b = windows[j].frame
                let intersection = a.intersection(b)
                guard !intersection.isNull else { continue }
                let overlapArea = intersection.width * intersection.height
                let smallerArea = min(areaA, b.width * b.height)
                guard smallerArea > 0 else { continue }
                if overlapArea / smallerArea > 0.3 { return true }
            }
        }
        return false
    }

    /// Moves `windows` — already ordered by the caller (front-to-back, or
    /// selection order) — into the split. The first `n` land one per slot;
    /// anything beyond that stacks on the last slot rather than being
    /// stranded off-grid.
    ///
    /// Does not touch `MoveHistory`; see the type documentation.
    @discardableResult
    static func placeWindows(_ windows: [WindowInfo], splitCount: Int, on screen: NSScreen) -> Int {
        let movable = windows.filter { $0.isMovable }
        guard !movable.isEmpty else { return 0 }

        let slots = slotFrames(count: splitCount, on: screen)
        guard !slots.isEmpty else { return 0 }

        var moved = 0
        for (index, window) in movable.enumerated() {
            guard let element = window.element else { continue }
            let slot = slots[min(index, slots.count - 1)]
            // Size, position, size again: resizing can nudge the origin, and some
            // apps clamp a move that would push them off-screen at their current
            // size, so the ordering matters and the second size pass settles it.
            WindowManager.setSize(element, to: slot.size)
            WindowManager.setPosition(element, to: slot.origin)
            WindowManager.setSize(element, to: slot.size)
            moved += 1
        }
        return moved
    }
}
