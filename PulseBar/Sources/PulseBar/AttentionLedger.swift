import Foundation

/// Durable attention state.
///
/// `AttentionReader` is an append-only bridge owned by agents. It is useful for
/// the current scan, but it is not a delivery ledger: a tray restart could
/// forget which Waiting edge had already been seen and either lose or duplicate
/// a notification. This small, versioned file records the Waiting edges Pulse
/// itself has seen and delivered.
///
/// **What it stores, exactly.** Row identity, timestamps, delivery state — and
/// the session `title`, capped at 160 characters, because the tray's recent-wait
/// history renders it. That title is `AgentRow.usefulTask`: since 0.98 the hero
/// is defined as the user's real goal, so the title is frequently the opening
/// line of a prompt. It has passed `ContentSanitizer`, so credential-shaped
/// content is already redacted, and nothing else from the transcript is kept —
/// no message bodies, no tool arguments, no file paths, no raw hook payloads.
///
/// This comment used to claim the file "never stores prompts". That was written
/// before the hero was a prompt, and it stayed while the meaning underneath it
/// changed. The privacy story rests on this paragraph, so it states what the
/// struct does rather than what it once intended.
///
/// Retention is `retentionDays` for resolved events and `maxEvents` total;
/// active Waiting events are live state and are never evicted by the cap. The
/// user can clear the whole history from Preferences.
struct AttentionLedger: Codable {
    static let schemaVersion = 1
    /// How long a resolved Waiting event stays on disk.
    static let retentionDays = 14
    /// Ceiling on stored events. Only the resolved trail is trimmed.
    static let maxEvents = 256

    struct Event: Codable, Equatable, Identifiable {
        var id: String
        var rowKey: String
        var agent: String
        var session: String
        var title: String
        var kind: String
        var project: String
        var observedAtMs: Int64
        var lastSeenAtMs: Int64
        var notifiedAtMs: Int64 = 0
        /// The user explicitly acknowledged/dismissed this Waiting event.
        /// This is separate from resolution: the Agent may still report the
        /// same wait for a short time after the user acted.
        var acknowledgedAtMs: Int64 = 0
        /// The event is waiting for a rate-limit window or notification
        /// authorization. Keeping this in the ledger prevents a relaunch from
        /// silently losing an edge that never reached Notification Center.
        var queuedAtMs: Int64 = 0
        var snoozedUntilMs: Int64 = 0
        var resolvedAtMs: Int64 = 0

        var isActive: Bool { resolvedAtMs == 0 }
    }

    var schema: Int = AttentionLedger.schemaVersion
    var baselineEstablished = false
    /// Last notification delivery across all Waiting events. This is the
    /// persisted global rate-limit anchor, not a replacement for per-event
    /// `notifiedAtMs`.
    var lastNotificationAtMs: Int64 = 0
    var events: [Event] = []

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/attention-ledger.json")
    }

    static func load(from url: URL = fileURL) -> AttentionLedger {
        guard let data = try? Data(contentsOf: url),
              var value = try? JSONDecoder().decode(AttentionLedger.self, from: data),
              value.schema == schemaVersion
        else { return AttentionLedger() }
        value.prune(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        return value
    }

    var activeKeys: Set<String> {
        Set(events.filter(\.isActive).map(\.rowKey))
    }

    var queuedKeys: Set<String> {
        Set(events.filter { $0.isActive && $0.queuedAtMs > 0 }.map(\.rowKey))
    }

    func eventID(for rowKey: String) -> String? {
        events.last(where: { $0.rowKey == rowKey && $0.isActive })?.id
    }

    func isAcknowledged(rowKey: String) -> Bool {
        (events.last(where: { $0.rowKey == rowKey && $0.isActive })?.acknowledgedAtMs ?? 0) > 0
    }

    func canDeliver(nowMs: Int64, minimumIntervalMs: Int64) -> Bool {
        lastNotificationAtMs == 0 || nowMs - lastNotificationAtMs >= minimumIntervalMs
    }

    var snoozedUntil: [String: Date] {
        var result: [String: Date] = [:]
        for event in events where event.isActive && event.snoozedUntilMs > 0 {
            let date = Date(timeIntervalSince1970: Double(event.snoozedUntilMs) / 1000)
            // A hand-edited or older ledger may contain duplicate active
            // records. Prefer the later deadline instead of crashing on
            // Dictionary(uniqueKeysWithValues:), which would prevent Pulse
            // from launching precisely when recovery is needed.
            if let existing = result[event.rowKey] {
                result[event.rowKey] = max(existing, date)
            } else {
                result[event.rowKey] = date
            }
        }
        return result
    }

    var recentResolved: [Event] {
        events
            .filter { $0.resolvedAtMs > 0 }
            .sorted { $0.resolvedAtMs > $1.resolvedAtMs }
    }

    mutating func observe(row: AgentRow, nowMs: Int64) {
        let key = row.rowKey
        if let index = events.lastIndex(where: { $0.rowKey == key && $0.isActive }) {
            events[index].lastSeenAtMs = nowMs
            let title = row.usefulTask ?? String(row.agent.displayName.prefix(160))
            events[index].title = String(title.prefix(160))
            events[index].kind = row.waitKind
            events[index].project = AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project)
            return
        }
        let title = row.usefulTask ?? AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project)
        events.append(Event(
            id: "\(key)|\(nowMs)",
            rowKey: key,
            agent: row.agent.rawValue,
            session: row.sessionID,
            title: String(title.prefix(160)),
            kind: row.waitKind,
            project: AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project),
            observedAtMs: nowMs,
            lastSeenAtMs: nowMs
        ))
    }

    mutating func reconcile(activeRows: [AgentRow], nowMs: Int64) {
        let active = Set(activeRows.map(\.rowKey))
        for index in events.indices where events[index].isActive {
            guard !active.contains(events[index].rowKey) else { continue }
            events[index].resolvedAtMs = nowMs
            events[index].snoozedUntilMs = 0
        }
        for row in activeRows { observe(row: row, nowMs: nowMs) }
        prune(nowMs: nowMs)
    }

    mutating func markNotified(rowKey: String, nowMs: Int64) {
        guard let index = events.lastIndex(where: { $0.rowKey == rowKey && $0.isActive }) else { return }
        events[index].notifiedAtMs = nowMs
        events[index].queuedAtMs = 0
        lastNotificationAtMs = nowMs
    }

    mutating func markQueued(rowKey: String, nowMs: Int64) {
        guard let index = events.lastIndex(where: { $0.rowKey == rowKey && $0.isActive }) else { return }
        if events[index].queuedAtMs == 0 { events[index].queuedAtMs = nowMs }
    }

    mutating func acknowledge(rowKey: String, nowMs: Int64) {
        guard let index = events.lastIndex(where: { $0.rowKey == rowKey && $0.isActive }) else { return }
        events[index].acknowledgedAtMs = nowMs
        events[index].queuedAtMs = 0
    }

    mutating func clearQueued(rowKey: String) {
        guard let index = events.lastIndex(where: { $0.rowKey == rowKey && $0.isActive }) else { return }
        events[index].queuedAtMs = 0
    }

    mutating func snooze(rowKey: String, untilMs: Int64) {
        guard let index = events.lastIndex(where: { $0.rowKey == rowKey && $0.isActive }) else { return }
        events[index].snoozedUntilMs = untilMs
    }

    mutating func unsnooze(rowKey: String) {
        guard let index = events.lastIndex(where: { $0.rowKey == rowKey && $0.isActive }) else { return }
        events[index].snoozedUntilMs = 0
    }

    mutating func markBaseline() {
        baselineEstablished = true
    }

    /// Clear the resolved trail when the user explicitly clears Waiting
    /// history. Active waits are never removed by this action: the current
    /// agent-owned signal remains the source of truth and still needs a
    /// visible response.
    mutating func remapRowKey(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, !newKey.isEmpty else { return }
        for index in events.indices where events[index].rowKey == oldKey {
            events[index].rowKey = newKey
        }
    }

    mutating func clearResolved() {
        events.removeAll { !$0.isActive }
    }

    mutating func prune(nowMs: Int64) {
        let retentionMs = Int64(Self.retentionDays) * 24 * 60 * 60 * 1000
        events = events.filter { event in
            event.isActive || event.resolvedAtMs <= 0 || nowMs - event.resolvedAtMs <= retentionMs
        }
        if events.count > Self.maxEvents {
            // Active Waiting events are live product state, not history. A
            // burst of concurrent sessions must never evict the 257th active
            // event merely because the resolved-history retention target is
            // 256. Bound only the resolved trail and preserve every active
            // row for notification, acknowledgement and restart recovery.
            let active = events.filter(\.isActive)
            let resolved = events
                .filter { !$0.isActive }
                .sorted { $0.resolvedAtMs > $1.resolvedAtMs }
            let resolvedLimit = max(0, Self.maxEvents - active.count)
            events = active + Array(resolved.prefix(resolvedLimit))
        }
    }

    /// This file holds session titles — the user's own words, up to 160
    /// characters — alongside project names and wait kinds. It used to be
    /// written through a temporary file that took the process umask and then
    /// renamed, setting no mode at any point, so the most prose-carrying file
    /// Pulse writes was the one local account boundary it did not respect.
    /// `PrivateFile` gives it the same 0600-from-the-first-byte treatment the
    /// respond spool beside it has always had.
    func save(to url: URL = fileURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            DebugLog.write("attention ledger encode failed")
            return
        }
        if !PrivateFile.write(data, to: url) {
            DebugLog.write("attention ledger save failed")
        }
    }
}
