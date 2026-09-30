import Foundation
import PulseHarvest

/// Where a session can be reached, read from the v5 `landing` column
/// (`HookLanding.handles`): `tmux:%3;tmuxsock:<path>;iterm:w0t1p0:<uuid>;
/// tty:/dev/ttys004;term:<TERM_PROGRAM>;app:<bundle id>`.
struct LandingHandle: Hashable, Sendable {
    /// `TMUX_PANE`, e.g. `%3`.
    var tmuxPane = ""
    /// The tmux server socket (`TMUX` up to its first comma).
    var tmuxSocket = ""
    /// `ITERM_SESSION_ID` as the shell saw it (`w0t1p0:<uuid>`).
    var itermSession = ""
    /// `ttys004`, without `/dev/`.
    var tty = ""
    /// `TERM_PROGRAM` (`Apple_Terminal`, `iTerm.app`, `ghostty`, `vscode`…).
    var term = ""
    /// `__CFBundleIdentifier` — the app the shell was launched from.
    var app = ""

    var isEmpty: Bool { self == LandingHandle() }

    /// The part of `ITERM_SESSION_ID` iTerm's AppleScript calls `unique id`.
    var itermUniqueID: String {
        guard let colon = itermSession.firstIndex(of: ":") else { return itermSession }
        return String(itermSession[itermSession.index(after: colon)...])
    }
}

extension LandingHandle {
    init(_ raw: String) {
        self.init()
        for part in raw.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard let colon = item.firstIndex(of: ":") else { continue }
            let key = item[..<colon]
            let value = String(item[item.index(after: colon)...])
            guard !value.isEmpty else { continue }
            switch key {
            case "tmux": if tmuxPane.isEmpty { tmuxPane = value }
            case "tmuxsock": if tmuxSocket.isEmpty { tmuxSocket = value }
            case "iterm": if itermSession.isEmpty { itermSession = value }
            case "tty": if tty.isEmpty { tty = Self.normalizeTTY(value) }
            case "term": if term.isEmpty { term = value }
            case "app": if app.isEmpty { app = value }
            default: continue
            }
        }
    }

    /// `/dev/ttys004` → `ttys004`; placeholders (`?`, `??`, `-`) → "".
    static func normalizeTTY(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "?" || t == "??" || t == "-" { return "" }
        if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
        return t
    }
}

/// One way to reach a session. `TerminalFocus.land` runs them.
enum LandingStep: Hashable, Sendable {
    /// Select the pane in tmux (`switch-client` / `select-window` /
    /// `select-pane`), then bring forward the app that hosts its client —
    /// found from the client's pid, else `hostBundleIDs`. No Automation.
    case tmuxPane(pane: String, socket: String, hostBundleIDs: [String])
    /// iTerm2's session whose `unique id` matches (Automation opt-in).
    case iTermSession(uniqueID: String)
    /// Terminal.app / iTerm tab whose tty matches (Automation opt-in).
    case ttyTab(tty: String)
    /// `open -b <bundle> <folder>` — an editor host opened on the session's
    /// folder. App precision: the editor cannot be told which terminal.
    case openFolder(bundleIDs: [String], path: String)
    /// Bring a running app forward by bundle id.
    case activateApp(bundleIDs: [String])
    /// Bring forward the regular app that owns this process (its parent chain).
    case activateOwner(pid: Int32)

    var precision: LandingPlan.Precision {
        switch self {
        case .tmuxPane, .iTermSession, .ttyTab: return .exact
        case .openFolder, .activateApp, .activateOwner: return .app
        }
    }
}

/// How a click lands, decided once per projection and never in a view:
/// steps in order, the first that succeeds wins, and its precision is what
/// the click reports. Pure.
struct LandingPlan: Hashable, Sendable {
    enum Precision: Hashable, Sendable {
        /// The exact pane, session or tab.
        case exact
        /// The app (or its folder) — never the exact terminal.
        case app
    }

    var steps: [LandingStep] = []

    /// What the plan promises at best; nil when there is nothing to click.
    var precision: Precision? { steps.first?.precision }

    var isEmpty: Bool { steps.isEmpty }

    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"

    /// `TERM_PROGRAM` (lowercased) → the app that sets it.
    static let termPrograms: [String: [String]] = [
        "apple_terminal": [terminalBundleID],
        "iterm.app": [iTermBundleID],
        "ghostty": ["com.mitchellh.ghostty"],
        "wezterm": ["com.github.wez.wezterm"],
        "kitty": ["net.kovidgoyal.kitty"],
        "warpterminal": ["dev.warp.Warp-Stable", "dev.warp.Warp"],
        "vscode": HostAppKind.vsCode.bundleIDs,
        "zed": HostAppKind.zed.bundleIDs,
    ]

    /// - Parameters:
    ///   - handle: the session's landing handle (or, for a process-only row,
    ///     what the process table knows).
    ///   - cwd: the session's folder, opened in an editor host.
    ///   - allowAutomation: `PulseSettings.allowTerminalAutomation`. Gates every
    ///     AppleScript step (iTerm session, Terminal/iTerm tab); tmux and app
    ///     activation never need it.
    ///   - pid: a live agent process, for the owner-app fallback; 0 none.
    ///   - hostApp: the editor the process table found on the parent chain.
    static func make(
        handle: LandingHandle,
        cwd: String,
        allowAutomation: Bool,
        pid: Int32 = 0,
        hostApp: HostAppKind? = nil
    ) -> LandingPlan {
        var steps: [LandingStep] = []
        let term = handle.term.lowercased()
        let editorHost = editor(handle: handle, hostApp: hostApp)
        let hostBundles = editorHost?.bundleIDs ?? hostBundleIDs(handle: handle)

        if !handle.tmuxPane.isEmpty {
            // Inside tmux the tty is the pane's, and `ITERM_SESSION_ID` /
            // `TERM_PROGRAM` may be the tmux server's: the pane is the handle.
            steps.append(.tmuxPane(pane: handle.tmuxPane, socket: handle.tmuxSocket, hostBundleIDs: hostBundles))
        } else if allowAutomation {
            let iTermHost = term.isEmpty || term == "iterm.app"
            if iTermHost, !handle.itermUniqueID.isEmpty {
                steps.append(.iTermSession(uniqueID: handle.itermUniqueID))
            }
            // The tab search asks only Terminal and iTerm; another terminal's
            // tty would prompt for Automation and find nothing.
            let tabHost = editorHost == nil
                && (hostBundles.isEmpty || hostBundles.contains(terminalBundleID) || hostBundles.contains(iTermBundleID))
            if tabHost, !handle.tty.isEmpty {
                steps.append(.ttyTab(tty: handle.tty))
            }
        }

        if let editorHost, isAbsoluteWorkspacePath(cwd) {
            steps.append(.openFolder(bundleIDs: editorHost.bundleIDs, path: cwd))
        }
        if !hostBundles.isEmpty {
            steps.append(.activateApp(bundleIDs: hostBundles))
        }
        if pid > 1 {
            steps.append(.activateOwner(pid: pid))
        }
        return LandingPlan(steps: steps)
    }

    /// The editor host: a bundle id the catalog of hosts knows, else
    /// `TERM_PROGRAM` (`vscode` is also what Cursor and Windsurf say, so the
    /// bundle id refines it), else the process table's parent walk.
    static func editor(handle: LandingHandle, hostApp: HostAppKind?) -> HostAppKind? {
        let term = handle.term.lowercased()
        let fromApp = HostAppKind.allCases.first { $0.bundleIDs.contains(handle.app) }
        switch term {
        case "vscode": return fromApp ?? hostApp ?? .vsCode
        case "zed": return .zed
        case "", "tmux": return fromApp ?? hostApp
        default: return nil
        }
    }

    /// The terminal app: `TERM_PROGRAM` first (the terminal sets it itself),
    /// else the launching app's bundle id.
    static func hostBundleIDs(handle: LandingHandle) -> [String] {
        if let known = termPrograms[handle.term.lowercased()] { return known }
        return handle.app.isEmpty ? [] : [handle.app]
    }

    /// Absolute path that could be a workspace folder (pure shape check).
    static func isAbsoluteWorkspacePath(_ raw: String) -> Bool {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.hasPrefix("/"), p.count > 1 else { return false }
        if p == "/" || p == "/tmp" || p == "/private/tmp" { return false }
        return true
    }

    /// The tmux commands for one pane, as one argv (`;` separates commands).
    static func tmuxArguments(pane: String, socket: String) -> [String] {
        var args: [String] = socket.isEmpty ? [] : ["-S", socket]
        args += [
            "switch-client", "-t", pane, ";",
            "select-window", "-t", pane, ";",
            "select-pane", "-t", pane, ";",
            "display-message", "-p", "-t", pane, "#{session_id}",
        ]
        return args
    }
}

/// What a click did — reported on the row, never rounded up.
enum LandingOutcome: Equatable, Sendable {
    case exact
    case appOnly
    case failed
}
