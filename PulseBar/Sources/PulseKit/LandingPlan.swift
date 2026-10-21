import Foundation

/// Where a session can be reached, read from the `landing` column
/// (`HookLanding.handles`): `detached:1;tmux:%3;tmuxsock:<path>;
/// zellij:<pane>;zellijsession:<name>;wezterm:<pane>;weztermsock:<path>;kitty:<window>;kittysock:unix:<path>;
/// iterm:w0t1p0:<uuid>;tty:/dev/ttys004;term:<TERM_PROGRAM>;
/// app:<bundle id>;host:<HostAppKind | other>`. An unknown key is ignored.
package struct LandingHandle: Hashable, Sendable {
    /// `TMUX_PANE`, e.g. `%3`.
    package var tmuxPane = ""
    /// The tmux server socket (`TMUX` up to its first comma).
    package var tmuxSocket = ""
    /// `ZELLIJ_PANE_ID`, e.g. `2`.
    package var zellijPane = ""
    /// `ZELLIJ_SESSION_NAME`.
    package var zellijSession = ""
    /// `WEZTERM_PANE`, e.g. `3`.
    package var weztermPane = ""
    /// `WEZTERM_UNIX_SOCKET`: the GUI instance that owns the pane.
    package var weztermSocket = ""
    /// `KITTY_WINDOW_ID`, e.g. `5`.
    package var kittyWindow = ""
    /// `KITTY_LISTEN_ON` (`unix:/tmp/kitty-501`): set only when kitty's
    /// remote control listens.
    package var kittyListenOn = ""
    /// `ITERM_SESSION_ID` as the shell saw it (`w0t1p0:<uuid>`).
    package var itermSession = ""
    /// `ttys004`, without `/dev/`.
    package var tty = ""
    /// `TERM_PROGRAM` (`Apple_Terminal`, `iTerm.app`, `ghostty`, `vscode`…).
    package var term = ""
    /// `__CFBundleIdentifier` — the app the shell was launched from.
    package var app = ""
    /// The app on the hook's parent chain: a `HostAppKind` raw value, or
    /// `otherHost` for an app bundle no host names.
    package var host = ""
    /// No process on the hook's chain had a terminal: a service, a daemon
    /// or an app runs the session (`HookLanding.handles`).
    package var detached = false

    /// `host:` for an app bundle that is no `HostAppKind`.
    package static let otherHost = "other"

    package var isEmpty: Bool { self == LandingHandle() }

    /// The part of `ITERM_SESSION_ID` iTerm's AppleScript calls `unique id`.
    package var itermUniqueID: String {
        guard let colon = itermSession.firstIndex(of: ":") else { return itermSession }
        return String(itermSession[itermSession.index(after: colon)...])
    }

    /// The known host the hook's chain runs in.
    package var hostKind: HostAppKind? { HostAppKind(rawValue: host) }
}

extension LandingHandle {
    package init(_ raw: String) {
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
            case "zellij": if zellijPane.isEmpty { zellijPane = value }
            case "zellijsession": if zellijSession.isEmpty { zellijSession = value }
            case "wezterm": if weztermPane.isEmpty { weztermPane = value }
            case "weztermsock": if weztermSocket.isEmpty { weztermSocket = value }
            case "kitty": if kittyWindow.isEmpty { kittyWindow = value }
            case "kittysock": if kittyListenOn.isEmpty { kittyListenOn = value }
            case "iterm": if itermSession.isEmpty { itermSession = value }
            case "tty": if tty.isEmpty { tty = Self.normalizeTTY(value) }
            case "term": if term.isEmpty { term = value }
            case "app": if app.isEmpty { app = value }
            case "host": if host.isEmpty { host = value }
            case "detached": detached = detached || value == "1"
            default: continue
            }
        }
    }

    /// `/dev/ttys004` → `ttys004`; placeholders (`?`, `??`, `-`) → "".
    package static func normalizeTTY(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "?" || t == "??" || t == "-" { return "" }
        if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
        return t
    }
}

/// One way to reach a session. `TerminalFocus.land` runs them.
package enum LandingStep: Hashable, Sendable {
    /// Select the pane in tmux (`switch-client` / `select-window` /
    /// `select-pane`), then bring forward the app that hosts its client —
    /// found from the client's pid, else `hostBundleIDs`. No Automation.
    case tmuxPane(pane: String, socket: String, hostBundleIDs: [String])
    /// Focus the pane in its Zellij session (`zellij --session <name>
    /// action focus-pane-id <N>`, Zellij 0.44.1+), then bring forward the
    /// terminal app (`hostBundleIDs`) — the pane focused with no app in
    /// front is no landing. No Automation.
    case zellijPane(session: String, pane: String, hostBundleIDs: [String])
    /// `wezterm cli activate-pane` with the CLI inside the running
    /// WezTerm.app, then bring WezTerm forward. No Automation.
    case weztermPane(pane: String, socket: String)
    /// `kitten @ --to <listen_on> focus-window --match id:N` with the CLI
    /// inside the running kitty.app, then bring kitty forward. Planned only
    /// when kitty's remote control listens on a unix socket.
    case kittyWindow(window: String, listenOn: String)
    /// iTerm2's session whose `unique id` matches (AppleScript: macOS asks
    /// its own Automation question the first time).
    case iTermSession(uniqueID: String)
    /// Terminal.app / iTerm tab whose tty matches (AppleScript, likewise).
    case ttyTab(tty: String)
    /// `open -b <bundle> <folder>` — an editor host opened on the session's
    /// folder. App precision: the editor cannot be told which terminal.
    case openFolder(bundleIDs: [String], path: String)
    /// Bring a running app forward by bundle id.
    case activateApp(bundleIDs: [String])
    /// Bring forward the regular app that owns this process (its parent chain).
    case activateOwner(pid: Int32)

    package var precision: LandingPlan.Precision {
        switch self {
        case .tmuxPane, .zellijPane, .weztermPane, .kittyWindow, .iTermSession, .ttyTab: return .exact
        case .openFolder, .activateApp, .activateOwner: return .app
        }
    }
}

/// How a click lands, decided once per projection and never in a view:
/// steps in order, the first that succeeds wins, and its precision is what
/// the click reports. Pure.
package struct LandingPlan: Hashable, Sendable {
    package enum Precision: Hashable, Sendable {
        /// The exact pane, session or tab.
        case exact
        /// The app (or its folder) — never the exact terminal.
        case app
    }

    package var steps: [LandingStep] = []

    /// What the plan promises at best; nil when there is nothing to click.
    package var precision: Precision? { steps.first?.precision }

    package var isEmpty: Bool { steps.isEmpty }

    package static let terminalBundleID = "com.apple.Terminal"
    package static let iTermBundleID = "com.googlecode.iterm2"
    package static let weztermBundleID = "com.github.wez.wezterm"
    package static let kittyBundleID = "net.kovidgoyal.kitty"

    /// `TERM_PROGRAM` (lowercased) → the app that sets it. Ghostty and Warp
    /// have no interface that selects a tab or pane from outside: their
    /// sessions land on the app.
    package static let termPrograms: [String: [String]] = [
        "apple_terminal": [terminalBundleID],
        "iterm.app": [iTermBundleID],
        "ghostty": ["com.mitchellh.ghostty"],
        "wezterm": [weztermBundleID],
        "kitty": [kittyBundleID],
        "warpterminal": ["dev.warp.Warp-Stable", "dev.warp.Warp"],
        "vscode": HostAppKind.vsCode.bundleIDs,
        "zed": HostAppKind.zed.bundleIDs,
    ]

    /// - Parameters:
    ///   - handle: the session's landing handle (or, for a process-only row,
    ///     what the process table knows).
    ///   - cwd: the session's folder, opened in an editor host.
    ///   - pid: a live agent process, for the owner-app fallback; 0 none.
    ///   - hostApp: the host the process table found on the parent chain.
    package static func make(
        handle: LandingHandle,
        cwd: String,
        pid: Int32 = 0,
        hostApp: HostAppKind? = nil
    ) -> LandingPlan {
        if handle.detached {
            return detached(handle: handle, cwd: cwd, pid: pid, hostApp: hostApp)
        }
        var steps: [LandingStep] = []
        let term = handle.term.lowercased()
        let editorHost = editor(handle: handle, hostApp: hostApp)
        let hostBundles = editorHost?.bundleIDs ?? hostBundleIDs(handle: handle)

        if !handle.tmuxPane.isEmpty {
            // Inside tmux the tty is the pane's, and `ITERM_SESSION_ID` /
            // `TERM_PROGRAM` may be the tmux server's: the pane is the handle.
            steps.append(.tmuxPane(pane: handle.tmuxPane, socket: handle.tmuxSocket, hostBundleIDs: hostBundles))
        } else if isNumericID(handle.zellijPane), isZellijSession(handle.zellijSession) {
            // Inside Zellij the tty is the pane's too: the pane is the
            // handle, and the terminal is what `TERM_PROGRAM` / `app:` say.
            if !hostBundles.isEmpty {
                steps.append(.zellijPane(session: handle.zellijSession, pane: handle.zellijPane, hostBundleIDs: hostBundles))
            }
        } else {
            // A pane id is the terminal's own only while that terminal is
            // the one `TERM_PROGRAM` names (or nothing does).
            if term.isEmpty || term == "wezterm", isNumericID(handle.weztermPane) {
                let socket = handle.weztermSocket.hasPrefix("/") ? handle.weztermSocket : ""
                steps.append(.weztermPane(pane: handle.weztermPane, socket: socket))
            }
            if term.isEmpty || term == "kitty", isNumericID(handle.kittyWindow),
               isKittySocket(handle.kittyListenOn) {
                steps.append(.kittyWindow(window: handle.kittyWindow, listenOn: handle.kittyListenOn))
            }
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

    /// A session with no terminal: a service, a daemon or an app runs it.
    /// It lands on the app its chain runs in — an editor opened on the
    /// folder, an agent's own app brought forward — or on the owner of its
    /// process when that is an app no host names. With no app at all
    /// there is nothing to click: ↩ and a banner open the detail page,
    /// never a terminal the environment remembered from whoever started
    /// the daemon.
    package static func detached(
        handle: LandingHandle,
        cwd: String,
        pid: Int32,
        hostApp: HostAppKind?
    ) -> LandingPlan {
        var steps: [LandingStep] = []
        if let host = handle.hostKind ?? HostAppKind(bundleID: handle.app) ?? hostApp {
            if host.opensFolders, isAbsoluteWorkspacePath(cwd) {
                steps.append(.openFolder(bundleIDs: host.bundleIDs, path: cwd))
            }
            steps.append(.activateApp(bundleIDs: host.bundleIDs))
        }
        if handle.host == LandingHandle.otherHost || !steps.isEmpty, pid > 1 {
            steps.append(.activateOwner(pid: pid))
        }
        return LandingPlan(steps: steps)
    }

    /// The editor host: a bundle id the catalog of hosts knows, else
    /// `TERM_PROGRAM` (`vscode` is also what Cursor and Windsurf say, so the
    /// bundle id refines it), else the hook's parent chain, else the process
    /// table's. Only a host that opens folders is an editor; an agent's own
    /// app is not one.
    package static func editor(handle: LandingHandle, hostApp: HostAppKind?) -> HostAppKind? {
        let term = handle.term.lowercased()
        let fromApp = HostAppKind(bundleID: handle.app).flatMap { $0.opensFolders ? $0 : nil }
        let fromHook = handle.hostKind.flatMap { $0.opensFolders ? $0 : nil }
        let fromScan = hostApp.flatMap { $0.opensFolders ? $0 : nil }
        switch term {
        case "vscode": return fromApp ?? fromHook ?? fromScan ?? .vsCode
        case "zed": return .zed
        case "", "tmux": return fromApp ?? fromHook ?? fromScan
        default: return nil
        }
    }

    /// The terminal app: `TERM_PROGRAM` first (the terminal sets it itself),
    /// else the terminal whose own handle the shell carries (kitty sets no
    /// `TERM_PROGRAM`; tmux says only `tmux`), else the launching app's
    /// bundle id.
    package static func hostBundleIDs(handle: LandingHandle) -> [String] {
        let term = handle.term.lowercased()
        if let known = termPrograms[term] { return known }
        if term.isEmpty || term == "tmux" {
            if !handle.weztermPane.isEmpty { return [weztermBundleID] }
            if !handle.kittyWindow.isEmpty { return [kittyBundleID] }
        }
        return handle.app.isEmpty ? [] : [handle.app]
    }

    /// A terminal's own pane or window id: digits only, so nothing read
    /// from the log becomes another argument.
    package static func isNumericID(_ raw: String) -> Bool {
        !raw.isEmpty && raw.count <= 12 && raw.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// kitty's remote-control address, on a unix socket path only: a
    /// `tcp:` address is a network connection, and Pulse makes none.
    package static func isKittySocket(_ raw: String) -> Bool {
        raw.hasPrefix("unix:/") && !raw.contains(" ")
    }

    /// Absolute path that could be a workspace folder (pure shape check).
    package static func isAbsoluteWorkspacePath(_ raw: String) -> Bool {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.hasPrefix("/"), p.count > 1 else { return false }
        if p == "/" || p == "/tmp" || p == "/private/tmp" { return false }
        return true
    }

    /// A Zellij session name as Zellij makes one (`pretentious-cat`) or a
    /// person names one: nothing that could be read as another argument.
    package static func isZellijSession(_ raw: String) -> Bool {
        !raw.isEmpty && raw.count <= 64 && !raw.hasPrefix("-")
            && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// `zellij --session <name> action focus-pane-id <N>`.
    package static func zellijArguments(session: String, pane: String) -> [String] {
        ["--session", session, "action", "focus-pane-id", pane]
    }

    /// The tmux commands for one pane, as one argv (`;` separates commands).
    package static func tmuxArguments(pane: String, socket: String) -> [String] {
        var args: [String] = socket.isEmpty ? [] : ["-S", socket]
        args += [
            "switch-client", "-t", pane, ";",
            "select-window", "-t", pane, ";",
            "select-pane", "-t", pane, ";",
            "display-message", "-p", "-t", pane, "#{session_id}",
        ]
        return args
    }

    /// One run of a terminal's own CLI: the program inside the running
    /// app's bundle — never a path from the log or a shell's `PATH` — its
    /// argv, and what its environment changes on top of Pulse's own.
    package struct HostCommand: Hashable, Sendable {
        package var executable: String
        package var arguments: [String]
        package var adds: [String: String] = [:]
        package var removes: [String] = []

        /// Pulse's environment with this command's changes.
        package func environment(over base: [String: String]) -> [String: String] {
            var out = base
            for key in removes { out.removeValue(forKey: key) }
            out.merge(adds) { _, new in new }
            return out
        }
    }

    /// `wezterm cli --no-auto-start activate-pane --pane-id N`, run from the
    /// app bundle at `bundlePath`. The socket names the GUI that owns the
    /// pane; without it the CLI finds the running GUI itself. A pane id
    /// Pulse's own environment carries is never inherited.
    package static func weztermCommand(bundlePath: String, pane: String, socket: String) -> HostCommand? {
        guard bundlePath.hasPrefix("/"), isNumericID(pane) else { return nil }
        return HostCommand(
            executable: bundlePath + "/Contents/MacOS/wezterm",
            arguments: ["cli", "--no-auto-start", "activate-pane", "--pane-id", pane],
            adds: socket.hasPrefix("/") ? ["WEZTERM_UNIX_SOCKET": socket] : [:],
            removes: ["WEZTERM_UNIX_SOCKET", "WEZTERM_PANE"]
        )
    }

    /// `kitten @ --to <listen_on> focus-window --match id:N` — `kitten` in
    /// the app bundle at `bundlePath`, else `kitty @` (kitty before 0.28),
    /// in that order; the first that exists runs.
    package static func kittyCommands(bundlePath: String, window: String, listenOn: String) -> [HostCommand] {
        guard bundlePath.hasPrefix("/"), isNumericID(window), isKittySocket(listenOn) else { return [] }
        let arguments = ["@", "--to", listenOn, "focus-window", "--match", "id:" + window]
        return ["kitten", "kitty"].map { program in
            HostCommand(
                executable: bundlePath + "/Contents/MacOS/" + program,
                arguments: arguments,
                removes: ["KITTY_LISTEN_ON", "KITTY_WINDOW_ID"]
            )
        }
    }
}

/// What a click did — reported on the row, never rounded up.
package enum LandingOutcome: Equatable, Sendable {
    case exact
    case appOnly
    case failed
}
