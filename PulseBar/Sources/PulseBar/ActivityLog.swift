import Foundation

/// 22.0 · Lamp — what happened, across every session, newest first.
///
/// "Why did the lamp go red at 14:02?" and "why didn't I get a banner?" used
/// to be answerable only from `debug.log`. Both facts are now recorded where
/// they belong — state spans in `SessionTimelineBook`, banner outcomes on
/// `AttentionLedger` events — and this value merges them into one readable,
/// bounded log. Pure: books in, lines out; nothing new is written to disk.
struct ActivityLogModel: Equatable {
    struct Entry: Equatable, Identifiable {
        var id: String
        var atMs: Int64
        var agent: AgentID?
        var place: String
        var text: String
        var tone: PulseTheme.Tone
    }

    var entries: [Entry]

    static let maxEntries = 60

    static func make(
        book: SessionTimelineBook,
        ledger: AttentionLedger,
        rows: [AgentRow],
        lang: ResolvedLanguage,
        agentFilter: AgentID? = nil
    ) -> ActivityLogModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        var byKey: [String: AgentRow] = [:]
        for row in rows { byKey[row.rowKey] = row }
        func agent(for key: String) -> AgentID? {
            if let row = byKey[key] { return row.agent }
            return AgentID(rawValue: String(key.split(separator: "|").first ?? ""))
        }
        func place(for key: String) -> String {
            guard let row = byKey[key] else { return "" }
            let project = AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project)
            if let task = row.usefulTask { return project.isEmpty ? task : "\(project) · \(task)" }
            return project
        }

        var entries: [Entry] = []
        for (key, spans) in book.spans {
            for (index, span) in spans.enumerated() {
                var text = stateText(span.state, lang: lang)
                if !span.kind.isEmpty { text += " · " + L10n.waitKind(span.kind, lang) }
                text += " · " + evidenceText(span.evidence, lang: lang)
                entries.append(Entry(
                    id: "\(key)#s\(index)", atMs: span.startMs, agent: agent(for: key),
                    place: place(for: key), text: text, tone: span.state.tone
                ))
                if let end = span.endMs, index == spans.count - 1 {
                    entries.append(Entry(
                        id: "\(key)#end", atMs: end, agent: agent(for: key),
                        place: place(for: key), text: t(.activityLeft), tone: .idle
                    ))
                }
            }
        }
        for event in ledger.events {
            guard let outcome = event.delivery, let at = event.deliveryAtMs else { continue }
            let when = NotificationAuditModel.outcomeText(outcome, lang: lang)
            // The outcome formats carry the time; the log has its own column.
            let text = when.replacingOccurrences(of: " (%@)", with: "")
                .replacingOccurrences(of: "（%@）", with: "")
                .replacingOccurrences(of: " %@", with: "")
                .replacingOccurrences(of: "%@ ", with: "")
                .replacingOccurrences(of: "%@", with: "")
            entries.append(Entry(
                id: "\(event.id)#d", atMs: at, agent: AgentID(rawValue: event.agent),
                place: event.title, text: text,
                tone: outcome == "posted" || outcome == "summary" ? .idle : .attention
            ))
        }
        if let agentFilter { entries = entries.filter { $0.agent == agentFilter } }
        entries.sort { ($0.atMs, $0.id) > ($1.atMs, $1.id) }
        return ActivityLogModel(entries: Array(entries.prefix(maxEntries)))
    }

    static func stateText(_ state: TimelineState, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch state {
        case .blocked: return t(.needsYou)
        case .running: return t(.running)
        case .thin: return t(.limitedData)
        case .stalled: return t(.stalled)
        case .turn: return t(.yourTurn)
        case .recent: return t(.recent)
        }
    }

    static func evidenceText(_ evidence: TimelineEvidence, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch evidence {
        case .hook: return t(.signalHooks)
        case .pending: return t(.signalPending)
        case .vendor: return t(.signalVendor)
        case .harvest: return t(.activityFromSession)
        case .process: return t(.activityFromProcess)
        }
    }
}
