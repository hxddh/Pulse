// Standalone utility types — never part of the store.

import Foundation
import AppKit
import CryptoKit
import ServiceManagement

/// Pulse's login item: `SMAppService.mainApp`, the system's own — listed in
/// System Settings → General → Login Items, where the person can see and
/// remove it. macOS is the truth; the store shows its answer
/// (`LoginItemState`).
enum LoginItem {
    /// What macOS says now.
    static var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Ask macOS to open Pulse at login (or not), and return what it then
    /// says — never what was asked: a register that did not take reads off.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> LoginItemState {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if state.isOn {
                // Off, or never found: nothing to unregister.
                try SMAppService.mainApp.unregister()
            }
        } catch {
            DebugLog.write("loginItem \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        let now = state
        DebugLog.write("loginItem enabled=\(enabled) status=\(now.rawValue)")
        return now
    }

    /// System Settings → Login Items, where a login item waiting for
    /// approval is approved.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - The LaunchAgent earlier versions wrote

    /// The label earlier versions gave their LaunchAgent.
    static let legacyLabel = "com.pulse.app"

    static func legacyAgentURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    /// Whether a LaunchAgent plist is the one Pulse wrote: its label is
    /// Pulse's and it launches Pulse (`PulseBar`, or `open -a …Pulse.app`).
    /// Anything else at that path is not Pulse's to remove. Pure.
    static func isPulsesOwnAgent(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == legacyLabel,
              let arguments = plist["ProgramArguments"] as? [String], !arguments.isEmpty
        else { return false }
        return arguments.contains { $0.hasSuffix("/PulseBar") || $0.hasSuffix("Pulse.app") }
    }

    /// Whether the LaunchAgent an earlier version wrote is there and is
    /// Pulse's own — the person had turned "Open at login" on.
    static func hasLegacyAgent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let url = legacyAgentURL(home: home)
        guard let data = SafeRead.regularFile(atPath: url.path, limit: 64 * 1024) else { return false }
        return isPulsesOwnAgent(data)
    }

    /// Unload and delete the LaunchAgent an earlier version wrote, when it
    /// is there and is Pulse's own. Called only once macOS has taken the
    /// login item in its place (`LoginAdoption`), so the person's choice is
    /// never lost. Returns whether it was removed.
    @discardableResult
    static func retireLegacyAgent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let url = legacyAgentURL(home: home)
        guard hasLegacyAgent(home: home) else { return false }
        _ = shell("/bin/launchctl", ["unload", url.path])
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            DebugLog.write("loginItem legacy agent not removed: \(error.localizedDescription)")
            return false
        }
        DebugLog.write("loginItem retired the legacy LaunchAgent")
        return true
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
