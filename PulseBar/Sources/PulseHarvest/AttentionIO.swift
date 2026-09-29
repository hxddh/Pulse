import Darwin
import Foundation
import PulseCore

/// Locked read/write for attention.tsv — same exclusive flock as
/// `PulseBar --hook`. Columns (v3, all eight required): agent \\t kind \\t ms
/// \\t message \\t session \\t cwd \\t host (ignored) \\t front
package enum AttentionIO {
    /// Tests and `PULSE_HOME` hook self-tests redirect the ledger without
    /// touching the user's real Application Support file.
    nonisolated(unsafe) package static var pathOverride: URL?

    package static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/attention.tsv")
    }

    package static var path: URL {
        if let pathOverride { return pathOverride }
        if let home = ProcessInfo.processInfo.environment["PULSE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("attention.tsv")
        }
        return defaultPath
    }

    /// Must match `AttentionProtocol.header` and `PulseHookReceiver` —
    /// divergent headers used to coexist in the same file and confuse readers.
    package static var header: String { AttentionProtocol.header }

    package static let maxRetainedLines = 80

    /// Keep unresolved raises when compacting the TSV. A suffix-only cap can
    /// drop a still-open permission/waiting line with no `done`.
    package static func compactLines(_ lines: [String], cap: Int = maxRetainedLines) -> [String] {
        guard lines.count > cap else { return lines }
        var lastOpen: [String: Bool] = [:]
        var lastIndex: [String: Int] = [:]
        for (index, raw) in lines.enumerated() {
            let columns = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3,
                  let agent = ActivityHarvest.mapAgent(String(columns[0]))
            else { continue }
            let kind = AttentionProtocol.kind(String(columns[1]))
            let session = columns.count > 4 ? String(columns[4]) : ""
            let key = session.isEmpty ? agent.surfaceID.rawValue : "\(agent.surfaceID.rawValue)|\(session)"
            lastOpen[key] = kind?.isOpen == true
            lastIndex[key] = index
        }
        // Blocked and your-turn lines are still owed to the user.
        var mustKeep = Set(
            lastIndex.compactMap { key, index -> Int? in
                lastOpen[key] == true ? index : nil
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

    /// The file's text. `url` nil reads `path`; the hook self-test passes its
    /// own temporary file instead of redirecting the global.
    package static func readText(at url: URL? = nil) -> String {
        var result = ""
        withExclusiveLock(at: url ?? path) { fd in
            let size = lseek(fd, 0, SEEK_END)
            lseek(fd, 0, SEEK_SET)
            guard size > 0 else { return }
            // Lossy, never empty: one invalid byte (a hook that wrote a
            // truncated multibyte character) must not hide every open wait.
            result = decode(readAll(fd, size: Int(size)))
        }
        return result
    }

    /// Bytes as text, replacing invalid UTF-8 rather than giving up on the
    /// whole file.
    package static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Last raw hook/bridge event per Agent, including done/stop. Runtime
    /// support needs to answer "has this connection ever fired recently?"
    /// without turning a completed event back into Waiting. Pure: the scan
    /// reads the file once and hands the text here.
    package static func latestEventTimes(in text: String) -> [AgentID: Int64] {
        var latest: [AgentID: Int64] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") { continue }
            let columns = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            )
            guard columns.count == AttentionProtocol.columnCount,
                  let agent = ActivityHarvest.mapAgent(String(columns[0])),
                  let ms = Int64(columns[2])
            else { continue }
            latest[agent] = max(latest[agent] ?? 0, ms)
        }
        return latest
    }

    /// The newest protocol event per agent (surface id), with its v3 kind —
    /// the self-check's "the hooks actually fire". 23.0: read from the file
    /// itself; Pulse no longer keeps a second copy of every hook line.
    package static func latestEvents() -> [AgentID: (kind: String, tsMs: Int64)] {
        latestEvents(in: readText())
    }

    /// Pure: `latestEvents` over a file's text.
    package static func latestEvents(in text: String) -> [AgentID: (kind: String, tsMs: Int64)] {
        var latest: [AgentID: (kind: String, tsMs: Int64)] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let cols = AttentionProtocol.columns(of: line),
                  let agent = ActivityHarvest.mapAgent(cols[0])?.surfaceID,
                  AttentionProtocol.acceptsWrite(kind: cols[1]),
                  let ms = Int64(cols[2]), ms > 0
            else { continue }
            if (latest[agent]?.tsMs ?? 0) < ms {
                latest[agent] = (AttentionProtocol.normalizeKind(cols[1]), ms)
            }
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

    /// `write(2)` may also be short; loop until every byte is down.
    private static func writeAll(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let wrote = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + offset, bytes.count - offset)
            }
            if wrote < 0, errno == EINTR { continue }
            if wrote <= 0 { break }
            offset += wrote
        }
    }

    /// Append a done event. The session is written exactly as given: a
    /// session clears that session, an empty one clears only the agent's
    /// session-less entries (v3, 23.0).
    package static func appendDone(agent: AgentID, session: String) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        // v3: all eight columns, host and front empty.
        let line = "\(agent.rawValue)\tdone\t\(ts)\t\t\(session)\t\t\t"
        appendRawLine(line)
    }

    /// Shared by the store (clears) and the native hook receiver. `url` nil
    /// writes `path`.
    package static func appendRawLine(_ line: String, at url: URL? = nil) {
        withExclusiveLock(at: url ?? path) { fd in
            let size = max(0, Int(lseek(fd, 0, SEEK_END)))
            lseek(fd, 0, SEEK_SET)
            let newLine = line.trimmingCharacters(in: .newlines)
            // `read(2)` may return fewer bytes than asked; one call used to
            // be taken as the whole file, and the rewrite below then dropped
            // everything it had not read.
            let data = size > 0 ? readAll(fd, size: size) : Data()
            guard data.count == size else {
                // Could not read what is there: never rewrite from a partial
                // copy. Append instead — an empty line is skipped by readers.
                lseek(fd, 0, SEEK_END)
                writeAll(fd, "\n" + newLine + "\n")
                fsync(fd)
                return
            }
            // Lossy, never empty: one invalid byte (a hook that wrote a
            // truncated multibyte character) used to decode the whole file
            // as "" — and the rewrite then erased every open wait.
            let text = decode(data)
            var lines = text.split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            lines.append(newLine)
            if lines.count > maxRetainedLines {
                lines = compactLines(lines, cap: maxRetainedLines)
            }
            let body = header + lines.joined(separator: "\n") + "\n"
            ftruncate(fd, 0)
            lseek(fd, 0, SEEK_SET)
            writeAll(fd, body)
            fsync(fd)
        }
    }

    private static func withExclusiveLock(at url: URL, _ body: (Int32) -> Void) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 0600, not 0644: every line in this file is either a command an
        // agent asked to run or the directory it asked from. The creation
        // mode only covers new installs, so an existing file is brought down
        // through the descriptor already in hand — see `PrivateFile.tighten`.
        let fd = url.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
        guard fd >= 0 else {
            DebugLog.write("attention open failed errno=\(errno)")
            return
        }
        defer { close(fd) }
        PrivateFile.tighten(fileDescriptor: fd)
        if flock(fd, LOCK_EX) != 0 {
            DebugLog.write("attention flock failed errno=\(errno)")
            return
        }
        defer { _ = flock(fd, LOCK_UN) }
        body(fd)
    }
}
