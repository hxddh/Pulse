import Darwin
import Foundation
import PulseCore

/// The one event log: `events.tsv`, append-only, one v5 line per hook
/// event (`AttentionRecord`), in the order the hooks wrote them.
///
/// - **Writers append** under an exclusive `flock` (`append`): the hook
///   receiver, the app's own `done` for a dismissal, an integrator's script.
///   The file is created 0600 (`PrivateFile.tighten`) with a header naming
///   its generation.
/// - **It is bounded**: an append that would take the file past `maxBytes`
///   compacts it first (`compact`) and writes a new header, so a reader
///   holding a byte offset sees the new generation and starts over. The
///   compaction keeps, per session (or per agent + folder for a session-less
///   one), its last `linesPerSession` lines, every line of the last
///   `recentWindowMs`, its first line that is not a block, the prompt its
///   title came from and its latest prompt; it never drops an open block,
///   nor anything after it in that session — the lines that answer it —
///   nor the line being appended.
/// - **Readers read from an offset** (`read(after:)`) under a shared lock,
///   only complete lines, split on `\n` bytes alone. A cursor from another
///   generation, or past the end, reads the whole file again
///   (`Chunk.fresh`); the engine then applies only the lines it has not
///   (`unapplied(_:after:)`). A missing file is an empty log; a failed read
///   returns nil and changes nothing.
package enum EventLog {
    package static let fileName = "events.tsv"
    /// An append that would pass this compacts the file first.
    package static let maxBytes = 1 << 20
    /// What a compaction aims for, so the next one is far away.
    package static let targetBytes = maxBytes / 2
    /// The most a fresh read takes from the end of an oversized file (one an
    /// integrator grew past the bound): its tail, from a line boundary.
    package static let readLimit = 4 << 20
    /// Lines kept per session by a compaction (at least; see `compact`).
    package static let linesPerSession = 64
    /// Every line this recent survives a compaction.
    package static let recentWindowMs: Int64 = 2 * 60 * 60 * 1000
    /// A session whose newest line is older than this is dropped whole by a
    /// compaction — `SessionBook` forgets it after the same day.
    package static let retentionMs: Int64 = 24 * 60 * 60 * 1000

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

    /// Where a reader is: the generation it read (the header line) and the
    /// byte after the last complete line it applied.
    package struct Cursor: Equatable, Sendable {
        package var header: String
        package var offset: Int

        package init(header: String, offset: Int) {
            self.header = header
            self.offset = offset
        }
    }

    /// One read.
    package struct Chunk: Equatable, Sendable {
        /// The file's first line when it is a `#` header, else "".
        package var header: String
        /// Complete lines, in file order, without comments or blanks.
        package var lines: [String]
        /// The byte after the last complete line read.
        package var end: Int
        /// Read from the start of the file (no cursor, another generation,
        /// or a file shorter than the cursor): some lines may already have
        /// been applied.
        package var fresh: Bool
        /// The byte the read began at (the cursor's offset for a read that
        /// is not fresh); nil when not known.
        package var start: Int?
        /// The byte after each of `lines`, in step with it; empty when not
        /// known. With `start`, it lets a reader whose cursor has moved on
        /// since the read began skip the lines it has already applied.
        package var lineEnds: [Int]

        package init(header: String, lines: [String], end: Int, fresh: Bool, start: Int? = nil, lineEnds: [Int] = []) {
            self.header = header
            self.lines = lines
            self.end = end
            self.fresh = fresh
            self.start = start
            self.lineEnds = lineEnds
        }

        /// The lines that end after `offset` — what is left of this chunk
        /// for a reader already there. Nil when the chunk cannot say (no
        /// line ends).
        package func lines(after offset: Int) -> [String]? {
            guard lineEnds.count == lines.count else { return nil }
            return zip(lines, lineEnds).filter { $0.1 > offset }.map { $0.0 }
        }

        package var cursor: Cursor { Cursor(header: header, offset: end) }
    }

    /// A new generation token: never the same twice on this Mac.
    package static func generation(nowMs: Int64) -> String {
        "g\(nowMs)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    }

    // MARK: - Write

    /// Append one line (a v5 record's `line`). Creates the file with its
    /// header; compacts it first when the line would take it past
    /// `maxBytes`. `url` nil is the real log; a test passes its own file.
    @discardableResult
    package static func append(_ line: String, at url: URL? = nil, nowMs: Int64) -> Bool {
        let record = line.trimmingCharacters(in: .newlines)
        guard !record.isEmpty else { return false }
        return withExclusiveLock(at: url ?? path) { fd in
            let size = Int(lseek(fd, 0, SEEK_END))
            guard size >= 0 else { return false }
            if size > 0, size + record.utf8.count + 1 > maxBytes {
                // Read whole or not at all: a rewrite from a partial copy
                // would drop lines nobody has read.
                if let data = readRange(fd, from: 0, count: size), data.count == size {
                    let lines = parse(data, from: 0, header: "", fresh: true).lines
                    // The record being appended is always kept: the append
                    // reports success only when its line is in the file.
                    var kept = compact(lines + [record], nowMs: nowMs)
                    if kept.last != record { kept.append(record) }
                    let body = AttentionProtocol.header(generation: generation(nowMs: nowMs))
                        + kept.map { $0 + "\n" }.joined()
                    guard ftruncate(fd, 0) == 0 else { return false }
                    let ok = writeAll(fd, body)
                    fsync(fd)
                    return ok
                }
                DebugLog.write("events compaction skipped: short read")
            }
            var text = ""
            if size == 0 {
                text = AttentionProtocol.header(generation: generation(nowMs: nowMs))
            } else if let last = readRange(fd, from: size - 1, count: 1), last.first != 0x0A {
                // A writer died mid-line: never glue this record onto it.
                text = "\n"
            }
            text += record + "\n"
            return writeAll(fd, text)
        } ?? false
    }

    /// Create the file with its header if it is missing or empty — what the
    /// watcher needs before it can open it.
    package static func ensureExists(at url: URL? = nil, nowMs: Int64) {
        _ = withExclusiveLock(at: url ?? path) { fd -> Bool in
            guard lseek(fd, 0, SEEK_END) == 0 else { return true }
            return writeAll(fd, AttentionProtocol.header(generation: generation(nowMs: nowMs)))
        }
    }

    // MARK: - Read

    /// The lines after `cursor`, or the whole file when the cursor is nil,
    /// from another generation, or past the end. A missing file is an empty
    /// log (a fresh, empty chunk). Nil when the file could not be read — the
    /// caller keeps what it had.
    package static func read(at url: URL? = nil, after cursor: Cursor?) -> Chunk? {
        let target = url ?? path
        let fd = target.path.withCString { open($0, O_RDONLY) }
        if fd < 0, errno == ENOENT { return Chunk(header: "", lines: [], end: 0, fresh: true) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_SH) == 0 else { return nil }
        defer { _ = flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let size = Int(info.st_size)
        guard size > 0 else { return Chunk(header: "", lines: [], end: 0, fresh: true) }
        guard let head = readRange(fd, from: 0, count: min(size, 512)) else { return nil }
        let header = headerLine(head)
        var start = 0
        var fresh = true
        if let cursor, cursor.header == header, cursor.offset >= 0, cursor.offset <= size {
            start = cursor.offset
            fresh = false
        }
        var partialFirst = false
        if fresh, size > readLimit {
            start = size - readLimit
            partialFirst = true
        }
        guard start < size else { return Chunk(header: header, lines: [], end: start, fresh: fresh, start: start) }
        guard let data = readRange(fd, from: start, count: size - start), data.count == size - start else {
            return nil
        }
        return parse(data, from: start, header: header, fresh: fresh, skipFirstLine: partialFirst)
    }

    /// The first line when it is a `#` header, without its line break.
    package static func headerLine(_ head: Data) -> String {
        let bytes = [UInt8](head)
        guard bytes.first == UInt8(ascii: "#") else { return "" }
        let end = bytes.firstIndex(of: 0x0A) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `data` read from byte `start`: its complete lines (up to the last line
    /// break; a line still being written is left for the next read), without
    /// comments or blanks. Lines end at `\n` bytes only — a U+2028 or a lone
    /// `\r` inside a field never splits a record. Lossy: one invalid byte
    /// never hides the file.
    package static func parse(_ data: Data, from start: Int, header: String, fresh: Bool, skipFirstLine: Bool = false) -> Chunk {
        let bytes = [UInt8](data)
        guard let lastBreak = bytes.lastIndex(of: 0x0A) else {
            return Chunk(header: header, lines: [], end: start, fresh: fresh, start: start)
        }
        var lineStart = 0
        if skipFirstLine, let first = bytes.firstIndex(of: 0x0A) {
            lineStart = first + 1
        }
        var lines: [String] = []
        var ends: [Int] = []
        var index = lineStart
        while index <= lastBreak {
            if bytes[index] == 0x0A {
                if index > lineStart {
                    var line = String(decoding: bytes[lineStart..<index], as: UTF8.self)
                    if line.hasSuffix("\r") { line.removeLast() }
                    if !line.isEmpty, !line.hasPrefix("#") {
                        lines.append(line)
                        ends.append(start + index + 1)
                    }
                }
                lineStart = index + 1
            }
            index += 1
        }
        return Chunk(header: header, lines: lines, end: start + lastBreak + 1, fresh: fresh, start: start, lineEnds: ends)
    }

    // MARK: - Compaction

    /// The lines a compaction keeps, in their order. Pure.
    ///
    /// Lines are grouped by session — `RowIdentity.session`, so a
    /// session-less line is grouped by agent **and** folder, never by agent
    /// alone — and a session-less `done` belongs to the group of its folder,
    /// or, when it names none, to every session-less group of its agent it
    /// could clear. A group whose newest line is older than
    /// `retentionMs` goes whole. Of the rest, each keeps its last
    /// `linesPerSession` lines, every line newer than `recentWindowMs`, and —
    /// whatever the budget — its first line that is not a block (the
    /// session's first clock), the prompt its title came from, its latest
    /// prompt, and everything from its open block on (a block no later line
    /// in the group answers; a `status` line answers nothing), so a replay
    /// keeps the session's title and first clock, and a block is never kept
    /// without the lines that answer it and never dropped while it is open.
    /// Over `budget`, the per-session count and the window halve until it fits
    /// (or reach one line and nothing). Unreadable lines and unknown agents
    /// go: no reader would apply them.
    package static func compact(_ lines: [String], nowMs: Int64, budget: Int = targetBytes) -> [String] {
        struct Line {
            var index: Int
            var record: AttentionRecord
            var kind: AttentionKind?
            var groups: [String]
        }
        var parsed: [Line] = []
        var sessionless: [AgentID: Set<String>] = [:]
        for (index, raw) in lines.enumerated() {
            guard let record = AttentionRecord(line: raw),
                  let agent = AgentCatalog.agent(named: record.agent)
            else { continue }
            let kind = AttentionProtocol.kind(record.kind)
            let session = record.session.trimmingCharacters(in: .whitespacesAndNewlines)
            var groups: [String]
            if session.isEmpty, kind == .done, record.cwd.isEmpty {
                groups = (sessionless[agent] ?? []).sorted()
                if groups.isEmpty { groups = ["\(agent.rawValue)|done"] }
            } else {
                let key = RowIdentity.session(agent: agent, session: session, cwd: record.cwd)
                if session.isEmpty { sessionless[agent, default: []].insert(key) }
                groups = [key]
            }
            parsed.append(Line(index: index, record: record, kind: kind, groups: groups))
        }

        // Each group's positions, its newest stamp and its open block.
        var members: [String: [Int]] = [:]
        var newest: [String: Int64] = [:]
        for (position, line) in parsed.enumerated() {
            for group in line.groups {
                members[group, default: []].append(position)
                newest[group] = max(newest[group] ?? .min, line.record.ms)
            }
        }
        var openFrom: [String: Int] = [:]
        for (group, positions) in members {
            var open: Int?
            var openTool = ""
            for position in positions {
                let record = parsed[position].record
                switch parsed[position].kind {
                case .permission?, .question?, .waiting?:
                    if open == nil {
                        open = position
                        openTool = record.tool.isEmpty ? AttentionProtocol.blockedTool(record.message) : record.tool
                    }
                case .working?, .done?, .end?, .start?:
                    open = nil
                case .tool?:
                    // A `status` line is work going on, never an answer.
                    if AttentionRecord.isStatus(tool: record.tool) { break }
                    if openTool.isEmpty || record.tool.isEmpty
                        || record.tool.caseInsensitiveCompare(openTool) == .orderedSame {
                        open = nil
                    }
                case .turn?, .idle?, nil:
                    // A turn inside a block's grace is held, not an answer:
                    // keep the block (keeping too much is only bytes).
                    break
                }
            }
            if let open { openFrom[group] = open }
        }
        let live = Set(members.keys.filter { nowMs - (newest[$0] ?? 0) <= retentionMs })
        // What a replay needs to rebuild a session's own facts, whatever the
        // budget: its first line that is not a block (its first clock), the
        // prompt its title came from — the first `working` line whose text
        // says something (`SessionBook`'s rule) — and its latest prompt (the
        // current turn's clock). None of them raises anything: a block is
        // kept only by the rules above, with what answers it.
        var anchors: [String: Set<Int>] = [:]
        for (group, positions) in members {
            var kept = Set<Int>()
            if let first = positions.first(where: { introduces(parsed[$0].record, kind: parsed[$0].kind) }) {
                kept.insert(first)
            }
            if let title = positions.first(where: { position in
                guard parsed[position].kind == .working else { return false }
                let text = TitleHeuristics.promptTitle(parsed[position].record.message)
                return !text.isEmpty && TitleHeuristics.isMeaningful(text)
            }) {
                kept.insert(title)
            }
            if let latest = positions.last(where: { parsed[$0].kind == .working }) {
                kept.insert(latest)
            }
            anchors[group] = kept
        }

        func select(perSession: Int, windowMs: Int64) -> Set<Int> {
            var keep = Set<Int>()
            for group in live {
                guard let positions = members[group] else { continue }
                keep.formUnion(anchors[group] ?? [])
                keep.formUnion(positions.suffix(perSession))
                if let open = openFrom[group] { keep.formUnion(positions.filter { $0 >= open }) }
            }
            if windowMs > 0 {
                for (position, line) in parsed.enumerated()
                where nowMs - line.record.ms <= windowMs && line.groups.contains(where: { live.contains($0) }) {
                    keep.insert(position)
                }
            }
            return keep
        }
        func bytes(_ keep: Set<Int>) -> Int {
            keep.reduce(0) { $0 + lines[parsed[$1].index].utf8.count + 1 }
        }

        var perSession = linesPerSession
        var windowMs = recentWindowMs
        var keep = select(perSession: perSession, windowMs: windowMs)
        while bytes(keep) > budget, perSession > 1 || windowMs > 0 {
            perSession = max(1, perSession / 2)
            windowMs = windowMs / 2 < 60_000 ? 0 : windowMs / 2
            keep = select(perSession: perSession, windowMs: windowMs)
        }
        return keep.sorted().map { lines[parsed[$0].index] }
    }

    /// Whether a line can introduce a session in `SessionBook` without
    /// raising anything — the line a compaction keeps as a session's first
    /// clock: a `start` or a prompt, or a `turn`, `idle` or `tool` that
    /// names its session. Never a block (an answered one kept without its
    /// answer would be red again), a `done` or an `end`.
    static func introduces(_ record: AttentionRecord, kind: AttentionKind?) -> Bool {
        switch kind {
        case .start?, .working?:
            return true
        case .turn?, .idle?, .tool?:
            return !record.session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .permission?, .question?, .waiting?, .done?, .end?, nil:
            return false
        }
    }

    // MARK: - Re-reading a rewritten log

    /// The lines of a whole-file read (`Chunk.fresh`) not already applied,
    /// in file order. `applied` is every line of the log applied so far, in
    /// the order it was applied.
    ///
    /// A rewrite keeps lines in their order (a compaction drops some, the
    /// record being appended and anything written since go last), so what
    /// was applied is a prefix of the rewrite and what is new follows it.
    /// The last line applied is the anchor: its place in the rewrite is the
    /// last one whose lines before it all fit, in order, among the lines
    /// applied before it — everything up to it was applied, everything
    /// after it is new, even a line whose text matches one applied earlier.
    /// When the rewrite kept no copy of that line, the lines are matched in
    /// order: each takes the next applied line with the same text, and a
    /// line with no match left is new. Identity is the position, not the
    /// text — a line written twice is applied twice, and a kept line is
    /// never applied again. Pure.
    package static func unapplied(_ lines: [String], after applied: [String]) -> [String] {
        guard let last = applied.last else { return lines }
        let earlier = applied.dropLast()
        for anchor in lines.indices.reversed() where lines[anchor] == last {
            if isSubsequence(lines[..<anchor], of: earlier) {
                return Array(lines[(anchor + 1)...])
            }
        }
        var positions: [String: [Int]] = [:]
        for (index, line) in applied.enumerated() { positions[line, default: []].append(index) }
        var next = 0
        var fresh: [String] = []
        for line in lines {
            if let candidates = positions[line], let match = candidates.first(where: { $0 >= next }) {
                next = match + 1
            } else {
                fresh.append(line)
            }
        }
        return fresh
    }

    /// `part` appears in `whole` in order, not necessarily side by side.
    static func isSubsequence(_ part: ArraySlice<String>, of whole: ArraySlice<String>) -> Bool {
        var cursor = whole.startIndex
        for line in part {
            guard let found = whole[cursor...].firstIndex(of: line) else { return false }
            cursor = whole.index(after: found)
        }
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
