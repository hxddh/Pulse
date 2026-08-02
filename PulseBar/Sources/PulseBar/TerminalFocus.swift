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
                // Do not enumerate another app here. On current macOS
                // that cross-app inspection can trigger the privacy prompt
                // "Pulse would like to access data from other apps" on every
                // refresh. ProcessProbe already reads a bounded `ps` snapshot;
                // use the same non-TCC evidence for the optional Warp focus
                // tier.
                warpRunning: processSnapshotContainsWarp(),
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
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/Warp.app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Warp.app"),
        ]
        guard let app = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return false
        }
        // This is an explicit user action, and launching an app via
        // NSWorkspace does not require Apple Events access.
        return NSWorkspace.shared.open(app)
    }

    private static func processSnapshotContainsWarp() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "args="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.split(whereSeparator: \.isNewline).contains {
                String($0).localizedCaseInsensitiveContains("Warp.app")
            }
        } catch {
            return false
        }
    }

}

/// Reveal the app-owned panel directly.
///
/// This intentionally has no Accessibility or Apple Events fallback. The
/// shortcut and notification actions call the panel controller owned by this
/// process, so they cannot trigger an Automation permission prompt.
enum TrayReveal {
    static func show() {
        Task { @MainActor in
            StatusPanelController.shared?.show()
        }
    }
}
