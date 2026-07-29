import Darwin
import Foundation

/// Locked read/write for attention.tsv — same exclusive flock as pulse_hook.py.
/// Columns: agent \\t kind \\t ms \\t message \\t session \\t cwd
enum AttentionIO {
    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/attention.tsv")
    }

    /// Must match `pulse_hook.py` and `AttentionWatcher` byte for byte —
    /// three different header strings used to end up in the same file.
    static let header = "# Pulse attention log (agent\\tkind\\tms\\tmessage\\tsession\\tcwd)\n"

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

    private static func appendRawLine(_ line: String) {
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
            if lines.count > 80 {
                lines = Array(lines.suffix(80))
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
