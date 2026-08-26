import AppKit

/// Terminal-side verification for the parts that are otherwise only observable by
/// pressing keys: permission state, display geometry, the AppKit<->CG coordinate
/// bridge, directional display lookup, and CG-window-to-AX-element matching.
///
///   ScreenSwap --diagnose
///   ScreenSwap --plan-swap              # dry run of Enter (swap all)
///   ScreenSwap --plan-send <direction>  # dry run of arrow (send selection)
///
/// The "plan" modes print what *would* move without touching a single window.
enum Diagnostics {

    static func run(arguments: [String]) {
        printPermissions()
        printLocalization()
        printDisplays()
        printDirectionalMap()
        printWindows()

        if arguments.contains("--plan-swap") {
            planSwap()
        }
        if let index = arguments.firstIndex(of: "--plan-send"),
           index + 1 < arguments.count,
           let direction = parseDirection(arguments[index + 1]) {
            planSend(direction)
        }
    }

    // MARK: - Sections

    private static func printPermissions() {
        section("Permissions")
        line("Accessibility", PermissionsHelper.hasAccessibilityPermission ? "GRANTED" : "NOT GRANTED")
        if !PermissionsHelper.hasAccessibilityPermission {
            print("  -> Windows cannot be moved until Accessibility is granted.")
        }
    }

    private static func printLocalization() {
        section("Localization")
        line("available   ", Bundle.main.localizations.joined(separator: ", "))
        line("resolved to ", Bundle.main.preferredLocalizations.joined(separator: ", "))
        line("sample      ", "\"Window Overview\" -> \"\(L("Window Overview"))\"")
    }

    private static func printDisplays() {
        section("Displays (\(DisplayManager.screens.count))")
        for (index, screen) in DisplayManager.screens.enumerated() {
            let isPrimary = screen == DisplayManager.primaryScreen
            print("  [\(index)] \(DisplayManager.name(of: screen))\(isPrimary ? "  (primary)" : "")")
            print("        AppKit frame  \(fmt(screen.frame))")
            print("        CG frame      \(fmt(DisplayManager.cgFrame(of: screen)))")
            print("        CG visible    \(fmt(DisplayManager.cgVisibleFrame(of: screen)))")
            print("        backingScale  \(screen.backingScaleFactor)")

            // The two conversions must round-trip exactly, or windows land on the
            // wrong display.
            let roundTrip = DisplayManager.nsRect(from: DisplayManager.cgRect(from: screen.frame))
            let ok = abs(roundTrip.minX - screen.frame.minX) < 0.001
                && abs(roundTrip.minY - screen.frame.minY) < 0.001
            print("        coord round-trip \(ok ? "OK" : "FAILED  got \(fmt(roundTrip))")")
        }
    }

    private static func printDirectionalMap() {
        section("Directional display map")
        let directions: [Direction] = [.left, .right, .up, .down]
        for screen in DisplayManager.screens {
            let name = DisplayManager.name(of: screen)
            var parts: [String] = []
            for direction in directions {
                if let target = DisplayManager.screen(from: screen, direction: direction) {
                    parts.append("\(direction.label) -> \(DisplayManager.name(of: target))")
                } else {
                    parts.append("\(direction.label) -> (none)")
                }
            }
            print("  \(name)")
            for part in parts { print("        \(part)") }
        }
    }

    private static func printWindows() {
        let windows = WindowManager.listAllWindows()
        section("Windows (\(windows.count))")
        let movable = windows.filter { $0.isMovable }.count
        print("  movable via AX: \(movable) / \(windows.count)")
        print("")
        for window in windows {
            let home = DisplayManager.screen(containingCGRect: window.frame)
                .map { DisplayManager.name(of: $0) } ?? "(offscreen)"
            let flag = window.isMovable ? " " : "!"
            print("  \(flag) \(pad(window.appName, 24)) \(pad(shorten(window.title), 34)) \(fmt(window.frame))  -> \(home)")
        }
        if movable < windows.count {
            print("")
            print("  '!' = no matching AX element; shown in the overlay but not movable.")
        }
    }

    // MARK: - Dry runs

    private static func planSwap() {
        section("Plan: Enter (swap all between the two displays)")

        let screens = DisplayManager.screens
        guard screens.count >= 2 else {
            print("  Only \(screens.count) display(s); swap would beep and do nothing.")
            return
        }

        let primary = DisplayManager.primaryScreen ?? screens[0]
        guard let secondary = screens.filter({ $0 != primary })
            .max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }) else { return }

        print("  A = \(DisplayManager.name(of: primary))")
        print("  B = \(DisplayManager.name(of: secondary))")
        print("")

        let windows = WindowManager.listAllWindows().filter { $0.isMovable }
        var toB = 0, toA = 0
        for window in windows {
            guard let home = DisplayManager.screen(containingCGRect: window.frame) else { continue }
            if home == primary {
                print("  A -> B  \(pad(window.appName, 24)) \(shorten(window.title))")
                toB += 1
            } else if home == secondary {
                print("  B -> A  \(pad(window.appName, 24)) \(shorten(window.title))")
                toA += 1
            }
        }
        print("")
        print("  Total: \(toB + toA) windows would move (\(toB) A->B, \(toA) B->A)")
    }

    private static func planSend(_ direction: Direction) {
        section("Plan: arrow \(direction.label) (send selection)")

        let windows = WindowManager.listAllWindows().filter { $0.isMovable }
        guard let anchor = windows.first,
              let anchorScreen = DisplayManager.screen(containingCGRect: anchor.frame) else {
            print("  No movable windows.")
            return
        }

        print("  Anchor (stands in for the focused thumbnail):")
        print("        \(anchor.appName) on \(DisplayManager.name(of: anchorScreen))")

        guard let target = DisplayManager.screen(from: anchorScreen, direction: direction) else {
            print("  No display to the \(direction.label) -> would beep, nothing moves.")
            return
        }
        print("  Target display: \(DisplayManager.name(of: target))")
        print("")

        // Show the landing rect so proportional placement can be eyeballed.
        let destination = DisplayManager.cgVisibleFrame(of: target)
        let source = DisplayManager.cgVisibleFrame(of: anchorScreen)
        let relativeX = (anchor.frame.minX - source.minX) / source.width
        let relativeY = (anchor.frame.minY - source.minY) / source.height
        var size = anchor.frame.size
        if size.width > destination.width || size.height > destination.height {
            let scale = min(destination.width / size.width, destination.height / size.height)
            size = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        }
        var origin = CGPoint(x: destination.minX + relativeX * destination.width,
                             y: destination.minY + relativeY * destination.height)
        origin.x = min(max(origin.x, destination.minX), destination.maxX - size.width)
        origin.y = min(max(origin.y, destination.minY), destination.maxY - size.height)

        print("  \(anchor.appName):")
        print("        from \(fmt(anchor.frame))")
        print("        to   \(fmt(CGRect(origin: origin, size: size)))")
        print("        relative position preserved: (\(pct(relativeX)), \(pct(relativeY)))")
    }

    // MARK: - Formatting

    private static func parseDirection(_ raw: String) -> Direction? {
        switch raw.lowercased() {
        case "left":  return .left
        case "right": return .right
        case "up":    return .up
        case "down":  return .down
        default:      return nil
        }
    }

    private static func section(_ title: String) {
        print("")
        print("=== \(title) " + String(repeating: "=", count: max(0, 60 - title.count)))
    }

    private static func line(_ label: String, _ value: String) {
        print("  \(label)  \(value)")
    }

    private static func fmt(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)), \(Int(rect.minY)))  \(Int(rect.width))x\(Int(rect.height))"
    }

    private static func pct(_ value: CGFloat) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func pad(_ string: String, _ width: Int) -> String {
        string.count >= width ? String(string.prefix(width)) : string + String(repeating: " ", count: width - string.count)
    }

    private static func shorten(_ title: String) -> String {
        title.isEmpty ? "-" : title
    }
}
