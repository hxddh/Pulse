import CryptoKit
import Foundation

/// The debug log (`~/Library/Application Support/Pulse/debug.log`).
///
/// 12.3: moved into PulseCore so the harvest and respond libraries can log
/// without reaching back into the app. Every write holds one lock.
public enum DebugLog {
    public static let path: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/debug.log")
    }()
    private static var previousPath: URL {
        path.deletingLastPathComponent().appendingPathComponent("debug.log.1")
    }
    /// Pulse writes ~5 lines every probe tick; without a cap the log grows
    /// unbounded (tens of MB per day). Roll at 2 MB, keep one generation.
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let lock = NSLock()
    // Only touched under `lock`.
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static var bytesWritten: UInt64 = 0
    nonisolated(unsafe) private static var sizeKnown = false

    /// A row key without the project name.
    ///
    /// `ActivityHarvest.sessionKey` falls back to the workspace leaf when an
    /// agent has no session id, so `claude|Pulse` — a directory name off the
    /// user's disk — was landing in a log file that support reports quote. The
    /// agent stays readable and the tail becomes a stable digest, so lines
    /// about the same row still correlate across a whole log.
    public static func key(_ rowKey: String) -> String {
        guard let split = rowKey.firstIndex(of: "|") else { return rowKey }
        let agent = rowKey[..<split]
        let tail = rowKey[rowKey.index(after: split)...]
        guard !tail.isEmpty else { return rowKey }
        let digest = SHA256.hash(data: Data(tail.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(agent)|\(digest)"
    }

    public static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if !sizeKnown {
            let attrs = try? fm.attributesOfItem(atPath: path.path)
            bytesWritten = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            sizeKnown = true
        }

        let line = "\(stamp.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if bytesWritten + UInt64(data.count) > maxBytes, fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: previousPath)
            try? fm.moveItem(at: path, to: previousPath)
            bytesWritten = 0
        }

        if fm.fileExists(atPath: path.path),
           let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: path, options: .atomic)
        }
        bytesWritten += UInt64(data.count)
    }
}
