import Darwin
import Foundation

/// Where a hooked session lives, read by the hook itself.
///
/// The hook runs inside the agent's own process tree and environment, so it
/// can say — at no cost to the scan — which process is the agent and how its
/// terminal can be reached. Both go into the event line (`pid`,
/// `landing`). No fork, no `ps`, no `lsof`: `sysctl`, libproc and the
/// environment only, matched by the same rule as the process scan
/// (`AgentProcesses.match(args:)`).
package enum HookLanding {
    /// A parent chain longer than this is not a chain (see PromptVisibility).
    package static let maxDepth = 16

    /// The receiver's bound on the `landing` column. `handles` keeps whole
    /// fields within it, so a cut never leaves half a socket path.
    package static let budget = 240

    // MARK: - Pure

    /// Landing handles, most specific first, `;`-separated (`LandingHandle`
    /// reads them back; an unknown key is ignored):
    /// `detached:1`, `tmux:%3`, `tmuxsock:<socket>`, `zellij:<pane id>`,
    /// `zellijsession:<name>`, `wezterm:<pane id>`,
    /// `weztermsock:<socket>`, `kitty:<window id>`, `kittysock:<listen_on>`,
    /// `iterm:w0t1p0:<uuid>`, `tty:/dev/ttys004`, `term:<program>`,
    /// `app:<bundle id>`, `host:<HostAppKind | other>`.
    ///
    /// - Parameters:
    ///   - tty: the session's terminal device, nil when none.
    ///   - host: the app on the hook's parent chain (`host(start:…)`):
    ///     a `HostAppKind` raw value, `other`, or "".
    ///   - detached: no process on the chain has a terminal. The session
    ///     runs in a service, a daemon or an app, and every terminal handle
    ///     in the environment was inherited from whoever started it — a
    ///     terminal that is not this session's. Only `detached:1`, a known
    ///     host's `app:` and `host:` are written.
    package static func handles(
        environment: [String: String],
        tty: String?,
        host: String = "",
        detached: Bool = false
    ) -> String {
        func value(_ key: String) -> String {
            clean(environment[key] ?? "")
        }
        var out: [String] = []
        let app = value("__CFBundleIdentifier")
        if detached {
            out.append("detached:1")
            // Kept only when it names a host: a daemon started from iTerm
            // still carries iTerm's id.
            if HostAppKind(bundleID: app) != nil { out.append("app:" + app) }
            if !host.isEmpty { out.append("host:" + clean(host)) }
            return bounded(out)
        }
        let pane = value("TMUX_PANE")
        if !pane.isEmpty {
            out.append("tmux:" + pane)
            // `TMUX` is `<socket>,<server pid>,<session>`: the socket lets
            // Pulse reach a server started with `-L` / `-S`.
            let socket = clean(String((environment["TMUX"] ?? "").split(separator: ",").first ?? ""))
            if socket.hasPrefix("/") { out.append("tmuxsock:" + socket) }
        }
        // Zellij's pane and session: `zellij --session <name> action
        // focus-pane-id <N>` reaches it from outside (Zellij 0.44.1+).
        let zellijPane = value("ZELLIJ_PANE_ID")
        let zellijSession = value("ZELLIJ_SESSION_NAME")
        if !zellijPane.isEmpty, !zellijSession.isEmpty {
            out.append("zellij:" + zellijPane)
            out.append("zellijsession:" + zellijSession)
        }
        // WezTerm's pane, and the socket of the GUI that owns it (several
        // GUIs can run): `wezterm cli activate-pane` reaches it.
        let wezPane = value("WEZTERM_PANE")
        if !wezPane.isEmpty {
            out.append("wezterm:" + wezPane)
            let socket = value("WEZTERM_UNIX_SOCKET")
            if socket.hasPrefix("/") { out.append("weztermsock:" + socket) }
        }
        // kitty's window, and its remote-control socket — set only when
        // the person enabled `listen_on`; without it there is no interface.
        let kittyWindow = value("KITTY_WINDOW_ID")
        if !kittyWindow.isEmpty {
            out.append("kitty:" + kittyWindow)
            let listen = value("KITTY_LISTEN_ON")
            if listen.hasPrefix("unix:") { out.append("kittysock:" + listen) }
        }
        let iterm = value("ITERM_SESSION_ID")
        if !iterm.isEmpty { out.append("iterm:" + iterm) }
        if let tty, tty.hasPrefix("/dev/") { out.append("tty:" + clean(tty)) }
        let program = value("TERM_PROGRAM")
        if !program.isEmpty { out.append("term:" + program) }
        // macOS sets this for a process launched from an app bundle: the
        // terminal (or editor) the shell runs in, when `TERM_PROGRAM` is
        // missing (kitty) or ambiguous (`vscode` is also Cursor, Windsurf…).
        if !app.isEmpty { out.append("app:" + app) }
        // In a terminal only a known host says anything a terminal handle
        // does not (an editor's integrated terminal).
        if HostAppKind(rawValue: host) != nil { out.append("host:" + host) }
        return bounded(out)
    }

    /// The fields that fit the column's budget, in order; a field that
    /// does not fit is left out whole.
    package static func bounded(_ fields: [String], budget: Int = HookLanding.budget) -> String {
        var kept: [String] = []
        var used = 0
        for field in fields {
            let cost = field.count + (kept.isEmpty ? 0 : 1)
            guard used + cost <= budget else { continue }
            kept.append(field)
            used += cost
        }
        return kept.joined(separator: ";")
    }

    /// The app the hook's parent chain runs in, nearest first: a
    /// `HostAppKind`'s raw value; `other` for an app bundle no host names
    /// (`LandingHandle.otherHost`); "" when the chain reaches launchd through
    /// no app at all (a daemon). Executable paths only. Pure.
    package static func host(
        start: Int32,
        parentOf: (Int32) -> Int32?,
        pathOf: (Int32) -> String
    ) -> String {
        var current = start
        var seen: Set<Int32> = []
        for _ in 0..<maxDepth {
            guard current > 1, !seen.contains(current) else { break }
            seen.insert(current)
            let path = pathOf(current)
            if let kind = HostAppKind(path: path) { return kind.rawValue }
            if path.contains(".app/Contents/") { return LandingHandle.otherHost }
            guard let parent = parentOf(current) else { break }
            current = parent
        }
        return ""
    }

    /// The agent's pid: the first process on the chain from `start` upward
    /// whose argv is this agent by its catalog process rule. When none is,
    /// 0 — unknown. Never the direct parent: that is usually the `sh -c` the
    /// vendor ran the hook in, which exits the moment the hook does, and a
    /// session bound to it would end at once. A chain that starts at launchd
    /// (the hook was re-parented to pid 1) is nobody's session either.
    ///
    /// When that process is the agent's service (`AgentProcesses.isService`
    /// with `serviceArguments`) — one process serving many sessions and
    /// outliving each — 0 too: the session has no process of its own, and
    /// a live service must not keep it listed.
    package static func agentPID(
        agent: AgentID,
        start: Int32,
        parentOf: (Int32) -> Int32?,
        argumentsOf: (Int32) -> String?,
        serviceArguments: [String] = []
    ) -> Int32 {
        var current = start
        var seen: Set<Int32> = []
        for _ in 0..<maxDepth {
            guard current > 1, !seen.contains(current) else { break }
            seen.insert(current)
            if let args = argumentsOf(current), AgentProcesses.match(args: args) == agent {
                return AgentProcesses.isService(args: args, arguments: serviceArguments) ? 0 : current
            }
            guard let parent = parentOf(current) else { break }
            current = parent
        }
        return 0
    }

    /// One field of a `;`-separated list inside a TSV column: no tab, no
    /// line break of any kind (`AttentionProtocol.flatten`), no `;`.
    package static func clean(_ raw: String) -> String {
        AttentionProtocol.flatten(raw.replacingOccurrences(of: ";", with: ","))
    }

    // MARK: - This process

    /// The agent pid and landing handles for the hook now running.
    package static func current(agent: AgentID, environment: [String: String]) -> (pid: Int32, landing: String) {
        let parent = getppid()
        // One `KERN_PROCARGS2` buffer for the whole walk.
        var buffer = [UInt8](repeating: 0, count: AgentProcesses.argumentsMax())
        let pid = agentPID(
            agent: agent,
            start: parent,
            parentOf: PromptVisibility.parentPID(of:),
            argumentsOf: { pid in
                // The executable path first, as the process scan matches it.
                let line = AgentProcesses.commandLine(
                    path: AgentProcesses.executablePath(of: pid),
                    argv: AgentProcesses.argv(of: pid, buffer: &buffer) ?? []
                )
                return line.isEmpty ? nil : line
            },
            serviceArguments: AgentProcesses.serviceArguments(of: agent)
        )
        // The controlling terminal is inherited by every child, piped or
        // not: none on the hook, the agent or the hook's parent means none
        // on the chain.
        let terminal = ownTTY() ?? tty(of: pid) ?? tty(of: parent)
        let chainHost = Self.host(
            start: parent,
            parentOf: PromptVisibility.parentPID(of:),
            pathOf: AgentProcesses.executablePath(of:)
        )
        return (pid, handles(environment: environment, tty: terminal, host: chainHost, detached: terminal == nil))
    }

    /// The argv of `pid` when it is still this agent by its catalog
    /// process rule (the pid `current` found) — what the receiver reads a
    /// promptless run from (`AgentProcessRule.cannotPrompt`); nil when it
    /// cannot be read or is not the agent. `sysctl` only.
    package static func agentArguments(agent: AgentID, pid: Int32) -> [String]? {
        guard pid > 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: AgentProcesses.argumentsMax())
        guard let argv = AgentProcesses.argv(of: pid, buffer: &buffer), !argv.isEmpty else { return nil }
        let line = AgentProcesses.commandLine(path: AgentProcesses.executablePath(of: pid), argv: argv)
        guard AgentProcesses.match(args: line) == agent else { return nil }
        return argv
    }

    /// The terminal on this process's own stdin, stdout or stderr.
    package static func ownTTY() -> String? {
        for fd: Int32 in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where isatty(fd) != 0 {
            if let name = ttyname(fd) { return String(cString: name) }
        }
        return nil
    }

    /// A process's controlling terminal, from `sysctl`.
    package static func tty(of pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let ok = mib.withUnsafeMutableBufferPointer { buffer -> Bool in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0) == 0
        }
        guard ok, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, device != 0, let name = devname(device, S_IFCHR) else { return nil }
        let value = String(cString: name)
        guard !value.isEmpty, value != "??" else { return nil }
        return "/dev/" + value
    }
}
