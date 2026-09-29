import Foundation

/// 22.0 · where the session timeline lives on disk, and the store's side of
/// recording it. A scan that finds the same world changes no span and writes
/// nothing; `timelineRevision` moves only when a span did.
enum SessionTimelineStore {
    static var fileURL: URL {
        AttentionIO.path.deletingLastPathComponent().appendingPathComponent("session-timeline.json")
    }

    static func load(from url: URL = fileURL) -> SessionTimelineBook {
        guard let data = try? Data(contentsOf: url),
              var book = try? JSONDecoder().decode(SessionTimelineBook.self, from: data)
        else { return SessionTimelineBook() }
        book.prune(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        return book
    }

    static func save(_ book: SessionTimelineBook, to url: URL = fileURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(book) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !PrivateFile.write(data, to: url) {
            DebugLog.write("session timeline write failed")
        }
    }
}

@MainActor
extension StatusStore {
    func recordTimeline(previous: [AgentRow], current: [AgentRow], remapped: [String: String], nowMs: Int64) {
        var book = timelineBook
        // A row that found a better key keeps its history.
        for (old, new) in remapped where old != new {
            if let spans = book.spans.removeValue(forKey: old), book.spans[new] == nil {
                book.spans[new] = spans
            }
        }
        var changed = book != timelineBook
        let transitions = SessionTimeline.transitions(
            previous: previous, current: current, remapped: remapped, nowMs: nowMs
        )
        if book.apply(transitions) { changed = true }
        if book.prune(nowMs: nowMs) { changed = true }
        guard changed else { return }
        timelineBook = book
        timelineRevision &+= 1
        SessionTimelineStore.save(book)
    }

    /// The last hour of a session, when anything is known about it.
    func timelineStrip(for row: AgentRow) -> TimelineStripModel? {
        _ = timelineRevision
        guard let spans = timelineBook.spans[row.rowKey], !spans.isEmpty else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Quantized to the minute so the strip does not redraw every second.
        let minute = (nowMs / 60_000) * 60_000
        return TimelineStripModel.make(spans: spans, nowMs: minute)
    }

    /// What happened to the banner for this row's latest wait.
    func notificationAudit(for row: AgentRow) -> NotificationAuditModel? {
        guard let event = attentionLedger.latestEvent(rowKey: row.rowKey) else { return nil }
        return NotificationAuditModel.make(event: event, lang: lang)
    }
}
