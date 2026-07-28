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
                ttyHostRunning: ttyFocusHostRunning()
            )
        }
    }

    @discardableResult
    static func focus(row: AgentRow) -> Bool {
        guard let tier = row.focusTier else { return false }

        switch tier {
        case .tty:
            let tty = normalizeTTY(row.tty)
            if focusTerminalAppTTY(tty) { return true }
            if focusITermTTY(tty) { return true }
            // Warp sessions often expose a TTY Terminal/iTerm cannot select.
            if row.viaWarp, activateWarp() { return true }
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
        let tty = normalizeTTY(rawTTY)
        // Prefer Warp when the process is under Warp — TTY tab select only works for Terminal/iTerm.
        if viaWarp, env.warpRunning { return .warp }
        if !tty.isEmpty, env.ttyHostRunning { return .tty }
        return nil
    }

    private static func ttyFocusHostRunning() -> Bool {
        isRunning(bundleIDs: ["com.apple.Terminal"], names: ["Terminal"])
            || isRunning(bundleIDs: ["com.googlecode.iterm2"], names: ["iTerm", "iTerm2"])
    }

    private static func activateWarp() -> Bool {
        activate(bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"], names: ["Warp"])
    }

    private static func normalizeTTY(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "?" || t == "??" || t == "-" { return "" }
        if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
        return t
    }

    /// Terminal.app — select tab whose tty matches.
    private static func focusTerminalAppTTY(_ tty: String) -> Bool {
        guard isRunning(bundleIDs: ["com.apple.Terminal"], names: ["Terminal"]) else { return false }
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
          activate
          repeat with w in windows
            set tabIndex to 1
            repeat with t in tabs of w
              try
                set ttyName to (tty of t as text)
                if ttyName contains "\(escaped)" then
                  set selected of t to true
                  set frontmost of w to true
                  return true
                end if
              end try
              set tabIndex to tabIndex + 1
            end repeat
          end repeat
        end tell
        return false
        """
        return osascriptBool(script)
    }

    /// iTerm2 — select session whose tty matches.
    private static func focusITermTTY(_ tty: String) -> Bool {
        guard isRunning(bundleIDs: ["com.googlecode.iterm2"], names: ["iTerm", "iTerm2"]) else { return false }
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  set ttyName to (tty of s as text)
                  if ttyName contains "\(escaped)" then
                    select t
                    tell w to select t
                    return true
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """
        return osascriptBool(script)
    }

    private static func osascriptBool(_ source: String) -> Bool {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        t.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        t.standardOutput = out
        t.standardError = err
        do {
            try t.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            t.waitUntilExit()
            guard t.terminationStatus == 0 else { return false }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return text.contains("true")
        } catch {
            return false
        }
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

/// Reveal the MenuBarExtra panel (Accessibility / System Events fallback).
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
        clickViaSystemEvents()
    }

    private static func clickViaSystemEvents() {
        let script = """
        tell application "System Events"
          tell process "PulseBar"
            try
              click menu bar item 1 of menu bar 2
            end try
          end tell
        end tell
        """
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        t.arguments = ["-e", script]
        t.standardOutput = Pipe()
        t.standardError = Pipe()
        try? t.run()
    }
}
