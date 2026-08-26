import Foundation
import AppKit

/// 4.0-γ file split — The scan engine — start, refresh, harvest application, activity light path.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    func start() {
        DebugLog.write("start begin \(PulseVersion.fingerprint)")
        let recovery = LaunchRecovery.begin(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        launchRecovery = recovery.state
        recoveryExitKind = recovery.kind
        // Update replacement is an intentional exit — never show the unclean banner.
        recoveredAfterCrash = recovery.wasUnclean
        if recoveredAfterCrash {
            DebugLog.write("launch recovery unclean kind=\(recovery.kind.rawValue)")
        }
        // Restore only Pulse-owned attention state. Agent-owned hooks remain
        // the source of truth for the current row; the ledger supplies the
        // cross-launch baseline, snooze timers and delivery dedupe.
        attentionLedger = AttentionLedger.load()
        snoozedUntil = attentionLedger.snoozedUntil
        knownWaitingKeys = attentionLedger.activeKeys
        waitingNotifySeeded = attentionLedger.baselineEstablished
        dismissedPendingKeys = Self.loadDismissedPendingKeys()
        respondLocalEnabled = RespondSpool.localHasSecret()
        restoreAttentionHistory()
        HooksSupport.seedAssets()
        hooksStatus = HooksSupport.probeStatus()
        refreshPulseHookLauncherStatus()
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
                if !self.powerMonitor.state.parked { self.refresh(reason: "wake") }
            }
        }
        UpdateCheck.shared.startIfEnabled(store: self)
        installTerminationSignalMarker()
        DebugLog.write("start armed auto=\(autoProbe)")
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
        let measureEffects = measureWorkspaceEffect
        // Only directories a scan already confirmed. `cwdBestEffort` paths are
        // excluded for the same reason 2.2 stopped offering them to Focus: a
        // path that decoded wrong but happens to exist would report somebody
        // else's repository as this agent's work.
        let knownWorkspaces = measureEffects
            ? Array(Set(cachedAll.filter { !$0.isRemote && !$0.cwdBestEffort }.map(\.cwd)))
            : []
        // Captured by value: `WorkspaceEffectStore` is a struct, so the scan
        // queue works on its own copy and hands the advanced one back on
        // main. Mutating a captured `var` from a concurrently-executing
        // closure would be a race the type system is right to refuse.
        let priorEffectStore = workspaceEffects

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
                outcome = result.unreliable
                    ? .failed(result.health, complete, intentionalPartial || scopedHarvest)
                    : .fresh(result.rows, result.health, complete, intentionalPartial || scopedHarvest)
            }

            // What has landed on disk. Off the main thread with the other
            // file work, bounded per root and capped per tick — a status lamp
            // that blocks on somebody's monorepo is the energy-hog failure the
            // cadence design exists to prevent.
            var effectStore = priorEffectStore
            let effects: [String: WorkspaceEffect.Measurement] = knownWorkspaces.isEmpty
                ? [:]
                : effectStore.refresh(
                    directories: knownWorkspaces,
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                )
            let advancedEffectStore = effectStore
            let attention = AttentionReader.load()
            // Respond (scene AR): read the inbound full-request spool off the
            // main thread, alongside the other file sources. Cleanup here too
            // — both are bounded (≤16 hosts × 32 files).
            let scanNowMs = Int64(Date().timeIntervalSince1970 * 1000)
            RespondSpool.cleanup(nowMs: scanNowMs)
            // The flat trees used to be swept only when the hook wrote a
            // request, so an install that turned local answering back off
            // kept its leftovers for ever.
            RespondSpool.cleanupOutbound(nowMs: scanNowMs)
            // Both trees. `requests.d/<host>/` is what a partner Mac's sync
            // tool delivered; `requests/` is what an agent on *this* Mac
            // raised and is still holding for. Until 2.4 only the first was
            // read, which is why Respond did nothing on a single-Mac install.
            let respondInbound = RespondSpool.readInboundRequests(nowMs: scanNowMs)
                + RespondSpool.readLocalRequests(
                    nowMs: scanNowMs,
                    host: PulseHookReceiver.respondHost()
                )
            // The rest of the fleet, not just its doorbell: every other
            // machine's snapshot, bounded, and absent until the user's own
            // sync tooling puts something in fleet.d/.
            let fleetReports = FleetSnapshot.readReports(
                selfHost: PulseHookReceiver.respondHost(), nowMs: scanNowMs
            )
            // 2.9: push-fresh activity events. Read here so a full rebuild
            // carries them; the watcher's light path keeps them second-fresh
            // between scans.
            let activityEvents = ActivitySpool.readEvents(nowMs: scanNowMs)
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
            DispatchQueue.main.async { [completedHarvestMs, completedCursor] in
                guard let self else { return }
                self.harvestScanCursor = completedCursor
                self.workspaceEffects = advancedEffectStore
                if measureEffects {
                    self.workspaceEffectsByDirectory = effects
                } else {
                    // Switched off: forget what was measured rather than let
                    // a row keep quoting a number nobody is refreshing.
                    self.workspaceEffectsByDirectory = [:]
                }
                switch outcome {
                case .fresh(_, let health, _, _), .failed(let health, _, _):
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
                    respondInbound: respondInbound,
                    fleet: fleetReports,
                    activityEvents: activityEvents
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
        /// Ran and failed; cached rows may be stale.
        case failed([ActivityHarvest.CollectorHealth], Bool, Bool)
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
        collectorScanIncomplete = !complete && !intentionalPartial
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
            DispatchQueue.main.async {
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
            for index in rows.indices where !rows[index].isRemote && !rows[index].sessionID.isEmpty {
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
        _ = patch(&cachedAll)
        var next = snapshot
        if patch(&next.rows) {
            snapshot = next
        }
    }

    fileprivate func applyScan(
        procs: [ProcessProbe.Hit],
        harvest: HarvestOutcome,
        processSignature: String,
        attention: [AttentionReader.Entry],
        ticket: UInt64,
        harvestMs: Int? = nil,
        clearRefreshing: Bool = false,
        reason: String = "",
        respondInbound: [RespondSpool.InboundRequest] = [],
        fleet: [FleetSnapshot.Report] = [],
        activityEvents: [ActivitySpool.Event] = []
    ) {
        defer { finishScanFlight() }

        if ticket < lastAppliedTicket {
            DebugLog.write("apply skip stale #\(ticket) lastApplied=\(lastAppliedTicket)")
            if clearRefreshing { isRefreshing = false }
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
        case .failed(let health, let complete, let intentionalPartial):
            recordCollectorHealth(
                health,
                complete: complete,
                intentionalPartial: intentionalPartial
            )
            // 0.95: keep last-good pending intact. Stripping pending on failure
            // manufactured a false clear then a re-raise on the next skip.
            acts = lastGoodHarvest
            ticksSinceHarvest = 0
            DebugLog.write("harvest unreliable → reuse \(acts.count) cached rows (pending kept)")
        }
        let harvestUnreliable: Bool = {
            switch harvest {
            case .failed(_, _, let intentionalPartial):
                return !intentionalPartial
            case .fresh(_, _, let complete, let intentionalPartial):
                // A timed-out stream may contain useful rows, but it is not a
                // complete baseline. Treat it as unreliable for attention
                // edge reconciliation so an adapter that was never reached
                // cannot silently resolve a real Waiting event.
                return !complete && !intentionalPartial
            case .skipped:
                return false
            }
        }()

        let now = Date()
        probeStats.record(
            ProbeStats.Sample(at: now, harvested: harvestMs != nil, harvestMs: harvestMs)
        )

        // A snooze that has run out must announce itself again, so forget the
        // row was ever waiting: the builder's "newly waiting" edge is a set
        // difference against these keys, and a wait that stayed in the set for
        // the whole snooze would come back silently.
        var waitingKeysForEdges = knownWaitingKeys
        for (key, deadline) in snoozedUntil where deadline <= now {
            snoozedUntil.removeValue(forKey: key)
            attentionLedger.unsnooze(rowKey: key)
            waitingKeysForEdges.remove(key)
            DebugLog.write("snooze expired \(DebugLog.key(key))")
        }

        let result = SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: procs,
                harvest: acts,
                harvestUnreliable: harvestUnreliable,
                attention: attention,
                fleet: fleet,
                activity: activityEvents
            ),
            previous: SnapshotBuilder.Previous(rows: cachedAll, waitingKeys: waitingKeysForEdges),
            context: SnapshotBuilder.Context(
                nowMs: Int64(now.timeIntervalSince1970 * 1000),
                terminal: TerminalFocus.Environment.current(
                    allowTTYAutomation: allowTerminalAutomation
                ),
                lang: lang,
                dismissedPendingKeys: dismissedPendingKeys,
                showAllAgents: showAllAgents,
                snoozedUntilMs: snoozedUntil.mapValues { Int64($0.timeIntervalSince1970 * 1000) },
                stalledSeconds: Double(stallMinutes) * 60,
                privacyLimitedAgents: Set(
                    AgentID.allCases.filter {
                        $0.requiresAppDataOptIn && !isAppDataAllowed(for: $0)
                    }
                ),
                workspaceEffects: workspaceEffectsByDirectory
            )
        )

        for note in result.debugNotes { DebugLog.write(note) }
        for (oldKey, newKey) in result.remappedRowKeys {
            migrateRowIdentity(from: oldKey, to: newKey)
        }
        // Write only when the set actually moved. A non-empty `clearedPendingKeys`
        // is not evidence of a change — it lists what the builder saw clear,
        // most of which the store never held — and taking it as one rewrote
        // `dismissed-pending.json` every two to five seconds for as long as any
        // session was running (U-5). `subtract` can only remove, so the count
        // settles the question.
        let dismissedCountBefore = dismissedPendingKeys.count
        dismissedPendingKeys.subtract(result.clearedPendingKeys)
        if dismissedPendingKeys.count != dismissedCountBefore {
            persistDismissedPendingKeys()
        }
        cachedAll = result.rows
        // Before any notification decision, not after the scan that made it.
        // The banner's Deny is chosen from these matches, and a permission
        // request only ever gets one banner — deciding from the previous
        // scan's matches meant a brand-new request never carried the action
        // it exists for (E-1). Matched against every row, not the visible
        // window, or a request on a row that scrolled out of the tray would
        // silently lose its controls (E-2).
        refreshRespondInbound(respondInbound, rows: result.rows)
        showAllAgents = result.showAllAgents
        knownWaitingKeys = result.waitingKeys
        // A wait that resolved on its own takes its snooze with it, or the next
        // wait on the same row would start life already silenced.
        snoozedUntil = snoozedUntil.filter { result.waitingKeys.contains($0.key) }

        // Reconcile before delivery so a restart can distinguish an already
        // known wait from a newly crossed edge. An unreliable first scan is
        // not a trustworthy baseline: seeding it would suppress the first
        // real notification after the collector recovers. The ledger is
        // written atomically; a crash during this scan leaves the previous
        // complete state intact.
        let attentionBaselineValid = !harvestUnreliable
            || result.rows.contains(where: \.waiting)
            || !attention.isEmpty
        if attentionBaselineValid {
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            attentionLedger.reconcile(
                activeRows: result.rows.filter(\.waiting),
                nowMs: nowMs
            )
            // A queued edge can outlive both the scan and the process. Rebuild
            // the in-memory delivery queue from the durable ledger before any
            // notification decision so a relaunch never loses it.
            for row in result.rows where row.waiting && attentionLedger.queuedKeys.contains(row.rowKey) {
                pendingWaitingNotifications[row.rowKey] = row
            }
            attentionLedger.markBaseline()
            attentionLedger.save()
        } else {
            DebugLog.write("attention ledger baseline deferred: harvest unreliable and no wait evidence")
        }

        var snap = result.snapshot
        snap.updatedAt = now

        // A healthy scan after launch means recovery succeeded. Keep the banner
        // through the first healthy scan so opening the tray once still shows
        // it; clear on the subsequent healthy scan (or explicit dismiss).
        if recoveredAfterCrash, !harvestUnreliable {
            if recoveryNoticeSurvivedFirstHealthyScan {
                dismissRecoveryNotice()
            } else {
                recoveryNoticeSurvivedFirstHealthyScan = true
            }
        }

        // Notification policy lives here; the builder only reports the edges.
        let quiet = isInQuietHours()
        if notifyAuthorized == true, notifyOnIdle, !quiet, result.wentIdle {
            PulseNotify.postIdle(title: "Pulse", body: tr(.idleNotify))
        }
        // Waiting edges stay available even during quiet hours (when enabled).
        // Skip the first scan so launch doesn't flood for already-waiting rows.
        if notifyOnWaiting, waitingNotifySeeded {
            let waitingEdges = result.newlyWaiting.filter { !mutedAgents.contains($0.agent) }
            let queuedRows = pendingWaitingNotifications.values.filter { row in
                row.waiting && !mutedAgents.contains(row.agent)
            }
            let deliveryRows = Self.waitingDeliveryRows(edges: waitingEdges, queued: queuedRows)
            if notifyAuthorized == true {
                postWaitingNotifications(deliveryRows)
            } else if notifyAuthorized != true {
                // Permission resolution is asynchronous, and a previously
                // denied permission may be enabled later in System Settings.
                // Preserve every edge until the callback arrives instead of
                // dropping the only interruption for a just-started session.
                for waiting in waitingEdges {
                    pendingWaitingNotifications[waiting.rowKey] = waiting
                    attentionLedger.markQueued(
                        rowKey: waiting.rowKey,
                        nowMs: Int64(now.timeIntervalSince1970 * 1000)
                    )
                }
                attentionLedger.save()
            }
        }
        if !waitingNotifySeeded, attentionBaselineValid {
            waitingNotifySeeded = true
        }

        recordResolvedWaits(result.resolvedWaits, at: now)

        // This Mac's own snapshot, for the machines that read what our sync
        // tool carries. Opt-in, on its own cadence, and written off the main
        // thread — the tray never waits on a disk.
        if broadcastFleet {
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            if nowMs - lastFleetWriteMs >= FleetSnapshot.writeIntervalMs {
                lastFleetWriteMs = nowMs
                let snapshot = FleetSnapshot.build(
                    host: PulseHookReceiver.respondHost(),
                    rows: result.rows,
                    sentAtMs: nowMs
                )
                scanQueue.async { FleetSnapshot.write(snapshot) }
            }
        }

        snapshot = snap
        if clearRefreshing { isRefreshing = false }
        if reason == "trayOpen" {
            applyPendingLookContinuity()
        }
        if reason == "trayOpen" || reason == "attentionSample" {
            applyPendingSampleReveal()
        }

        let previousActivity = activity
        activity = result.activity
        // Only re-arm when the cadence tier actually moved — a timer rebuilt on
        // every tick never fires at its own interval.
        if previousActivity != activity || timer == nil {
            rescheduleTimer()
        }

        DebugLog.write(
            "apply #\(ticket) rows=\(snap.rows.count)/\(snap.totalCount) glance=\(snap.glance) " +
            "activity=\(activity) wait=\(result.waitingKeys.count) " +
            "every=\(currentInterval.map { String(Int($0)) } ?? "parked")"
        )
    }

    /// Deliver one actionable notification per Waiting session. A previous
    /// implementation used `first(where:)`, so a scan that found Codex and
    /// Cursor approvals notified only whichever row happened to sort first.
}
