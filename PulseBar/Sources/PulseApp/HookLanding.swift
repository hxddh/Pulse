import Darwin
import Foundation

/// Where a hooked session lives, read by the hook itself.
///
/// The hook runs inside the agent's own process tree and environment, so it
/// can say — at no cost to the scan — which process is the agent and how its
/// terminal can be reached. Both go into the v5 event line (`pid`,
/// `landing`). No fork, no `ps`, no `lsof`: `sysctl`, libproc and the
/// environment only, matched by the same rule as the process scan
/// (`AgentProcesses.match(args:)`).
enum HookLanding {
    /// A parent chain longer than this is not a chain (see PromptVisibility).
    static let maxDepth = 16

    // MARK: - Pure

    /// Landing handles, most specific first, `;`-separated:
    /// `tmux:%3`, `tmuxsock:<socket>`, `iterm:w0t1p0:<uuid>`,
    /// `tty:/dev/ttys004`, `term:<program>`, `app:<bundle id>`
    /// (`LandingHandle` reads them back).
    static func handles(environment: [String: String], tty: String?) -> String {
        func value(_ key: String) -> String {
            clean(environment[key] ?? "")
        }
        var out: [String] = []
        let pane = value("TMUX_PANE")
        if !pane.isEmpty {
            out.append("tmux:" + pane)
            // `TMUX` is `<socket>,<server pid>,<session>`: the socket lets
            // Pulse reach a server started with `-L` / `-S`.
            let socket = clean(String((environment["TMUX"] ?? "").split(separator: ",").first ?? ""))
            if socket.hasPrefix("/") { out.append("tmuxsock:" + socket) }
        }
        let iterm = value("ITERM_SESSION_ID")
        if !iterm.isEmpty { out.append("iterm:" + iterm) }
        if let tty, tty.hasPrefix("/dev/") { out.append("tty:" + clean(tty)) }
        let program = value("TERM_PROGRAM")
        if !program.isEmpty { out.append("term:" + program) }
        // macOS sets this for a process launched from an app bundle: the
        // terminal (or editor) the shell runs in, when `TERM_PROGRAM` is
        // missing (kitty) or ambiguous (`vscode` is also Cursor, Windsurf…).
        let app = value("__CFBundleIdentifier")
        if !app.isEmpty { out.append("app:" + app) }
        return out.joined(separator: ";")
    }

    /// The agent's pid: the first process on the chain from `start` upward
    /// whose argv is this agent by its catalog process rule. When none is,
    /// 0 — unknown. Never the direct parent: that is usually the `sh -c` the
    /// vendor ran the hook in, which exits the moment the hook does, and a
    /// session bound to it would end at once. A chain that starts at launchd
    /// (the hook was re-parented to pid 1) is nobody's session either.
    static func agentPID(
        agent: AgentID,
        start: Int32,
        parentOf: (Int32) -> Int32?,
        argumentsOf: (Int32) -> String?
    ) -> Int32 {
        var current = start
        var seen: Set<Int32> = []
        for _ in 0..<maxDepth {
            guard current > 1, !seen.contains(current) else { break }
            seen.insert(current)
            if let args = argumentsOf(current), AgentProcesses.match(args: args) == agent {
                return current
            }
            guard let parent = parentOf(current) else { break }
            current = parent
        }
        return 0
    }

    /// One field of a `;`-separated list inside a TSV column: no tab, no
    /// line break of any kind (`AttentionProtocol.flatten`), no `;`.
    static func clean(_ raw: String) -> String {
        AttentionProtocol.flatten(raw.replacingOccurrences(of: ";", with: ","))
    }

    // MARK: - This process

    /// The agent pid and landing handles for the hook now running.
    static func current(agent: AgentID, environment: [String: String]) -> (pid: Int32, landing: String) {
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
            }
        )
        let terminal = ownTTY() ?? tty(of: pid) ?? tty(of: parent)
        return (pid, handles(environment: environment, tty: terminal))
    }

    /// The terminal on this process's own stdin, stdout or stderr.
    static func ownTTY() -> String? {
        for fd: Int32 in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where isatty(fd) != 0 {
            if let name = ttyname(fd) { return String(cString: name) }
        }
        return nil
    }

    /// A process's controlling terminal, from `sysctl`.
    static func tty(of pid: Int32) -> String? {
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
