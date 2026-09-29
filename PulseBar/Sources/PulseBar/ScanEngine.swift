import Foundation
import AppKit

/// The scan engine (23.0): cadence, the background scan, and everything it
/// remembers between passes. Not observed — no view reads it.
///
/// It owns the probe timer (`ProbeSchedule`), runs `ProcessProbe`,
/// `ActivityHarvest`, `AttentionReader`, `ClaudeAgentsProbe` and
/// `ActivitySpool` off the main thread, merges partial harvests, keeps the
/// collector health, the harvest supervisor and the probe counters, and
/// calls the pure `SnapshotBuilder`. What a scan found is handed to the
/// model (`StatusStore.land`), which assigns an observed property only when
/// its value changed. The engine holds no UI state and writes none.
@MainActor
final class ScanEngine {
    /// The model this engine feeds. Weak: the model owns the engine.
    weak var model: StatusStore?

    /// Tests exercising store behaviour must not start a real background scan.
    ///
    /// A scan is not read-only: it writes attention files and, once
    /// `start()` has loaded it, the session log — so an unguarded `refresh(reason:)`
    /// inside a unit test would touch the developer's own files. Same shape
    /// as `AttentionIO.pathOverride` and `HooksInstaller.homeOverride`.
    static var suppressBackgroundScansForTesting = false

    let powerMonitor = PowerMonitor()
    let attentionWatcher = AttentionWatcher()
    let scanQueue = DispatchQueue(label: "com.pulse.scan", qos: .userInitiated)

    // MARK: Cadence

    private var timer: Timer?
    /// Tray panel is on screen — worth probing faster while the user reads it.
    private(set) var trayOpen = false
    private(set) var activity: ProbeSchedule.Activity = .empty
    private(set) var currentInterval: TimeInterval?
    /// The display is asleep or the screen is locked — nothing is being read.
    var powerParked: Bool { powerMonitor.state.parked }
    /// When the timer parked, for the parked-duration counter.
    private var parkedSince: Date?
    /// Rolling scan counters, so the energy claim can be checked, not believed.
    private(set) var probeStats = ProbeStats()
    /// When the last scan was applied — advances on every scan, published or
    /// not, unlike `snapshot.updatedAt` which moves only when the snapshot
    /// changes. Read by the self-check; never drives a view.
    private(set) var lastScanAt: Date?
    /// The cadence that scheduled the last applied scan. Opening the tray
    /// shortens `currentInterval` at once, but the scan already on screen
    /// was due by the old one — the header judges its age by this.
    private(set) var lastScanInterval: TimeInterval?
    /// The newest attention line per agent, from the text the last scan read
    /// — Health's "has this hook fired". Cached here so a Diagnostics
    /// redraw never reads (and locks) the attention file.
    private(set) var latestHookEventMs: [AgentID: Int64] = [:]

    // MARK: Harvest bookkeeping

    private var lastGoodHarvest: [ActivityHarvest.Row] = []
    /// Result of the latest attempted adapter scan, including adapters that
    /// ran successfully but had no recent local session. This is deliberately
    /// separate from row evidence: zero rows is a useful result, not silence.
    var collectorHealthByAgent: [AgentID: ActivityHarvest.CollectorHealth] = [:]
    /// Latest successful collector read by Agent, retained even after its
    /// session row ages out so Health can distinguish "not running" from
    /// "collector has never produced evidence".
    var lastSuccessfulReadByAgent: [AgentID: Int64] = [:]
    /// 23.0: the processes the last applied scan saw, by (surface) agent,
    /// stamped with when each began. Health reads them — the row no longer
    /// carries process evidence, start or count.
    var processesByAgent: [AgentID: ProcessFacts] = [:]
    /// Per-Agent retry/backoff/circuit policy. A bad store must not consume the
    /// next scan budget for every other adapter.
    private(set) var harvestSupervisor = HarvestSupervisor()
    /// Where the next native harvest should start.
    ///
    /// The collector walks its adapters in a fixed order, so before 0.98 a
    /// global budget cutoff always fell in the same place and the same tail
    /// adapters were reported `unscanned` on every refresh. The scan returns
    /// the first adapter it could not reach; the next one begins there.
    private var harvestScanCursor = 0
    /// Live-process fingerprint; a change forces a harvest even off-cadence.
    private var lastProcessSignature = ""
    private var ticksSinceHarvest = Int.max
    private var lastApplyLogSignature = ""

    // MARK: Flight

    private var scanTicket: UInt64 = 0
    private var lastAppliedTicket: UInt64 = 0
    private var scanInFlight = false

    /// A refresh that arrived while one was already in flight.
    ///
    /// Only the reason used to survive the wait, so a scoped rescan replayed
    /// as a full scan — and a full scan is precisely what a scoped rescan is
    /// not. The scope exists to force an agent the supervisor would otherwise
    /// defer, so toggling that agent's data source during an in-flight scan
    /// could leave it unread until its backoff expired: "I enabled it and
    /// nothing happened."
    struct PendingRefresh {
        var reason: String
        /// nil means a full scan, which absorbs any scoped request merged in.
        var agentFilter: Set<AgentID>?

        mutating func absorb(reason: String, agentFilter: Set<AgentID>?) {
            self.reason = reason
            guard let agentFilter, let existing = self.agentFilter else {
                self.agentFilter = nil
                return
            }
            self.agentFilter = existing.union(agentFilter)
        }
    }

    private var pendingRefresh: PendingRefresh?

    /// What the background scan managed to get from the native collector.
    enum HarvestOutcome {
        /// Ran and produced rows (possibly partial after a timeout).
        case fresh([ActivityHarvest.Row], [ActivityHarvest.CollectorHealth], Bool, Bool)
        /// Deliberately not run this tick — cached rows are still current.
        case skipped
    }

    // MARK: - Lifecycle

    /// Arm the scan: the first refresh, the timer, the attention watcher and
    /// the power monitor. `StatusStore.start()` calls it once settings and
    /// the session log are loaded.
    func start() {
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
                    if let model = self.model { UpdateCheck.shared.startIfEnabled(store: model) }
                }
            }
        }
    }

    func stop() {
        attentionWatcher.stop()
        timer?.invalidate()
        timer = nil
    }

    /// The tray panel came on screen or left it — probe faster while the
    /// person is reading.
    func setTrayOpen(_ open: Bool) {
        trayOpen = open
        rescheduleTimer()
    }

    // MARK: - Cadence

    /// Current cadence, for Health ("probing every 5s").
    func probeIntervalDescription(lang: ResolvedLanguage) -> String {
        guard let interval = currentInterval else { return L10n.t(.probeParked, lang) }
        return String(format: L10n.t(.probeEvery, lang), Int(interval.rounded()))
    }

    /// Close an open parked span.
    private func settleParked() {
        guard let since = parkedSince else { return }
        probeStats.addParked(Date().timeIntervalSince(since))
        parkedSince = nil
    }

    func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        let interval = ProbeSchedule.interval(
            activity: activity,
            power: powerMonitor.state,
            trayOpen: trayOpen
        )
        currentInterval = interval
        guard let interval else {
            if parkedSince == nil { parkedSince = Date() }
            DebugLog.write("probe parked (display asleep / locked)")
            return
        }
        settleParked()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Bind before the Task: the timer block is @Sendable, and referencing
            // the captured `weak self` var from inside a Task is not allowed.
            guard let engine = self else { return }
            Task { @MainActor in
                engine.refresh(reason: "timer")
                // One date comparison unless a day has passed since the last
                // answer — how a Mac that never sleeps still re-checks.
                if let model = engine.model { UpdateCheck.shared.startIfEnabled(store: model) }
            }
        }
        // Let the system coalesce wakeups — meaningful battery win for a
        // background poller that does not need millisecond precision.
        t.tolerance = interval * 0.2
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: - The scan

    func refresh(reason: String, agentFilter: Set<AgentID>? = nil) {
        if Self.suppressBackgroundScansForTesting { return }
        guard let model else { return }
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
        DebugLog.write("refresh enqueue #\(ticket) reason=\(reason)")

        // Native harvest walks bounded vendor roots; probe is one `ps` call.
        // Only pay for the richer scan when something plausibly changed.
        let forceHarvest = reason != "timer"
        let priorSignature = lastProcessSignature
        let ticks = ticksSinceHarvest
        let everyN = ProbeSchedule.harvestEveryNTicks(activity: activity, trayOpen: trayOpen)
        let readAppData = model.settings.readProtectedAppData
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
        let claudeHooked = model.hooksStatus == .installedClaude || model.hooksStatus == .installedBoth

        scanQueue.async { [weak self] in
            let t0 = Date()
            let procs = ProcessProbe.scan(allowAppData: readAppData)
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
                    allowAppData: readAppData,
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

            let scanNowMs = Int64(Date().timeIntervalSince1970 * 1000)
            // One read of the attention file serves the rows and Health.
            let attentionText = AttentionIO.readText()
            let attention = AttentionReader.parse(attentionText, nowMs: scanNowMs)
            let hookEventTimes = AttentionIO.latestEventTimes(in: attentionText)
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
            // Land results on the engine that started the flight, not the
            // AppServices singleton: a hardwired singleton sent every other
            // instance's results to the wrong store and left its
            // `scanInFlight` stuck forever.
            DispatchQueue.main.async { [weak self, completedHarvestMs, completedCursor] in
                guard let self else { return }
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
                    reason: reason,
                    activityEvents: activityEvents,
                    vendorWaits: vendorWaits,
                    hookEventTimes: hookEventTimes
                )
            }
        }
    }

    private func finishScanFlight() {
        scanInFlight = false
        if let pending = pendingRefresh {
            pendingRefresh = nil
            refresh(reason: pending.reason, agentFilter: pending.agentFilter)
        }
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

    /// Record a collector health report and hand the model whether the scan
    /// was incomplete.
    func recordCollectorHealth(
        _ health: [ActivityHarvest.CollectorHealth],
        complete: Bool = true,
        intentionalPartial: Bool = false
    ) {
        // A partial stream must not erase the last known result for adapters
        // that have not been reached yet. Only a complete health report resets
        // the map to the explicit unscanned baseline before applying results.
        let baseline = Dictionary(
            uniqueKeysWithValues: AgentID.allCases.map {
                ($0, ActivityHarvest.CollectorHealth.unscanned($0))
            }
        )
        var next = complete && !health.isEmpty
            ? baseline
            : (collectorHealthByAgent.isEmpty ? baseline : collectorHealthByAgent)
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
        model?.landCollectorScanIncomplete(!complete && !intentionalPartial)
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
                self?.model?.landActivityEvents(events, nowMs: nowMs)
            }
        }
    }

    // MARK: - Applying a finished scan

    func applyScan(
        procs: [ProcessProbe.Hit],
        harvest: HarvestOutcome,
        processSignature: String,
        attention: [AttentionReader.Entry],
        ticket: UInt64,
        harvestMs: Int? = nil,
        reason: String = "",
        activityEvents: [ActivitySpool.Event] = [],
        vendorWaits: [ClaudeAgentsProbe.Wait] = [],
        hookEventTimes: [AgentID: Int64]? = nil
    ) {
        defer { finishScanFlight() }
        guard let model else { return }

        if ticket < lastAppliedTicket {
            DebugLog.write("apply skip stale #\(ticket) lastApplied=\(lastAppliedTicket)")
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
            // when Pulse successfully read that adapter. Keep the two clocks
            // separate: this timestamp records the completed collector read,
            // while row.harvestMs remains session activity.
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
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        lastScanAt = now
        lastScanInterval = currentInterval
        if let hookEventTimes { latestHookEventMs = hookEventTimes }
        probeStats.record(
            ProbeStats.Sample(at: now, harvested: harvestMs != nil, harvestMs: harvestMs)
        )

        processesByAgent = ProcessFacts.byAgent(procs, nowMs: nowMs)
        let settings = model.settings
        let result = SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: procs,
                harvest: acts,
                attention: attention,
                activity: activityEvents,
                vendorWaits: vendorWaits
            ),
            previous: SnapshotBuilder.Previous(
                rows: model.cachedAll,
                waitingKeys: model.sessionLog.waitingKeys,
                waitingSince: model.sessionLog.waitingSince
            ),
            context: SnapshotBuilder.Context(
                nowMs: nowMs,
                terminal: TerminalFocus.Environment.current(
                    allowTTYAutomation: settings.allowTerminalAutomation
                ),
                lang: model.lang,
                dismissedPendingKeys: model.sessionLog.suppressedKeys,
                showAllAgents: model.showAllAgents
            )
        )

        for note in result.debugNotes { DebugLog.write(note) }
        var snap = result.snapshot
        snap.updatedAt = now
        model.land(result, snapshot: snap, nowMs: nowMs)

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
}

/// What Health says about an agent's processes: how it was matched, when
/// the oldest began, how many there are. Diagnostic only — never a row fact.
struct ProcessFacts: Equatable {
    var evidence: ProcessEvidence
    var startedMs: Int64
    var count: Int

    static func byAgent(_ hits: [ProcessProbe.Hit], nowMs: Int64) -> [AgentID: ProcessFacts] {
        var out: [AgentID: ProcessFacts] = [:]
        for hit in hits {
            let agent = hit.id.surfaceID
            let started = hit.elapsedSeconds > 0 ? nowMs - Int64(hit.elapsedSeconds * 1000) : 0
            if var existing = out[agent] {
                existing.count = max(existing.count, hit.count)
                if started > 0, existing.startedMs == 0 || started < existing.startedMs { existing.startedMs = started }
                out[agent] = existing
            } else {
                out[agent] = ProcessFacts(evidence: hit.evidence, startedMs: started, count: hit.count)
            }
        }
        return out
    }
}
