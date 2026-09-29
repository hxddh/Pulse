import Foundation
import AppKit

/// 4.0-γ file split — The scan engine — start, refresh, harvest application, activity light path.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    func start() {
        DebugLog.write("start begin \(PulseVersion.fingerprint)")
        // Restore only Pulse-owned attention state. Agent-owned hooks remain
        // the source of truth for the current row; the session log supplies
        // the cross-launch baseline, delivery dedupe and dismissals.
        loadSessionLog()
        waitingNotifySeeded = sessionLog.baselineEstablished
        HooksSupport.seedAssets()
        hooksStatus = HooksSupport.probeStatus()
        loadSettings()
        applyHotkey()
        PulseNotify.registerCategories(lang: lang)
        PulseNotify.configure { [weak self] granted in
            Task { @MainActor in
                self?.notifyAuthorized = granted
                self?.deliverPendingWaitingNotificationsIfPossible()
                DebugLog.write("notify authorization granted=\(String(describing: granted))")
            }
        }
        refresh(reason: "start")
        rescheduleTimer()
        attentionWatcher.start(
            onChange: { [weak self] in
                Task { @MainActor in
                    self?.refresh(reason: "attention")
                }
            },
            onActivity: { [weak self] in
                // An event per vendor tool call must never cost a full
                // harvest — this path reads one bounded directory and
                // patches the rows in place.
                Task { @MainActor in
                    self?.applyActivityLight()
                }
            }
        )
        powerMonitor.start { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rescheduleTimer()
                // Coming back from sleep/lock: catch up immediately.
                if !self.powerMonitor.state.parked {
                    self.refresh(reason: "wake")
                    // Rationed inside (a day after success, an hour after a
                    // failure); waking is when a long-lived Mac is most
                    // likely to have missed a release.
                    UpdateCheck.shared.startIfEnabled(store: self)
                }
            }
        }
        UpdateCheck.shared.startIfEnabled(store: self)
        DebugLog.write("start armed")
    }


    func refresh() {
        refresh(reason: "manual")
    }

    func refresh(reason: String, agentFilter: Set<AgentID>? = nil) {
        if Self.suppressBackgroundScansForTesting { return }
        if scanInFlight {
            if var pending = pendingRefresh {
                pending.absorb(reason: reason, agentFilter: agentFilter)
                pendingRefresh = pending
            } else {
                pendingRefresh = PendingRefresh(reason: reason, agentFilter: agentFilter)
            }
            let scope = pendingRefresh?.agentFilter?
                .map(\.rawValue).sorted().joined(separator: ",") ?? "all"
            DebugLog.write("refresh coalesce pending=\(reason) scope=\(scope)")
            return
        }
        scanInFlight = true
        scanTicket &+= 1
        let ticket = scanTicket
        let showSpinner = reason == "manual" || reason == "start"
        if showSpinner {
            isRefreshing = true
        }
        DebugLog.write("refresh enqueue #\(ticket) reason=\(reason)")

        // Native harvest walks bounded vendor roots; probe is one `ps` call.
        // Only pay for the richer scan when something plausibly changed.
        let forceHarvest = reason != "timer"
        let priorSignature = lastProcessSignature
        let ticks = ticksSinceHarvest
        let everyN = ProbeSchedule.harvestEveryNTicks(activity: activity, trayOpen: trayOpen)
        let allowAllAppData = allowAppData
        let appDataAgentPolicy = harvestAppDataAgents
        let supervisorNowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let supervisorPlan = harvestSupervisor.plan(nowMs: supervisorNowMs)
        if !supervisorPlan.deferred.isEmpty {
            DebugLog.write("harvest supervisor deferred=\(supervisorPlan.deferred.map(\.rawValue).sorted().joined(separator: ",")) \(harvestSupervisor.summary(nowMs: supervisorNowMs))")
        }
        // Permission toggles force the affected Agent(s) even if the supervisor
        // would otherwise defer them. Full scans keep the supervisor plan.
        let harvestFilter: Set<AgentID>? = {
            if let agentFilter { return Set(agentFilter.map(\.surfaceID)) }
            return supervisorPlan.attempted
        }()
        let scopedHarvest = agentFilter != nil
        let startCursor = harvestScanCursor
        // 18.0: Claude's hooks already say who is waiting, sooner; the
        // agents probe only runs where they are not installed.
        let claudeHooked = hooksStatus == .installedClaude || hooksStatus == .installedBoth

        scanQueue.async { [weak self] in
            let t0 = Date()
            let procs = ProcessProbe.scan(
                allowAppData: allowAllAppData,
                appDataAgents: appDataAgentPolicy
            )
            let signature = ProcessProbe.signature(procs)

            let why: String
            if forceHarvest {
                why = "forced"
            } else if signature != priorSignature {
                why = "procChanged"
            } else if ticks >= everyN {
                why = "cadence"
            } else {
                why = "skipped"
            }

            let outcome: HarvestOutcome
            var harvestMs: Int?
            var nextCursor = startCursor
            if why == "skipped" {
                outcome = .skipped
            } else {
                let h0 = Date()
                let result = ActivityHarvest.scan(
                    allowAppData: allowAllAppData,
                    appDataAgents: appDataAgentPolicy,
                    agentFilter: harvestFilter,
                    startCursor: startCursor
                )
                harvestMs = Int(Date().timeIntervalSince(h0) * 1000)
                // A scoped rescan covers a hand-picked subset; its cursor is
                // meaningless to the full rotation.
                nextCursor = scopedHarvest ? startCursor : result.nextCursor
                let intentionalPartial = Self.isIntentionalSupervisorPartial(
                    health: result.health,
                    plan: supervisorPlan
                )
                // Scoped permission rescans report only the affected adapters.
                // Force a partial merge so other Agents keep their last good rows.
                let complete = scopedHarvest ? false : result.complete
                outcome = .fresh(result.rows, result.health, complete, intentionalPartial || scopedHarvest)
            }

            let attention = AttentionReader.load()
            let scanNowMs = Int64(Date().timeIntervalSince1970 * 1000)
            // 2.9: push-fresh activity events. Read here so a full rebuild
            // carries them; the watcher's light path keeps them second-fresh
            // between scans.
            let activityEvents = ActivitySpool.readEvents(nowMs: scanNowMs)
            let vendorWaits = ClaudeAgentsProbe.sample(
                nowMs: scanNowMs,
                claudeLive: procs.contains { $0.id.surfaceID == .claude },
                hooksInstalled: claudeHooked
            )
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DebugLog.write(
                "scan done #\(ticket) \(ms)ms harvest=\(why) scoped=\(scopedHarvest) procs=\(procs.count) " +
                "att=\(attention.count) procIds=\(procs.map(\.id.rawValue).joined(separator: ","))"
            )
            let completedHarvestMs = harvestMs
            let completedCursor = nextCursor
            // Land results on the store that started the flight, not the
            // AppServices singleton: a hardwired singleton sent every other
            // instance's results to the wrong store and left its
            // `scanInFlight` stuck forever — which is also why the scan
            // pipeline could never be exercised from a test.
            DispatchQueue.main.async { [weak self, completedHarvestMs, completedCursor] in
                guard let self else { return }
                self.isApplyingScan = true
                defer { self.isApplyingScan = false }
                self.harvestScanCursor = completedCursor
                switch outcome {
                case .fresh(_, let health, _, _):
                    self.harvestSupervisor.record(
                        health,
                        nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                case .skipped:
                    break
                }
                self.applyScan(
                    procs: procs,
                    harvest: outcome,
                    processSignature: signature,
                    attention: attention,
                    ticket: ticket,
                    harvestMs: completedHarvestMs,
                    clearRefreshing: showSpinner,
                    reason: reason,
                    activityEvents: activityEvents,
                    vendorWaits: vendorWaits
                )
            }
        }
    }

    fileprivate func finishScanFlight() {
        scanInFlight = false
        if let pending = pendingRefresh {
            pendingRefresh = nil
            refresh(reason: pending.reason, agentFilter: pending.agentFilter)
        }
    }

    /// What the background scan managed to get from the native collector.
    enum HarvestOutcome {
        /// Ran and produced rows (possibly partial after a timeout).
        case fresh([ActivityHarvest.Row], [ActivityHarvest.CollectorHealth], Bool, Bool)
        /// Deliberately not run this tick — cached rows are still current.
        case skipped
    }

    /// A supervisor plan can intentionally omit adapters that are backing off
    /// or inside a circuit. That is a bounded, known partial scan: the rows
    /// from those adapters remain in `mergePartialRows`, while the adapters
    /// that did run are a trustworthy snapshot for Waiting reconciliation.
    /// Distinguish this from a global deadline or a failed adapter, otherwise
    /// one broken source would delay notifications and resolution for all the
    /// healthy agents on every subsequent tick.
    nonisolated static func isIntentionalSupervisorPartial(
        health: [ActivityHarvest.CollectorHealth],
        plan: HarvestSupervisor.Plan
    ) -> Bool {
        guard !plan.deferred.isEmpty else { return false }
        let attempted = Set(plan.attempted.map(\.surfaceID))
        guard !attempted.isEmpty else { return false }
        let reported = Set(health.map { $0.id.surfaceID })
        guard attempted.isSubset(of: reported) else { return false }
        return health
            .filter { attempted.contains($0.id.surfaceID) }
            .allSatisfy { item in
                switch item.state {
                case .failed, .schemaMismatch, .unscanned:
                    return false
                case .observed, .noRecentData, .sourceAbsent, .noSessions, .permissionDenied:
                    return true
                }
            }
    }

    func recordCollectorHealth(
        _ health: [ActivityHarvest.CollectorHealth],
        complete: Bool = true,
        intentionalPartial: Bool = false
    ) {
        // A partial stream must not erase the last known result for adapters
        // that have not been reached yet. Only a complete health report resets
        // the map to the explicit unscanned baseline before applying results.
        var next = complete && !health.isEmpty
            ? Dictionary(
                uniqueKeysWithValues: AgentID.allCases.map {
                    ($0, ActivityHarvest.CollectorHealth.unscanned($0))
                }
            )
            : (collectorHealthByAgent.isEmpty
                ? Dictionary(
                    uniqueKeysWithValues: AgentID.allCases.map {
                        ($0, ActivityHarvest.CollectorHealth.unscanned($0))
                    }
                )
                : collectorHealthByAgent)
        for item in health {
            var normalized = item
            normalized.id = item.id.surfaceID
            next[normalized.id] = normalized
        }
        // Cursor Agent sessions are merged into Cursor rows by SnapshotBuilder
        // to avoid duplicate IDE/CLI entries. They share Cursor's local-store
        // collector, so the runtime health must share that result too.
        if let cursor = next[.cursor] {
            next[.cursorAgent] = ActivityHarvest.CollectorHealth(
                id: .cursorAgent,
                state: cursor.state,
                durationMs: cursor.durationMs,
                rowCount: cursor.rowCount,
                sourcePresent: cursor.sourcePresent,
                errorKind: cursor.errorKind,
                explain: cursor.explain
            )
        }
        collectorHealthByAgent = next
        // Supervisor-deferred adapters are a policy partial, not a failed scan.
        // Lighting the incomplete banner for intentional deferral made healthy
        // ticks look broken every time one agent was in backoff.
        let incomplete = !complete && !intentionalPartial
        if collectorScanIncomplete != incomplete { collectorScanIncomplete = incomplete }
    }

    // MARK: - 2.9 activity light path

    /// The watcher's cheap wake: read the bounded spool off the main thread,
    /// then patch matching rows in place. No harvest, no rebuild — the next
    /// full scan re-applies the same events through the builder, so this
    /// path can never drift from it.
    func applyActivityLight() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        scanQueue.async { [weak self] in
            let events = ActivitySpool.readEvents(nowMs: nowMs)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyActivityEvents(events, nowMs: nowMs)
            }
        }
    }

    func applyActivityEvents(_ events: [ActivitySpool.Event], nowMs: Int64) {
        var byKey: [String: ActivitySpool.Event] = [:]
        for event in events {
            guard let agent = AgentID(rawValue: event.agent)?.surfaceID else { continue }
            byKey[agent.rawValue + "|" + event.session] = event
        }
        guard !byKey.isEmpty else { return }
        func patch(_ rows: inout [AgentRow]) -> Bool {
            var changed = false
            for index in rows.indices where !rows[index].sessionID.isEmpty {
                let key = rows[index].agent.rawValue + "|" + rows[index].sessionID
                guard let event = byKey[key] else { continue }
                var row = rows[index]
                row.applyActivity(event, nowMs: nowMs)
                if row != rows[index] {
                    rows[index] = row
                    changed = true
                }
            }
            return changed
        }
        var rows = cachedAll
        if patch(&rows) {
            setCachedAll(rows)
        }
        var next = snapshot
        if patch(&next.rows) {
            snapshot = next
        }
    }

    func applyScan(
        procs: [ProcessProbe.Hit],
        harvest: HarvestOutcome,
        processSignature: String,
        attention: [AttentionReader.Entry],
        ticket: UInt64,
        harvestMs: Int? = nil,
        clearRefreshing: Bool = false,
        reason: String = "",
        activityEvents: [ActivitySpool.Event] = [],
        vendorWaits: [ClaudeAgentsProbe.Wait] = []
    ) {
        defer { finishScanFlight() }

        if ticket < lastAppliedTicket {
            DebugLog.write("apply skip stale #\(ticket) lastApplied=\(lastAppliedTicket)")
            if clearRefreshing, isRefreshing { isRefreshing = false }
            return
        }
        lastAppliedTicket = ticket
        lastProcessSignature = processSignature

        // Resolve which harvest rows this scan should use, and remember them.
        let acts: [ActivityHarvest.Row]
        switch harvest {
        case .fresh(let rows, let health, let complete, let intentionalPartial):
            // A timed-out child can still emit a valid prefix of the stream.
            // Replace only adapters that reported; keep the previous rows for
            // adapters the child never reached so one slow collector cannot
            // make unrelated live sessions disappear from the tray.
            acts = complete
                ? rows
                : ActivityHarvest.mergePartialRows(
                    current: rows,
                    health: health,
                    previous: lastGoodHarvest
                )
            lastGoodHarvest = acts
            recordCollectorHealth(
                health,
                complete: complete,
                intentionalPartial: intentionalPartial
            )
            // `row.harvestMs` is the vendor session's last activity time, not
            // when Pulse successfully read that adapter. Using it as "last
            // read" made a healthy but idle collector look months stale, and
            // made a newly-read old session look like a failed adapter. Keep
            // the two clocks separate: this timestamp records the completed
            // collector read, while row.harvestMs remains session activity.
            let collectorReadAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            for item in health where !item.state.isIssue {
                let agent = item.id.surfaceID
                lastSuccessfulReadByAgent[agent] = max(
                    lastSuccessfulReadByAgent[agent] ?? 0,
                    collectorReadAtMs
                )
            }
            ticksSinceHarvest = 0
        case .skipped:
            // Cached rows are at most a couple of ticks old — keep them whole,
            // pending included, or Waiting would flicker off between harvests.
            acts = lastGoodHarvest
            ticksSinceHarvest = ticksSinceHarvest == Int.max ? 1 : ticksSinceHarvest + 1
        }

        let now = Date()
        lastScanAt = now
        probeStats.record(
            ProbeStats.Sample(at: now, harvested: harvestMs != nil, harvestMs: harvestMs)
        )

        let result = SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: procs,
                harvest: acts,
                attention: attention,
                activity: activityEvents,
                vendorWaits: vendorWaits
            ),
            previous: SnapshotBuilder.Previous(rows: cachedAll, waitingKeys: sessionLog.waitingKeys),
            context: SnapshotBuilder.Context(
                nowMs: Int64(now.timeIntervalSince1970 * 1000),
                terminal: TerminalFocus.Environment.current(
                    allowTTYAutomation: allowTerminalAutomation
                ),
                lang: lang,
                dismissedPendingKeys: sessionLog.suppressedKeys,
                showAllAgents: showAllAgents,
                privacyLimitedAgents: Set(
                    AgentID.allCases.filter {
                        $0.requiresAppDataOptIn && !isAppDataAllowed(for: $0)
                    }
                )
            )
        )

        for note in result.debugNotes { DebugLog.write(note) }
        for (oldKey, newKey) in result.remappedRowKeys {
            migrateRowIdentity(from: oldKey, to: newKey)
        }
        let previousRows = cachedAll
        setCachedAll(result.rows)
        if showAllAgents != result.showAllAgents { showAllAgents = result.showAllAgents }

        // Reconcile before delivery so a restart can distinguish an already
        // known wait from a newly crossed edge. Spans, waits, released soft
        // dismissals and the baseline move in one change; a scan that finds
        // the same world changes nothing and writes nothing (scan-quiet
        // applies to the disk too).
        recordScan(previous: previousRows, result: result, nowMs: Int64(now.timeIntervalSince1970 * 1000))

        var snap = result.snapshot
        snap.updatedAt = now

        // Notification policy lives here; the builder only reports the edges.
        // 22.0: quiet hours are macOS Focus's job now; Focus already filters
        // Pulse's banners, and a second clock inside Pulse disagreed with it.
        if notifyAuthorized == true, notifyOnIdle, result.wentIdle {
            PulseNotify.postIdle(title: "Pulse", body: tr(.idleNotify))
        }
        // Waiting edges stay available even during quiet hours (when enabled).
        // Skip the first scan so launch doesn't flood for already-waiting rows.
        let edgeNowMs = Int64(now.timeIntervalSince1970 * 1000)
        // 22.0: an edge that will get no banner says why on its event.
        if !result.newlyWaiting.isEmpty {
            var reasons: [String: String] = [:]
            for row in result.newlyWaiting {
                if !waitingNotifySeeded {
                    reasons[row.rowKey] = WaitingDelivery.SkipReason.atLaunch.rawValue
                } else if !notifyOnWaiting {
                    reasons[row.rowKey] = WaitingDelivery.SkipReason.notifyOff.rawValue
                } else if mutedAgents.contains(row.agent) {
                    reasons[row.rowKey] = WaitingDelivery.SkipReason.muted.rawValue
                } else if notifyAuthorized != true {
                    reasons[row.rowKey] = WaitingDelivery.SkipReason.notAuthorized.rawValue
                }
            }
            recordDelivery(reasons, nowMs: edgeNowMs)
        }
        if notifyOnWaiting, waitingNotifySeeded {
            let waitingEdges = result.newlyWaiting.filter { !mutedAgents.contains($0.agent) }
            // Owed banners come from the log, rebuilt from this scan's rows:
            // a wait that resolved has no open record, so it can neither
            // linger in a queue nor bring back a banner for a prompt that is
            // gone.
            let queuedRows = Self.queuedDeliveryRows(
                queued: sessionLog.queuedKeys, rows: result.rows, muted: mutedAgents
            )
            let deliveryRows = Self.waitingDeliveryRows(edges: waitingEdges, queued: queuedRows)
            if notifyAuthorized == true {
                postWaitingNotifications(deliveryRows)
            } else {
                // Permission resolution is asynchronous, and a previously
                // denied permission may be enabled later in System Settings.
                // Keep every edge owed until the callback arrives instead of
                // dropping the only interruption for a just-started session —
                // written once, not on every scan while it waits.
                updateLog { log in
                    for waiting in waitingEdges { log.markQueued(waiting.rowKey, nowMs: edgeNowMs) }
                }
            }
        }
        if !waitingNotifySeeded {
            waitingNotifySeeded = true
        }

        // 12.4 Surface: a scan that found the same world leaves `snapshot`
        // alone, so no surface observing the store is woken for it — except
        // when a relative-time label on screen is due to move.
        if PulseSnapshot.needsPublish(next: snap, current: snapshot) {
            snapshot = snap
        }
        if clearRefreshing, isRefreshing { isRefreshing = false }

        let previousActivity = activity
        activity = result.activity
        // Only re-arm when the cadence tier actually moved — a timer rebuilt on
        // every tick never fires at its own interval.
        if previousActivity != activity || timer == nil {
            rescheduleTimer()
        }

        // 22.0: one line when the lamp, the cadence or the counts move —
        // not five lines per tick. Scan-quiet applies to the log too.
        let applySignature = "rows=\(snap.rows.count)/\(snap.totalCount) glance=\(snap.glance) " +
            "activity=\(activity) wait=\(result.waitingKeys.count) " +
            "every=\(currentInterval.map { String(Int($0)) } ?? "parked")"
        if applySignature != lastApplyLogSignature {
            lastApplyLogSignature = applySignature
            DebugLog.write("apply #\(ticket) " + applySignature)
        }
    }

    /// Deliver one actionable notification per Waiting session. A previous
    /// implementation used `first(where:)`, so a scan that found Codex and
    /// Cursor approvals notified only whichever row happened to sort first.
}

// MARK: - 12.4 Surface: publish only what changed
//
// Observation (19.0), like `@Published` before it, announces every
// assignment, equal or not, and every view that read the property
// re-evaluates on each announcement. The scan path therefore writes a
// tracked property only when the value differs; `ScanQuietTests` holds it
// to that.

extension StatusStore {
    /// The merged rows every surface reads. Re-merged on every scan, so the
    /// write is guarded: an identical merge must not wake the tray.
    func setCachedAll(_ rows: [AgentRow]) {
        if rows != cachedAll { cachedAll = rows }
    }
}

extension PulseSnapshot {
    /// Equal in everything a surface draws — `updatedAt` aside.
    func sameContent(as other: PulseSnapshot) -> Bool {
        var mine = self
        mine.updatedAt = other.updatedAt
        return mine == other
    }

    /// Below a minute, durations are drawn in seconds (`DurationFormat`).
    static let secondsLabelWindowMs: Int64 = 60_000
    /// Minute labels need a redraw at most this often when nothing else moved.
    static let minuteLabelRefresh: TimeInterval = 60

    /// Whether `next` must replace `current` for the surfaces to stay true.
    ///
    /// Content changed → yes. Otherwise only the clock can make a drawn fact
    /// stale: a row whose wait or activity is younger than a minute shows a
    /// seconds count that moves every scan, and minute labels move once a
    /// minute. Nothing else about an unchanged world is worth a redraw.
    static func needsPublish(next: PulseSnapshot, current: PulseSnapshot) -> Bool {
        if current.updatedAt == .distantPast { return true }
        if !next.sameContent(as: current) { return true }
        let nowMs = Int64(next.updatedAt.timeIntervalSince1970 * 1000)
        let secondsOnScreen = next.rows.contains { row in
            let newest = max(row.waitSinceMs, row.activityChangedMs, row.harvestMs)
            return newest > 0 && nowMs - newest < secondsLabelWindowMs
        }
        if secondsOnScreen { return true }
        return next.updatedAt.timeIntervalSince(current.updatedAt) >= minuteLabelRefresh
    }
}
