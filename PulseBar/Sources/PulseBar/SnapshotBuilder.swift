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

    /// Safety bound for the searchable session index, not the glance viewport.
    /// The tray folds globally after `maxVisibleRows`; 0.50 raises retain so
    /// search can cover up to 500 sessions per agent without dumping them into
    /// the menu-bar panel.
    static let maxSessionsPerAgent = 500
    /// Rows shown before the "and N more" fold.
    ///
    /// Was 5, but every row also carried a permanently visible action strip, so
    /// the panel's fixed 300pt viewport fit about three — people with four or
    /// five agents running had to scroll to learn that. Actions moved to hover
    /// for non-waiting rows and the panel is sized by its content now, so this
    /// can be what it should always have been.
    static let maxVisibleRows = 12

    /// Outside-world facts, captured once per scan.
    struct Context {
        var nowMs: Int64
        var terminal: TerminalFocus.Environment
        var lang: ResolvedLanguage
        var maxSessionsPerAgent: Int
        var maxVisibleRows: Int
        /// Harvest `pending` rows the user soft-dismissed.
        var dismissedPendingKeys: Set<String>
        var showAllAgents: Bool
        /// Silence deadlines by row key — a "remind me later" the user set.
        var snoozedUntilMs: [String: Int64]
        /// Seconds of silence that make a live row stalled; 0 disables it.
        var stalledSeconds: Double
        /// Agents whose protected App Data the user has not granted. Used only
        /// to label ObservationQuality gaps — never to invent facts.
        var privacyLimitedAgents: Set<AgentID>

        init(
            nowMs: Int64,
            terminal: TerminalFocus.Environment,
            lang: ResolvedLanguage,
            maxSessionsPerAgent: Int = SnapshotBuilder.maxSessionsPerAgent,
            maxVisibleRows: Int = SnapshotBuilder.maxVisibleRows,
            dismissedPendingKeys: Set<String> = [],
            showAllAgents: Bool = false,
            snoozedUntilMs: [String: Int64] = [:],
            stalledSeconds: Double = AgentRow.stalledSeconds,
            privacyLimitedAgents: Set<AgentID> = []
        ) {
            self.nowMs = nowMs
            self.terminal = terminal
            self.lang = lang
            self.maxSessionsPerAgent = maxSessionsPerAgent
            self.maxVisibleRows = maxVisibleRows
            self.dismissedPendingKeys = dismissedPendingKeys
            self.showAllAgents = showAllAgents
            self.snoozedUntilMs = snoozedUntilMs
            self.stalledSeconds = stalledSeconds
            self.privacyLimitedAgents = privacyLimitedAgents
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
        /// Process-only / Attention adoption that changed row identity (old → new).
        var remappedRowKeys: [String: String] = [:]
        /// `showAllAgents` after collapsing it when the list got short again.
        var showAllAgents: Bool = false
        /// Lines the caller should log; keeps `DebugLog` out of the pure path.
        var debugNotes: [String] = []
    }

    private static func t(_ key: L10n.Key, _ lang: ResolvedLanguage) -> String {
        L10n.t(key, lang)
    }

    /// Short, process-independent digest of a row's identity.
    ///
    /// `Hasher` / `hashValue` are seeded per launch, so they would give the
    /// same session a different row key after every restart — the exact defect
    /// this exists to remove. FNV-1a over the UTF-8 bytes is stable across
    /// launches, machines and Swift versions, and eight hex digits are plenty
    /// to separate the handful of sessions that ever share one project.
    static func stableIdentityHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }

    /// The row key for a harvest row whose `sessionKey` cannot stand alone.
    ///
    /// Only fields that cannot change while the session is alive take part:
    /// the working directory it was started in and its start time. `tool`,
    /// `phase`, `progress` and friends move as the agent works, and a key that
    /// moves with them would lose a snooze mid-wait. `task` is the last resort
    /// rather than a first-class part of the seed — a vendor may rename a
    /// session once, early, which is still far steadier than array order.
    ///
    /// When even that is empty the row has no durable identity of its own, so
    /// the old ordinal remains: two rows that nothing on disk tells apart must
    /// still become two rows rather than merge into one.
    static func stableRowKey(
        base: String,
        act: ActivityHarvest.Row,
        ordinal: Int,
        taken: [String: AgentRow]
    ) -> String {
        var seed: [String] = []
        if !act.cwd.isEmpty { seed.append("c:\(act.cwd)") }
        if act.startedMs > 0 { seed.append("s:\(act.startedMs)") }
        if seed.isEmpty, !act.task.isEmpty { seed.append("t:\(act.task)") }
        guard !seed.isEmpty else {
            return taken[base] == nil ? base : "\(base)#\(ordinal)"
        }
        let stable = "\(base)#\(stableIdentityHash(seed.joined(separator: "\u{1}")))"
        guard taken[stable] != nil else { return stable }
        var twin = 2
        while taken["\(stable)~\(twin)"] != nil { twin += 1 }
        return "\(stable)~\(twin)"
    }

    static func build(_ input: Input, previous: Previous, context: Context) -> Result {
        var result = Result()

        var rowsByKey: [String: AgentRow] = [:]
        var liveHits: [AgentID: ProcessProbe.Hit] = [:]
        var perAgentSessionCount: [AgentID: Int] = [:]
        var droppedSessionsByAgent: [AgentID: Int] = [:]
        var observedHarvestKeys: Set<String> = []

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
                if cursor.hostApp == nil { cursor.hostApp = agentHit.hostApp }
                liveHits[.cursor] = cursor
            } else {
                var mapped = agentHit
                mapped.id = .cursor
                liveHits[.cursor] = mapped
            }
            liveHits.removeValue(forKey: .cursorAgent)
        }

        func normalizedAgent(_ id: AgentID) -> AgentID { id.surfaceID }

        // A live CLI may preserve one known goal when its session store has
        // stopped updating, but it is not a blanket lease for every unfinished
        // rollout that Agent ever wrote. Prefer fresh rows. Only when an Agent
        // has no fresh/subagent row at all may one best stale, unfinished row
        // inherit the live process.
        var agentsWithFreshRows = Set<AgentID>()
        for act in input.harvest {
            let agent = normalizedAgent(act.id)
            if ActivityHarvest.isFresh(act, nowMs: context.nowMs) || act.subRunning > 0 {
                agentsWithFreshRows.insert(agent)
            }
        }

        var staleFallbackByAgent: [AgentID: Int] = [:]
        for (index, act) in input.harvest.enumerated() {
            let agent = normalizedAgent(act.id)
            guard liveHits[agent] != nil,
                  !agentsWithFreshRows.contains(agent),
                  !ActivityHarvest.isFresh(act, nowMs: context.nowMs),
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

        for (harvestIndex, act) in input.harvest.enumerated() {
            let agentID = act.id.surfaceID

            let fresh = ActivityHarvest.isFresh(act, nowMs: context.nowMs)
            let isStaleFallback = staleFallbackIndices.contains(harvestIndex)
            if !fresh, act.subRunning == 0, !isStaleFallback {
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
            // Avoid colliding keys when a second session lacks a session id.
            //
            // The suffix used to be `#\(count + 1)` — the number of rows this
            // agent had already contributed *in this scan* — and it was only
            // applied to whichever colliding row arrived second. Both halves
            // depended on harvest order: the same two sessions swapped keys
            // when the collector enumerated them the other way round, and the
            // survivor of a pair silently reverted to the bare key when its
            // sibling went stale. Snooze, soft-dismiss, notification
            // de-duplication and the Look fingerprint are all stored against
            // `rowKey`, so every drift dropped a snooze or replayed a Waiting
            // edge (U-6).
            //
            // A session id already makes the key unique and stable; when the
            // collector has none, the discriminator comes from the row's own
            // durable identity instead of from its position in the array.
            var finalKey = key
            let needsDiscriminator = act.sessionID.isEmpty
                || (rowsByKey[key] != nil && rowsByKey[key]?.sessionID != act.sessionID)
            if needsDiscriminator {
                finalKey = stableRowKey(
                    base: key,
                    act: act,
                    ordinal: count + 1,
                    taken: rowsByKey
                )
            }
            observedHarvestKeys.insert(finalKey)

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
            if act.records > 0 { row.records = act.records }
            if act.startedMs > 0 { row.startedMs = act.startedMs }
            if !act.phase.isEmpty { row.phase = act.phase }
            if !act.outcome.isEmpty { row.outcome = act.outcome }
            if !act.model.isEmpty { row.model = act.model }
            if !act.mode.isEmpty { row.mode = act.mode }
            if act.errors > 0 { row.errors = act.errors }
            if act.files > 0 { row.files = act.files }
            if act.contextPercent > 0 { row.contextPercent = act.contextPercent }
            if act.progressDone > 0 { row.progressDone = act.progressDone }
            if act.progressTotal > 0 { row.progressTotal = act.progressTotal }
            // Digest facts: carried straight through. They were produced by
            // reading the whole transcript, and nothing here can second-guess
            // them without reading it again.
            if !act.loopTool.isEmpty {
                row.loopTool = act.loopTool
                row.loopCount = act.loopCount
            }
            if act.sessionErrors > 0 { row.sessionErrors = act.sessionErrors }
            if !act.toolSummary.isEmpty { row.toolSummary = act.toolSummary }
            // 2.1 Evidence: same discipline, more facts. Copied verbatim —
            // no truncation, no re-ordering, no re-derivation. The digest read
            // the transcript; the builder did not, so it has nothing to add
            // and everything to lose by second-guessing.
            if act.sessionTokensIn > 0 { row.sessionTokensIn = act.sessionTokensIn }
            if act.sessionTokensOut > 0 { row.sessionTokensOut = act.sessionTokensOut }
            if !act.recentTools.isEmpty { row.recentTools = act.recentTools }
            if act.digestProgressPercent > 0 { row.digestProgressPercent = act.digestProgressPercent }
            // `false` is a real answer here — "still catching up" must be able
            // to survive a merge, so this one is assigned unconditionally.
            row.digestCaughtUp = act.digestCaughtUp
            if act.bytesPerMinute > 0 { row.bytesPerMinute = act.bytesPerMinute }
            if act.sessionStartedMs > 0 { row.sessionStartedMs = act.sessionStartedMs }
            row.observationSource = act.evidence

            // Harvest pending (Cursor / OpenCode / Gemini / Codex / …) → Waiting.
            if act.skill == "pending", ActivityHarvest.isFresh(act, nowMs: context.nowMs) {
                if !context.dismissedPendingKeys.contains(finalKey) {
                    row.waiting = true
                    row.waitKind = harvestWaitKind(tool: act.tool, phase: act.phase)
                    row.waitSignal = .pending
                    row.waitSinceMs = act.harvestMs > 0 ? act.harvestMs : context.nowMs
                }
            } else if context.dismissedPendingKeys.contains(finalKey) {
                // Pending cleared — the soft dismiss has served its purpose.
                //
                // Only a key the store is actually holding belongs here. This
                // used to report every non-pending row on every scan, so the
                // store received a large non-empty set two to five seconds
                // apart, subtracted nothing from its tombstones, and rewrote
                // `dismissed-pending.json` anyway (U-5).
                result.clearedPendingKeys.insert(finalKey)
            }

            rowsByKey[finalKey] = row
            perAgentSessionCount[agentID] = count + 1
        }

        // 0.95: a reliable complete scan that no longer observes a dismissed
        // key means the session left — forget the tombstone so a genuine new
        // pending on the same identity can re-raise.
        if !input.harvestUnreliable {
            for key in context.dismissedPendingKeys where !observedHarvestKeys.contains(key) {
                result.clearedPendingKeys.insert(key)
            }
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
                row.hostApp = hit.hostApp
                row.pid = hit.pid
                row.tty = hit.tty
                row.processEvidence = hit.evidence
                row.cwd = hit.cwd
                row.project = AgentRow.shortProject(hit.cwd)
                if hit.elapsedSeconds > 0 {
                    row.processStartedMs = context.nowMs - Int64(hit.elapsedSeconds * 1000)
                }
                rowsByKey[key] = row
                continue
            }
            let bestKey = keys.max { a, b in
                let ra = rowsByKey[a]!, rb = rowsByKey[b]!
                if ra.waiting != rb.waiting { return !ra.waiting && rb.waiting }
                if ra.isCompletedPhase != rb.isCompletedPhase {
                    return ra.isCompletedPhase && !rb.isCompletedPhase
                }
                if ra.harvestMs != rb.harvestMs { return ra.harvestMs < rb.harvestMs }
                return a < b
            }!
            for key in keys {
                guard var row = rowsByKey[key] else { continue }
                if key == bestKey {
                    row.liveProcess = true
                    row.processCount = max(row.processCount, hit.count)
                    row.viaWarp = hit.viaWarp || row.viaWarp
                    if row.hostApp == nil { row.hostApp = hit.hostApp }
                    if hit.pid != 0 { row.pid = hit.pid }
                    if !hit.tty.isEmpty { row.tty = hit.tty }
                    row.processEvidence = hit.evidence
                    if row.cwd.isEmpty, !hit.cwd.isEmpty {
                        row.cwd = hit.cwd
                        row.project = AgentRow.shortProject(hit.cwd)
                    }
                    if hit.elapsedSeconds > 0 {
                        row.processStartedMs = context.nowMs - Int64(hit.elapsedSeconds * 1000)
                    }
                } else {
                    row.liveProcess = false
                    // Do not inherit any process count on sibling sessions.
                    // A single ProcessProbe hit is attached to one best row;
                    // the other rows remain harvest-only observations.
                }
                rowsByKey[key] = row
            }
        }

        // Hooks attention — prefer session / cwd match, else best row for agent.
        for att in input.attention {
            // A wait raised on another machine is its own row, always. Matching
            // it onto a local session would attach a remote question to a local
            // process — and then Focus, snooze and dismiss would all act on the
            // wrong thing.
            if att.isRemote {
                let key = remoteRowKey(att)
                var row = rowsByKey[key] ?? AgentRow(rowKey: key, agent: att.id.surfaceID)
                row.sessionID = att.session
                row.cwd = att.cwd
                row.project = AgentRow.shortProject(att.cwd)
                row.host = att.host
                row.observationSource = .remote
                row.lastHeardMs = att.receivedAtMs > 0 ? att.receivedAtMs : att.effectiveMs
                row.clockSuspect = att.clockSuspect
                row.lostContact = att.lostContact
                // No process table, no session file, no focus handle. Every
                // one of these would be a claim about this Mac.
                row.liveProcess = false
                row.processCount = 0
                row.focusTier = nil
                if att.lostContact {
                    row.waiting = false
                    row.waitKind = ""
                    row.waitMessage = ""
                    row.waitSignal = nil
                    row.waitSinceMs = 0
                } else {
                    row.waiting = true
                    row.waitKind = att.kind
                    row.waitSignal = .hooks
                    row.waitMessage = att.message
                    row.waitSinceMs = att.effectiveMs
                }
                rowsByKey[key] = row
                continue
            }
            switch matchAttentionRow(att, in: rowsByKey) {
            case .hit(let targetKey):
                guard var best = rowsByKey[targetKey] else { continue }
                best.waiting = true
                best.waitKind = att.kind
                best.waitSignal = .hooks
                best.waitMessage = att.message
                best.waitSinceMs = att.tsMs
                if best.sessionID.isEmpty, !att.session.isEmpty { best.sessionID = att.session }
                if best.cwd.isEmpty, !att.cwd.isEmpty { best.cwd = att.cwd }
                best.processCount = max(best.processCount, 1)
                // 0.96: rekey process-only adoption so snooze/dismiss follow harvest identity.
                let newKey = ActivityHarvest.sessionKey(
                    id: best.agent,
                    sessionID: best.sessionID,
                    project: best.project,
                    cwd: best.cwd
                )
                if newKey != targetKey, rowsByKey[newKey] == nil {
                    rowsByKey.removeValue(forKey: targetKey)
                    best.rowKey = newKey
                    rowsByKey[newKey] = best
                    result.remappedRowKeys[targetKey] = newKey
                } else {
                    rowsByKey[targetKey] = best
                }
                continue
            case .ambiguous:
                // Truncated id matched multiple siblings — never invent Waiting.
                result.debugNotes.append(
                    "attention ambiguous session=\(att.session) agent=\(att.id.rawValue)"
                )
                continue
            case .unmatched:
                break
            }
            let key: String = {
                if !att.session.isEmpty {
                    return ActivityHarvest.sessionKey(id: att.id.surfaceID, sessionID: att.session, project: "", cwd: att.cwd)
                }
                return att.id.surfaceID.rawValue
            }()
            var row = AgentRow(rowKey: key, agent: att.id.surfaceID)
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

        // A harvest row is still useful without a matching process: a session
        // store can outlive its CLI process and should remain observable. Do
        // not manufacture a process count merely to keep it in the tray; the
        // count is reserved for ProcessProbe evidence.
        func hasHarvestEvidence(_ row: AgentRow) -> Bool {
            guard row.observationSource != .process else { return false }
            return row.harvestMs > 0
                || row.startedMs > 0
                || !row.task.isEmpty
                || !row.cwd.isEmpty
                || !row.sessionID.isEmpty
                || !row.model.isEmpty
                || !row.phase.isEmpty
                || !row.outcome.isEmpty
                || row.tokensIn > 0
                || row.tokensOut > 0
                || row.records > 0
                || row.files > 0
                || row.errors > 0
                || row.contextPercent > 0
                || row.progressDone > 0
                || row.progressTotal > 0
        }
        var all = Array(rowsByKey.values).filter {
            // A remote row is kept on the strength of the event that created
            // it. It has no process and no session store to point at, and a
            // lost-contact row in particular carries no facts at all — which
            // is the whole message.
            $0.liveProcess || $0.waiting || $0.subRunning > 0 || $0.isRemote
                || hasHarvestEvidence($0)
        }

        // Compare the same concrete session with the prior scan. Preserve a
        // meaningful change briefly so a 5-second polling interval does not
        // turn it into a one-frame flash.
        let previousByKey = Dictionary(
            uniqueKeysWithValues: previous.rows.map { ($0.rowKey, $0) }
        )
        let changeLifetimeMs: Int64 = 3 * 60 * 1000
        for index in all.indices {
            guard let old = previousByKey[all[index].rowKey] else { continue }
            let current = all[index]
            let changed: AgentActivityChange? = {
                // Filesystems and vendor stores often expose second-level
                // mtimes. A session can therefore advance its progress or
                // token counters without increasing `harvestMs`; requiring a
                // strictly newer timestamp made the change banner silently
                // miss exactly the fast updates users look for.
                let signalMoved = current.outcome != old.outcome
                    || current.errors != old.errors
                    || current.progressDone != old.progressDone
                    || current.progressTotal != old.progressTotal
                    || current.files != old.files
                    || current.tokensIn != old.tokensIn
                    || current.tokensOut != old.tokensOut
                    || current.model != old.model
                    || current.mode != old.mode
                    || current.records != old.records
                    || current.subRunning != old.subRunning
                    || current.subTotal != old.subTotal
                    // 0.91 Row Story — tool/phase/task are what users mean by
                    // "it moved", even when token counters stay flat.
                    || current.tool != old.tool
                    || current.phase != old.phase
                    || current.task != old.task
                guard current.harvestMs > 0,
                      current.harvestMs > old.harvestMs || signalMoved
                else { return nil }
                let outcome = current.outcome.lowercased()
                let oldOutcome = old.outcome.lowercased()
                if outcome != oldOutcome {
                    if outcome.contains("fail") || outcome.contains("error") { return .failed }
                    if outcome.contains("cancel") || outcome.contains("abort") { return .cancelled }
                    if outcome.contains("complete") { return .completed }
                }
                if current.errors > old.errors { return .errors(current.errors - old.errors) }
                if current.progressTotal > 0,
                   current.progressDone > old.progressDone {
                    return .progress(done: current.progressDone, total: current.progressTotal)
                }
                if current.files > old.files { return .files(current.files - old.files) }
                if current.tool != old.tool, !current.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .toolChanged
                }
                if current.phase != old.phase, !current.phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .phaseChanged
                }
                if current.task != old.task, !current.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .taskChanged
                }
                if current.tokensIn != old.tokensIn || current.tokensOut != old.tokensOut
                    || current.model != old.model || current.mode != old.mode
                    || current.records != old.records {
                    return .modelCall
                }
                return nil
            }()
            if let changed {
                all[index].activityChange = changed
                all[index].activityChangedMs = context.nowMs
            } else if let priorChange = old.activityChange,
                      old.activityChangedMs > 0,
                      context.nowMs - old.activityChangedMs <= changeLifetimeMs {
                all[index].activityChange = priorChange
                all[index].activityChangedMs = old.activityChangedMs
            }
        }

        // Resolve focus once per scan. Doing this per row inside the SwiftUI body
        // meant enumerating running apps and stat-ing the disk on every redraw.
        var snoozeUntilByKey = context.snoozedUntilMs
        for (oldKey, newKey) in result.remappedRowKeys {
            if let until = snoozeUntilByKey[oldKey] {
                snoozeUntilByKey[newKey] = until
            }
        }
        for i in all.indices {
            let row = all[i]
            all[i].isStalled = !row.isCompletedPhase && AgentRow.stalled(
                harvestMs: row.harvestMs,
                nowMs: context.nowMs,
                waiting: row.waiting,
                live: row.liveProcess || row.isExplicitlyRunningPhase || row.subRunning > 0,
                threshold: context.stalledSeconds,
                activityChangedMs: all[i].activityChangedMs
            )
            // Resolved here for the same reason as `isStalled`: a countdown
            // read from `Date()` inside a view body drifts away from the scan
            // that produced the row it is drawn on.
            if row.waiting, let until = snoozeUntilByKey[row.rowKey], until > context.nowMs {
                all[i].snoozeRemainingSeconds = Double(until - context.nowMs) / 1000.0
            }
            // A remote row has no handle on this machine. `cwd` from another
            // host may even exist here by coincidence, which would open the
            // wrong folder — advertising Focus for it is worse than offering
            // nothing.
            all[i].focusTier = row.isRemote
                ? nil
                : TerminalFocus.focusTier(
                    tty: row.tty,
                    viaWarp: row.viaWarp,
                    hostApp: row.hostApp,
                    workspace: row.cwd,
                    env: context.terminal
                )
            let privacy = row.agent.requiresAppDataOptIn
                && context.privacyLimitedAgents.contains(row.agent)
            all[i].refreshObservationQuality(privacyLimited: privacy)
        }

        // Waiting → active → stalled → recent; evidence quality and agent
        // priority only break ties inside the same operational state.
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
            if a.section != b.section { return a.section.rawValue < b.section.rawValue }
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
        let liveRunning = all.filter { $0.section == .running }.count
        let healthyRunning = all.filter(\.isHealthyRunning).count
        let thinRunning = all.filter(\.isThinRunning).count
        let stalledCount = all.filter { $0.section == .stalled }.count
        let recentOnly = all.filter { $0.section == .recent }.count
        result.waitingKeys = Set(all.filter(\.waiting).map(\.rowKey))

        /// Menu-bar lamp for non-Waiting fleets.
        /// Priority: any stalled → orange; else healthy Running → green; else
        /// thin/process-only Running → orange (not healthy green); else idle.
        func liveFleetGlance() -> GlanceKind {
            if stalledCount > 0 { return .stalled }
            if healthyRunning > 0 { return .running }
            if thinRunning > 0 || liveRunning > 0 { return .stalled }
            return .idle
        }

        var snap = PulseSnapshot()
        snap.totalCount = all.count
        snap.sectionTotals = [
            .needsYou: waitingCount,
            .running: liveRunning,
            .stalled: stalledCount,
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

        /// A complete operational census. Unlike agent names or "just now",
        /// these counts cannot be recovered from a single row and they explain
        /// every row the header sits above.
        func stateSummary() -> String {
            var bits: [String] = []
            if waitingCount > 0 { bits.append("\(waitingCount) \(t(.waitingN, lang))") }
            if liveRunning > 0 { bits.append("\(liveRunning) \(t(.runningN, lang))") }
            if stalledCount > 0 { bits.append("\(stalledCount) \(t(.sectionStalled, lang).lowercased())") }
            if recentOnly > 0 { bits.append("\(recentOnly) \(t(.recentN, lang))") }
            return bits.joined(separator: " · ")
        }

        // Header accounts for all four states; no live-but-stalled row is
        // allowed to inflate the healthy Running count.
        if all.isEmpty, input.harvestUnreliable, liveHits.isEmpty {
            snap.glance = .error
            snap.title = "!"
            snap.tooltip = t(.cantRefresh, lang)
            snap.headerTitle = t(.cantRefresh, lang)
            snap.headerDetail = ""
            snap.header = t(.cantRefresh, lang)
            snap.probeError = "probe+harvest unavailable"
        } else if waitingCount > 0 {
            // Snoozed waits keep their row, their section and their place in
            // the count — the panel tells the truth. What they lose is the
            // menu bar: no red lamp, no elapsed time, nothing in the corner of
            // your eye. That suppression *is* the feature; without it "remind
            // me later" reminds you continuously.
            let waitingRows = all.filter { $0.waiting && !$0.isSnoozed }
            snap.glance = waitingRows.isEmpty
                ? liveFleetGlance()
                : .waiting
            let nameJoin = waitingRows.prefix(3).map(\.agent.displayName).joined(separator: " · ")
            // The menu bar carries the two facts that decide whether to look:
            // how many are blocked, and how long the worst one has waited.
            //
            // A wait younger than five seconds formats as "now", which says
            // nothing the lamp has not already said — so hold the space until
            // the number is worth it, and let the label escalate on its own
            // from "Claude…" to a duration that still fits the 8-cell budget
            // (`1 · 4m` when `Claude · 4m` is too wide).
            // Elapsed time in the menu bar must come from the waits that are
            // still shouting, not from a snoozed one that happens to be older.
            let activeStamps = waitingRows.filter { $0.waitSinceMs > 0 }.map(\.waitSinceMs)
            let activeOldest = activeStamps.min().map { max(0, Double(context.nowMs - $0) / 1000.0) } ?? 0
            let rawDuration = activeOldest > 0
                ? DurationFormat.label(seconds: activeOldest, lang: lang)
                : ""
            let dur = rawDuration == t(.durNow, lang) ? "" : rawDuration
            if waitingRows.isEmpty {
                // Every wait is snoozed. The lamp already went quiet above; the
                // menu bar text goes with it, and the panel keeps the count.
                snap.title = ""
                snap.tooltip = "\(t(.needsYou, lang)) · \(t(.snoozed, lang))"
                snap.headerTitle = stateSummary()
            } else if waitingRows.count == 1, let w = waitingRows.first {
                let named = dur.isEmpty
                    ? "\(w.agent.displayName)…"
                    : "\(w.agent.displayName) · \(dur)"
                let counted = dur.isEmpty ? "1" : "1 · \(dur)"
                snap.title = GlanceTitle.fit(named, counted, "1")
                // `waitKind` is a protocol token (`Permission` / `Input`), not
                // user copy. Printing it raw put a bare English word in the
                // Chinese tooltip; the row chip and the banner had already
                // learned to translate it.
                let reason = w.waitKind.isEmpty
                    ? (w.waitMessage.isEmpty ? t(.needsYou, lang) : w.waitMessage)
                    : L10n.waitKind(w.waitKind, lang)
                snap.tooltip = dur.isEmpty
                    ? "\(t(.needsYou, lang)) · \(w.agent.displayName) · \(reason)"
                    : "\(t(.needsYou, lang)) · \(w.agent.displayName) · \(reason) · \(dur)"
                snap.headerTitle = stateSummary()
            } else {
                let counted = dur.isEmpty
                    ? "\(waitingRows.count)"
                    : "\(waitingRows.count) · \(dur)"
                snap.title = GlanceTitle.fit(counted, "\(waitingRows.count)")
                snap.tooltip = dur.isEmpty
                    ? "\(t(.needsYou, lang)): \(nameJoin)"
                    : "\(t(.needsYou, lang)): \(nameJoin) · \(dur)"
                snap.headerTitle = stateSummary()
            }
            snap.headerDetail = aggregate()
            snap.header = snap.headerDetail.isEmpty
                ? snap.headerTitle
                : "\(snap.headerTitle) · \(snap.headerDetail)"
        } else if liveRunning > 0 || stalledCount > 0 {
            snap.glance = liveFleetGlance()
            let liveRows = all.filter { $0.section == .running }
            let stalledRows = all.filter { $0.section == .stalled }
            let busyRows = liveRows + stalledRows
            let liveNames = busyRows.prefix(3).map(\.agent.displayName).joined(separator: " · ")
            let oldestStall = stalledRows.map(\.lastActivitySeconds).filter { $0 > 0 }.max() ?? 0
            let stalledDur = oldestStall > 0
                ? DurationFormat.label(seconds: oldestStall, lang: lang)
                : ""
            if healthyRunning == 1, stalledCount == 0, thinRunning == 0 {
                let name = liveRows.first(where: \.isHealthyRunning)?.agent.displayName
                    ?? liveRows[0].agent.displayName
                snap.title = GlanceTitle.fit(name, "1")
                snap.tooltip = "\(name) \(t(.running, lang))"
            } else if snap.glance == .stalled, liveRunning == 0 || stalledCount > 0 {
                // Stall-only, or mixed fleet where stall wins the lamp: surface
                // count + oldest silence so the corner matches Waiting's "how long".
                let n = max(stalledCount, liveRunning + stalledCount)
                snap.title = "\(stalledCount > 0 ? stalledCount : n)"
                if stalledCount > 0 {
                    snap.tooltip = stalledDur.isEmpty
                        ? "\(stalledCount) \(t(.sectionStalled, lang).lowercased()): \(liveNames)"
                        : "\(stalledCount) \(t(.sectionStalled, lang).lowercased()): \(liveNames) · \(stalledDur)"
                } else {
                    snap.tooltip = "\(stateSummary()): \(liveNames)"
                }
            } else if snap.glance == .stalled {
                // Thin / process-only Running — orange lamp, not "healthy".
                snap.title = "\(liveRunning)"
                snap.tooltip = "\(stateSummary()): \(liveNames)"
            } else {
                snap.title = "\(liveRunning + stalledCount)"
                snap.tooltip = "\(stateSummary()): \(liveNames)"
            }
            snap.headerTitle = stateSummary()
            snap.headerDetail = aggregate()
            snap.header = snap.headerDetail.isEmpty
                ? snap.headerTitle
                : "\(snap.headerTitle) · \(snap.headerDetail)"
        } else if recentOnly > 0 {
            snap.glance = .idle
            snap.title = ""
            snap.tooltip = "Pulse · \(recentOnly) \(t(.recentN, lang))"
            snap.headerTitle = recentOnly == 1
                ? t(.recent1, lang)
                : "\(recentOnly) \(t(.recentN, lang))"
            snap.headerDetail = aggregate()
            snap.header = snap.headerDetail.isEmpty
                ? snap.headerTitle
                : "\(snap.headerTitle) · \(snap.headerDetail)"
        } else {
            snap.glance = .idle
            snap.title = ""
            snap.tooltip = "Pulse · \(t(.idleWord, lang))"
            snap.headerTitle = t(.noAgents, lang)
            snap.headerDetail = ""
            snap.header = t(.noAgents, lang)
        }
        snap.accessibilityLabel = t(snap.glance.accessibilityKey, lang)
        if snap.glance == .waiting || snap.glance == .stalled || snap.glance == .error {
            // Keep VoiceOver aligned with the explainable menu-bar tooltip.
            if !snap.tooltip.isEmpty {
                snap.accessibilityLabel = snap.tooltip
            }
        }
        result.snapshot = snap

        // Edges — reported, not acted on. The store owns notification policy.
        let previousLampBusy = previous.rows.contains {
            $0.waiting || $0.section == .running || $0.section == .stalled
        }
        let nowLampBusy = all.contains {
            $0.waiting || $0.section == .running || $0.section == .stalled
        }
        result.wentIdle = previousLampBusy && !nowLampBusy

        var previousWaiting = previous.waitingKeys
        for (oldKey, newKey) in result.remappedRowKeys {
            if previousWaiting.contains(oldKey) {
                previousWaiting.remove(oldKey)
                previousWaiting.insert(newKey)
            }
        }
        let newcomers = result.waitingKeys.subtracting(previousWaiting)
        result.newlyWaiting = all.filter { newcomers.contains($0.rowKey) }
        // "Lost contact ≠ finished." A remote row whose host stopped reporting
        // drops its red lamp and keeps its place with a reason — and the row
        // says exactly that. Recording it as a resolved wait wrote the opposite
        // into the history the user reads later, so the two disagreed about the
        // same event (U-8). An answered wait resolves; an unreachable one waits
        // on, out of contact.
        let currentByKey = Dictionary(all.map { ($0.rowKey, $0) }, uniquingKeysWith: { first, _ in first })
        result.resolvedWaits = previous.rows.filter { row in
            guard row.waiting else { return false }
            let liveKey = result.remappedRowKeys[row.rowKey] ?? row.rowKey
            guard !result.waitingKeys.contains(liveKey) else { return false }
            if currentByKey[liveKey]?.lostContact == true { return false }
            return true
        }

        if waitingCount > 0 {
            result.activity = .waiting
        } else if liveRunning > 0 || stalledCount > 0 {
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

    /// Match an attention entry to an existing harvest/process row.
    ///
    /// Identity order: session id → (empty-session process row) → cwd → best
    /// live/fresh row for the agent.
    /// If Attention names a **session** and every candidate already owns a
    /// *different* session, return `.unmatched` so the caller creates a dedicated
    /// Waiting row — never smear onto a sibling. A process-only row with an
    /// empty session id may adopt the named wait.
    /// Ambiguous truncated prefixes return `.ambiguous` and must not light.
    enum AttentionMatch: Equatable {
        case hit(String)
        case unmatched
        case ambiguous
    }

    /// Row identity for a remote wait. The host is part of the key because
    /// snooze, dismiss and notification de-duplication all follow `rowKey`:
    /// two machines running the same agent must not be able to silence each
    /// other.
    static func remoteRowKey(_ att: AttentionReader.Entry) -> String {
        let agent = att.id.surfaceID.rawValue
        let session = att.session.isEmpty ? "" : "|\(att.session)"
        return "\(agent)\(session)@\(att.host)"
    }

    static func matchAttentionRow(
        _ att: AttentionReader.Entry,
        in rowsByKey: [String: AgentRow]
    ) -> AttentionMatch {
        let candidates = rowsByKey.values.filter { $0.agent == att.id.surfaceID }
        guard !candidates.isEmpty else { return .unmatched }

        if !att.session.isEmpty {
            // Exact match first; prefix only when uniquely resolvable so a
            // truncated Attention id cannot smear onto a sibling (0.95).
            let sessionMatches = candidates.filter {
                guard !$0.sessionID.isEmpty else { return false }
                return $0.sessionID == att.session
                    || att.session.hasPrefix($0.sessionID)
                    || $0.sessionID.hasPrefix(att.session)
            }
            if let exact = sessionMatches.first(where: { $0.sessionID == att.session }) {
                return .hit(exact.rowKey)
            }
            if sessionMatches.count == 1 {
                return .hit(sessionMatches[0].rowKey)
            }
            if sessionMatches.count > 1 {
                return .ambiguous
            }
            // Process-only / unset-session rows can adopt the named wait.
            if let unset = candidates.first(where: { $0.sessionID.isEmpty }) {
                return .hit(unset.rowKey)
            }
            // Every candidate already owns a different session — do not smear.
            return .unmatched
        }
        if !att.cwd.isEmpty {
            if let hit = candidates.first(where: {
                !$0.cwd.isEmpty && (
                    $0.cwd == att.cwd
                        || $0.cwd.hasPrefix(att.cwd + "/")
                        || att.cwd.hasPrefix($0.cwd + "/")
                )
            }) {
                return .hit(hit.rowKey)
            }
            let want = AgentRow.shortProject(att.cwd)
            if !want.isEmpty, let hit = candidates.first(where: {
                AgentRow.shortProject($0.project) == want || AgentRow.shortProject($0.cwd) == want
            }) {
                return .hit(hit.rowKey)
            }
        }
        var ranked = candidates
        ranked.sort { a, b in
            if a.liveProcess != b.liveProcess { return a.liveProcess && !b.liveProcess }
            return a.harvestMs > b.harvestMs
        }
        if let first = ranked.first {
            return .hit(first.rowKey)
        }
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
