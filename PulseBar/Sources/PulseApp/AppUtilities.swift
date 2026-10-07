// Standalone utility types — never part of the store.

import Foundation
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
}
