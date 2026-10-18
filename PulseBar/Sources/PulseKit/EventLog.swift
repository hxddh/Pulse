import Darwin
import Foundation

/// The one event log: `events.tsv`, append-only, one numbered v8 line per
/// hook event (`AttentionRecord`), in the order the hooks wrote them.
///
/// - **Only a v8 log is read.** A file whose first line is not a v8 header
///   (`AttentionProtocol.Header`) is treated as absent: a read finds it
///   empty, and the next writer (`append`, `ensureExists` at launch) empties
///   it and starts a fresh v8 log — a new `gen`, numbering from 1 — under the
///   same lock. It is never read and never migrated.
/// - **Writers append** under an exclusive `flock` (`append`): the hook
///   receiver and the app's own `dismiss`. The appender numbers the line —
///   one past the last line's `seq` (or the header's `next`) — so the
///   numbering is the order the lock granted. The file is created 0600
///   (`PrivateFile.tighten`).
/// - **It is bounded**: an append that would take the file past `maxBytes`
///   compacts it first (`compact`) and rewrites it under a header with the
///   same `gen` and a new `next`. Every kept line keeps its `seq`. Per
///   session (or per agent + folder for a session-less one) it keeps the
///   last `linesPerSession` lines, every line of the last `recentWindowMs`
///   and the lines a replay rebuilds its title and clocks from; it never
///   drops an open block — as a replay through `SessionBook` holds it —
///   nor anything after it in that session (the lines that answer it), nor
///   the line being appended.
/// - **Readers read from an offset** (`read(after:)`) under a shared lock,
///   only complete lines, split on `\n` bytes alone. A cursor whose header
///   is not the file's (a compaction, a log started over), or one past the
///   end, reads the whole file again; either way the reader applies only
///   the lines numbered past the last it applied (`Chunk.unapplied`) — or
///   every line, when the file is another log (`gen`). A missing file is an
///   empty log; a failed read returns nil and changes nothing.
package enum EventLog {
    package static let fileName = "events.tsv"
    /// An append that would pass this compacts the file first.
    package static let maxBytes = 1 << 20
    /// What a compaction aims for, so the next one is far away.
    package static let targetBytes = maxBytes / 2
    /// The most a whole-file read takes from the end of an oversized file
    /// (one grown past the bound by hand): its tail, from a line boundary.
    package static let readLimit = 4 << 20
    /// Lines kept per session by a compaction (at least; see `compact`).
    package static let linesPerSession = 64
    /// Every line this recent survives a compaction.
    package static let recentWindowMs: Int64 = 2 * 60 * 60 * 1000
    /// A session whose newest line is older than this is dropped whole by a
    /// compaction — `SessionBook` forgets it after the same day.
    package static let retentionMs: Int64 = 24 * 60 * 60 * 1000
    /// How far from the end an append looks for the last line's `seq`.
    static let tailWindow = 16 * 1024

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
        /// The file's header; nil when there is no v8 log (a missing or
        /// empty file, or one that is not v8) — an empty log.
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
    /// it is not a v8 log; compacts it first when the line would take it past
    /// `maxBytes`. Returns whether the line is in the file. `url` nil is the
    /// real log; a test passes its own file.
    @discardableResult
    package static func append(_ record: AttentionRecord, at url: URL? = nil, nowMs: Int64) -> Bool {
        withExclusiveLock(at: url ?? path) { fd in
            var size = Int(lseek(fd, 0, SEEK_END))
            guard size >= 0 else { return false }
            let header = size > 0 ? currentHeader(fd, size: size) : nil
            if size > 0, header == nil {
                DebugLog.write("events: not a v8 log — started over")
                guard ftruncate(fd, 0) == 0 else { return false }
                size = 0
            }
            var line = record
            line.seq = max(header?.next ?? 1, (header == nil ? 0 : lastSeq(fd, size: size)) + 1)
            let text = line.line
            if let header, size + text.utf8.count + 1 > maxBytes {
                // Read whole or not at all: a rewrite from a partial copy
                // would drop lines nobody has read.
                if let data = readRange(fd, from: 0, count: size), data.count == size {
                    // The record being appended is always kept: the append
                    // reports success only when its line is in the file.
                    var kept = compact(parse(data, from: 0).records + [line], nowMs: nowMs)
                    if kept.last != line { kept.append(line) }
                    let body = AttentionProtocol.Header(next: line.seq + 1, gen: header.gen).line
                        + kept.map { $0.line + "\n" }.joined()
                    guard ftruncate(fd, 0) == 0 else { return false }
                    let ok = writeAll(fd, body)
                    fsync(fd)
                    return ok
                }
                DebugLog.write("events compaction skipped: short read")
            }
            var out = ""
            if size == 0 {
                out = AttentionProtocol.Header(next: line.seq + 1, gen: generation(nowMs: nowMs)).line
            } else if let last = readRange(fd, from: size - 1, count: 1), last.first != 0x0A {
                // A writer died mid-line: never glue this record onto it.
                out = "\n"
            }
            out += text + "\n"
            return writeAll(fd, out)
        } ?? false
    }

    /// Create the file with its header if it is missing, empty or not a v8
    /// log (then it is emptied first, unread) — what the watcher needs
    /// before it can open it.
    package static func ensureExists(at url: URL? = nil, nowMs: Int64) {
        _ = withExclusiveLock(at: url ?? path) { fd -> Bool in
            let size = Int(lseek(fd, 0, SEEK_END))
            guard size >= 0 else { return false }
            if size > 0 {
                if currentHeader(fd, size: size) != nil { return true }
                DebugLog.write("events: not a v8 log — started over")
                guard ftruncate(fd, 0) == 0 else { return false }
            }
            return writeAll(fd, AttentionProtocol.Header(next: 1, gen: generation(nowMs: nowMs)).line)
        }
    }

    /// The open file's v8 header, or nil.
    private static func currentHeader(_ fd: Int32, size: Int) -> AttentionProtocol.Header? {
        guard let head = readRange(fd, from: 0, count: min(size, 512)) else { return nil }
        return AttentionProtocol.Header(line: headerLine(head))
    }

    /// The `seq` of the last record in the file's tail; 0 when none reads.
    private static func lastSeq(_ fd: Int32, size: Int) -> Int64 {
        let count = min(size, tailWindow)
        guard let tail = readRange(fd, from: size - count, count: count) else { return 0 }
        for line in tail.split(separator: 0x0A).reversed() {
            if let record = AttentionRecord(line: String(decoding: line, as: UTF8.self)) { return record.seq }
        }
        return 0
    }

    // MARK: - Read

    /// The records after `cursor`, or the whole file when the cursor is
    /// nil, names another header, or is past the end. A missing file, or one
    /// that is not a v8 log, is an empty log (`Chunk.empty`). Nil when the
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
        return Chunk(header: header, headerLine: line, records: parsed.records, end: parsed.end)
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
    /// lines that are not v8 records are skipped.
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

    // MARK: - Compaction

    /// The records a compaction keeps, in their order, each with its `seq`.
    /// Pure.
    ///
    /// Records are grouped by session — `SessionKey`, so a session-less one
    /// is grouped by agent **and** folder, never by agent alone — and a
    /// session-less `done` or `dismiss` naming no folder belongs to every
    /// session-less group of its agent before it. A group whose newest line
    /// is older than `retentionMs` goes whole. The records are replayed
    /// through `SessionBook`, so its own rules say what a session needs:
    /// each group keeps its last `linesPerSession` lines, every line newer
    /// than `recentWindowMs`, and — whatever the budget — the lines its first
    /// clock, title, turn clock, latest prompt and vendor name came from
    /// (`SessionBook.Anchors`, none of them a block) and, while the book
    /// holds it blocked, the raise that turned it red with everything after
    /// it — so a block is never kept without the lines that answer it and
    /// never dropped while it is open. Over `budget`, the per-session count
    /// and the window halve until it fits (or reach one line and nothing).
    package static func compact(_ records: [AttentionRecord], nowMs: Int64, budget: Int = targetBytes) -> [AttentionRecord] {
        var groupsOf: [[SessionKey]] = []
        var sessionless: [AgentID: Set<SessionKey>] = [:]
        for record in records {
            let session = record.session.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = SessionKey(record.agent, session, cwd: record.cwd)
            if session.isEmpty, record.kind.isResolution, record.cwd.isEmpty {
                let all = (sessionless[record.agent] ?? []).sorted()
                groupsOf.append(all.isEmpty ? [key] : all)
            } else {
                if session.isEmpty { sessionless[record.agent, default: []].insert(key) }
                groupsOf.append([key])
            }
        }
        var members: [SessionKey: [Int]] = [:]
        var newest: [SessionKey: Int64] = [:]
        for (position, groups) in groupsOf.enumerated() {
            for group in groups {
                members[group, default: []].append(position)
                newest[group] = max(newest[group] ?? .min, records[position].ms)
            }
        }

        // The replay, each line numbered by its position (1-based: 0 is
        // "none" to the book).
        var book = SessionBook()
        for (position, record) in records.enumerated() {
            var line = record
            line.seq = Int64(position) + 1
            book.apply(line, nowMs: nowMs)
        }
        var anchors: [SessionKey: [Int]] = [:]
        var openFrom: [SessionKey: Int] = [:]
        for (key, session) in book.sessions {
            anchors[key] = session.anchors.lines.map { Int($0) - 1 }
            if case .blocked = session.state, session.anchors.block > 0 { openFrom[key] = Int(session.anchors.block) - 1 }
        }
        let live = Set(members.keys.filter { nowMs - (newest[$0] ?? 0) <= retentionMs })

        func select(perSession: Int, windowMs: Int64) -> Set<Int> {
            var keep = Set<Int>()
            for group in live {
                guard let positions = members[group] else { continue }
                keep.formUnion(anchors[group] ?? [])
                keep.formUnion(positions.suffix(perSession))
                if let open = openFrom[group] { keep.formUnion(positions.filter { $0 >= open }) }
            }
            if windowMs > 0 {
                for (position, groups) in groupsOf.enumerated()
                where nowMs - records[position].ms <= windowMs && groups.contains(where: { live.contains($0) }) {
                    keep.insert(position)
                }
            }
            return keep
        }
        let sizes = records.map { $0.line.utf8.count + 1 }
        func bytes(_ keep: Set<Int>) -> Int {
            keep.reduce(0) { $0 + sizes[$1] }
        }

        var perSession = linesPerSession
        var windowMs = recentWindowMs
        var keep = select(perSession: perSession, windowMs: windowMs)
        while bytes(keep) > budget, perSession > 1 || windowMs > 0 {
            perSession = max(1, perSession / 2)
            windowMs = windowMs / 2 < 60_000 ? 0 : windowMs / 2
            keep = select(perSession: perSession, windowMs: windowMs)
        }
        return keep.sorted().map { records[$0] }
    }

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
