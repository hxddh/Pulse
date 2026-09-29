import Darwin
import Foundation
import PulseCore

/// 24.0 · agent processes, read from the kernel's process table.
///
/// libproc and `sysctl` only — no `ps`, no `lsof`, no subprocess, no
/// privacy prompt. Two jobs:
///
/// - **discovery** (`scan`, every 30 s and at launch and wake): find the
///   agent processes this user runs, so a session that started before Pulse
///   was running shows as a process-only row until its next hook event;
/// - **matching** (`match(args:)`): which agent a command line is, by the
///   catalog's process rule — shared with the hook, which walks its own
///   parent chain to find the agent's pid.
///
/// Liveness (`isAlive`) is the exit watch's fallback; the exit itself
/// arrives through kqueue (`ProcessExitWatch`).
package enum AgentProcesses {
    /// One agent process — or, when an agent runs as a wrapper and its
    /// child (`codex` → the native `codex`), one family: `pid` is the
    /// top-most matching process and `family` holds every matching pid.
    package struct Hit: Equatable, Sendable {
        package var agent: AgentID
        package var pid: Int32
        package var family: [Int32]
        /// The working directory, when it names user work (`usefulWorkingDirectory`).
        package var cwd: String = ""
        /// Kernel tty name without `/dev/` (`ttys004`); "" when none.
        package var tty: String = ""
        package var startedMs: Int64 = 0
        package var viaWarp = false
        package var hostApp: HostAppKind? = nil

        package init(
            agent: AgentID,
            pid: Int32,
            family: [Int32] = [],
            cwd: String = "",
            tty: String = "",
            startedMs: Int64 = 0,
            viaWarp: Bool = false,
            hostApp: HostAppKind? = nil
        ) {
            self.agent = agent
            self.pid = pid
            self.family = family.isEmpty ? [pid] : family
            self.cwd = cwd
            self.tty = tty
            self.startedMs = startedMs
            self.viaWarp = viaWarp
            self.hostApp = hostApp
        }
    }

    /// One row of the process table as the scan read it — the pure input of
    /// `hits(in:cwd:)`.
    package struct Proc: Equatable, Sendable {
        package var pid: Int32
        package var ppid: Int32
        /// Executable path and argv, joined by a space — the shape
        /// `match(args:)` reads.
        package var args: String
        package var tty: String = ""
        package var startedMs: Int64 = 0

        package init(pid: Int32, ppid: Int32, args: String, tty: String = "", startedMs: Int64 = 0) {
            self.pid = pid
            self.ppid = ppid
            self.args = args
            self.tty = tty
            self.startedMs = startedMs
        }
    }

    /// A parent chain longer than this is not a chain.
    static let maxDepth = 32

    // MARK: - Discovery

    /// The agent processes this user runs, or nil when the process table
    /// could not be read at all (the caller keeps what it had: a failed read
    /// never removes a row).
    package static func scan() -> [Hit]? {
        guard let table = processTable() else { return nil }
        return hits(in: table, cwd: workingDirectory(of:))
    }

    /// Pure: which rows of `table` are agents, collapsed into families, with
    /// the handles Focus needs from the parent chain.
    package static func hits(in table: [Proc], cwd: (Int32) -> String) -> [Hit] {
        var byPid: [Int32: Proc] = [:]
        for proc in table { byPid[proc.pid] = proc }
        var matched: [Int32: AgentID] = [:]
        for proc in table {
            // Warp's own helpers carry agent-looking argv; they are the
            // terminal, not a session.
            if proc.args.contains("Warp.app") { continue }
            if let agent = match(args: proc.args) { matched[proc.pid] = agent }
        }

        func ancestors(of pid: Int32) -> [Proc] {
            var out: [Proc] = []
            var seen: Set<Int32> = [pid]
            var current = byPid[pid]?.ppid ?? 0
            while current > 1, out.count < maxDepth, seen.insert(current).inserted, let proc = byPid[current] {
                out.append(proc)
                current = proc.ppid
            }
            return out
        }

        // A matching process whose ancestor is the same agent belongs to
        // that ancestor's family.
        var roots: [Int32: [Int32]] = [:]
        for (pid, agent) in matched {
            let root = ancestors(of: pid).last { matched[$0.pid] == agent }?.pid ?? pid
            roots[root, default: []].append(pid)
        }

        var out: [Hit] = []
        for (root, members) in roots {
            guard let proc = byPid[root], let agent = matched[root] else { continue }
            let chain = [proc] + ancestors(of: root)
            var hit = Hit(agent: agent, pid: root, family: members.sorted())
            hit.startedMs = proc.startedMs
            hit.tty = chain.lazy.map(\.tty).first { !$0.isEmpty } ?? ""
            hit.viaWarp = chain.contains { $0.args.contains("Warp.app") }
            hit.hostApp = chain.lazy.compactMap { hostApp(in: $0.args) }.first
            hit.cwd = usefulWorkingDirectory(cwd(root))
            out.append(hit)
        }
        return out.sorted { ($0.agent.rawValue, $0.pid) < ($1.agent.rawValue, $1.pid) }
    }

    static func hostApp(in args: String) -> HostAppKind? {
        HostAppKind.allCases.first { kind in kind.pathNeedles.contains { args.contains($0) } }
    }

    // MARK: - Matching

    /// Process rules in roster order — the first matching rule wins.
    private static let rules: [(id: AgentID, rule: AgentProcessRule)] =
        AgentCatalog.all.map { ($0.id, $0.process) }

    /// The agent a command line (executable path, then argv) belongs to.
    package static func match(args: String) -> AgentID? {
        let exe = args.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? args
        let base = (exe as NSString).lastPathComponent
        for (id, rule) in rules {
            if rule.denyNeedles.contains(where: { args.contains($0) }) { continue }
            if rule.pathNeedles.contains(where: { args.contains($0) }) { return id }
            let baseHit = rule.basenames.contains { $0.caseInsensitiveCompare(base) == .orderedSame }
            guard baseHit else { continue }
            // Electron gives Cursor's helpers the same `Cursor` name as the
            // app; only the app's own executable path is the app.
            if id == .cursor { continue }
            // A short bare name (`pi`) is evidence only where the rule says so.
            if !rule.pathNeedles.isEmpty, base.count <= 3, !rule.allowBareBasename { continue }
            return id
        }
        return nil
    }

    // MARK: - The table (libproc)

    /// Every process this user runs: pid, parent, executable and argv, tty,
    /// start. Nil when the pid list itself could not be read.
    static func processTable() -> [Proc]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard got > 0 else { return nil }
        let me = getuid()
        var argvBuffer = [UInt8](repeating: 0, count: argumentsMax())
        var table: [Proc] = []
        for pid in pids.prefix(Int(got)) where pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == me else { continue }
            let path = executablePath(of: pid)
            let argv = arguments(of: pid, buffer: &argvBuffer) ?? ""
            let args = [path, argv].filter { !$0.isEmpty }.joined(separator: " ")
            guard !args.isEmpty else { continue }
            let started = Int64(info.pbi_start_tvsec) * 1000 + Int64(info.pbi_start_tvusec) / 1000
            table.append(Proc(
                pid: pid,
                ppid: Int32(bitPattern: info.pbi_ppid),
                args: args,
                tty: ttyName(info.e_tdev),
                startedMs: started
            ))
        }
        return table
    }

    package static func executablePath(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The process's current directory (`PROC_PIDVNODEPATHINFO`); "" when
    /// it cannot be read.
    static func workingDirectory(of pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// `ttys004` for a controlling terminal device, "" for none.
    static func ttyName(_ device: UInt32) -> String {
        guard device != 0, device != UInt32.max,
              let name = devname(dev_t(bitPattern: device), S_IFCHR)
        else { return "" }
        let value = String(cString: name)
        return value.isEmpty || value == "??" ? "" : value
    }

    /// Liveness only — no signal is sent.
    package static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - argv (`KERN_PROCARGS2`)

    static func argumentsMax() -> Int {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        let ok = mib.withUnsafeMutableBufferPointer { buffer -> Bool in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &argmax, &size, nil, 0) == 0
        }
        return ok && argmax > 0 ? Int(argmax) : 256 * 1024
    }

    /// A process's argv, from `sysctl(KERN_PROCARGS2)`.
    package static func arguments(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: argumentsMax())
        return arguments(of: pid, buffer: &buffer)
    }

    static func arguments(of pid: Int32, buffer: inout [UInt8]) -> String? {
        guard pid > 1, !buffer.isEmpty else { return nil }
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let ok = mib.withUnsafeMutableBufferPointer { names -> Bool in
            buffer.withUnsafeMutableBytes { raw -> Bool in
                sysctl(names.baseAddress, UInt32(names.count), raw.baseAddress, &size, nil, 0) == 0
            }
        }
        guard ok, size > 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` bytes: argc (a 32-bit little-endian int), the exec
    /// path, NUL padding, then argc NUL-terminated argv strings. The argv
    /// joined by spaces.
    package static func parseProcArgs(_ bytes: [UInt8]) -> String? {
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

    // MARK: - Working directories

    /// Keep only paths that can identify user work. `/`, the home folder,
    /// app bundles and support folders are implementation context, not a
    /// project.
    package static func usefulWorkingDirectory(_ raw: String) -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path != "/" else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path != home, path != home + "/" else { return "" }
        let excluded = [
            "/Applications/", "/System/", "/Library/",
            home + "/Library/", "/private/var/", "/var/",
        ]
        guard !excluded.contains(where: path.hasPrefix) else { return "" }
        return path
    }
}
