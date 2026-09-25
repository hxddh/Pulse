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
