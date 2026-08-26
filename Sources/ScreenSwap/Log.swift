import Foundation

/// Debug logging, shared by everything that needs it.
///
/// Enable with SCREENSWAP_DEBUG=1 or `open ScreenSwap.app --args --debug`. Output
/// goes to ~/Library/Logs/ScreenSwap.log, because stderr is discarded when
/// LaunchServices starts the bundle.
enum Log {

    static let isEnabled = ProcessInfo.processInfo.environment["SCREENSWAP_DEBUG"] == "1"
        || CommandLine.arguments.contains("--debug")

    private static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Logs") ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("ScreenSwap.log")
    }()

    static func debug(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }
}
