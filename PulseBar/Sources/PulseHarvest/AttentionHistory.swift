import Foundation
import PulseCore

/// 17.0 · Why — what the hooks actually said, kept long enough to explain a
/// lamp.
///
/// `attention.tsv` is a mailbox, not a record: it keeps the last 80 lines and
/// compacts, and last-event-wins throws away everything but the newest line
/// per session. By the time someone asks "why was that red?" the sequence
/// that answers it is usually gone — and the order in which a vendor really
/// sends its events on a real machine (Respond P0-0, the 16.0 turn order) is
/// exactly what nobody has been able to look at.
///
/// Pulse copies every event it reads into this bounded history: per
/// session-key, chronological, deduplicated, sanitized again on the way in.
/// It never leaves this Mac. A session's history can be exported, on the
/// user's click, as a v3 TSV the reader and `TurnTruthTests` consume as-is —
/// a real sequence becomes a regression test.
package struct AttentionHistory: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1
    /// Events kept per session key.
    package static let perKey = 40
    /// Session keys kept, newest activity first.
    package static let maxKeys = 64
    /// A session silent this long is dropped.
    package static let retentionMs: Int64 = 24 * 60 * 60 * 1000

    package struct Event: Codable, Equatable, Sendable {
        package var agent: String
        /// As written, after `normalizeKind` (a v3 kind).
        package var kind: String
        package var tsMs: Int64
        package var message: String
        package var session: String
        package var cwd: String
        package var host: String
        package var front: Bool?

        package init(
            agent: String, kind: String, tsMs: Int64, message: String = "",
            session: String = "", cwd: String = "", host: String = "", front: Bool? = nil
        ) {
            self.agent = agent
            self.kind = kind
            self.tsMs = tsMs
            self.message = message
            self.session = session
            self.cwd = cwd
            self.host = host
            self.front = front
        }

        /// Same key as `AttentionReader.Entry.mapKey`, so a row can find its
        /// own history.
        package var key: String {
            AttentionHistory.key(agent: agent, session: session)
        }

        var identity: String { "\(tsMs)|\(kind)|\(session)|\(host)|\(message)" }
    }

    package var schemaVersion = AttentionHistory.currentSchemaVersion
    package var events: [String: [Event]] = [:]

    package init() {}

    package static func key(agent: String, session: String) -> String {
        let surface = ActivityHarvest.mapAgent(agent)?.surfaceID.rawValue ?? agent
        return session.isEmpty ? surface : "\(surface)|\(session)"
    }

    package func history(agent: String, session: String) -> [Event] {
        events[Self.key(agent: agent, session: session)] ?? []
    }

    // MARK: - Ingest

    /// Copy every protocol line of `sources` in. Returns whether anything
    /// changed, so an unchanged scan writes nothing.
    @discardableResult
    package mutating func ingest(_ sources: [AttentionIO.Source], nowMs: Int64) -> Bool {
        var changed = false
        for source in sources {
            for line in source.text.split(whereSeparator: \.isNewline) {
                let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty || raw.hasPrefix("#") { continue }
                guard let event = Self.parse(raw) else { continue }
                changed = append(event) || changed
            }
        }
        changed = prune(nowMs: nowMs) || changed
        return changed
    }

    /// One TSV line → event; nil for anything the protocol does not accept.
    /// The `host` column is kept as written so an export replays verbatim,
    /// but it no longer keys anything: every line is this Mac's (22.0).
    package static func parse(_ raw: String) -> Event? {
        let cols = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 3,
              ActivityHarvest.mapAgent(cols[0]) != nil,
              AttentionProtocol.acceptsWrite(kind: cols[1]),
              let ts = Int64(cols[2]), ts > 0
        else { return nil }
        let named = cols.count > 6 ? AttentionProtocol.normalizeHost(cols[6]) : ""
        return Event(
            agent: cols[0],
            kind: AttentionProtocol.normalizeKind(cols[1]),
            tsMs: ts,
            message: bound(ContentSanitizer.redact(cols.count > 3 ? cols[3] : ""), 200),
            session: bound(cols.count > 4 ? cols[4] : "", 80),
            cwd: bound(ContentSanitizer.redact(cols.count > 5 ? cols[5] : ""), 240),
            host: named,
            front: AttentionProtocol.parseFront(cols.count > 7 ? cols[7] : "")
        )
    }

    private mutating func append(_ event: Event) -> Bool {
        let key = event.key
        var list = events[key] ?? []
        guard !list.contains(where: { $0.identity == event.identity }) else { return false }
        list.append(event)
        list.sort { $0.tsMs < $1.tsMs }
        if list.count > Self.perKey { list.removeFirst(list.count - Self.perKey) }
        events[key] = list
        return true
    }

    private mutating func prune(nowMs: Int64) -> Bool {
        let before = events.count
        events = events.filter { _, list in
            guard let newest = list.last?.tsMs else { return false }
            return nowMs - newest <= Self.retentionMs
        }
        if events.count > Self.maxKeys {
            let keep = events
                .sorted { ($0.value.last?.tsMs ?? 0) > ($1.value.last?.tsMs ?? 0) }
                .prefix(Self.maxKeys)
            events = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return events.count != before
    }

    private static func bound(_ value: String, _ limit: Int) -> String {
        let clean = value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        return String(clean.prefix(limit))
    }

    // MARK: - Export

    /// A replayable v3 TSV of `events`, oldest first: the header, then one
    /// line per event. Times are kept (order and gaps are the evidence); the
    /// working directory is cut to its last component — a fixture needs to
    /// match rows, not to know where on this Mac the code lives.
    package static func fixture(_ events: [Event]) -> String {
        let lines = events.sorted { $0.tsMs < $1.tsMs }.map { event -> String in
            let cwd = event.cwd.isEmpty ? "" : "/" + (event.cwd.split(separator: "/").last.map(String.init) ?? "")
            return [
                event.agent, event.kind, String(event.tsMs), event.message,
                event.session, cwd, event.host, AttentionProtocol.frontField(event.front),
            ].joined(separator: "\t")
        }
        return AttentionProtocol.header + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    // MARK: - Persistence

    /// `attention-history.json` next to `attention.tsv` (so `PULSE_HOME`
    /// and test overrides move both together).
    package static var fileURL: URL {
        AttentionIO.path.deletingLastPathComponent().appendingPathComponent("attention-history.json")
    }

    package static func load() -> AttentionHistory {
        guard let data = SafeRead.regularFile(atPath: fileURL.path, limit: 4 * 1024 * 1024),
              let history = try? JSONDecoder().decode(AttentionHistory.self, from: data),
              history.schemaVersion <= currentSchemaVersion
        else { return AttentionHistory() }
        return history
    }

    package func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        _ = PrivateFile.write(data, to: Self.fileURL)
    }
}

/// The process's one history: loaded once, fed by every scan (off the main
/// thread), read by the Details timeline (on it).
package enum AttentionHistoryStore {
    private static let state = Guarded<AttentionHistory?>(nil)

    /// Ingest this scan's attention sources; writes the file only on change.
    package static func ingest(_ sources: [AttentionIO.Source], nowMs: Int64) {
        state.withValue { value in
            var history = value ?? AttentionHistory.load()
            if history.ingest(sources, nowMs: nowMs) { history.save() }
            value = history
        }
    }

    package static var current: AttentionHistory {
        state.withValue { value in
            if value == nil { value = AttentionHistory.load() }
            return value ?? AttentionHistory()
        }
    }

    /// Tests only.
    package static func reset() {
        state.withValue { $0 = nil }
    }
}
