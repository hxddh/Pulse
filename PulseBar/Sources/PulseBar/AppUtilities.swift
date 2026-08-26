// 3.0-α: standalone utility types moved verbatim out of StatusStore.swift
// — they were never part of the store, just parked at the bottom of its
// file.

import Foundation
import AppKit
import CryptoKit

enum TokenScope {
    case compact, reported, latestCall

    var both: L10n.Key {
        switch self {
        case .compact: return .compactTokens
        case .reported: return .reportedTokens
        case .latestCall: return .latestCallTokens
        }
    }

    var inputOnly: L10n.Key {
        switch self {
        case .compact: return .compactTokensIn
        case .reported: return .reportedTokensIn
        case .latestCall: return .latestCallTokensIn
        }
    }

    var outputOnly: L10n.Key {
        switch self {
        case .compact: return .compactTokensOut
        case .reported: return .reportedTokensOut
        case .latestCall: return .latestCallTokensOut
        }
    }
}

enum DebugLog {
    static let path: URL = {
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
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static var bytesWritten: UInt64 = 0
    private static var sizeKnown = false

    /// A row key without the project name.
    ///
    /// `ActivityHarvest.sessionKey` falls back to the workspace leaf when an
    /// agent has no session id, so `claude|Pulse` — a directory name off the
    /// user's disk — was landing in a log file that support reports quote. The
    /// agent stays readable and the tail becomes a stable digest, so lines
    /// about the same row still correlate across a whole log.
    static func key(_ rowKey: String) -> String {
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

    static func write(_ message: String) {
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

enum LoginItem {
    static let label = "com.pulse.app"

    /// Whether launchd currently knows the agent. `launchctl list <label>`
    /// exits non-zero when it does not.
    static func isRegistered() -> Bool {
        shell("/bin/launchctl", ["list", label]) == 0
    }

    /// Returns whether launchd ended up in the state the user asked for.
    ///
    /// Both `launchctl` calls used to be discarded with `_ =`, so the toggle
    /// reported success whether or not anything was registered — the same
    /// "claimed done, never verified" shape this project keeps having to undo.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let label = Self.label
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        if enabled {
            var appPath = Bundle.main.bundleURL.path
            if !appPath.hasSuffix(".app") {
                appPath = Bundle.main.executableURL?.path
                    ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PulseBar").path
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                  <key>Label</key><string>\(label)</string>
                  <key>ProgramArguments</key><array><string>\(appPath)</string></array>
                  <key>RunAtLoad</key><true/>
                </dict></plist>
                """
                try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? xml.write(to: plist, atomically: true, encoding: .utf8)
            } else {
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                  <key>Label</key><string>\(label)</string>
                  <key>ProgramArguments</key><array>
                    <string>/usr/bin/open</string>
                    <string>-a</string>
                    <string>\(appPath)</string>
                  </array>
                  <key>RunAtLoad</key><true/>
                </dict></plist>
                """
                try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? xml.write(to: plist, atomically: true, encoding: .utf8)
            }
            _ = shell("/bin/launchctl", ["unload", "-w", plist.path])
            _ = shell("/bin/launchctl", ["load", "-w", plist.path])
        } else {
            _ = shell("/bin/launchctl", ["unload", "-w", plist.path])
            try? FileManager.default.removeItem(at: plist)
        }
        let applied = isRegistered() == enabled
        DebugLog.write("loginItem enabled=\(enabled) applied=\(applied)")
        return applied
    }

    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        guard let result = ProcessIO.run(
            executable: path,
            arguments: args,
            timeout: 4.0
        ), !result.timedOut else {
            return -1
        }
        return result.status
    }
}
