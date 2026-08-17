import Darwin
import Foundation

/// Locked read/write for attention.tsv — same exclusive flock as pulse_hook.py /
/// `PulseBar --hook`. Columns: agent \\t kind \\t ms \\t message \\t session \\t cwd
enum AttentionIO {
    /// Tests and `PULSE_HOME` hook self-tests redirect the ledger without
    /// touching the user's real Application Support file.
    static var pathOverride: URL?

    static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/attention.tsv")
    }

    static var path: URL {
        if let pathOverride { return pathOverride }
        if let home = ProcessInfo.processInfo.environment["PULSE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("attention.tsv")
        }
        return defaultPath
    }

    /// Must match `AttentionProtocol.header`, `PulseHookReceiver`, and the
    /// optional legacy `pulse_hook.py` — divergent headers used to coexist in
    /// the same file and confuse readers.
    static var header: String { AttentionProtocol.header }

    static let maxRetainedLines = 80

    /// Inbox for machines that are not this one.
    ///
    /// Pulse writes no network code and runs no server: whatever the user
    /// already uses to move files — rsync, syncthing, a mounted volume, a
    /// `scp` in their own script — drops one TSV per host in here. One file
    /// per host means remote writers never contend for the local flock.
    static var inboxDirectory: URL {
        path.deletingLastPathComponent().appendingPathComponent("attention.d", isDirectory: true)
    }

    /// A remote file is someone else's disk quota, not ours. Bound both the
    /// number of hosts and the bytes read from each.
    static let maxInboxFiles = 16
    static let maxInboxBytesPerFile = 256 * 1024

    /// One place events came from, with the local time they arrived.
    ///
    /// `receivedAtMs` is the file's own modification time. Pulse cannot trust
    /// a remote machine's clock, and it keeps no cross-launch record of when
    /// each line showed up — but the moment the bytes landed on *this* disk is
    /// both local and durable, which is exactly what a skewed event stamp
    /// needs to be checked against.
    struct Source {
        var host: String
        var text: String
        var receivedAtMs: Int64
        var isLocal: Bool
    }

    /// The local file plus every inbox file, newest host first.
    static func readSources() -> [Source] {
        var sources = [
            Source(host: "", text: readText(), receivedAtMs: 0, isLocal: true)
        ]
        sources.append(contentsOf: readInbox())
        return sources
    }

    static func readInbox() -> [Source] {
        let fm = FileManager.default
        let directory = inboxDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var found: [Source] = []
        for name in names.sorted() where name.hasSuffix(".tsv") {
            if found.count >= maxInboxFiles { break }
            let url = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            // Read the TAIL of an oversized file, not the head: the TSV is
            // append-only, so the newest events are the last bytes. Reading
            // the first 256KB meant a busy remote host's fresh raises were
            // exactly the part that got dropped, while stale lines stayed
            // visible. After seeking mid-file, drop the first (partial) line.
            let size = (try? handle.seekToEnd()) ?? 0
            if size > UInt64(maxInboxBytesPerFile) {
                try? handle.seek(toOffset: size - UInt64(maxInboxBytesPerFile))
            } else {
                try? handle.seek(toOffset: 0)
            }
            var data = (try? handle.readToEnd()) ?? Data()
            if size > UInt64(maxInboxBytesPerFile), let newline = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: (newline + 1)..<data.count)
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            let modified = attributes?[.modificationDate] as? Date
            // The file name is the fallback identity, so a remote box running
            // an older v1 hook still shows up as itself rather than as "here".
            let fallbackHost = AttentionProtocol.normalizeHost(String(name.dropLast(4)))
            found.append(
                Source(
                    host: fallbackHost,
                    text: text,
                    receivedAtMs: Int64((modified?.timeIntervalSince1970 ?? 0) * 1000),
                    isLocal: false
                )
            )
        }
        return found
    }

    /// Keep unresolved raises when compacting the TSV. A suffix-only cap can
    /// drop a still-open permission/waiting line with no `done`.
    static func compactLines(_ lines: [String], cap: Int = maxRetainedLines) -> [String] {
        guard lines.count > cap else { return lines }
        var lastKind: [String: String] = [:]
        var lastIndex: [String: Int] = [:]
        for (index, raw) in lines.enumerated() {
            let columns = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3,
                  let agent = ActivityHarvest.mapAgent(String(columns[0]))
            else { continue }
            let kind = AttentionProtocol.normalizeKind(String(columns[1]))
            let session = columns.count > 4 ? String(columns[4]) : ""
            let key = session.isEmpty ? agent.surfaceID.rawValue : "\(agent.surfaceID.rawValue)|\(session)"
            lastKind[key] = kind
            lastIndex[key] = index
        }
        let openKinds: Set<String> = ["permission", "idle_prompt", "waiting"]
        var mustKeep = Set(
            lastIndex.compactMap { key, index -> Int? in
                openKinds.contains(lastKind[key] ?? "") ? index : nil
            }
        )
        if mustKeep.count > cap {
            return mustKeep.sorted().suffix(cap).map { lines[$0] }
        }
        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            if mustKeep.count >= cap { break }
            mustKeep.insert(index)
        }
        return mustKeep.sorted().map { lines[$0] }
    }

    static func readText() -> String {
        var result = ""
        withExclusiveLock { fd in
            let size = lseek(fd, 0, SEEK_END)
            lseek(fd, 0, SEEK_SET)
            guard size > 0 else { return }
            result = String(data: readAll(fd, size: Int(size)), encoding: .utf8) ?? ""
        }
        return result
    }

    /// Last raw hook/bridge event per Agent, including done/stop. Runtime
    /// support needs to answer "has this connection ever fired recently?"
    /// without turning a completed event back into Waiting.
    static func latestEventTimes() -> [AgentID: Int64] {
        var latest: [AgentID: Int64] = [:]
        for line in readText().split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") { continue }
            let columns = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            )
            guard columns.count >= 3,
                  let agent = ActivityHarvest.mapAgent(String(columns[0])),
                  let ms = Int64(columns[2])
            else { continue }
            latest[agent] = max(latest[agent] ?? 0, ms)
        }
        return latest
    }

    /// `read(2)` may return fewer bytes than asked for; the old single call
    /// silently truncated whenever it did.
    private static func readAll(_ fd: Int32, size: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var remaining = size
        while remaining > 0 {
            let want = min(remaining, buffer.count)
            let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if got <= 0 { break }
            data.append(contentsOf: buffer[0..<got])
            remaining -= got
        }
        return data
    }

    static func clearAll() {
        withExclusiveLock { fd in
            ftruncate(fd, 0)
            _ = header.withCString { ptr in write(fd, ptr, strlen(ptr)) }
        }
    }

    /// Append a done event (optional session scopes the clear).
    static func appendDone(agent: AgentID, session: String = "") {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let line = "\(agent.rawValue)\tdone\t\(ts)\t\t\(session)\t"
        appendRawLine(line)
    }

    /// Append a permission Waiting line — used by Settings sample and tests.
    /// Never invents Waiting for adapters; the caller must be an explicit user action.
    static func appendPermission(
        agent: AgentID,
        message: String,
        session: String = "",
        cwd: String = ""
    ) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let safeMessage = message
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeSession = session
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let safeCwd = cwd
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let line = "\(agent.rawValue)\tpermission\t\(ts)\t\(safeMessage)\t\(safeSession)\t\(safeCwd)"
        appendRawLine(line)
    }

    /// Shared by Settings samples and the native hook receiver.
    static func appendRawLine(_ line: String) {
        withExclusiveLock { fd in
            let size = lseek(fd, 0, SEEK_END)
            lseek(fd, 0, SEEK_SET)
            var data = Data(count: max(0, Int(size)))
            if size > 0 {
                _ = data.withUnsafeMutableBytes { buf in
                    read(fd, buf.baseAddress, Int(size))
                }
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            var lines = text.split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            lines.append(line.trimmingCharacters(in: .newlines))
            if lines.count > maxRetainedLines {
                lines = compactLines(lines, cap: maxRetainedLines)
            }
            let body = header + lines.joined(separator: "\n") + "\n"
            ftruncate(fd, 0)
            lseek(fd, 0, SEEK_SET)
            _ = body.withCString { ptr in write(fd, ptr, strlen(ptr)) }
            fsync(fd)
        }
    }

    private static func withExclusiveLock(_ body: (Int32) -> Void) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = path.path.withCString { open($0, O_RDWR | O_CREAT, 0o644) }
        guard fd >= 0 else {
            DebugLog.write("attention open failed errno=\(errno)")
            return
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX) != 0 {
            DebugLog.write("attention flock failed errno=\(errno)")
            return
        }
        defer { _ = flock(fd, LOCK_UN) }
        body(fd)
    }
}
