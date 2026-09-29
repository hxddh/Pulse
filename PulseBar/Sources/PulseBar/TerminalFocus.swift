import AppKit

/// Best-effort: focus the terminal or host app tied to an agent's process.
enum TerminalFocus {
    /// Scan-time focus environment — no cross-app enumeration.
    ///
    /// `viaWarp` / `hostApp` evidence already comes from the process table
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
    ///
    /// `workspaceVerified` is the other half of that check, and the click-time
    /// one cannot stand in for it. A vendor directory named
    /// `-Users-me-my-project` decodes to both `/Users/me/my-project` and
    /// `/Users/me/my/project`; when the collector could not settle which one
    /// exists it hands the naive decode over for display only. Landing on it
    /// would pass an existence test and still open **the wrong workspace**
    /// under someone's hands — so an unverified path drops to app precision,
    /// which is honest about what it knows.
    static func focusTier(
        tty rawTTY: String,
        viaWarp: Bool,
        hostApp: HostAppKind? = nil,
        workspace: String = "",
        workspaceVerified: Bool = true,
        env: Environment
    ) -> FocusTier? {
        // Warp activation uses NSWorkspace and needs no Automation permission.
        // It is app-level only — never advertise tab precision.
        if viaWarp, env.warpRunning { return .warp }
        // Host IDE — prefer workspace open when cwd looks like a real absolute path.
        if let hostApp {
            if workspaceVerified, isAbsoluteWorkspacePath(workspace) {
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
    /// Focus runs on the main thread from a click, so this call needs a
    /// deadline: `open -a` normally returns immediately, but a host app that
    /// is slow to launch — or stuck behind its own dialog — would otherwise
    /// freeze the menu bar for as long as it likes.
    private static func openFolder(_ path: String, inApplicationAt app: URL) -> Bool {
        guard let result = ProcessIO.run(
            executable: "/usr/bin/open",
            arguments: ["-a", app.path, path],
            timeout: 5
        ) else { return false }
        return !result.timedOut && result.status == 0
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
    ///
    /// Only a terminal that is already running is asked: `tell application`
    /// launches an app that is not, so a click meant for iTerm used to open
    /// Terminal.app (and the other way round) just to search it for a tab it
    /// could not have. Each script activates its app only on a match.
    static func focusTTY(_ raw: String) -> Bool {
        let tty = normalizeTTY(raw)
        guard !tty.isEmpty else { return false }
        if isRunning(terminalBundleID), focusTerminalAppTTY(tty) { return true }
        if isRunning(iTermBundleID), focusITermTTY(tty) { return true }
        return false
    }

    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"
    /// A tab search that has not answered in this long will not; the click
    /// reports "not reached" instead of freezing the menu bar.
    static let focusScriptTimeout: TimeInterval = 5

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func normalizeTTY(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "?" || t == "??" || t == "-" { return "" }
        if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
        return t
    }

    private static func focusTerminalAppTTY(_ tty: String) -> Bool {
        osascriptBool(terminalTabScript(tty: tty), timeout: focusScriptTimeout)
    }

    private static func focusITermTTY(_ tty: String) -> Bool {
        osascriptBool(iTermTabScript(tty: tty), timeout: focusScriptTimeout)
    }

    /// The Terminal.app tab search. Internal so a test can hold the rule
    /// that `activate` runs only on a match.
    static func terminalTabScript(tty: String) -> String {
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                set ttyName to (tty of t as text)
                if ttyName contains "\(escaped)" then
                  set selected of t to true
                  set frontmost of w to true
                  activate
                  return true
                end if
              end try
            end repeat
          end repeat
        end tell
        return false
        """
    }

    /// The iTerm tab search; same rule.
    static func iTermTabScript(tty: String) -> String {
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "iTerm"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  set ttyName to (tty of s as text)
                  if ttyName contains "\(escaped)" then
                    select w
                    select t
                    activate
                    return true
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """
    }

    /// Internal since 4.0-β for the same reason as `focusTTY`.
    ///
    /// Bounded: `ProcessIO.run` drains both pipes and kills the child at the
    /// deadline, so a scripted app that never answers cannot hang the caller.
    /// The default is generous for callers that type text; the tab search
    /// passes `focusScriptTimeout`.
    static func osascriptBool(_ source: String, timeout: TimeInterval = 30) -> Bool {
        guard let result = ProcessIO.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source],
            timeout: timeout,
            outputLimit: 64 * 1024
        ), !result.timedOut, result.status == 0 else { return false }
        let text = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return text.contains("true")
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

    /// 23.0: the global shortcut — open closes, closed opens with the most
    /// urgent row selected.
    static func toggle() {
        Task { @MainActor in
            StatusPanelController.shared?.toggleFromHotkey()
        }
    }
}
