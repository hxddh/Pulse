import AppKit

/// Host IDE / editor that owns an agent process (parent walk from `ps`).
///
/// Activation uses `NSWorkspace.open` / bundle-id activate on an explicit user
/// click — never a scan-time enumeration of every running application.
enum HostAppKind: String, Equatable, Hashable, CaseIterable {
    case cursor
    case vsCode
    case windsurf
    case zed
    case trae
    case antigravity
    case zcode

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vsCode: return "VS Code"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .trae: return "Trae"
        case .antigravity: return "Antigravity"
        case .zcode: return "ZCode"
        }
    }

    /// Path fragments seen in `ps` parent argv.
    var pathNeedles: [String] {
        switch self {
        case .cursor: return ["Cursor.app/"]
        case .vsCode: return [
            "Visual Studio Code.app/",
            "Code.app/Contents/MacOS/Electron",
            "Code - Insiders.app/",
        ]
        case .windsurf: return ["Windsurf.app/"]
        case .zed: return ["Zed.app/"]
        case .trae: return ["Trae.app/"]
        case .antigravity: return ["Antigravity.app/"]
        case .zcode: return ["ZCode.app/"]
        }
    }

    var appURLs: [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let names: [String]
        switch self {
        case .cursor: names = ["Cursor.app"]
        case .vsCode: names = ["Visual Studio Code.app", "Code.app", "Code - Insiders.app"]
        case .windsurf: names = ["Windsurf.app"]
        case .zed: names = ["Zed.app"]
        case .trae: names = ["Trae.app"]
        case .antigravity: names = ["Antigravity.app"]
        case .zcode: names = ["ZCode.app"]
        }
        var urls: [URL] = []
        for name in names {
            urls.append(URL(fileURLWithPath: "/Applications/\(name)"))
            urls.append(home.appendingPathComponent("Applications/\(name)"))
        }
        return urls
    }

    var bundleIDs: [String] {
        switch self {
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .vsCode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .windsurf: return ["com.exafunction.windsurf"]
        case .zed: return ["dev.zed.Zed"]
        case .trae: return ["com.bytedance.trae"]
        case .antigravity: return ["com.antigravity.app"]
        // Electron ADE — path/open -a is primary; bundle id is best-effort.
        case .zcode: return ["ai.z.zcode", "com.zhipuai.zcode"]
        }
    }
}

/// Best-effort: focus the terminal or host app tied to an agent's process.
enum TerminalFocus {
    /// Scan-time focus environment — no cross-app enumeration.
    ///
    /// `viaWarp` / `hostApp` evidence already comes from ProcessProbe's `ps`
    /// snapshot. TTY tab select is advertised only when the user opted into
    /// Automation; the click itself may prompt TCC once.
    struct Environment: Equatable {
        var warpRunning = false
        /// When true, a real tty string may resolve to `.tty` (opt-in only).
        var ttyHostRunning = false
        var allowTTYAutomation = false

        static func current(allowTTYAutomation: Bool = false) -> Environment {
            Environment(
                warpRunning: true,
                ttyHostRunning: allowTTYAutomation,
                allowTTYAutomation: allowTTYAutomation
            )
        }
    }

    @discardableResult
    static func focus(row: AgentRow) -> Bool {
        guard let tier = row.focusTier else { return false }

        switch tier {
        case .tty:
            return focusTTY(row.tty)
        case .warp:
            return activateWarp()
        case .hostWorkspace(let kind):
            return activateHost(kind, workspace: row.cwd)
        case .hostApp(let kind):
            return activateHost(kind, workspace: nil)
        }
    }

    /// Pure given an `Environment`, so it can be computed once per scan.
    ///
    /// Workspace advertising uses path shape only (absolute, non-trivial).
    /// Existence is verified at click time; missing folders fall back to app activate.
    static func focusTier(
        tty rawTTY: String,
        viaWarp: Bool,
        hostApp: HostAppKind? = nil,
        workspace: String = "",
        env: Environment
    ) -> FocusTier? {
        // Warp activation uses NSWorkspace and needs no Automation permission.
        // It is app-level only — never advertise tab precision.
        if viaWarp, env.warpRunning { return .warp }
        // Host IDE — prefer workspace open when cwd looks like a real absolute path.
        if let hostApp {
            if isAbsoluteWorkspacePath(workspace) {
                return .hostWorkspace(hostApp)
            }
            return .hostApp(hostApp)
        }
        // TTY tab select requires Apple Events. Advertise only after opt-in.
        let tty = normalizeTTY(rawTTY)
        if env.allowTTYAutomation, env.ttyHostRunning, !tty.isEmpty {
            return .tty
        }
        return nil
    }

    /// Absolute path that could be a workspace folder (pure shape check).
    static func isAbsoluteWorkspacePath(_ raw: String) -> Bool {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.hasPrefix("/"), p.count > 1 else { return false }
        if p == "/" || p == "/tmp" || p == "/private/tmp" { return false }
        return true
    }

    @discardableResult
    static func activateHost(_ kind: HostAppKind, workspace: String? = nil) -> Bool {
        if let workspace, isAbsoluteWorkspacePath(workspace) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: workspace, isDirectory: &isDir),
               isDir.boolValue,
               let app = kind.appURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
               openFolder(workspace, inApplicationAt: app) {
                return true
            }
        }
        // Prefer opening the app URL — no need to list every running app.
        if let app = kind.appURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            if NSWorkspace.shared.open(app) { return true }
        }
        // Narrow bundle-id lookup on an explicit user click only.
        for bid in kind.bundleIDs {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            if let app = running.first, app.activate() { return true }
        }
        return false
    }

    /// `open -a App.app /path` — no Automation TCC; lands on the folder in that host.
    private static func openFolder(_ path: String, inApplicationAt app: URL) -> Bool {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        t.arguments = ["-a", app.path, path]
        t.standardOutput = Pipe()
        t.standardError = Pipe()
        do {
            try t.run()
            t.waitUntilExit()
            return t.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func activateWarp() -> Bool {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/Warp.app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Warp.app"),
        ]
        if let app = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            if NSWorkspace.shared.open(app) { return true }
        }
        for bid in ["dev.warp.Warp-Stable", "dev.warp.Warp"] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
               app.activate() {
                return true
            }
        }
        return false
    }

    /// Terminal / iTerm tab select — only called after Automation opt-in + click.
    private static func focusTTY(_ raw: String) -> Bool {
        let tty = normalizeTTY(raw)
        guard !tty.isEmpty else { return false }
        if focusTerminalAppTTY(tty) { return true }
        if focusITermTTY(tty) { return true }
        return false
    }

    private static func normalizeTTY(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "?" || t == "??" || t == "-" { return "" }
        if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
        return t
    }

    private static func focusTerminalAppTTY(_ tty: String) -> Bool {
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              try
                set ttyName to (tty of t as text)
                if ttyName contains "\(escaped)" then
                  set selected of t to true
                  set frontmost of w to true
                  return true
                end if
              end try
            end repeat
          end repeat
        end tell
        return false
        """
        return osascriptBool(script)
    }

    private static func focusITermTTY(_ tty: String) -> Bool {
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
}

/// Reveal the app-owned panel directly.
///
/// This intentionally has no Accessibility or Apple Events fallback. The
/// shortcut and notification actions call the panel controller owned by this
/// process, so they cannot trigger an Automation permission prompt.
///
/// Prefer `StatusStore.requestTrayReveal(rowKey:)` when a concrete Waiting row
/// should be selected after open (Go-Look Closure).
enum TrayReveal {
    static func show() {
        Task { @MainActor in
            StatusPanelController.shared?.show()
        }
    }
}
