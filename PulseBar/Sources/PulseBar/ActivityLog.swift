import Foundation

/// 22.0 · Lamp — what happened, across every session, newest first.
///
/// "Why did the lamp go red at 14:02?" and "why didn't I get a banner?" used
/// to be answerable only from `debug.log`. Both facts are recorded in
/// `SessionLog` (23.0: state spans and wait records in one value), and this
/// value merges them into one readable, bounded log. Pure: the log in, lines
/// out; nothing new is written to disk.
struct ActivityLogModel: Equatable {
    struct Entry: Equatable, Identifiable {
        var id: String
        var atMs: Int64
        /// `LogClock.label` for `atMs` — the day is said when it is not today.
        var clock: String
        var agent: AgentID?
        var place: String
        var text: String
        var tone: PulseTheme.Tone
    }

    var entries: [Entry]

    static let maxEntries = 60

    /// The agent a session key belongs to (`claude|…` → Claude).
    static func agent(forKey key: String) -> AgentID? {
        AgentID(rawValue: String(key.split(separator: "|").first ?? ""))
    }

    static func make(
        log: SessionLog,
        rows: [AgentRow],
        lang: ResolvedLanguage,
        nowMs: Int64,
        agentFilter: AgentID? = nil,
        timeZone: TimeZone = .current
    ) -> ActivityLogModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        var byKey: [String: AgentRow] = [:]
        for row in rows where byKey[row.rowKey] == nil { byKey[row.rowKey] = row }
        func agent(for key: String) -> AgentID? {
            if let row = byKey[key] { return row.agent }
            return Self.agent(forKey: key)
        }
        func place(for key: String) -> String {
            guard let row = byKey[key] else { return "" }
            let project = AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project)
            if let task = row.usefulTask { return project.isEmpty ? task : "\(project) · \(task)" }
            return project
        }

        var entries: [Entry] = []
        func add(_ id: String, _ at: Int64, _ key: String, _ place: String, _ text: String, _ tone: PulseTheme.Tone) {
            entries.append(Entry(
                id: id, atMs: at, clock: "", agent: agent(for: key),
                place: place, text: text, tone: tone
            ))
        }
        for (key, session) in log.sessions {
            let spans = session.spans
            for (index, span) in spans.enumerated() {
                var text = stateText(span.state, lang: lang)
                if !span.kind.isEmpty { text += " · " + L10n.waitKind(span.kind, lang) }
                text += " · " + evidenceText(span.evidence, lang: lang)
                add("\(key)#s\(index)", span.startMs, key, place(for: key), text, span.state.tone)
                if let end = span.endMs, index == spans.count - 1 {
                    add("\(key)#end", end, key, place(for: key), t(.activityLeft), .idle)
                }
            }
            for wait in session.waits {
                guard let outcome = wait.outcome, let at = wait.outcomeMs else { continue }
                let format = NotificationAuditModel.outcomeText(outcome, lang: lang)
                // The outcome formats carry the time; the log has its own column.
                let text = format.replacingOccurrences(of: " (%@)", with: "")
                    .replacingOccurrences(of: "（%@）", with: "")
                    .replacingOccurrences(of: " %@", with: "")
                    .replacingOccurrences(of: "%@ ", with: "")
                    .replacingOccurrences(of: "%@", with: "")
                add(
                    "\(wait.id)#d", at, key, wait.title, text,
                    outcome == "posted" || outcome == "summary" ? .idle : .attention
                )
            }
        }
        if let agentFilter { entries = entries.filter { $0.agent == agentFilter } }
        entries.sort { ($0.atMs, $0.id) > ($1.atMs, $1.id) }
        var shown = Array(entries.prefix(maxEntries))
        for index in shown.indices {
            shown[index].clock = LogClock.label(ms: shown[index].atMs, nowMs: nowMs, lang: lang, timeZone: timeZone)
        }
        return ActivityLogModel(entries: shown)
    }

    static func stateText(_ state: TimelineState, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch state {
        case .blocked: return t(.needsYou)
        case .running: return t(.running)
        case .thin: return t(.processOnly)
        case .stalled: return t(.stalled)
        case .turn: return t(.yourTurn)
        case .recent: return t(.recent)
        }
    }

    static func evidenceText(_ evidence: TimelineEvidence, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch evidence {
        case .hook: return t(.signalHooks)
        case .process: return t(.activityFromProcess)
        }
    }
}

/// 23.0 · one clock for every logged moment. `HH:mm` alone said nothing
/// about which day: yesterday's 14:02 read as today's. Today is `HH:mm`,
/// the last week `Mon HH:mm` / `周一 HH:mm`, anything older `M/d HH:mm` —
/// always in the app's language, not the system's.
enum LogClock {
    static func label(ms: Int64, nowMs: Int64, lang: ResolvedLanguage, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang == .zh ? "zh-Hans" : "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        if days == 0 {
            formatter.dateFormat = "HH:mm"
        } else if days > 0, days < 7 {
            formatter.dateFormat = "EEE HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}
