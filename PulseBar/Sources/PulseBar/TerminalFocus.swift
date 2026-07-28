import ApplicationServices
import AppKit

/// Best-effort: focus the terminal surface tied to an agent's TTY / Warp parent.
enum TerminalFocus {
    /// Which terminals exist / are running right now.
    ///
    /// Resolving this per row inside a SwiftUI body meant enumerating every
    /// running application and stat-ing the filesystem on each redraw. It is
    /// captured once per scan instead and stored on the row.
    struct Environment: Equatable {
        var warpRunning = false
        var ttyHostRunning = false

        static func current() -> Environment {
            Environment(
                warpRunning: isRunning(bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"], names: ["Warp"]),
                // Selecting a Terminal/iTerm tab requires Apple Events and
                // causes macOS Automation permission dialogs. Pulse never asks
                // for that permission implicitly, so TTY focus is unavailable.
                ttyHostRunning: false
            )
        }
    }

    @discardableResult
    static func focus(row: AgentRow) -> Bool {
        guard let tier = row.focusTier else { return false }

        switch tier {
        case .tty:
            // Kept for decoding older in-memory/test rows. Runtime resolution
            // no longer creates this tier because selecting a Terminal/iTerm
            // tab would require a surprise Automation permission request.
            return false
        case .warp:
            return activateWarp()
        }
    }

    /// Pure given an `Environment`, so it can be computed once per scan (and
    /// unit-tested) instead of once per redraw.
    static func focusTier(
        tty rawTTY: String,
        viaWarp: Bool,
        env: Environment
    ) -> FocusTier? {
        // Warp activation uses NSWorkspace and needs no Automation permission.
        if viaWarp, env.warpRunning { return .warp }
        // A TTY is diagnostic evidence, but selecting that tab in
        // Terminal/iTerm requires Apple Events. Do not advertise an action that
        // would make macOS ask for permission when clicked.
        _ = rawTTY
        return nil
    }

    private static func activateWarp() -> Bool {
        activate(bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"], names: ["Warp"])
    }

    private static func isRunning(bundleIDs: [String], names: [String]) -> Bool {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let bid = app.bundleIdentifier, bundleIDs.contains(bid) { return true }
            if let name = app.localizedName,
               names.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                return true
            }
        }
        return false
    }

    private static func activate(bundleIDs: [String], names: [String]) -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier, bundleIDs.contains(bid) {
                return app.activate()
            }
            if let name = app.localizedName,
               names.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                return app.activate()
            }
        }
        return false
    }

}

/// Reveal the app's own MenuBarExtra panel through its accessibility element.
///
/// Do not fall back to System Events / Apple Events here. That path asks macOS
/// for Automation or Accessibility permission merely because the user pressed
/// Pulse's shortcut or clicked a notification, and repeated retries can become
/// a stream of permission dialogs. If the app-owned status item is not
/// available, fail quietly and let the user click it normally.
enum TrayReveal {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            clickStatusItem()
        }
    }

    private static func clickStatusItem() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        var extras: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
           let extrasBar = extras {
            var items: CFTypeRef?
            if AXUIElementCopyAttributeValue(extrasBar as! AXUIElement, kAXChildrenAttribute as CFString, &items) == .success,
               let arr = items as? [AXUIElement],
               let first = arr.first {
                AXUIElementPerformAction(first, kAXPressAction as CFString)
                return
            }
        }
        DebugLog.write("tray reveal unavailable — no app-owned status item")
    }
}
