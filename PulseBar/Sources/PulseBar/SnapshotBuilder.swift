import Foundation

/// 24.0 · the thin end of the pipeline: rows in, the tray's snapshot out.
///
/// `SessionBook` holds what the events said; `SessionProjection` turns it
/// into rows; this sorts them, folds them into the tray's window, sets the
/// lamp, the menu-bar title and the census, and reports the Waiting edges —
/// as data. The store stays in charge of policy and I/O; this stays a
/// function of its inputs.
enum SnapshotBuilder {
    /// Rows shown before the "and N more" fold.
    static let maxVisibleRows = 12

    /// Outside-world facts, captured once per projection.
    struct Context {
        var nowMs: Int64
        var lang: ResolvedLanguage
        var maxVisibleRows: Int = SnapshotBuilder.maxVisibleRows
        var showAllAgents: Bool = false
    }

    /// What the previous projection left behind, for edge detection.
    struct Previous {
        var rows: [AgentRow] = []
        var waitingKeys: Set<String> = []
        /// When each open wait was raised (`SessionLog.waitingSince`). A key
        /// still waiting whose wait now carries a later raise is a new wait
        /// (`SessionLog.isNewRaise`) — the second ask gets its own edge.
        var waitingSince: [String: Int64] = [:]
    }

    struct Result {
        var rows: [AgentRow] = []
        var snapshot = PulseSnapshot()
        var activity: ProbeSchedule.Activity = .empty
        var waitingKeys: Set<String> = []
        /// Rows that became Waiting since the previous projection.
        var newlyWaiting: [AgentRow] = []
        /// Rows that were Waiting and no longer are.
        var resolvedWaits: [AgentRow] = []
        /// `showAllAgents` after collapsing it when the list got short again.
        var showAllAgents: Bool = false
    }

    private static func t(_ key: L10n.Key, _ lang: ResolvedLanguage) -> String {
        L10n.t(key, lang)
    }

    static func build(
        rows input: [AgentRow],
        staleHidden: [AgentID: Int] = [:],
        previous: Previous,
        context: Context
    ) -> Result {
        var result = Result()
        // Waiting → active → stalled → recent; within Waiting the oldest
        // first (unknown last); a real title, a live process and agent
        // priority break ties; the key makes the order total, so the same
        // world always lists the same way.
        let all = input.sorted { a, b in
            if a.isBlocked != b.isBlocked { return a.isBlocked }
            let wa = a.wait?.sinceMs ?? 0, wb = b.wait?.sinceMs ?? 0
            if a.isBlocked, wa != wb {
                if wa == 0 { return false }
                if wb == 0 { return true }
                return wa < wb
            }
            if a.section != b.section { return a.section.rawValue < b.section.rawValue }
            let ta = a.usefulTask != nil, tb = b.usefulTask != nil
            if ta != tb { return ta }
            if a.liveProcess != b.liveProcess { return a.liveProcess }
            let ra = AgentID.priority.firstIndex(of: a.agent) ?? 999
            let rb = AgentID.priority.firstIndex(of: b.agent) ?? 999
            if ra != rb { return ra < rb }
            return a.rowKey < b.rowKey
        }

        result.rows = all
        result.showAllAgents = context.showAllAgents && all.count > context.maxVisibleRows
        result.waitingKeys = Set(all.filter(\.isBlocked).map(\.rowKey))
        result.snapshot = snapshot(rows: all, showAll: result.showAllAgents, staleHiddenByAgent: staleHidden, context: context)

        // Edges — reported, not acted on. `WaitNotifier` owns notification
        // policy. Keys are stable: an edge is a key that was not waiting, or
        // one whose wait is a new raise (a second ask on the same row).
        result.newlyWaiting = all.filter { row in
            guard row.isBlocked else { return false }
            guard previous.waitingKeys.contains(row.rowKey) else { return true }
            guard let since = previous.waitingSince[row.rowKey] else { return false }
            return SessionLog.isNewRaise(row, previousSinceMs: since)
        }
        result.resolvedWaits = previous.rows.filter { $0.isBlocked && !result.waitingKeys.contains($0.rowKey) }
        result.activity = activity(rows: all)
        return result
    }

    /// The tick's tier. By row state, like the lamp and the header — a
    /// process with no session, or a finished turn, is not work in progress.
    static func activity(rows: [AgentRow]) -> ProbeSchedule.Activity {
        if rows.contains(where: \.isBlocked) { return .waiting }
        if rows.contains(where: { $0.state == .running }) { return .running }
        return rows.isEmpty ? .empty : .recent
    }

    /// The glance, header, tooltip and lamp for a row list.
    private static func snapshot(
        rows all: [AgentRow],
        showAll: Bool,
        staleHiddenByAgent: [AgentID: Int],
        context: Context
    ) -> PulseSnapshot {
        let lang = context.lang
        let nowMs = context.nowMs
        let waitingRows = all.filter(\.isBlocked)
        let waitingCount = waitingRows.count
        let census = Census(rows: all)

        var snap = PulseSnapshot()
        snap.totalCount = all.count
        snap.sectionTotals = [
            .needsYou: waitingCount,
            .running: all.filter { $0.section == .running }.count,
            .stalled: all.filter { $0.section == .stalled }.count,
            .recent: all.filter { $0.section == .recent }.count,
        ]
        // Oldest wait = smallest non-zero timestamp.
        let waitStamps = waitingRows.compactMap { $0.wait?.sinceMs }.filter { $0 > 0 }
        window(rows: all, showAll: showAll, maxVisible: context.maxVisibleRows, into: &snap)

        // 23.0 · the lamp. Red when anything is blocked; orange only for a
        // stalled session; green for a running session; grey otherwise — a
        // finished turn is grey even while its process lives, and a process
        // with no session is grey, never orange and never green.
        let sessionRunning = census.running > 0
        if waitingCount > 0 {
            snap.glance = .waiting
        } else if census.stalled > 0 {
            snap.glance = .stalled
        } else if sessionRunning {
            snap.glance = .running
        } else {
            snap.glance = .idle
        }

        // The menu bar carries a title only when something is blocked: how
        // many, and how long the oldest has waited. A wait younger than five
        // seconds says nothing the lamp has not.
        if waitingCount > 0 {
            let oldest = waitStamps.min().map { max(0, Double(nowMs - $0) / 1000.0) } ?? 0
            let raw = oldest > 0 ? DurationFormat.label(seconds: oldest, lang: lang) : ""
            let dur = raw == t(.durNow, lang) ? "" : raw
            snap.title = dur.isEmpty
                ? "\(waitingCount)"
                : GlanceTitle.fit("\(waitingCount) · \(dur)", "\(waitingCount)")
        } else {
            snap.title = ""
        }

        snap.headerTitle = census.summary(lang)

        // One sentence for the tooltip and VoiceOver: the rule that set the
        // lamp. The tray names the sessions.
        let explanation = LampExplanation.make(rows: all, glance: snap.glance)
        snap.tooltip = explanation.sentence(lang)
        snap.lamp = LampFace.glance(snap.glance, processOnly: explanation.rule == .processOnly)
        snap.accessibilityLabel = snap.glance == .idle
            ? t(snap.glance.accessibilityKey, lang)
            : snap.tooltip
        snap.staleHidden = staleHiddenByAgent.values.reduce(0, +)
        snap.staleHiddenAgents = staleHiddenByAgent.keys.sorted {
            (AgentID.priority.firstIndex(of: $0) ?? 999) < (AgentID.priority.firstIndex(of: $1) ?? 999)
        }
        return snap
    }

    /// Every row counted once, by its state — the census VoiceOver announces.
    struct Census: Equatable {
        var blocked = 0
        var running = 0
        var stalled = 0
        var yourTurn = 0
        var processOnly = 0
        var recent = 0

        init(rows: [AgentRow]) {
            for row in rows {
                switch row.state {
                case .blocked: blocked += 1
                case .running: if row.isStalled { stalled += 1 } else { running += 1 }
                case .yourTurn: yourTurn += 1
                case .processOnly: processOnly += 1
                case .recent: recent += 1
                }
            }
        }

        /// "1 needs you · 2 running · 1 recent", or "No coding agents".
        func summary(_ lang: ResolvedLanguage) -> String {
            func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
            var bits: [String] = []
            // 23.0: "1 needs you", not "1 need you".
            if blocked > 0 { bits.append("\(blocked) \(t(blocked == 1 ? .waiting1 : .waitingN))") }
            if running > 0 { bits.append("\(running) \(t(.runningN))") }
            if stalled > 0 { bits.append("\(stalled) \(t(.stalledN))") }
            if yourTurn > 0 { bits.append("\(yourTurn) \(t(.yourTurnN))") }
            if processOnly > 0 { bits.append("\(processOnly) \(t(.processOnlyN))") }
            if recent > 0 { bits.append(recent == 1 ? t(.recent1) : "\(recent) \(t(.recentN))") }
            return bits.isEmpty ? t(.noAgents) : bits.joined(separator: " · ")
        }
    }

    /// Fold the row list down to what the tray shows.
    static func window(
        rows: [AgentRow],
        showAll: Bool,
        maxVisible: Int,
        into snap: inout PulseSnapshot
    ) {
        if showAll || rows.count <= maxVisible {
            snap.rows = rows
            snap.hiddenCount = 0
        } else {
            snap.rows = Array(rows.prefix(maxVisible))
            snap.hiddenCount = rows.count - maxVisible
        }
        snap.totalCount = rows.count
    }
}

/// Menu-bar title budget (EXPERIENCE: ≤ 8 display cells; CJK = 2).
enum GlanceTitle {
    static let maxCells = 8

    static func cells(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    static func fit(_ candidates: String...) -> String {
        for text in candidates where cells(text) <= maxCells {
            return text
        }
        return candidates.last ?? ""
    }

    private static func isWide(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF:
            return true
        default:
            return false
        }
    }
}
