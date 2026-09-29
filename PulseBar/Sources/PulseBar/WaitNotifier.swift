import Foundation
import AppKit

/// The "needs you" banner (23.0): what to post, when, and what became of it.
/// Not observed — no view reads it.
///
/// The builder reports Waiting edges; `WaitingDelivery` decides which rows get
/// a banner; this class carries the plan out through `PulseNotify`, rate
/// limits it, keeps each owed banner owed across a restart, records every
/// outcome (and every click) on the wait's own `SessionLog` record, and
/// sends a banner click back to the row that raised it.
@MainActor
final class WaitNotifier {
    /// The model this notifier reads settings and rows from. Weak: the model
    /// owns the notifier.
    weak var model: StatusStore?

    /// One interruption per short window keeps a burst of parallel approvals
    /// useful without turning Notification Center into a stream of duplicates.
    static let minimumIntervalMs: Int64 = 3_000

    /// First apply seeds waiting keys without firing edge notifications.
    var seeded = false
    private var deliveryTask: Task<Void, Never>?
    /// Notification Center accepts requests asynchronously. Keep the event
    /// in-flight until its callback arrives so a fast follow-up scan cannot
    /// post a duplicate or mark a failed request as delivered.
    private(set) var inFlight: Set<String> = []

    // MARK: - Lifecycle

    /// Register the banner's button and learn whether macOS lets Pulse
    /// notify. Never asks — asking is an explicit Settings action.
    func start() {
        guard let model else { return }
        PulseNotify.registerCategories(lang: model.lang)
        PulseNotify.configure { [weak self] granted in
            Task { @MainActor in
                self?.model?.landNotifyAuthorized(granted)
                self?.deliverPendingIfPossible()
                DebugLog.write("notify authorization granted=\(String(describing: granted))")
            }
        }
    }

    /// Banner button titles are baked into the registered category, so they
    /// go stale on a language switch unless re-registered.
    func languageChanged(_ lang: ResolvedLanguage) {
        PulseNotify.registerCategories(lang: lang)
    }

    // MARK: - A scan landed

    /// Notification policy for one scan; the builder only reports the edges.
    /// Called after the session log has reconciled the scan, so a restart can
    /// distinguish an already known wait from a newly crossed edge.
    func scanLanded(_ result: SnapshotBuilder.Result, nowMs: Int64) {
        guard let model else { return }
        let settings = model.settings
        let authorized = model.notifyAuthorized
        // 22.0: an edge that will get no banner says why on its event.
        if !result.newlyWaiting.isEmpty {
            var reasons: [String: String] = [:]
            for row in result.newlyWaiting {
                if !seeded {
                    reasons[row.rowKey] = WaitingDelivery.SkipReason.atLaunch.rawValue
                } else if !settings.notifyOnWaiting {
                    reasons[row.rowKey] = WaitingDelivery.SkipReason.notifyOff.rawValue
                } else if settings.mutedAgents.contains(row.agent) {
                    reasons[row.rowKey] = WaitingDelivery.SkipReason.muted.rawValue
                } else if authorized != true {
                    reasons[row.rowKey] = WaitingDelivery.SkipReason.notAuthorized.rawValue
                }
            }
            recordDelivery(reasons, nowMs: nowMs)
        }
        // Skip the first scan so launch doesn't flood for already-waiting rows.
        if settings.notifyOnWaiting, seeded {
            let edges = result.newlyWaiting.filter { !settings.mutedAgents.contains($0.agent) }
            // Owed banners come from the log, rebuilt from this scan's rows:
            // a wait that resolved has no open record, so it can neither
            // linger in a queue nor bring back a banner for a prompt that is
            // gone.
            let queued = Self.queuedDeliveryRows(
                queued: model.sessionLog.queuedKeys, rows: result.rows, muted: settings.mutedAgents
            )
            let rows = Self.waitingDeliveryRows(edges: edges, queued: queued)
            if authorized == true {
                post(rows)
            } else {
                // Permission resolution is asynchronous, and a previously
                // denied permission may be enabled later in System Settings.
                // Keep every edge owed until the callback arrives instead of
                // dropping the only interruption for a just-started session —
                // written once, not on every scan while it waits.
                model.updateLog { log in
                    for waiting in edges { log.markQueued(waiting.rowKey, nowMs: nowMs) }
                }
            }
        }
        if !seeded { seeded = true }
    }

    // MARK: - Posting

    /// Deliver one actionable notification per Waiting session. A previous
    /// implementation used `first(where:)`, so a scan that found Codex and
    /// Cursor approvals notified only whichever row happened to sort first.
    func post(_ rows: [AgentRow]) {
        guard let model, model.notifyAuthorized == true, model.settings.notifyOnWaiting else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let current = model.sessionLog
        // 12.3 δ: the decision is `WaitingDelivery`; this method carries it out.
        let delivery = WaitingDelivery(
            muted: model.settings.mutedAgents,
            acknowledged: current.dismissedKeys,
            inFlight: inFlight,
            canDeliverNow: current.canDeliver(nowMs: nowMs, minimumIntervalMs: Self.minimumIntervalMs),
            msSinceLastNotification: nowMs - current.lastNotificationMs,
            minimumIntervalMs: Self.minimumIntervalMs
        )
        // 22.0: the rows this plan leaves out say why, on their own event.
        recordDelivery(delivery.skipReasons(rows).mapValues(\.rawValue), nowMs: nowMs)
        let candidates: [AgentRow]
        let asSummary: Bool
        switch delivery.plan(rows) {
        case .nothing:
            return
        case .hold(let held, let retryAfterMs):
            // Owed, on the wait's own record — written only if that is news.
            model.updateLog { log in
                for waiting in held { log.markQueued(waiting.rowKey, nowMs: nowMs) }
            }
            scheduleDelivery(afterMs: retryAfterMs)
            return
        case .post(let ready, let summary):
            candidates = ready
            asSummary = summary
        }

        let deliveryKeys = candidates.map(\.rowKey)
        for waiting in candidates { inFlight.insert(waiting.rowKey) }
        // Persist before asking Notification Center to accept the request. A
        // crash between those two operations leaves a durable queued wait,
        // which the next launch can deliver exactly once.
        model.updateLog(immediately: true) { log in
            for waiting in candidates { log.markQueued(waiting.rowKey, nowMs: nowMs) }
        }

        if asSummary {
            let eventIDs = candidates.compactMap { model.sessionLog.openWait($0.rowKey)?.id }
            let title = String(format: model.tr(.waitingSummaryTitle), candidates.count)
            let body = candidates.prefix(3).map(notificationBody).joined(separator: " · ")
                + (candidates.count > 3 ? " …" : "")
            let first = candidates[0]
            PulseNotify.postWaitingSummary(
                title: title,
                body: body,
                agent: first.agent.rawValue,
                session: first.sessionID,
                rowKeys: candidates.map(\.rowKey),
                eventIDs: eventIDs,
                completion: { [weak self] success in
                    self?.finishDelivery(keys: deliveryKeys, rows: candidates, success: success)
                }
            )
        } else {
            for waiting in candidates {
                PulseNotify.postWaiting(
                    title: notificationTitle(waiting),
                    body: notificationBody(waiting),
                    agent: waiting.agent.rawValue,
                    session: waiting.sessionID,
                    rowKey: waiting.rowKey,
                    eventID: model.sessionLog.openWait(waiting.rowKey)?.id ?? "",
                    completion: { [weak self] success in
                        // Each individual request owns one wait; commit that
                        // wait independently so one rejected request never
                        // hides the other accepted Waiting notifications.
                        self?.finishDelivery(keys: [waiting.rowKey], rows: [waiting], success: success)
                    }
                )
            }
        }
    }

    /// Commit or requeue the durable event only after Notification Center has
    /// reported whether the request was accepted. This closes the rare but
    /// important gap where an app reinstall, identity transition, or system
    /// service error rejects an otherwise valid request.
    private func finishDelivery(keys: [String], rows: [AgentRow], success: Bool) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for key in keys { inFlight.remove(key) }
        // 21.0: a banner Notification Center refused is said in the tray,
        // not only in debug.log; the next accepted one clears it.
        model?.landWaitingBannerFailed(!success)
        let outcome = success
            ? (rows.count > WaitingDelivery.summaryAbove ? "summary" : "posted")
            : WaitingDelivery.SkipReason.rejected.rawValue
        // One change: the outcome, and either the banner shown or still owed.
        // A wait that resolved meanwhile has no open record and is left alone.
        // 22.0: the banner carries the system sound the person chose in
        // System Settings → Notifications; Pulse no longer plays its own.
        model?.updateLog(immediately: true) { log in
            for row in rows {
                log.markDelivery(row.rowKey, outcome: outcome, nowMs: nowMs)
                if success {
                    log.markNotified(row.rowKey, nowMs: nowMs)
                } else {
                    log.markQueued(row.rowKey, nowMs: nowMs)
                }
            }
        }
        if !success {
            DebugLog.write("waiting notification requeued keys=\(keys.joined(separator: ","))")
            scheduleDelivery(afterMs: Self.minimumIntervalMs)
        }
    }

    private func scheduleDelivery(afterMs: Int64) {
        deliveryTask?.cancel()
        deliveryTask = Task { @MainActor [weak self] in
            let nanos = UInt64(max(250, afterMs)) * 1_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.deliveryTask = nil
            self.deliverPendingIfPossible()
        }
    }

    /// Authorization may become known after the scan that observed a new
    /// Waiting edge. Flush only rows that are still waiting; a resolved prompt
    /// should not reappear as a stale notification when the user returns from
    /// System Settings.
    func deliverPendingIfPossible() {
        guard let model, model.notifyAuthorized == true, model.settings.notifyOnWaiting else { return }
        let rows = Self.queuedDeliveryRows(
            queued: model.sessionLog.queuedKeys, rows: model.cachedAll, muted: model.settings.mutedAgents
        )
        guard !rows.isEmpty else { return }
        post(rows)
    }

    // MARK: - Delivery rows (pure)

    /// Index rows by their key, keeping the first of any pair that collides.
    ///
    /// `Dictionary(uniqueKeysWithValues:)` **traps** on a duplicate key, and
    /// this one already crashed the menu bar once — the failure mode is the
    /// app disappearing from the menu bar rather than a wrong pixel.
    nonisolated static func byRowKey(_ rows: [AgentRow]) -> [String: AgentRow] {
        Dictionary(rows.map { ($0.rowKey, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 23.0: the rows whose banner is still owed, taken from *this* scan.
    /// The queue used to hold frozen copies of rows and filter them by
    /// `row.waiting` — always true on a copy made while it waited — so a wait
    /// that had resolved could still get its banner, and the queue grew with
    /// every session that ever waited unannounced. Only a key that is
    /// waiting now, in a current row, qualifies.
    nonisolated static func queuedDeliveryRows(
        queued: Set<String>,
        rows: [AgentRow],
        muted: Set<AgentID>
    ) -> [AgentRow] {
        guard !queued.isEmpty else { return [] }
        return Array(byRowKey(rows.filter { row in
            row.isBlocked && queued.contains(row.rowKey) && !muted.contains(row.agent)
        }).values)
    }

    /// One delivery row per Waiting session, fresh edge preferred.
    ///
    /// A row can legitimately be in both lists: an edge queued while
    /// notification authorization was still unresolved, then re-emitted as a
    /// new wait once the agent cleared and asked again. The previous inline
    /// `Dictionary(uniqueKeysWithValues:)` **trapped** on that duplicate key.
    nonisolated static func waitingDeliveryRows(
        edges: [AgentRow],
        queued: [AgentRow]
    ) -> [AgentRow] {
        Array(
            Dictionary(
                (edges + queued).map { ($0.rowKey, $0) },
                uniquingKeysWith: { fresh, _ in fresh }
            ).values
        )
    }

    // MARK: - Banner copy

    /// `Claude · Pulse` — who and where, so the banner is actionable at a glance.
    func notificationTitle(_ row: AgentRow) -> String {
        let project = AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project)
        return project.isEmpty
            ? row.agent.displayName
            : "\(row.agent.displayName) · \(project)"
    }

    /// `Permission · Approve shell command` — the reason, not just "Needs you".
    func notificationBody(_ row: AgentRow) -> String {
        let lang = model?.lang ?? AppLanguage.auto.resolved
        let kind = row.wait?.kind ?? ""
        var bits: [String] = [
            kind.isEmpty ? L10n.t(.needsYou, lang) : L10n.waitKind(kind, lang)
        ]
        let msg = (row.wait?.ask ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty {
            bits.append(msg.count > 120 ? String(msg.prefix(119)) + "…" : msg)
        } else if let task = row.usefulTask {
            bits.append(task.count > 120 ? String(task.prefix(119)) + "…" : task)
        }
        return bits.joined(separator: " · ")
    }

    // MARK: - The banner's audit

    /// Records a banner outcome per row on its open wait; the log changes
    /// (and is written) only when an outcome actually changed.
    func recordDelivery(_ outcomes: [String: String], nowMs: Int64) {
        guard !outcomes.isEmpty else { return }
        model?.updateLog { log in
            for (key, outcome) in outcomes { log.markDelivery(key, outcome: outcome, nowMs: nowMs) }
        }
    }

    /// The person clicked a banner. 23.0: the banner carries the ids of the
    /// waits it was posted for, and those are what is credited — a click on
    /// an old banner no longer lands on whatever the row waits for now.
    func recordBannerClick(waitIDs: [String]) {
        guard !waitIDs.isEmpty else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        model?.updateLog(immediately: true) { log in
            for id in waitIDs { log.markClicked(waitID: id, nowMs: nowMs) }
        }
    }

    /// A banner (or its Focus button) was clicked: credit the waits it stood
    /// for, then go to the row that raised it. Prefer the concrete rowKey
    /// (a summary carries its first row's key too); never open the tray
    /// without an identity when one was carried.
    func handleBannerClick(
        agent: String, session: String, rowKey: String, summaryRowKeys: [String], waitIDs: [String]
    ) {
        recordBannerClick(waitIDs: waitIDs)
        guard let model else { return }
        if !rowKey.isEmpty {
            model.focusAgent(idRaw: agent, session: session, rowKey: rowKey)
        } else if let first = summaryRowKeys.first {
            model.focusAgent(idRaw: agent, session: session, rowKey: first)
        } else if !agent.isEmpty {
            model.focusAgent(idRaw: agent, session: session, rowKey: "")
        } else {
            model.focusFirstWaiting()
        }
    }
}
