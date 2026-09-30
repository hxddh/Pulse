import Foundation
import AppKit

/// The "needs you" banner: what to post and when. Not observed — no view
/// reads it.
///
/// The projection reports Waiting edges (`TrayState.newlyBlocked`);
/// `WaitingDelivery` decides which rows get a banner; this class carries the
/// plan out through `PulseNotify`, rate limits it, keeps an owed banner owed
/// until it is accepted or its wait resolves (`WaitLedger`, in memory), and
/// sends a banner click back to the row that raised it.
@MainActor
final class WaitNotifier {
    /// The model this notifier reads settings and rows from. Weak: the model
    /// owns the notifier.
    weak var model: StatusStore?

    /// One interruption per short window keeps a burst of parallel approvals
    /// useful without turning Notification Center into a stream of duplicates.
    static let minimumIntervalMs: Int64 = 3_000

    /// Every open wait and what its banner owes — in memory only.
    private(set) var ledger = WaitLedger()
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

    /// Notification policy for one projection; the projection only reports
    /// the edges. `baseline`: the event log has not been read since
    /// launch (or this is the projection of that first read) — its waits
    /// were raised before Pulse was watching and get no banner.
    func scanLanded(_ state: TrayState, nowMs: Int64, baseline: Bool) {
        ledger.reconcile(rows: state.rows, edges: Set(state.newlyBlocked.map(\.rowKey)))
        guard !baseline, let model else { return }
        let settings = model.settings
        guard settings.notifyOnWaiting else { return }
        let edges = state.newlyBlocked.filter { !settings.mutedAgents.contains($0.agent) }
        // Owed banners are rebuilt from this projection's rows: a wait that
        // resolved has no open record, so it can neither linger in a queue
        // nor bring back a banner for a prompt that is gone.
        let queued = Self.queuedDeliveryRows(
            queued: ledger.queuedKeys, rows: state.rows, muted: settings.mutedAgents
        )
        if model.notifyAuthorized == true {
            post(Self.waitingDeliveryRows(edges: edges, queued: queued))
        } else {
            // Permission resolution is asynchronous, and a denied permission
            // may be allowed later in System Settings: keep every edge owed
            // until the callback arrives instead of dropping the only
            // interruption for a just-started session.
            for waiting in edges { ledger.markQueued(waiting.rowKey) }
        }
    }

    /// The person dismissed the row's wait: no banner for it.
    func dismissed(_ rowKey: String) {
        ledger.dismiss(rowKey)
    }

    // MARK: - Posting

    /// Deliver one actionable notification per Waiting session. A previous
    /// implementation used `first(where:)`, so a scan that found Codex and
    /// Cursor approvals notified only whichever row happened to sort first.
    func post(_ rows: [AgentRow]) {
        guard let model, model.notifyAuthorized == true, model.settings.notifyOnWaiting else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // The decision is `WaitingDelivery`; this method carries it out.
        let delivery = WaitingDelivery(
            muted: model.settings.mutedAgents,
            acknowledged: ledger.dismissedKeys,
            inFlight: inFlight,
            canDeliverNow: ledger.canDeliver(nowMs: nowMs, minimumIntervalMs: Self.minimumIntervalMs),
            msSinceLastNotification: nowMs - ledger.lastNotificationMs,
            minimumIntervalMs: Self.minimumIntervalMs
        )
        let candidates: [AgentRow]
        let asSummary: Bool
        switch delivery.plan(rows) {
        case .nothing:
            return
        case .hold(let held, let retryAfterMs):
            for waiting in held { ledger.markQueued(waiting.rowKey) }
            scheduleDelivery(afterMs: retryAfterMs)
            return
        case .post(let ready, let summary):
            candidates = ready
            asSummary = summary
        }

        for waiting in candidates { inFlight.insert(waiting.rowKey) }
        if asSummary {
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
                completion: { [weak self] success in
                    self?.finishDelivery(keys: candidates.map(\.rowKey), success: success)
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
                    completion: { [weak self] success in
                        // Each request owns one wait; commit it on its own so
                        // one rejected request never hides the others.
                        self?.finishDelivery(keys: [waiting.rowKey], success: success)
                    }
                )
            }
        }
    }

    /// Commit the banner only once Notification Center has said whether it
    /// accepted the request; a refused one stays owed and is retried.
    private func finishDelivery(keys: [String], success: Bool) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for key in keys { inFlight.remove(key) }
        // A banner Notification Center refused is said in the tray, not
        // only in debug.log; the next accepted one clears it.
        model?.landWaitingBannerFailed(!success)
        for key in keys {
            if success {
                ledger.markNotified(key, nowMs: nowMs)
            } else {
                ledger.markQueued(key)
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
            queued: ledger.queuedKeys, rows: model.cachedAll, muted: model.settings.mutedAgents
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

    /// The rows whose banner is still owed, taken from *this* scan.
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

    // MARK: - Clicks

    /// A banner (or its Focus button) was clicked: go to the row that raised
    /// it. Prefer the concrete rowKey (a summary carries its first row's key
    /// too); never open the tray without an identity when one was carried.
    func handleBannerClick(agent: String, session: String, rowKey: String, summaryRowKeys: [String]) {
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
