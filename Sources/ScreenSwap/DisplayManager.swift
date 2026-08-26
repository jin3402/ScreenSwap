import AppKit
import Carbon.HIToolbox

/// A cardinal direction, used for both display lookup and grid navigation.
enum Direction {
    case left, right, up, down

    init?(keyCode: UInt16) {
        switch Int(keyCode) {
        case kVK_LeftArrow:  self = .left
        case kVK_RightArrow: self = .right
        case kVK_UpArrow:    self = .up
        case kVK_DownArrow:  self = .down
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .left:  return "left"
        case .right: return "right"
        case .up:    return "up"
        case .down:  return "down"
        }
    }
}

/// Screen enumeration plus the AppKit <-> CoreGraphics coordinate bridging that
/// every other part of the app depends on.
///
/// Two coordinate spaces are in play and mixing them up is the classic source of
/// "window jumps to the wrong monitor" bugs:
/// - **AppKit** (`NSScreen.frame`): origin bottom-left of the primary display, y grows upward.
/// - **CoreGraphics / Accessibility**: origin top-left of the primary display, y grows downward.
enum DisplayManager {

    static var screens: [NSScreen] { NSScreen.screens }

    /// The display that owns the global origin. `NSScreen.screens[0]` is the screen
    /// containing the menu bar, which is exactly what CG treats as the origin.
    static var primaryScreen: NSScreen? { NSScreen.screens.first }

    private static var flipHeight: CGFloat {
        primaryScreen?.frame.maxY ?? 0
    }

    // MARK: - Coordinate conversion

    /// AppKit rect -> CoreGraphics/AX rect. Self-inverse with `nsRect(from:)`.
    static func cgRect(from nsRect: CGRect) -> CGRect {
        CGRect(x: nsRect.origin.x,
               y: flipHeight - nsRect.maxY,
               width: nsRect.width,
               height: nsRect.height)
    }

    /// CoreGraphics/AX rect -> AppKit rect.
    static func nsRect(from cgRect: CGRect) -> CGRect {
        CGRect(x: cgRect.origin.x,
               y: flipHeight - cgRect.maxY,
               width: cgRect.width,
               height: cgRect.height)
    }

    /// The screen's full bounds in CG/AX coordinates.
    static func cgFrame(of screen: NSScreen) -> CGRect {
        cgRect(from: screen.frame)
    }

    /// The screen's bounds minus menu bar and Dock, in CG/AX coordinates.
    /// This is the area windows should actually be placed into.
    static func cgVisibleFrame(of screen: NSScreen) -> CGRect {
        cgRect(from: screen.visibleFrame)
    }

    // MARK: - Hit testing

    /// The screen a CG-space rect belongs to, chosen by largest overlapping area so
    /// that a window straddling two displays lands on the one showing most of it.
    static func screen(containingCGRect rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0

        for screen in screens {
            let intersection = cgFrame(of: screen).intersection(rect)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }

        // A fully offscreen window still needs a home; fall back to nearest centre.
        if best == nil {
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            best = screens.min { a, b in
                distanceSquared(centre, cgFrame(of: a).centre) < distanceSquared(centre, cgFrame(of: b).centre)
            }
        }
        return best
    }

    /// The screen currently under the mouse cursor, used to decide which overlay
    /// panel should take keyboard focus.
    static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(location) } ?? primaryScreen
    }

    // MARK: - Directional lookup

    /// The neighbouring display in `direction`, based on physical arrangement.
    ///
    /// A candidate qualifies when its centre lies in that direction and it actually
    /// overlaps on the perpendicular axis (so a monitor sitting diagonally does not
    /// count as "directly left"). Among qualifying displays the nearest wins.
    ///
    /// When nothing overlaps perpendicularly we fall back to a looser test, but only
    /// for candidates whose displacement along the requested axis *dominates* their
    /// perpendicular displacement. Without that guard a plain side-by-side pair whose
    /// centres differ by a few pixels vertically (very common: a 1080p monitor beside
    /// a shorter laptop panel) would answer "down" with the display sitting to the
    /// left, and arrow keys would fling windows sideways.
    static func screen(from source: NSScreen, direction: Direction) -> NSScreen? {
        // Work in AppKit coordinates: physical arrangement is what matters here and
        // NSScreen.frame already reflects the user's Displays layout.
        let sourceFrame = source.frame
        let sourceCentre = sourceFrame.centre

        var overlapping: [(screen: NSScreen, distance: CGFloat)] = []
        var loose: [(screen: NSScreen, distance: CGFloat)] = []

        for candidate in screens where candidate != source {
            let frame = candidate.frame
            let centre = frame.centre

            let isInDirection: Bool
            let distance: CGFloat
            let perpendicularOverlap: Bool

            switch direction {
            case .left:
                isInDirection = centre.x < sourceCentre.x
                distance = sourceCentre.x - centre.x
                perpendicularOverlap = frame.maxY > sourceFrame.minY && frame.minY < sourceFrame.maxY
            case .right:
                isInDirection = centre.x > sourceCentre.x
                distance = centre.x - sourceCentre.x
                perpendicularOverlap = frame.maxY > sourceFrame.minY && frame.minY < sourceFrame.maxY
            case .up:
                // AppKit y grows upward, so "up" means a larger y.
                isInDirection = centre.y > sourceCentre.y
                distance = centre.y - sourceCentre.y
                perpendicularOverlap = frame.maxX > sourceFrame.minX && frame.minX < sourceFrame.maxX
            case .down:
                isInDirection = centre.y < sourceCentre.y
                distance = sourceCentre.y - centre.y
                perpendicularOverlap = frame.maxX > sourceFrame.minX && frame.minX < sourceFrame.maxX
            }

            guard isInDirection else { continue }
            if perpendicularOverlap {
                overlapping.append((candidate, distance))
            } else {
                // Perpendicular gap between the two centres.
                let perpendicularDistance: CGFloat
                switch direction {
                case .left, .right: perpendicularDistance = abs(centre.y - sourceCentre.y)
                case .up, .down:    perpendicularDistance = abs(centre.x - sourceCentre.x)
                }
                // Only accept when this really is the requested direction.
                if distance > perpendicularDistance {
                    loose.append((candidate, distance))
                }
            }
        }

        let pool = overlapping.isEmpty ? loose : overlapping
        return pool.min { $0.distance < $1.distance }?.screen
    }

    // MARK: - Helpers

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    /// Human-readable display name, used in the overlay header.
    static func name(of screen: NSScreen) -> String {
        if #available(macOS 10.15, *) {
            return screen.localizedName
        }
        return "Display"
    }
}

extension CGRect {
    var centre: CGPoint { CGPoint(x: midX, y: midY) }
}
