import AppKit
import ApplicationServices

/// One movable window, pairing the CoreGraphics record (id, owner, on-screen
/// geometry) with the Accessibility element used to actually move it.
struct WindowInfo {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    /// Frame in CG/AX coordinates (top-left origin).
    var frame: CGRect
    /// nil when no matching AX element could be found; such a window is shown in
    /// the overlay but cannot be moved.
    let element: AXUIElement?

    var isMovable: Bool { element != nil }

    var displayTitle: String {
        title.isEmpty ? appName : title
    }
}

/// Reads the window list and moves windows via the Accessibility API.
enum WindowManager {

    // MARK: - Safe AXValue accessors
    //
    // AXUIElementCopyAttributeValue hands back an untyped CFTypeRef. Force-casting
    // it to AXValue crashes whenever an app returns something unexpected, so every
    // read below verifies the CFTypeID *and* the AXValueType before unwrapping.

    static func getPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute: attribute, expecting: .cgPoint) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    static func getSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute: attribute, expecting: .cgSize) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func copyAXValue(_ element: AXUIElement,
                                    attribute: String,
                                    expecting type: AXValueType) -> AXValue? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard status == .success, let raw else { return nil }

        // Verified before the cast, so the cast below cannot trap.
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == type else { return nil }
        return value
    }

    static func getString(_ element: AXUIElement, attribute: String) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard status == .success, let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = getPoint(element, attribute: kAXPositionAttribute as String),
              let size = getSize(element, attribute: kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Writing

    @discardableResult
    static func setPosition(_ element: AXUIElement, to point: CGPoint) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, to size: CGSize) -> Bool {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    // MARK: - Enumeration

    /// Every ordinary, on-screen, movable window, front-to-back.
    ///
    /// CoreGraphics gives reliable ordering and geometry; the Accessibility API gives
    /// the ability to move things. Windows are matched between the two per process,
    /// as a batch, so that one AX element can back at most one CG window.
    static func listAllWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var entries: [Entry] = []

        for item in raw {
            // Layer 0 is the normal window layer. Anything else is a panel, menu,
            // Dock tile, status item, wallpaper, etc.
            guard let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = item[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let windowID = item[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            // Skip slivers: tooltips and offscreen helpers not worth showing.
            guard bounds.width >= 80, bounds.height >= 80 else { continue }

            // CG reports the executable name for some system agents
            // ("universalAccessAuthWarn"); the running application knows a better one.
            let ownerName = item[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ownerName
            // Titles require Screen Recording permission; may be empty without it.
            let title = item[kCGWindowName as String] as? String ?? ""

            entries.append(Entry(windowID: windowID, pid: pid, appName: appName,
                                 title: title, bounds: bounds))
        }

        // Match per process. Doing this as a batch rather than one window at a time
        // is what makes multi-window apps work: matching each CG window on its own
        // let several of them settle on the same AX element, leaving the rest with
        // none and therefore silently unmovable.
        var matches: [CGWindowID: AXUIElement] = [:]
        for (pid, group) in Dictionary(grouping: entries, by: { $0.pid }) {
            let candidates = axWindows(for: pid)
            guard !candidates.isEmpty else { continue }
            for (windowID, element) in assign(group, to: candidates) {
                matches[windowID] = element
            }
        }

        return entries.map { entry in
            WindowInfo(windowID: entry.windowID,
                       pid: entry.pid,
                       appName: entry.appName,
                       title: entry.title,
                       frame: entry.bounds,
                       element: matches[entry.windowID])
        }
    }

    private struct Entry {
        let windowID: CGWindowID
        let pid: pid_t
        let appName: String
        let title: String
        let bounds: CGRect
    }

    /// Pairs one process's CG windows with its AX elements, one to one.
    ///
    /// Geometry is the strongest signal — CG bounds and AX frames agree closely — with
    /// the title as a tiebreak. Every pairing is scored, the best are taken first, and
    /// neither side is used twice.
    private static func assign(_ cgWindows: [Entry],
                               to axWindows: [(element: AXUIElement, frame: CGRect, title: String)])
        -> [(CGWindowID, AXUIElement)] {

        // One window each way is unambiguous, whatever the geometry says. This is what
        // rescues apps whose AX frame does not agree with their CG bounds at all.
        if cgWindows.count == 1 && axWindows.count == 1 {
            return [(cgWindows[0].windowID, axWindows[0].element)]
        }

        struct Pair {
            let cgIndex: Int
            let axIndex: Int
            let score: CGFloat
        }

        var pairs: [Pair] = []
        for (cgIndex, cg) in cgWindows.enumerated() {
            for (axIndex, ax) in axWindows.enumerated() {
                var score = abs(ax.frame.origin.x - cg.bounds.origin.x)
                          + abs(ax.frame.origin.y - cg.bounds.origin.y)
                          + abs(ax.frame.width - cg.bounds.width)
                          + abs(ax.frame.height - cg.bounds.height)
                if !cg.title.isEmpty && ax.title == cg.title {
                    score -= 25   // nudge, not an override
                }
                pairs.append(Pair(cgIndex: cgIndex, axIndex: axIndex, score: score))
            }
        }
        pairs.sort { $0.score < $1.score }

        var usedCG = Set<Int>()
        var usedAX = Set<Int>()
        var result: [(CGWindowID, AXUIElement)] = []

        for pair in pairs {
            guard !usedCG.contains(pair.cgIndex), !usedAX.contains(pair.axIndex) else { continue }
            let cg = cgWindows[pair.cgIndex]

            // Scaled tolerance rather than a flat few points. A fixed 12pt budget threw
            // away legitimate matches from apps whose AX geometry is merely
            // approximate, and since the only rival candidates are this same app's
            // other windows, being generous here is safe.
            let tolerance = max(60, (cg.bounds.width + cg.bounds.height) * 0.2)
            guard pair.score <= tolerance else { continue }

            usedCG.insert(pair.cgIndex)
            usedAX.insert(pair.axIndex)
            result.append((cg.windowID, axWindows[pair.axIndex].element))
        }

        if result.count < cgWindows.count {
            Log.debug("assign: matched \(result.count)/\(cgWindows.count) windows for \(cgWindows.first?.appName ?? "?") (\(axWindows.count) AX candidates)")
        }
        return result
    }

    /// AX windows for a process, with their frames pre-read for matching.
    private static func axWindows(for pid: pid_t) -> [(element: AXUIElement, frame: CGRect, title: String)] {
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard status == .success, let raw, CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }

        guard let elements = raw as? [AXUIElement] else { return [] }
        return elements.compactMap { element in
            guard let frame = frame(of: element) else { return nil }
            let title = getString(element, attribute: kAXTitleAttribute as String) ?? ""
            return (element, frame, title)
        }
    }

    /// The frontmost ordinary window, used as the overlay's initial focus.
    static func frontmostWindowID(in windows: [WindowInfo]) -> CGWindowID? {
        // CGWindowListCopyWindowInfo returns front-to-back order already.
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return windows.first?.windowID }
        let pid = frontApp.processIdentifier
        return windows.first(where: { $0.pid == pid })?.windowID ?? windows.first?.windowID
    }

    // MARK: - Moving

    /// Moves a window to `screen`, keeping its position *proportional* to where it
    /// sat on its old display. A window centred on a 27" monitor stays centred on a
    /// 14" one instead of drifting off the edge.
    @discardableResult
    static func moveWindow(_ window: WindowInfo, to screen: NSScreen) -> Bool {
        guard let element = window.element else { return false }

        let destination = DisplayManager.cgVisibleFrame(of: screen)
        guard destination.width > 0, destination.height > 0 else { return false }

        let source = DisplayManager.cgVisibleFrame(
            of: DisplayManager.screen(containingCGRect: window.frame) ?? screen
        )

        // Re-read the live frame: the cached one can be stale by the time we act.
        let current = frame(of: element) ?? window.frame

        var newSize = current.size
        // Shrink to fit if the destination is smaller, preserving aspect.
        let maxWidth = destination.width
        let maxHeight = destination.height
        if newSize.width > maxWidth || newSize.height > maxHeight {
            let scale = min(maxWidth / newSize.width, maxHeight / newSize.height)
            newSize = CGSize(width: floor(newSize.width * scale), height: floor(newSize.height * scale))
        }

        // Proportional placement based on the window's relative offset in the old screen.
        let relativeX = source.width > 0 ? (current.minX - source.minX) / source.width : 0
        let relativeY = source.height > 0 ? (current.minY - source.minY) / source.height : 0

        var newOrigin = CGPoint(x: destination.minX + relativeX * destination.width,
                                y: destination.minY + relativeY * destination.height)

        // Clamp so the window is fully on the destination display.
        newOrigin.x = min(max(newOrigin.x, destination.minX), destination.maxX - newSize.width)
        newOrigin.y = min(max(newOrigin.y, destination.minY), destination.maxY - newSize.height)

        // Size first, then position: resizing can nudge the origin, so position wins last.
        if newSize != current.size {
            setSize(element, to: newSize)
        }
        let moved = setPosition(element, to: newOrigin)
        if newSize != current.size {
            setSize(element, to: newSize)
        }
        return moved
    }

    // MARK: - Diagnostics

    /// Whether the AX API will actually let us write an attribute. An app can expose
    /// a window and still refuse to have it moved or resized.
    static func isSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    /// Everything the AX API will tell us about one process's windows. Used by
    /// --debug logging to work out why a particular app refuses to move: either no
    /// element matched its CoreGraphics window, or the element is read-only.
    static func axReport(for pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard status == .success else { return ["AXWindows failed, status \(status.rawValue)"] }
        guard let raw, let elements = raw as? [AXUIElement], !elements.isEmpty else {
            return ["app exposes no AX windows"]
        }

        return elements.map { element in
            let box = frame(of: element).map {
                "(\(Int($0.minX)),\(Int($0.minY))) \(Int($0.width))x\(Int($0.height))"
            } ?? "no frame"
            let role = getString(element, attribute: kAXRoleAttribute as String) ?? "?"
            let subrole = getString(element, attribute: kAXSubroleAttribute as String) ?? "-"
            let title = getString(element, attribute: kAXTitleAttribute as String) ?? ""
            let pos = isSettable(element, attribute: kAXPositionAttribute as String)
            let size = isSettable(element, attribute: kAXSizeAttribute as String)
            return "role=\(role)/\(subrole) \(box) title=\"\(title)\" posSettable=\(pos) sizeSettable=\(size)"
        }
    }

    /// Whether a window is currently in native full screen.
    static func isFullScreen(_ window: WindowInfo) -> Bool {
        guard let element = window.element else { return false }
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &raw)
        guard status == .success, let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return false }
        // Verified above, so this cast cannot trap.
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    /// Puts a window into (or out of) native full screen — the same state the green
    /// button and ⌃⌘F control, giving the window its own Space.
    ///
    /// Not every window supports it: dialogs, panels and some non-native apps expose
    /// no writable AXFullScreen, which is why this reports whether it took.
    @discardableResult
    static func setFullScreen(_ window: WindowInfo, _ fullScreen: Bool) -> Bool {
        guard let element = window.element else { return false }

        // The Swift SDK has no constant for this one; the raw attribute name is the
        // documented interface.
        let attribute = "AXFullScreen"
        guard isSettable(element, attribute: attribute) else { return false }

        let value: CFBoolean = fullScreen ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// Brings a window to the front of its own app and activates that app, without
    /// touching the window's size or position.
    static func raise(_ window: WindowInfo) {
        guard let element = window.element else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate()
        }
    }
}
