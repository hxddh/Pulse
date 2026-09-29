import Darwin
import Foundation

/// 24.0 · Where a hooked session lives, read by the hook itself.
///
/// The hook runs inside the agent's own process tree and environment, so it
/// can say — at no cost to the scan — which process is the agent and how its
/// terminal can be reached. Both go into the v4 attention record (`pid`,
/// `landing`). No fork, no `ps`, no `lsof`: `sysctl` and the environment only.
enum HookLanding {
    /// A parent chain longer than this is not a chain (see PromptVisibility).
    static let maxDepth = 16

    // MARK: - Pure

    /// Landing handles, most specific first, `;`-separated:
    /// `tmux:%3`, `iterm:w0t1p0:<uuid>`, `tty:/dev/ttys004`, `term:<program>`.
    static func handles(environment: [String: String], tty: String?) -> String {
        func value(_ key: String) -> String {
            clean(environment[key] ?? "")
        }
        var out: [String] = []
        let pane = value("TMUX_PANE")
        if !pane.isEmpty { out.append("tmux:" + pane) }
        let iterm = value("ITERM_SESSION_ID")
        if !iterm.isEmpty { out.append("iterm:" + iterm) }
        if let tty, tty.hasPrefix("/dev/") { out.append("tty:" + clean(tty)) }
        let program = value("TERM_PROGRAM")
        if !program.isEmpty { out.append("term:" + program) }
        return out.joined(separator: ";")
    }

    /// The agent's pid: the first process on the chain from `start` upward
    /// whose argv is this agent by its catalog process rule. When none is,
    /// the direct parent (`start`) — the process that ran the hook.
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
            if let args = argumentsOf(current), ProcessProbe.match(args: args) == agent {
                return current
            }
            guard let parent = parentOf(current) else { break }
            current = parent
        }
        return start
    }

    /// `KERN_PROCARGS2` bytes: argc (a 32-bit little-endian int), the exec
    /// path, NUL padding, then argc NUL-terminated argv strings. The argv
    /// joined by spaces — the shape `ProcessProbe.match(args:)` reads.
    static func parseProcArgs(_ bytes: [UInt8]) -> String? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard argc > 0 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var args: [String] = []
        var start = index
        while index < bytes.count, args.count < argc {
            if bytes[index] == 0 {
                args.append(String(decoding: bytes[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    /// One field of a `;`-separated list inside a TSV column.
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: ";", with: ",")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - This process

    /// The agent pid and landing handles for the hook now running.
    static func current(agent: AgentID, environment: [String: String]) -> (pid: Int32, landing: String) {
        let parent = getppid()
        let pid = agentPID(
            agent: agent,
            start: parent,
            parentOf: PromptVisibility.parentPID(of:),
            argumentsOf: arguments(of:)
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

    /// A process's argv, from `sysctl(KERN_PROCARGS2)`.
    static func arguments(of pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        let gotMax = argmaxMIB.withUnsafeMutableBufferPointer { buffer -> Bool in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &argmax, &argmaxSize, nil, 0) == 0
        }
        guard gotMax, argmax > 0 else { return nil }
        var size = Int(argmax)
        var bytes = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let ok = mib.withUnsafeMutableBufferPointer { buffer -> Bool in
            bytes.withUnsafeMutableBytes { raw -> Bool in
                sysctl(buffer.baseAddress, UInt32(buffer.count), raw.baseAddress, &size, nil, 0) == 0
            }
        }
        guard ok, size > 0 else { return nil }
        return parseProcArgs(Array(bytes.prefix(size)))
    }
}
