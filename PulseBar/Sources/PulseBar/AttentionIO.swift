import Darwin
import Foundation

/// Locked read/write for attention.tsv — same exclusive flock as pulse_hook.py.
/// Columns: agent \\t kind \\t ms \\t message \\t session \\t cwd
enum AttentionIO {
    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/attention.tsv")
    }

    private static let header = "# Pulse attention log (agent\\tkind\\tms\\tmessage\\tsession\\tcwd)\n"

    static func readText() -> String {
        var result = ""
        withExclusiveLock { fd in
            let size = lseek(fd, 0, SEEK_END)
            lseek(fd, 0, SEEK_SET)
            guard size > 0 else { return }
            var data = Data(count: Int(size))
            _ = data.withUnsafeMutableBytes { buf in
                read(fd, buf.baseAddress, Int(size))
            }
            result = String(data: data, encoding: .utf8) ?? ""
        }
        return result
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
