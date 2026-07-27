import ApplicationServices
import AppKit

/// Best-effort: focus the terminal tab tied to an agent's TTY / cwd / Warp parent.
enum TerminalFocus {
    private struct Candidate {
        var bundleIDs: [String]
        var appNames: [String]
    }

    private static let preferenceOrder: [Candidate] = [
        .init(bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"], appNames: ["Warp"]),
        .init(bundleIDs: ["com.apple.Terminal"], appNames: ["Terminal"]),
        .init(bundleIDs: ["com.googlecode.iterm2"], appNames: ["iTerm", "iTerm2"]),
        .init(bundleIDs: ["com.mitchellh.ghostty"], appNames: ["Ghostty"]),
        .init(bundleIDs: ["com.github.wez.wezterm"], appNames: ["WezTerm"]),
        .init(bundleIDs: ["org.alacritty"], appNames: ["Alacritty"]),
        .init(bundleIDs: ["net.kovidgoyal.kitty"], appNames: ["kitty"]),
    ]

    @discardableResult
    static func focus(row: AgentRow) -> Bool {
        guard let tier = focusTier(row: row) else { return false }

        switch tier {
        case .tty:
            let tty = normalizeTTY(row.tty)
            if focusTerminalAppTTY(tty) { return true }
            if focusITermTTY(tty) { return true }
            // Warp sessions often expose a TTY we cannot select — fall back honestly.
            if row.viaWarp, activateWarp() { return true }
            return openCwdIfPossible(row)
        case .warp:
            return activateWarp()
        case .openCwd:
            return openCwdIfPossible(row)
        }
    }

    static func focusTier(row: AgentRow) -> FocusTier? {
        let tty = normalizeTTY(row.tty)
        let warpUp = isRunning(bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"], names: ["Warp"])
        // Prefer Warp when the process is under Warp — TTY tab select only works for Terminal/iTerm.
        if row.viaWarp, warpUp { return .warp }
        if !tty.isEmpty, ttyFocusHostRunning() { return .tty }
        // TTY known but no Terminal/iTerm: still offer open cwd rather than a dead Focus button.
        if !tty.isEmpty, openCwdPossible(row) { return .openCwd }
        if row.viaWarp, warpUp { return .warp }
        if openCwdPossible(row) { return .openCwd }
        return nil
    }

    private static func ttyFocusHostRunning() -> Bool {
        isRunning(bundleIDs: ["com.apple.Terminal"], names: ["Terminal"])
            || isRunning(bundleIDs: ["com.googlecode.iterm2"], names: ["iTerm", "iTerm2"])
    }

    private static func activateWarp() -> Bool {
        activate(bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"], names: ["Warp"])
    }

    private static func openCwdPossible(_ row: AgentRow) -> Bool {
        let path = row.cwd
        return !path.isEmpty && FileManager.default.fileExists(atPath: path) && hasInstalledTerminal()
    }

    private static func openCwdIfPossible(_ row: AgentRow) -> Bool {
        let path = row.cwd
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return false }
        return openInTerminalApp(path: path)
    }

    static func canFocus(row: AgentRow) -> Bool {
        focusTier(row: row) != nil
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

    private static func hasInstalledTerminal() -> Bool {
        preferenceOrder.contains { cand in
            cand.bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
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

    private static func openInTerminalApp(path: String) -> Bool {
        let folder = URL(fileURLWithPath: path)
        for cand in preferenceOrder {
            for bid in cand.bundleIDs {
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { continue }
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: config)
                return true
            }
            for name in cand.appNames {
                let t = Process()
                t.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                t.arguments = ["-a", name, path]
                let out = Pipe()
                let err = Pipe()
                t.standardOutput = out
                t.standardError = err
                do {
                    try t.run()
                    _ = out.fileHandleForReading.readDataToEndOfFile()
                    _ = err.fileHandleForReading.readDataToEndOfFile()
                    t.waitUntilExit()
                    if t.terminationStatus == 0 { return true }
                } catch {
                    continue
                }
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
