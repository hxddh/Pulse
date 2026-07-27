import Foundation

/// The merge core: probe hits + harvest rows + attention entries → tray rows and
/// a `PulseSnapshot`.
///
/// This used to live inside `StatusStore.applyScan`, where six kinds of side
/// effect (`Date()`, running-app enumeration, disk stats, system notifications,
/// timers, logging) made the most regression-prone logic in the product
/// impossible to test. Everything the merge needs from the outside world is now
/// injected through `Context`, and everything it wants the world to *do* comes
/// back as data — notification edges, cleared keys, log lines. The store stays
/// in charge of policy and I/O; this stays a function of its inputs.
enum SnapshotBuilder {

    /// Sessions kept per agent. Was hardcoded to 2, which made the third
    /// concurrent Claude invisible with no hint that anything was dropped.
    static let maxSessionsPerAgent = 4
    /// Rows shown before the "and N more" fold.
    ///
    /// Was 5, but every row also carried a permanently visible action strip, so
    /// the panel's fixed 300pt viewport fit about three — people with four or
    /// five agents running had to scroll to learn that. Actions moved to hover
    /// for non-waiting rows and the panel is sized by its content now, so this
    /// can be what it should always have been.
    static let maxVisibleRows = 8

    /// Outside-world facts, captured once per scan.
    struct Context {
        var nowMs: Int64
        var terminal: TerminalFocus.Environment
        /// Injected so tests do not depend on the filesystem.
        var pathExists: (String) -> Bool
        var lang: ResolvedLanguage
        var maxSessionsPerAgent: Int
        var maxVisibleRows: Int
        /// Harvest `pending` rows the user soft-dismissed.
        var dismissedPendingKeys: Set<String>
        var showAllAgents: Bool

        init(
            nowMs: Int64,
            terminal: TerminalFocus.Environment,
            pathExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
            lang: ResolvedLanguage,
            maxSessionsPerAgent: Int = SnapshotBuilder.maxSessionsPerAgent,
            maxVisibleRows: Int = SnapshotBuilder.maxVisibleRows,
            dismissedPendingKeys: Set<String> = [],
            showAllAgents: Bool = false
        ) {
            self.nowMs = nowMs
            self.terminal = terminal
            self.pathExists = pathExists
            self.lang = lang
            self.maxSessionsPerAgent = maxSessionsPerAgent
            self.maxVisibleRows = maxVisibleRows
            self.dismissedPendingKeys = dismissedPendingKeys
            self.showAllAgents = showAllAgents
        }
    }

    struct Input {
        var procs: [ProcessProbe.Hit] = []
        /// Already resolved to the rows this scan should use (fresh or cached).
        var harvest: [ActivityHarvest.Row] = []
        /// True when the harvest failed outright — only then can we claim Error.
        var harvestUnreliable: Bool = false
        var attention: [AttentionReader.Entry] = []
    }

    /// What the previous scan left behind, for edge detection.
    struct Previous {
        var rows: [AgentRow] = []
        var waitingKeys: Set<String> = []
    }

    struct Result {
        var rows: [AgentRow] = []
        var snapshot = PulseSnapshot()
        var activity: ProbeSchedule.Activity = .empty
        var waitingKeys: Set<String> = []
        /// Rows that became Waiting since the previous scan (edge-triggered).
        var newlyWaiting: [AgentRow] = []
        /// Rows that were Waiting and no longer are.
        var resolvedWaits: [AgentRow] = []
        /// The lamp went from busy to fully idle.
        var wentIdle: Bool = false
        /// Soft-dismissed keys whose `pending` cleared — the store may forget them.
        var clearedPendingKeys: Set<String> = []
        /// `showAllAgents` after collapsing it when the list got short again.
        var showAllAgents: Bool = false
        /// Lines the caller should log; keeps `DebugLog` out of the pure path.
        var debugNotes: [String] = []
    }

    private static func t(_ key: L10n.Key, _ lang: ResolvedLanguage) -> String {
        L10n.t(key, lang)
    }

    static func build(_ input: Input, previous: Previous, context: Context) -> Result {
        var result = Result()

        var rowsByKey: [String: AgentRow] = [:]
        var liveHits: [AgentID: ProcessProbe.Hit] = [:]
        var perAgentSessionCount: [AgentID: Int] = [:]
        var droppedSessionsByAgent: [AgentID: Int] = [:]

        for hit in input.procs {
            // Prefer richer hit if duplicate agent ids appear.
            if let existing = liveHits[hit.id] {
                if existing.tty.isEmpty, !hit.tty.isEmpty { liveHits[hit.id] = hit }
            } else {
                liveHits[hit.id] = hit
            }
        }
        // cursor_agent live counts as Cursor live for merge.
        if let agentHit = liveHits[.cursorAgent] {
            if var cursor = liveHits[.cursor] {
                cursor.count = max(cursor.count, agentHit.count)
                if cursor.tty.isEmpty { cursor.tty = agentHit.tty }
                if cursor.pid == 0 { cursor.pid = agentHit.pid }
                cursor.viaWarp = cursor.viaWarp || agentHit.viaWarp
                liveHits[.cursor] = cursor
            } else {
                var mapped = agentHit
                mapped.id = .cursor
                liveHits[.cursor] = mapped
            }
            liveHits.removeValue(forKey: .cursorAgent)
        }

        for act in input.harvest {
            var agentID = act.id
            if agentID == .cursorAgent { agentID = .cursor }

            let live = liveHits[agentID] != nil
            if !live, !ActivityHarvest.isFresh(act, nowMs: context.nowMs), act.subRunning == 0 {
                result.debugNotes.append("drop stale harvest \(agentID.rawValue) hm=\(act.harvestMs)")
                continue
            }

            let count = perAgentSessionCount[agentID, default: 0]
            if count >= context.maxSessionsPerAgent {
                // Don't drop it silently — the tray says how many were held back.
                droppedSessionsByAgent[agentID, default: 0] += 1
                continue
            }

            let key = ActivityHarvest.sessionKey(
                id: agentID,
                sessionID: act.sessionID,
                project: act.project,
                cwd: act.cwd
            )
            // Avoid colliding keys when second session lacks project — uniquify.
            var finalKey = key
            if rowsByKey[finalKey] != nil, rowsByKey[finalKey]?.sessionID != act.sessionID || act.sessionID.isEmpty {
                finalKey = "\(key)#\(count + 1)"
            }

            var row = rowsByKey[finalKey] ?? AgentRow(rowKey: finalKey, agent: agentID)
            if !act.sessionID.isEmpty { row.sessionID = act.sessionID }
            if !act.task.isEmpty { row.task = act.task }
            if !act.project.isEmpty { row.project = act.project }
            if !act.cwd.isEmpty { row.cwd = act.cwd }
            if !act.tool.isEmpty { row.tool = act.tool }
            if !act.skill.isEmpty { row.skill = act.skill }
            if act.tokensIn > 0 { row.tokensIn = act.tokensIn }
            if act.tokensOut > 0 { row.tokensOut = act.tokensOut }
            if act.harvestMs > 0 { row.harvestMs = act.harvestMs }
            if act.subTotal > 0 {
                row.subRunning = act.subRunning
                row.subTotal = act.subTotal
            }
            row.processCount = max(row.processCount, 1)

            // Harvest pending (Cursor / OpenCode / Gemini / Codex / …) → Waiting.
            if act.skill == "pending", ActivityHarvest.isFresh(act, nowMs: context.nowMs) {
                if !context.dismissedPendingKeys.contains(finalKey) {
                    row.waiting = true
                    row.waitKind = "Input"
                    row.waitSignal = .pending
                    row.waitSinceMs = act.harvestMs > 0 ? act.harvestMs : context.nowMs
                }
            } else {
                // Pending cleared — the soft dismiss has served its purpose.
                result.clearedPendingKeys.insert(finalKey)
            }

            rowsByKey[finalKey] = row
            perAgentSessionCount[agentID] = count + 1
        }

        // Attach live process to at most one session row per agent (no smear).
        for (agentID, hit) in liveHits {
            let keys = rowsByKey.keys.filter { rowsByKey[$0]?.agent == agentID }
            if keys.isEmpty {
                let key = agentID.rawValue
                var row = AgentRow(rowKey: key, agent: agentID)
                row.liveProcess = true
                row.processCount = hit.count
                row.viaWarp = hit.viaWarp
                row.pid = hit.pid
                row.tty = hit.tty
                rowsByKey[key] = row
                continue
            }
            let bestKey = keys.max { a, b in
                let ra = rowsByKey[a]!, rb = rowsByKey[b]!
                if ra.waiting != rb.waiting { return !ra.waiting && rb.waiting }
                if ra.harvestMs != rb.harvestMs { return ra.harvestMs < rb.harvestMs }
                return a < b
            }!
            for key in keys {
                guard var row = rowsByKey[key] else { continue }
                if key == bestKey {
                    row.liveProcess = true
                    row.processCount = max(row.processCount, hit.count)
                    row.viaWarp = hit.viaWarp || row.viaWarp
                    if hit.pid != 0 { row.pid = hit.pid }
                    if !hit.tty.isEmpty { row.tty = hit.tty }
                } else {
                    row.liveProcess = false
                    // Don't inherit ×N on sibling sessions.
                    row.processCount = max(row.processCount, 1)
                }
                rowsByKey[key] = row
            }
        }

        // Hooks attention — prefer session / cwd match, else best row for agent.
        for att in input.attention {
            if let targetKey = matchAttentionRow(att, in: rowsByKey) {
                guard var best = rowsByKey[targetKey] else { continue }
                best.waiting = true
                best.waitKind = att.kind
                best.waitSignal = .hooks
                best.waitMessage = att.message
                best.waitSinceMs = att.tsMs
                if best.sessionID.isEmpty, !att.session.isEmpty { best.sessionID = att.session }
                if best.cwd.isEmpty, !att.cwd.isEmpty { best.cwd = att.cwd }
                best.processCount = max(best.processCount, 1)
                rowsByKey[targetKey] = best
                continue
            }
            let key: String = {
                if !att.session.isEmpty {
                    return ActivityHarvest.sessionKey(id: att.id, sessionID: att.session, project: "", cwd: att.cwd)
                }
                return att.id.rawValue
            }()
            var row = AgentRow(rowKey: key, agent: att.id)
            row.sessionID = att.session
            row.cwd = att.cwd
            row.project = AgentRow.shortProject(att.cwd)
            row.waiting = true
            row.waitKind = att.kind
            row.waitSignal = .hooks
            row.waitMessage = att.message
            row.waitSinceMs = att.tsMs
            row.processCount = max(row.processCount, 1)
            rowsByKey[key] = row
        }

        var all = Array(rowsByKey.values).filter { $0.processCount > 0 || $0.waiting || $0.subRunning > 0 }

        // Resolve focus once per scan. Doing this per row inside the SwiftUI body
        // meant enumerating running apps and stat-ing the disk on every redraw.
        for i in all.indices {
            let row = all[i]
            let folderPath = row.cwd.isEmpty ? row.project : row.cwd
            let cwdExists = !row.cwd.isEmpty && context.pathExists(row.cwd)
            all[i].canOpenFolder = !folderPath.isEmpty && context.pathExists(folderPath)
            all[i].focusTier = TerminalFocus.focusTier(
                tty: row.tty,
                viaWarp: row.viaWarp,
                cwdExists: cwdExists,
                env: context.terminal
            )
        }

        // Waiting → titled sessions → live process → recent; agent priority last.
        //
        // Within Waiting, the oldest goes first: when three agents are blocked,
        // "who has been stuck longest" is the question the list should answer.
        // A zero timestamp means unknown, which sorts last rather than first.
        all.sort { a, b in
            if a.waiting != b.waiting { return a.waiting && !b.waiting }
            if a.waiting && b.waiting, a.waitSinceMs != b.waitSinceMs {
                if a.waitSinceMs == 0 { return false }
                if b.waitSinceMs == 0 { return true }
                return a.waitSinceMs < b.waitSinceMs
            }
            if a.hasSessionTitle != b.hasSessionTitle { return a.hasSessionTitle && !b.hasSessionTitle }
            if a.liveProcess != b.liveProcess { return a.liveProcess && !b.liveProcess }
            if (a.subRunning > 0) != (b.subRunning > 0) { return a.subRunning > 0 && b.subRunning == 0 }
            let ra = AgentID.priority.firstIndex(of: a.agent) ?? 999
            let rb = AgentID.priority.firstIndex(of: b.agent) ?? 999
            return ra < rb
        }
        // Attribute held-back sessions to that agent's top row, so the badge
        // appears once rather than on every sibling session.
        var creditedAgents: Set<AgentID> = []
        for i in all.indices {
            let agent = all[i].agent
            guard let dropped = droppedSessionsByAgent[agent], dropped > 0 else { continue }
            if creditedAgents.insert(agent).inserted {
                all[i].hiddenSessions = dropped
            }
        }

        result.rows = all
        result.showAllAgents = context.showAllAgents && all.count > context.maxVisibleRows

        let waitingCount = all.filter(\.waiting).count
        let liveRunning = all.filter { !$0.waiting && ($0.liveProcess || $0.subRunning > 0) }.count
        let recentOnly = all.filter { !$0.waiting && !$0.liveProcess && $0.subRunning == 0 }.count
        result.waitingKeys = Set(all.filter(\.waiting).map(\.rowKey))

        var snap = PulseSnapshot()
        snap.totalCount = all.count
        snap.sectionTotals = [
            .needsYou: waitingCount,
            .running: liveRunning,
            .recent: recentOnly,
        ]
        // Oldest wait = smallest non-zero timestamp. Computed here so the view
        // never has to scan rows to decide what the menu bar should say.
        let waitStamps = all.filter { $0.waiting && $0.waitSinceMs > 0 }.map(\.waitSinceMs)
        if let oldest = waitStamps.min() {
            snap.longestWaitSeconds = max(0, Double(context.nowMs - oldest) / 1000.0)
        }
        window(rows: all, showAll: result.showAllAgents, maxVisible: context.maxVisibleRows, into: &snap)

        let lang = context.lang

        // Distinct projects — the header's one legitimate subject.
        var projectNames: [String] = []
        for r in all {
            let p = r.displayPath
            guard !p.isEmpty, !projectNames.contains(p) else { continue }
            projectNames.append(p)
        }
        snap.projectCount = projectNames.count

        /// What the header may say.
        ///
        /// It read `relative(updatedAt)` — computed microseconds after
        /// `updatedAt = Date()`, so always "just now". 0.24 replaced that with
        /// the agent names, which the rows already carry: the panel then said
        /// "2 running / Cursor · Amp" above two rows that each named their own
        /// agent. A header earns its line only by stating something no single
        /// row can — how much is hidden, or how far the work is spread.
        func aggregate() -> String {
            if snap.hiddenCount > 0 {
                return String(format: t(.andMore, lang), snap.hiddenCount)
            }
            if projectNames.count > 1 {
                return String(format: t(.acrossProjects, lang), projectNames.count)
            }
            // One project is on every row already. Saying it again here is the
            // exact duplication this rewrite exists to remove.
            return ""
        }

        // Header answers only "N need you / N running"; row detail carries the rest.
        if all.isEmpty, input.harvestUnreliable, liveHits.isEmpty {
            snap.glance = .error
            snap.title = "!"
            snap.tooltip = t(.cantRefresh, lang)
            snap.headerTitle = t(.cantRefresh, lang)
            snap.headerDetail = ""
            snap.header = t(.cantRefresh, lang)
            snap.probeError = "probe+harvest unavailable"
        } else if waitingCount > 0 {
            snap.glance = .waiting
            let waitingRows = all.filter(\.waiting)
            let nameJoin = waitingRows.prefix(3).map(\.agent.displayName).joined(separator: " · ")
            // The menu bar carries the two facts that decide whether to look:
            // how many are blocked, and how long the worst one has waited.
            //
            // A wait younger than five seconds formats as "now", which says
            // nothing the lamp has not already said — so hold the space until
            // the number is worth it, and let the label escalate on its own
            // from "Claude…" to "Claude · 4m".
            let rawDuration = snap.longestWaitSeconds > 0
                ? DurationFormat.label(seconds: snap.longestWaitSeconds, lang: lang)
                : ""
            let dur = rawDuration == t(.durNow, lang) ? "" : rawDuration
            if waitingCount == 1, let w = waitingRows.first {
                snap.title = dur.isEmpty
                    ? "\(w.agent.displayName)…"
                    : "\(w.agent.displayName) · \(dur)"
                snap.tooltip = "\(t(.needsYou, lang)) · \(w.agent.displayName)"
                snap.headerTitle = t(.needsYou, lang)
            } else {
                snap.title = dur.isEmpty ? "\(waitingCount)" : "\(waitingCount) · \(dur)"
                snap.tooltip = "\(t(.needsYou, lang)): \(nameJoin)"
                snap.headerTitle = "\(waitingCount) \(t(.waitingN, lang))"
            }
            snap.headerDetail = aggregate()
            snap.header = "\(snap.headerTitle) · \(snap.headerDetail)"
        } else if liveRunning > 0 {
            snap.glance = .running
            let liveRows = all.filter { !$0.waiting && ($0.liveProcess || $0.subRunning > 0) }
            let liveNames = liveRows.prefix(3).map(\.agent.displayName).joined(separator: " · ")
            if liveRunning == 1 {
                snap.title = liveRows[0].agent.displayName
                snap.tooltip = "\(liveRows[0].agent.displayName) \(t(.running, lang))"
                snap.headerTitle = t(.running1, lang)
            } else {
                snap.title = "\(liveRunning)"
                snap.tooltip = "\(liveRunning) \(t(.runningN, lang)): \(liveNames)"
                snap.headerTitle = "\(liveRunning) \(t(.runningN, lang))"
            }
            // "2 running" above four rows left the other two unaccounted for.
            // The header counts what the list contains.
            if recentOnly > 0 {
                snap.headerTitle += " · \(recentOnly) \(t(.recentN, lang))"
            }
            snap.headerDetail = aggregate()
            snap.header = "\(snap.headerTitle) · \(snap.headerDetail)"
        } else if recentOnly > 0 {
            snap.glance = .idle
            snap.title = ""
            snap.tooltip = "Pulse · \(recentOnly) \(t(.recentN, lang))"
            snap.headerTitle = recentOnly == 1
                ? t(.recent1, lang)
                : "\(recentOnly) \(t(.recentN, lang))"
            snap.headerDetail = aggregate()
            snap.header = "\(snap.headerTitle) · \(snap.headerDetail)"
        } else {
            snap.glance = .idle
            snap.title = ""
            snap.tooltip = "Pulse · \(t(.idleWord, lang))"
            snap.headerTitle = t(.noAgents, lang)
            snap.headerDetail = ""
            snap.header = t(.noAgents, lang)
        }
        snap.accessibilityLabel = t(snap.glance.accessibilityKey, lang)
        result.snapshot = snap

        // Edges — reported, not acted on. The store owns notification policy.
        let previousLampBusy = previous.rows.contains { $0.waiting || $0.liveProcess || $0.subRunning > 0 }
        let nowLampBusy = all.contains { $0.waiting || $0.liveProcess || $0.subRunning > 0 }
        result.wentIdle = previousLampBusy && !nowLampBusy

        let newcomers = result.waitingKeys.subtracting(previous.waitingKeys)
        result.newlyWaiting = all.filter { newcomers.contains($0.rowKey) }
        result.resolvedWaits = previous.rows.filter {
            $0.waiting && !result.waitingKeys.contains($0.rowKey)
        }

        if waitingCount > 0 {
            result.activity = .waiting
        } else if liveRunning > 0 {
            result.activity = .running
        } else if recentOnly > 0 {
            result.activity = .recent
        } else {
            result.activity = .empty
        }

        return result
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
        // Sessions dropped by the per-agent cap are separate from folded rows.
        snap.cappedSessions = rows.reduce(0) { $0 + $1.hiddenSessions }
    }

    /// Match an attention entry to an existing harvest/process row.
    static func matchAttentionRow(
        _ att: AttentionReader.Entry,
        in rowsByKey: [String: AgentRow]
    ) -> String? {
        let candidates = rowsByKey.values.filter { $0.agent == att.id }
        guard !candidates.isEmpty else { return nil }

        if !att.session.isEmpty {
            // `rowKey` elides long session ids (prefix…suffix), so a full id can
            // never be a substring of it — that check silently never matched.
            // Compare session ids directly, both directions for truncated forms.
            if let hit = candidates.first(where: {
                guard !$0.sessionID.isEmpty else { return false }
                return $0.sessionID == att.session
                    || att.session.hasPrefix($0.sessionID)
                    || $0.sessionID.hasPrefix(att.session)
            }) {
                return hit.rowKey
            }
        }
        if !att.cwd.isEmpty {
            if let hit = candidates.first(where: {
                !$0.cwd.isEmpty && (
                    $0.cwd == att.cwd
                        || $0.cwd.hasPrefix(att.cwd)
                        || att.cwd.hasPrefix($0.cwd)
                )
            }) {
                return hit.rowKey
            }
            let want = AgentRow.shortProject(att.cwd)
            if !want.isEmpty, let hit = candidates.first(where: {
                AgentRow.shortProject($0.project) == want || AgentRow.shortProject($0.cwd) == want
            }) {
                return hit.rowKey
            }
        }
        var ranked = candidates
        ranked.sort { a, b in
            if a.liveProcess != b.liveProcess { return a.liveProcess && !b.liveProcess }
            return a.harvestMs > b.harvestMs
        }
        return ranked.first?.rowKey
    }
}
