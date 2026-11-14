import Darwin
import Foundation

/// The one event log: `events.tsv`, append-only, one numbered v10 line per
/// hook event (`AttentionRecord`), in the order the hooks wrote them.
///
/// - **Only a v10 log is read.** A file whose first line is not a v10
///   header (`AttentionProtocol.Header`) is treated as absent: a read finds
///   it empty, and the next writer (`append`, `ensureExists` at launch)
///   empties it and starts a fresh v10 log — a new `gen`, numbering from 1 —
///   under the same lock. It is never read and never migrated.
/// - **Writers append** under an exclusive `flock` (`append`): the hook
///   receiver and the app's own `dismiss`. The appender numbers the line —
///   one past the last line's `seq` (or the header's `next`) — so the
///   numbering is the order the lock granted. A line is at most
///   `maxLineBytes` (its message is cut to fit), so the last `seq` is always
///   inside the tail an appender reads. The file is created 0600.
/// - **It is bounded by rotation, never by meaning.** An append that would
///   take the file past `maxBytes` first moves its bytes, unread, to
///   `events.1.tsv` (replacing the one before), then empties the live file
///   under a header with the same `gen` and the next `seq`. Same inode, same
///   lock: a writer waiting on the lock appends to the fresh file. The hook
///   never parses the log and never runs the reducer.
/// - **Readers read from an offset** (`read(after:)`) under a shared lock,
///   only complete lines, split on `\n` bytes alone. A cursor whose header
///   is not the file's (a rotation, a log started over), or one past the
///   end, reads the rotated file of the same `gen` and the live file whole;
///   either way the reader applies only the lines numbered past the last it
///   applied (`Chunk.unapplied`) — or every line, when the file is another
///   log (`gen`). A missing file is an empty log; a failed read returns nil
///   and changes nothing.
/// - **What outlives the log is the app's snapshot** (`BookSnapshot`): the
///   reduced book, written by the app, so a session older than both files
///   keeps its title and clocks across a relaunch.
package enum EventLog {
    package static let fileName = "events.tsv"
    package static let rotatedFileName = "events.1.tsv"
    /// An append that would pass this rotates the file first.
    package static let maxBytes = 1 << 20
    /// The most a whole-file read takes from the end of an oversized file
    /// (one grown past the bound by hand): its tail, from a line boundary.
    package static let readLimit = 4 << 20
    /// The longest line an appender writes, in UTF-8 bytes.
    package static let maxLineBytes = 8 * 1024
    /// How far from the end an append looks for the last line's `seq`:
    /// several whole lines, so a torn last line never hides the number.
    static let tailWindow = 8 * maxLineBytes

    package static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
    }

    /// Pulse's support folder: `PULSE_HOME` when set (the hook self-test and
    /// integration runs), else Application Support.
    package static var directory: URL {
        if let home = ProcessInfo.processInfo.environment["PULSE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return defaultDirectory
    }

    package static var path: URL {
        directory.appendingPathComponent(fileName)
    }

    /// Where `url`'s rotated bytes go: `events.1.tsv` beside it.
    package static func rotatedURL(for url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(base + ".1." + (url.pathExtension.isEmpty ? "tsv" : url.pathExtension))
    }

    /// Where a reader is: the header line it read (so a rewrite is seen),
    /// the byte after the last complete line it read, the log it read
    /// (`gen`) and the last `seq` it applied.
    package struct Cursor: Equatable, Sendable {
        package var header: String
        package var offset: Int
        package var gen: String
        package var seq: Int64

        package init(header: String, offset: Int, gen: String, seq: Int64) {
            self.header = header
            self.offset = offset
            self.gen = gen
            self.seq = seq
        }
    }

    /// One read.
    package struct Chunk: Equatable, Sendable {
        /// The file's header; nil when there is no v10 log (a missing or
        /// empty file, or one that is not v10) — an empty log.
        package var header: AttentionProtocol.Header?
        /// The header line exactly as read.
        package var headerLine: String
        /// Complete records, in file order.
        package var records: [AttentionRecord]
        /// The byte after the last complete line read.
        package var end: Int

        package init(header: AttentionProtocol.Header?, headerLine: String = "", records: [AttentionRecord], end: Int) {
            self.header = header
            self.headerLine = headerLine.isEmpty ? (header.map { String($0.line.dropLast()) } ?? "") : headerLine
            self.records = records
            self.end = end
        }

        /// No log there.
        package static let empty = Chunk(header: nil, records: [], end: 0)

        /// The records a reader at `cursor` has not applied: those numbered
        /// past its `seq` when this is the log it read; every one when it is
        /// another (started over since). Pure.
        package func unapplied(after cursor: Cursor?) -> [AttentionRecord] {
            guard let header else { return [] }
            let last = cursor?.gen == header.gen ? cursor?.seq ?? 0 : 0
            return records.filter { $0.seq > last }
        }

        /// Where the reader is once this chunk is applied: this header, this
        /// end, the newest `seq` applied. No log there moves nothing. Pure.
        package func advancing(_ cursor: Cursor?) -> Cursor? {
            guard let header else { return cursor }
            let newest = records.map(\.seq).max() ?? 0
            let seq = cursor?.gen == header.gen ? max(cursor?.seq ?? 0, newest) : newest
            return Cursor(header: headerLine, offset: end, gen: header.gen, seq: seq)
        }
    }

    /// A new `gen`: never the same twice on this Mac.
    package static func generation(nowMs: Int64) -> String {
        "g\(nowMs)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    }

    // MARK: - Write

    /// Append one record, numbered under the lock (its `seq` is ignored and
    /// assigned). Creates the file with its header — and starts it over when
    /// it is not a v10 log; rotates it first when the line would take it past
    /// `maxBytes`. Returns whether the line is in the file. `url` nil is the
    /// real log; a test passes its own file.
    @discardableResult
    package static func append(_ record: AttentionRecord, at url: URL? = nil, nowMs: Int64) -> Bool {
        let target = url ?? path
        return withExclusiveLock(at: target) { fd in
            var size = Int(lseek(fd, 0, SEEK_END))
            guard size >= 0 else { return false }
            let header = size > 0 ? currentHeader(fd, size: size) : nil
            if size > 0, header == nil {
                DebugLog.write("events: not a v10 log — started over")
                guard ftruncate(fd, 0) == 0 else { return false }
                size = 0
            }
            var line = fitted(record)
            line.seq = max(header?.next ?? 1, (header == nil ? 0 : lastSeq(fd, size: size)) + 1)
            let text = line.line
            var out = ""
            if let header, size + text.utf8.count + 1 > maxBytes {
                // Rotate: the bytes go unread to events.1.tsv; the live file
                // starts again under the same gen, numbering on.
                guard let data = readRange(fd, from: 0, count: size), data.count == size,
                      writeRotated(data, to: rotatedURL(for: target)),
                      ftruncate(fd, 0) == 0
                else {
                    DebugLog.write("events rotation failed; appending past the bound")
                    return writeAll(fd, separator(fd, size: size) + text + "\n")
                }
                out = AttentionProtocol.Header(next: line.seq + 1, gen: header.gen).line
            } else if size == 0 {
                out = AttentionProtocol.Header(next: line.seq + 1, gen: generation(nowMs: nowMs)).line
            } else {
                out = separator(fd, size: size)
            }
            out += text + "\n"
            return writeAll(fd, out)
        } ?? false
    }

    /// A line break before the new line when a writer died mid-line: never
    /// glue a record onto it.
    private static func separator(_ fd: Int32, size: Int) -> String {
        guard size > 0, let last = readRange(fd, from: size - 1, count: 1), last.first != 0x0A else { return "" }
        return "\n"
    }

    /// The record cut to `maxLineBytes`: its message first, then its folder
    /// and facts, at a character boundary. Pure.
    package static func fitted(_ record: AttentionRecord) -> AttentionRecord {
        var line = record
        line.seq = max(line.seq, 1)
        func over() -> Int { line.line.utf8.count - maxLineBytes }
        if over() > 0 { line.message = cut(line.message, by: over()) }
        if over() > 0 { line.meta = LineMeta() }
        if over() > 0 { line.cwd = cut(line.cwd, by: over()) }
        if over() > 0 { line.tool = cut(line.tool, by: over()) }
        return line
    }

    /// `text` shortened by at least `bytes` UTF-8 bytes, whole characters.
    private static func cut(_ text: String, by bytes: Int) -> String {
        var budget = max(0, text.utf8.count - bytes)
        var out = ""
        for character in text {
            let size = character.utf8.count
            if size > budget { break }
            budget -= size
            out.append(character)
        }
        return out
    }

    /// The rotated file, written whole and private, then moved into place.
    private static func writeRotated(_ data: Data, to url: URL) -> Bool {
        PrivateFile.write(data, to: url)
    }

    /// Create the file with its header if it is missing, empty or not a v10
    /// log (then it is emptied first, unread) — what the watcher needs
    /// before it can open it.
    package static func ensureExists(at url: URL? = nil, nowMs: Int64) {
        _ = withExclusiveLock(at: url ?? path) { fd -> Bool in
            let size = Int(lseek(fd, 0, SEEK_END))
            guard size >= 0 else { return false }
            if size > 0 {
                if currentHeader(fd, size: size) != nil { return true }
                DebugLog.write("events: not a v10 log — started over")
                guard ftruncate(fd, 0) == 0 else { return false }
            }
            return writeAll(fd, AttentionProtocol.Header(next: 1, gen: generation(nowMs: nowMs)).line)
        }
    }

    /// The open file's v10 header, or nil.
    private static func currentHeader(_ fd: Int32, size: Int) -> AttentionProtocol.Header? {
        guard let head = readRange(fd, from: 0, count: min(size, 512)) else { return nil }
        return AttentionProtocol.Header(line: headerLine(head))
    }

    /// The `seq` of the last record in the file; 0 when none reads. The
    /// tail holds whole lines (`maxLineBytes`); a file grown by hand past
    /// that is read whole rather than numbered backwards.
    private static func lastSeq(_ fd: Int32, size: Int) -> Int64 {
        for window in [min(size, tailWindow), size] {
            guard let tail = readRange(fd, from: size - window, count: window) else { return 0 }
            for line in tail.split(separator: 0x0A).reversed() {
                if let record = AttentionRecord(line: String(decoding: line, as: UTF8.self)) { return record.seq }
            }
            if window == size { break }
        }
        return 0
    }

    // MARK: - Read

    /// The records after `cursor`, or the whole file when the cursor is
    /// nil, names another header, or is past the end. A missing file, or one
    /// that is not a v10 log, is an empty log (`Chunk.empty`). Nil when the
    /// file could not be read — the caller keeps what it had.
    package static func read(at url: URL? = nil, after cursor: Cursor?) -> Chunk? {
        let target = url ?? path
        let fd = target.path.withCString { open($0, O_RDONLY) }
        if fd < 0, errno == ENOENT { return .empty }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_SH) == 0 else { return nil }
        defer { _ = flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let size = Int(info.st_size)
        guard size > 0 else { return .empty }
        guard let head = readRange(fd, from: 0, count: min(size, 512)) else { return nil }
        let line = headerLine(head)
        guard let header = AttentionProtocol.Header(line: line) else { return .empty }
        var start = 0
        var whole = true
        if let cursor, cursor.header == line, cursor.offset >= 0, cursor.offset <= size {
            start = cursor.offset
            whole = false
        }
        var partialFirst = false
        if whole, size > readLimit {
            start = size - readLimit
            partialFirst = true
        }
        guard start < size else { return Chunk(header: header, headerLine: line, records: [], end: start) }
        guard let data = readRange(fd, from: start, count: size - start), data.count == size - start else {
            return nil
        }
        let parsed = parse(data, from: start, skipFirstLine: partialFirst)
        // A whole read starts with the rotated file of the same log: the
        // lines a rotation moved before this reader saw them.
        let rotated = whole && !partialFirst ? readRotated(of: target, gen: header.gen) : []
        return Chunk(header: header, headerLine: line, records: rotated + parsed.records, end: parsed.end)
    }

    /// The complete records of `url`'s rotated file when it belongs to the
    /// log `gen`; none otherwise.
    private static func readRotated(of url: URL, gen: String) -> [AttentionRecord] {
        guard let data = try? Data(contentsOf: rotatedURL(for: url)), data.count <= readLimit else { return [] }
        guard let header = AttentionProtocol.Header(line: headerLine(data.prefix(512))), header.gen == gen else { return [] }
        return parse(data, from: 0).records
    }

    /// The first line when it is a `#` header, without its line break.
    package static func headerLine(_ head: Data) -> String {
        let bytes = [UInt8](head)
        guard bytes.first == UInt8(ascii: "#") else { return "" }
        let end = bytes.firstIndex(of: 0x0A) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `data` read from byte `start`: its complete records (up to the last
    /// line break; a line still being written is left for the next read)
    /// and the byte after the last complete line. Lines end at `\n` bytes
    /// only — a U+2028 or a lone `\r` inside a field never splits a record.
    /// Lossy: one invalid byte never hides the file. Comments, blanks and
    /// lines that are not v10 records are skipped.
    package static func parse(_ data: Data, from start: Int, skipFirstLine: Bool = false) -> (records: [AttentionRecord], end: Int) {
        let bytes = [UInt8](data)
        guard let lastBreak = bytes.lastIndex(of: 0x0A) else { return ([], start) }
        var lineStart = 0
        if skipFirstLine, let first = bytes.firstIndex(of: 0x0A) {
            lineStart = first + 1
        }
        var records: [AttentionRecord] = []
        var index = lineStart
        while index <= lastBreak {
            if bytes[index] == 0x0A {
                if index > lineStart,
                   let record = AttentionRecord(line: String(decoding: bytes[lineStart..<index], as: UTF8.self)) {
                    records.append(record)
                }
                lineStart = index + 1
            }
            index += 1
        }
        return (records, start + lastBreak + 1)
    }

    // MARK: - Completeness

    /// Whether `records` — one whole read of a log — are every line the log
    /// was ever given: numbered 1, 2, 3… with none missing. A compaction
    /// drops lines, and a read cut to an oversized file's tail starts past
    /// the first; a log with no line has dropped none. Pure.
    package static func keepsEveryLine(_ records: [AttentionRecord]) -> Bool {
        for (index, record) in records.enumerated() where record.seq != Int64(index) + 1 { return false }
        return true
    }

    // MARK: - Descriptors

    private static func withExclusiveLock(at url: URL, _ body: (Int32) -> Bool) -> Bool? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 0600: a line holds the command an agent asked to run and the
        // folder it asked from. An existing file is brought down through the
        // descriptor in hand (`PrivateFile.tighten`).
        let fd = url.path.withCString { open($0, O_RDWR | O_CREAT | O_APPEND, 0o600) }
        guard fd >= 0 else {
            DebugLog.write("events open failed errno=\(errno)")
            return nil
        }
        defer { close(fd) }
        PrivateFile.tighten(fileDescriptor: fd)
        guard flock(fd, LOCK_EX) == 0 else {
            DebugLog.write("events flock failed errno=\(errno)")
            return nil
        }
        defer { _ = flock(fd, LOCK_UN) }
        return body(fd)
    }

    /// `count` bytes from `offset` (`pread` may return short); nil on error.
    private static func readRange(_ fd: Int32, from offset: Int, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        var position = offset
        var remaining = count
        while remaining > 0 {
            let want = min(remaining, buffer.count)
            let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(position)) }
            if got < 0, errno == EINTR { continue }
            if got < 0 { return nil }
            if got == 0 { break }
            data.append(contentsOf: buffer[0..<got])
            position += got
            remaining -= got
        }
        return data
    }

    /// `write(2)` may be short; loop until every byte is down.
    private static func writeAll(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let wrote = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + offset, bytes.count - offset)
            }
            if wrote < 0, errno == EINTR { continue }
            if wrote <= 0 { return false }
            offset += wrote
        }
        return true
    }
}
