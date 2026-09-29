import Foundation

/// The merge core: probe hits + harvest rows + attention entries → tray rows and
/// a `PulseSnapshot`.
///
/// Everything the merge needs from the outside world is injected through
/// `Context`, and everything it wants the world to *do* comes back as data —
/// notification edges, released dismissals, log lines. The store stays in
/// charge of policy and I/O; this stays a function of its inputs.
///
/// 23.0 · **identity is decided once.** Every row is born with the key
/// `RowIdentity` gives it and keeps it: a session row is keyed by the
/// vendor's session, a hook wait with no session row by the session it names
/// (so the transcript turning up later finds the same key), and a process
/// with no session is its own ephemeral `agent|pid:<pid>` row that is simply
/// not built once a session row for the agent exists — it never "upgrades".
/// Nothing downstream has to follow a key from one name to another.
enum SnapshotBuilder {

    /// Safety bound for the searchable session index, not the glance viewport.
    static let maxSessionsPerAgent = 500
    /// Rows shown before the "and N more" fold.
    static let maxVisibleRows = 12
    /// How long a harvest `pending` (an ask written into a vendor's own
    /// session file) may stay red with no process of that agent alive. The
    /// file keeps the ask forever when the app was quit mid-question; past
    /// this bound it is a record of an old ask, not someone blocked now.
    static let pendingWithoutProcessMaxAgeMs: Int64 = 30 * 60 * 1000
    /// Stale sessions counted in "N older hidden": only those that went
    /// quiet within this window. A month of old transcripts is not news.
    static let staleHiddenWindowMs: Int64 = 24 * 60 * 60 * 1000

    /// Outside-world facts, captured once per scan.
    struct Context {
        var nowMs: Int64
        var terminal: TerminalFocus.Environment
        var lang: ResolvedLanguage
        var maxSessionsPerAgent: Int
        var maxVisibleRows: Int
        /// Harvest `pending` / vendor waits the user soft-dismissed.
        var dismissedPendingKeys: Set<String>
        var showAllAgents: Bool
        /// Seconds of silence that make a live row stalled; 0 disables it.
        var stalledSeconds: Double

        init(
            nowMs: Int64,
            terminal: TerminalFocus.Environment,
            lang: ResolvedLanguage,
            maxSessionsPerAgent: Int = SnapshotBuilder.maxSessionsPerAgent,
            maxVisibleRows: Int = SnapshotBuilder.maxVisibleRows,
            dismissedPendingKeys: Set<String> = [],
            showAllAgents: Bool = false,
            stalledSeconds: Double = AgentRow.stalledSeconds
        ) {
            self.nowMs = nowMs
            self.terminal = terminal
            self.lang = lang
            self.maxSessionsPerAgent = maxSessionsPerAgent
            self.maxVisibleRows = maxVisibleRows
            self.dismissedPendingKeys = dismissedPendingKeys
            self.showAllAgents = showAllAgents
            self.stalledSeconds = stalledSeconds
        }
    }

    struct Input {
        var procs: [ProcessProbe.Hit] = []
        /// Already resolved to the rows this scan should use (fresh or cached).
        var harvest: [ActivityHarvest.Row] = []
        var attention: [AttentionReader.Entry] = []
        /// 2.9: push-fresh activity events from the hook's spool. They move a
        /// session's live clock; never a wait, never a new row.
        var activity: [ActivitySpool.Event] = []
        /// 18.0: sessions Claude itself reports as waiting (`claude agents`).
        var vendorWaits: [ClaudeAgentsProbe.Wait] = []
    }

    /// What the previous scan left behind, for edge detection.
    struct Previous {
        var rows: [AgentRow] = []
        var waitingKeys: Set<String> = []
        /// When each open wait was raised, by its evidence's clock
        /// (`SessionLog.waitingSince`). A key still waiting whose wait now
        /// carries a later raise is a new wait (`SessionLog.isNewRaise`) —
        /// the second ask on the same row gets its own edge.
        var waitingSince: [String: Int64] = [:]
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
        /// Soft-dismissed keys whose source stopped reporting — the store may
        /// release them.
        var clearedPendingKeys: Set<String> = []
        /// `showAllAgents` after collapsing it when the list got short again.
        var showAllAgents: Bool = false
        /// Lines the caller should log; keeps `DebugLog` out of the pure path.
        var debugNotes: [String] = []
    }

    /// A row while the merge is still deciding its state.
    private struct Draft {
        var row: AgentRow
        var wait: RowWait?
        var turnSinceMs: Int64 = 0
        /// The vendor said this turn is complete.
        var completed = false
        /// The vendor's phase says it is running, process or not.
        var explicitRunning = false
        var subagentsRunning = false
        /// The harvest carried something about this session.
        var hasEvidence = false
        var processOnly = false
    }

    private static func t(_ key: L10n.Key, _ lang: ResolvedLanguage) -> String {
        L10n.t(key, lang)
    }

    static func build(_ input: Input, previous: Previous, context: Context) -> Result {
        var result = Result()
        let nowMs = context.nowMs

        var drafts: [String: Draft] = [:]
        var liveHits: [AgentID: ProcessProbe.Hit] = [:]
        var perAgentSessionCount: [AgentID: Int] = [:]
        var droppedSessionsByAgent: [AgentID: Int] = [:]
        /// 21.0: sessions left out for being older than the fresh window.
        var staleHiddenByAgent: [AgentID: Int] = [:]
        var observedHarvestKeys: Set<String> = []

        for hit in input.procs {
            // Prefer the richer hit if duplicate agent ids appear.
            if let existing = liveHits[hit.id] {
                if existing.tty.isEmpty, !hit.tty.isEmpty { liveHits[hit.id] = hit }
            } else {
                liveHits[hit.id] = hit
            }
        }
        // A live CLI may preserve one known goal when its session store has
        // stopped updating, but it is not a blanket lease for every unfinished
        // rollout that Agent ever wrote. Only when an Agent has no fresh row
        // at all may its best stale, unfinished row inherit the live process.
        var agentsWithFreshRows = Set<AgentID>()
        for act in input.harvest {
            if ActivityHarvest.isFresh(act, nowMs: nowMs) || act.subRunning > 0 {
                agentsWithFreshRows.insert(act.id)
            }
        }
        var staleFallbackByAgent: [AgentID: Int] = [:]
        for (index, act) in input.harvest.enumerated() {
            let agent = act.id
            guard liveHits[agent] != nil,
                  !agentsWithFreshRows.contains(agent),
                  !ActivityHarvest.isFresh(act, nowMs: nowMs),
                  act.subRunning == 0,
                  !act.isCompleted,
                  act.harvestMs > 0
            else { continue }
            guard let existingIndex = staleFallbackByAgent[agent] else {
                staleFallbackByAgent[agent] = index
                continue
            }
            let existing = input.harvest[existingIndex]
            let processCwd = liveHits[agent]?.cwd ?? ""
            let existingMatches = !processCwd.isEmpty && existing.cwd == processCwd
            let candidateMatches = !processCwd.isEmpty && act.cwd == processCwd
            if candidateMatches != existingMatches {
                if candidateMatches { staleFallbackByAgent[agent] = index }
            } else if act.harvestMs > existing.harvestMs {
                staleFallbackByAgent[agent] = index
            }
        }
        let staleFallbackIndices = Set(staleFallbackByAgent.values)

        // MARK: 1 · Session rows, from the harvest.

        for (harvestIndex, act) in input.harvest.enumerated() {
            let agentID = act.id
            let fresh = ActivityHarvest.isFresh(act, nowMs: nowMs)
            if !fresh, act.subRunning == 0, !staleFallbackIndices.contains(harvestIndex) {
                result.debugNotes.append("drop stale harvest \(agentID.rawValue) hm=\(act.harvestMs)")
                if act.harvestMs > 0, nowMs - act.harvestMs <= staleHiddenWindowMs {
                    staleHiddenByAgent[agentID, default: 0] += 1
                }
                continue
            }
            let count = perAgentSessionCount[agentID, default: 0]
            if count >= context.maxSessionsPerAgent {
                // Don't drop it silently — the tray says how many were held back.
                droppedSessionsByAgent[agentID, default: 0] += 1
                continue
            }

            // The same vendor session (or the same file) seen twice is one
            // row whose facts merge; two sessions nothing on disk tells apart
            // stay two rows.
            var key = act.rowKey
            if drafts[key] != nil, act.sessionID.isEmpty, act.transcriptPath.isEmpty {
                var twin = 2
                while drafts["\(key)~\(twin)"] != nil { twin += 1 }
                key = "\(key)~\(twin)"
            }
            observedHarvestKeys.insert(key)

            var draft = drafts[key] ?? Draft(row: AgentRow(rowKey: key, agent: agentID))
            var row = draft.row
            if !act.sessionID.isEmpty { row.sessionID = act.sessionID }
            // A live tool id promoted into `task` is an action, not a goal.
            if !act.task.isEmpty, act.task.caseInsensitiveCompare(act.tool) != .orderedSame {
                row.task = act.task
            }
            if !act.project.isEmpty { row.project = act.project }
            if !act.cwd.isEmpty { row.cwd = act.cwd }
            if !act.model.isEmpty { row.model = act.model }
            if act.errors > 0 { row.errors = act.errors }
            if act.harvestMs > 0 { row.harvestMs = act.harvestMs }
            if act.startedMs > 0 { row.startedMs = act.startedMs }
            // 2.8 self-report: carried, never re-derived; display decides
            // freshness.
            if !act.planSteps.isEmpty {
                row.planSteps = act.planSteps
            } else if !act.planStep.isEmpty, row.planSteps.isEmpty {
                row.planSteps = [ActivityHarvest.PlanStep(text: act.planStep, state: .current)]
            }
            if !act.lastWord.isEmpty { row.lastWord = act.lastWord }
            if !act.lastErrorText.isEmpty { row.lastErrorText = act.lastErrorText }
            // Carried, never re-derived: only the collector saw the disk.
            row.cwdBestEffort = act.cwdBestEffort
            row.source = RowSource(act.evidence)
            draft.row = row

            let phase = act.phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            draft.completed = draft.completed
                || phase == "turn_complete" || phase == "completed" || phase == "complete"
            draft.explicitRunning = draft.explicitRunning
                || phase == "running" || phase == "in_progress" || phase == "working" || phase == "executing"
            draft.subagentsRunning = draft.subagentsRunning || act.subRunning > 0
            draft.hasEvidence = draft.hasEvidence || hasHarvestEvidence(act)

            // Harvest pending → Waiting, only for an agent whose vendor
            // reports blocks at all (`waiting: .hooks`). 24.0: Codex and
            // Cursor never do, so their `pending` is not evidence of a block.
            // The harvest layer, and this path with it, goes in the next phase.
            if act.skill == "pending", agentID.waitingSource != .none, fresh {
                if !context.dismissedPendingKeys.contains(key) {
                    draft.wait = RowWait(
                        kind: harvestWaitKind(tool: act.tool, phase: act.phase),
                        sinceMs: act.harvestMs > 0 ? act.harvestMs : nowMs,
                        signal: .pending
                    )
                }
            } else if context.dismissedPendingKeys.contains(key) {
                // Pending cleared — the soft dismiss has served its purpose.
                result.clearedPendingKeys.insert(key)
            }

            drafts[key] = draft
            perAgentSessionCount[agentID] = count + 1
        }

        // 0.95: a scan that no longer observes a dismissed key means the
        // session left — forget the tombstone so a genuine new pending on the
        // same identity can re-raise.
        for key in context.dismissedPendingKeys where !observedHarvestKeys.contains(key) {
            result.clearedPendingKeys.insert(key)
        }

        // MARK: 2 · Hooks — onto a session row, or a hook-only row.

        for att in input.attention {
            switch matchAttention(att, in: drafts.values.map(\.row)) {
            case .hit(let key):
                guard var draft = drafts[key] else { continue }
                if !att.session.isEmpty, draft.row.sessionID.isEmpty { draft.row.sessionID = att.session }
                // 23.0: the entry's own session, exactly (possibly empty) —
                // the `done` that clears it must carry the same spelling.
                if att.isTurn {
                    // 16.0: a finished turn marks the row it belongs to and
                    // nothing else — no wait, no invented row.
                    if draft.wait == nil {
                        draft.turnSinceMs = att.tsMs
                        draft.row.attentionSession = att.session
                    }
                } else {
                    draft.wait = hookWait(att)
                    draft.row.attentionSession = att.session
                    if draft.row.cwd.isEmpty, !att.cwd.isEmpty { draft.row.cwd = att.cwd }
                }
                drafts[key] = draft
            case .ambiguous:
                // A truncated id matched several sessions — never invent Waiting.
                result.debugNotes.append("attention ambiguous session=\(att.session) agent=\(att.id.rawValue)")
            case .unmatched:
                // A turn with no row has nothing to mark: a row invented from
                // "it finished" would have no other evidence.
                guard !att.isTurn else { continue }
                let key = att.hookRowKey
                var draft = drafts[key] ?? Draft(row: AgentRow(rowKey: key, agent: att.id))
                draft.row.sessionID = att.session
                draft.row.attentionSession = att.session
                if draft.row.cwd.isEmpty { draft.row.cwd = att.cwd }
                if draft.row.project.isEmpty { draft.row.project = AgentRow.shortProject(att.cwd) }
                draft.row.source = .hooks
                draft.wait = hookWait(att)
                drafts[key] = draft
            }
        }

        // MARK: 3 · Processes — onto the agent's best row, or their own row.

        for (agentID, hit) in liveHits {
            let keys = drafts.keys.filter { drafts[$0]?.row.agent == agentID }
            guard !keys.isEmpty else {
                let key = RowIdentity.process(agent: agentID, pid: hit.pid)
                var row = AgentRow(rowKey: key, agent: agentID)
                row.cwd = hit.cwd
                row.project = AgentRow.shortProject(hit.cwd)
                row.source = .process
                attach(hit, to: &row)
                if hit.elapsedSeconds > 0 {
                    row.startedMs = nowMs - Int64(hit.elapsedSeconds * 1000)
                }
                var draft = Draft(row: row)
                draft.processOnly = true
                drafts[key] = draft
                continue
            }
            // One process, one row (no smear): the wait first, then an
            // unfinished session, then the one in the process's folder, then
            // the freshest.
            let bestKey = keys.max { a, b in
                let da = drafts[a]!, db = drafts[b]!
                if (da.wait != nil) != (db.wait != nil) { return db.wait != nil }
                if da.completed != db.completed { return da.completed }
                let ca = !hit.cwd.isEmpty && da.row.cwd == hit.cwd
                let cb = !hit.cwd.isEmpty && db.row.cwd == hit.cwd
                if ca != cb { return cb }
                if da.row.harvestMs != db.row.harvestMs { return da.row.harvestMs < db.row.harvestMs }
                return a > b
            }!
            guard var draft = drafts[bestKey] else { continue }
            attach(hit, to: &draft.row)
            if draft.row.cwd.isEmpty, !hit.cwd.isEmpty {
                draft.row.cwd = hit.cwd
                if draft.row.project.isEmpty { draft.row.project = AgentRow.shortProject(hit.cwd) }
            }
            drafts[bestKey] = draft
        }

        // A vendor-file `pending` with no process of that agent alive and
        // no activity for `pendingWithoutProcessMaxAgeMs` is not red: the
        // ask was written down, but nothing on this Mac is still waiting on
        // it. A hook raise (signal `.hooks`) is not affected.
        for (key, draft) in drafts {
            guard let wait = draft.wait, wait.signal == .pending,
                  liveHits[draft.row.agent] == nil,
                  wait.sinceMs > 0, nowMs - wait.sinceMs > pendingWithoutProcessMaxAgeMs
            else { continue }
            var updated = draft
            updated.wait = nil
            drafts[key] = updated
            result.debugNotes.append("stale pending without process \(draft.row.agent.rawValue)")
        }

        // MARK: 4 · Claude's own report of a waiting session (18.0).

        // A hook raise for the same session already said it (and said it
        // first); a report with no row has no other evidence and makes none.
        // Soft-dismissible like a harvest pending.
        for wait in input.vendorWaits {
            guard let key = drafts.keys.sorted().first(where: { key in
                guard let row = drafts[key]?.row, row.agent == .claude else { return false }
                if !wait.sessionID.isEmpty { return row.sessionID == wait.sessionID }
                return wait.pid > 0 && row.pid == wait.pid
            }), var draft = drafts[key] else { continue }
            if context.dismissedPendingKeys.contains(key) {
                // The user soft-dismissed this wait and Claude still reports
                // it: the tombstone has not served its purpose yet.
                result.clearedPendingKeys.remove(key)
                continue
            }
            guard draft.wait == nil else { continue }
            let kind: String
            switch wait.kind {
            case .permission: kind = "Permission"
            case .question: kind = "Input"
            default: kind = "Waiting"
            }
            draft.wait = RowWait(kind: kind, ask: wait.reason, sinceMs: wait.sinceMs, signal: .vendor)
            drafts[key] = draft
        }

        // MARK: 5 · Live clocks.

        // 2.9 activity events: push-fresh "now" from the hook, applied to the
        // matching session row. Never a wait, and never a new row.
        for event in input.activity {
            guard let agent = AgentID(rawValue: event.agent) else { continue }
            for (key, draft) in drafts
            where draft.row.agent == agent && !event.session.isEmpty && draft.row.sessionID == event.session {
                var updated = draft
                updated.row.applyActivity(event, nowMs: nowMs)
                drafts[key] = updated
            }
        }

        // A hook raise is answered in the vendor's own prompt, and nothing
        // writes `done` when it is: the approved tool simply runs. Its
        // PreToolUse fired *before* the PermissionRequest, so only activity
        // stamped after the raise — the next tool, a new prompt — says the
        // session moved on. Session-scoped: the activity was applied above
        // only to the row owning that exact session.
        for (key, draft) in drafts {
            guard let wait = draft.wait, wait.signal == .hooks,
                  wait.sinceMs > 0, draft.row.activityMs > wait.sinceMs
            else { continue }
            var updated = draft
            updated.wait = nil
            drafts[key] = updated
            result.debugNotes.append("hook wait answered \(draft.row.agent.rawValue) activity after raise")
        }

        // MARK: 6 · One state per row.

        var all: [AgentRow] = []
        for draft in drafts.values {
            guard draft.row.liveProcess || draft.wait != nil || draft.subagentsRunning
                || draft.hasEvidence || draft.processOnly
            else { continue }
            var row = draft.row
            if let wait = draft.wait {
                row.state = .blocked(wait)
            } else if draft.processOnly {
                row.state = .processOnly
            } else if draft.turnSinceMs > 0,
                      turnStillOwed(sinceMs: draft.turnSinceMs, harvestMs: row.harvestMs, activityMs: row.activityMs) {
                row.state = .yourTurn(sinceMs: draft.turnSinceMs)
            } else if draft.subagentsRunning
                        || (!draft.completed && (row.liveProcess || draft.explicitRunning)) {
                row.state = .running
            } else {
                row.state = .recent
            }
            // Resolved once per scan against the scan's own clock.
            row.isStalled = row.state == .running
                && AgentRow.stalled(lastActivityMs: row.lastActivityMs, nowMs: nowMs, threshold: context.stalledSeconds)
            row.focusTier = TerminalFocus.focusTier(
                tty: row.tty,
                viaWarp: row.viaWarp,
                hostApp: row.hostApp,
                workspace: row.cwd,
                workspaceVerified: !row.cwdBestEffort,
                env: context.terminal
            )
            all.append(row)
        }

        // Waiting → active → stalled → recent; within Waiting the oldest
        // first (unknown last); a real title, a live process and agent
        // priority break ties; the key makes the order total, so the same
        // world always lists the same way.
        all.sort { a, b in
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
        result.waitingKeys = Set(all.filter(\.isBlocked).map(\.rowKey))

        result.snapshot = snapshot(rows: all, showAll: result.showAllAgents, staleHiddenByAgent: staleHiddenByAgent, context: context)

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

    /// The cadence tier. 23.0: by row state, like the lamp and the header —
    /// a process with no session, or a finished turn whose CLI stays open,
    /// is not work in progress and must not hold the fast cadence.
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
        // Sessions dropped by the per-agent cap are separate from folded rows.
        snap.cappedSessions = rows.reduce(0) { $0 + $1.hiddenSessions }
    }

    private static func attach(_ hit: ProcessProbe.Hit, to row: inout AgentRow) {
        row.liveProcess = true
        row.viaWarp = row.viaWarp || hit.viaWarp
        if row.hostApp == nil { row.hostApp = hit.hostApp }
        if hit.pid != 0 { row.pid = hit.pid }
        if !hit.tty.isEmpty { row.tty = hit.tty }
    }

    private static func hookWait(_ att: AttentionReader.Entry) -> RowWait {
        RowWait(kind: att.kind, ask: att.message, sinceMs: att.tsMs, signal: .hooks, inFront: att.front == true)
    }

    /// Whether the harvest carried anything about the session at all. A
    /// session store can outlive its CLI process and stay observable; the
    /// row needs something besides a live process to exist on its own.
    private static func hasHarvestEvidence(_ act: ActivityHarvest.Row) -> Bool {
        guard act.evidence != .process else { return false }
        return act.harvestMs > 0
            || act.startedMs > 0
            || !act.task.isEmpty
            || !act.cwd.isEmpty
            || !act.sessionID.isEmpty
            || !act.model.isEmpty
            || !act.phase.isEmpty
            || !act.outcome.isEmpty
            || act.tokensIn > 0
            || act.tokensOut > 0
            || act.records > 0
            || act.errors > 0
            || act.progressDone > 0
            || act.progressTotal > 0
    }

    /// Harvest only stamps `skill=pending`. Map approval/permission evidence
    /// to the Permission chip; everything else stays Input. Never invent
    /// Permission from an empty phase.
    private static func harvestWaitKind(tool: String, phase: String) -> String {
        let normalized = tool.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let permissionTools: Set<String> = [
            "request_approval", "requestapproval",
            "confirm_with_user", "confirmwithuser",
        ]
        if permissionTools.contains(normalized) { return "Permission" }
        let phaseLow = phase.lowercased()
        if phaseLow.contains("permission") || phaseLow.contains("approval") {
            return "Permission"
        }
        return "Input"
    }

    /// How long after a turn ended the transcript may still be written to
    /// (the vendor's own last bookkeeping) before growth means new work.
    static let turnResumeSlackMs: Int64 = 15_000

    /// 16.0: "your turn" ends when the session moves again — a tool call
    /// after the turn ended, or the transcript growing well after it.
    static func turnStillOwed(sinceMs: Int64, harvestMs: Int64, activityMs: Int64) -> Bool {
        guard sinceMs > 0 else { return false }
        if activityMs > sinceMs { return false }
        if harvestMs > sinceMs + turnResumeSlackMs { return false }
        return true
    }

    /// Where an attention entry lands.
    enum AttentionMatch: Equatable {
        case hit(String)
        case unmatched
        case ambiguous
    }

    /// Match an attention entry to a session (or hook-only) row. Never a
    /// process-only row: a process is not a session a hook can speak for.
    ///
    /// Identity order: the session id (exact, else a prefix that fits one
    /// row only; several is `.ambiguous` and must not light) → the working
    /// directory. A hook that names a session never lands on a row that owns
    /// a different one, and (23.0) a hook that names none never lands on a
    /// row that owns one — only a row with no session id of its own can take
    /// an entry by folder, so the `done` that dismisses it names exactly the
    /// entry it clears. Unmatched makes a hook-only row (the caller decides).
    static func matchAttention(_ att: AttentionReader.Entry, in rows: [AgentRow]) -> AttentionMatch {
        let candidates = rows.filter { $0.agent == att.id && !RowIdentity.isProcessKey($0.rowKey) }
        guard !candidates.isEmpty else { return .unmatched }
        let pool = candidates.filter { $0.sessionID.isEmpty }
        if !att.session.isEmpty {
            let sessionMatches = candidates.filter {
                !$0.sessionID.isEmpty && (
                    $0.sessionID == att.session
                        || att.session.hasPrefix($0.sessionID)
                        || $0.sessionID.hasPrefix(att.session)
                )
            }
            if let exact = sessionMatches.first(where: { $0.sessionID == att.session }) {
                return .hit(exact.rowKey)
            }
            if sessionMatches.count == 1 { return .hit(sessionMatches[0].rowKey) }
            if sessionMatches.count > 1 { return .ambiguous }
        }
        guard !att.cwd.isEmpty, !pool.isEmpty else { return .unmatched }
        /// The freshest wins a tie; the key makes it total.
        func best(_ rows: [AgentRow]) -> AgentRow? {
            rows.max { a, b in
                if a.harvestMs != b.harvestMs { return a.harvestMs < b.harvestMs }
                return a.rowKey > b.rowKey
            }
        }
        if let exact = best(pool.filter { $0.cwd == att.cwd }) { return .hit(exact.rowKey) }
        if let nested = best(pool.filter {
            !$0.cwd.isEmpty && ($0.cwd.hasPrefix(att.cwd + "/") || att.cwd.hasPrefix($0.cwd + "/"))
        }) {
            return .hit(nested.rowKey)
        }
        // Rows that know only an encoded project name: one unique match.
        let want = AgentRow.shortProject(att.cwd)
        let named = pool.filter {
            $0.cwd.isEmpty && !want.isEmpty && AgentRow.shortProject($0.project) == want
        }
        if named.count == 1 { return .hit(named[0].rowKey) }
        return .unmatched
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
