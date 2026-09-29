import Foundation
import AppKit

/// 4.0-γ file split — Waiting delivery and actions — notifications, dismiss, focus.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    func postWaitingNotifications(_ rows: [AgentRow]) {
        guard notifyAuthorized == true, notifyOnWaiting else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 12.3 δ: the decision is `WaitingDelivery`; this method carries it out.
        let delivery = WaitingDelivery(
            muted: mutedAgents,
            acknowledged: Set(
                rows.filter(\.waiting).map(\.rowKey).filter { attentionLedger.isAcknowledged(rowKey: $0) }
            ),
            inFlight: waitingDeliveryInFlight,
            canDeliverNow: attentionLedger.canDeliver(
                nowMs: nowMs,
                minimumIntervalMs: Self.waitingNotificationMinimumIntervalMs
            ),
            msSinceLastNotification: nowMs - attentionLedger.lastNotificationAtMs,
            minimumIntervalMs: Self.waitingNotificationMinimumIntervalMs
        )
        // 22.0: the rows this plan leaves out say why, on their own event.
        recordDelivery(delivery.skipReasons(rows).mapValues(\.rawValue), nowMs: nowMs)
        let candidates: [AgentRow]
        let asSummary: Bool
        switch delivery.plan(rows) {
        case .nothing:
            return
        case .hold(let held, let retryAfterMs):
            for waiting in held {
                pendingWaitingNotifications[waiting.rowKey] = waiting
                attentionLedger.markQueued(rowKey: waiting.rowKey, nowMs: nowMs)
            }
            attentionLedger.save()
            scheduleWaitingDelivery(afterMs: retryAfterMs)
            return
        case .post(let ready, let summary):
            candidates = ready
            asSummary = summary
        }

        let deliveryKeys = candidates.map(\.rowKey)
        for waiting in candidates {
            pendingWaitingNotifications[waiting.rowKey] = waiting
            waitingDeliveryInFlight.insert(waiting.rowKey)
            attentionLedger.markQueued(rowKey: waiting.rowKey, nowMs: nowMs)
        }
        // Persist before asking Notification Center to accept the request. A
        // crash between those two operations leaves a durable queued edge,
        // which the next launch can rehydrate and deliver exactly once.
        attentionLedger.save()

        let batchCompletion: (Bool) -> Void = { [weak self] success in
            guard let self else { return }
            self.finishWaitingDelivery(
                keys: deliveryKeys,
                rows: candidates,
                success: success
            )
        }

        if asSummary {
            let eventIDs = candidates.compactMap { attentionLedger.eventID(for: $0.rowKey) }
            let title = String(format: tr(.waitingSummaryTitle), candidates.count)
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
                completion: batchCompletion
            )
        } else {
            for waiting in candidates {
                PulseNotify.postWaiting(
                    title: notificationTitle(waiting),
                    body: notificationBody(waiting),
                    agent: waiting.agent.rawValue,
                    session: waiting.sessionID,
                    rowKey: waiting.rowKey,
                    eventID: attentionLedger.eventID(for: waiting.rowKey) ?? "",
                    completion: { success in
                        // Each individual request owns one event; commit that
                        // event independently so one rejected request never
                        // hides the other accepted Waiting notifications.
                        self.finishWaitingDelivery(
                            keys: [waiting.rowKey],
                            rows: [waiting],
                            success: success
                        )
                    }
                )
            }
        }
    }

    /// Commit or requeue the durable event only after Notification Center has
    /// reported whether the request was accepted. This closes the rare but
    /// important gap where an app reinstall, identity transition, or system
    /// service error rejects an otherwise valid request.
    /// One delivery row per Waiting session, fresh edge preferred.
    ///
    /// A row can legitimately be in both lists: an edge queued while
    /// notification authorization was still unresolved, then re-emitted as a
    /// new wait once the agent cleared and asked again — 0.96 made a new
    /// `waitSinceMs` on the same key a new edge. The previous inline
    /// `Dictionary(uniqueKeysWithValues:)` **traps** on a duplicate key, so
    /// that sequence crashed the menu bar outright.
    /// Index rows by their key, keeping the first of any pair that collides.
    ///
    /// `Dictionary(uniqueKeysWithValues:)` **traps** on a duplicate key, and
    /// this one already crashed the menu bar once — the fix landed in
    /// `waitingDeliveryRows` and the same construct stayed in four other
    /// places, each safe only because the builder happens to hand back a
    /// dictionary's values today. That is a property of the current
    /// implementation, not a guarantee, and the failure mode is the app
    /// disappearing from the menu bar rather than a wrong pixel.
    nonisolated static func byRowKey(_ rows: [AgentRow]) -> [String: AgentRow] {
        Dictionary(rows.map { ($0.rowKey, $0) }, uniquingKeysWith: { first, _ in first })
    }

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

    private func finishWaitingDelivery(
        keys: [String],
        rows: [AgentRow],
        success: Bool
    ) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for key in keys {
            waitingDeliveryInFlight.remove(key)
        }
        // 21.0: a banner Notification Center refused is said in the tray,
        // not only in debug.log; the next accepted one clears it.
        if waitingBannerFailed == success { waitingBannerFailed = !success }
        let outcome = success
            ? (rows.count > WaitingDelivery.summaryAbove ? "summary" : "posted")
            : WaitingDelivery.SkipReason.rejected.rawValue
        for row in rows { attentionLedger.markDelivery(rowKey: row.rowKey, outcome: outcome, nowMs: nowMs) }
        if success {
            for row in rows {
                attentionLedger.markNotified(rowKey: row.rowKey, nowMs: nowMs)
                pendingWaitingNotifications.removeValue(forKey: row.rowKey)
            }
            attentionLedger.save()
            // 22.0: the banner carries the system sound the person chose in
            // System Settings → Notifications; Pulse no longer plays its own.
        } else {
            for row in rows where row.waiting {
                pendingWaitingNotifications[row.rowKey] = row
                attentionLedger.markQueued(rowKey: row.rowKey, nowMs: nowMs)
            }
            attentionLedger.save()
            DebugLog.write("waiting notification requeued keys=\(keys.joined(separator: ","))")
            scheduleWaitingDelivery(afterMs: Self.waitingNotificationMinimumIntervalMs)
        }
    }

    private func scheduleWaitingDelivery(afterMs: Int64) {
        waitingDeliveryTask?.cancel()
        waitingDeliveryTask = Task { @MainActor [weak self] in
            let nanos = UInt64(max(250, afterMs)) * 1_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.waitingDeliveryTask = nil
            self.deliverPendingWaitingNotificationsIfPossible()
        }
    }

    /// Authorization may become known after the scan that observed a new
    /// Waiting edge. Flush only rows that are still waiting; a resolved prompt
    /// should not reappear as a stale notification when the user returns from
    /// System Settings.
    func deliverPendingWaitingNotificationsIfPossible() {
        guard notifyAuthorized == true, notifyOnWaiting, !pendingWaitingNotifications.isEmpty else {
            if !notifyOnWaiting { pendingWaitingNotifications.removeAll() }
            return
        }
        let current = Self.byRowKey(cachedAll)
        let rows = pendingWaitingNotifications.values.compactMap { pending -> AgentRow? in
            guard let row = current[pending.rowKey], row.waiting else { return nil }
            return row
        }
        postWaitingNotifications(rows)
    }

    func applyRowWindow() {
        var snap = snapshot
        SnapshotBuilder.window(
            rows: cachedAll,
            showAll: showAllAgents,
            maxVisible: SnapshotBuilder.maxVisibleRows,
            into: &snap
        )
        snapshot = snap
    }

    /// `Claude · Pulse` — who and where, so the banner is actionable at a glance.
    func notificationTitle(_ row: AgentRow) -> String {
        let project = AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project)
        return project.isEmpty
            ? row.agent.displayName
            : "\(row.agent.displayName) · \(project)"
    }

    /// `Permission · Approve shell command` — the reason, not just "Needs you".
    /// The old body was the glance tooltip, which never said what was wanted.
    func notificationBody(_ row: AgentRow) -> String {
        var bits: [String] = [
            row.waitKind.isEmpty ? tr(.needsYou) : localizedWaitKind(row.waitKind)
        ]
        let msg = row.waitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty {
            bits.append(msg.count > 120 ? String(msg.prefix(119)) + "…" : msg)
        } else if let task = row.usefulTask {
            bits.append(task.count > 120 ? String(task.prefix(119)) + "…" : task)
        }
        return bits.joined(separator: " · ")
    }

    func clearWaiting() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 0.95: extinguish delivery synchronously so a queued banner cannot
        // fire after the user already cleared Waiting.
        pendingWaitingNotifications.removeAll()
        // 2.2: emptying our own queue only covers the requests we had not
        // submitted yet. `center.add` is asynchronous — a request accepted a
        // moment before the click is already past that queue and still lands
        // on screen after the user cleared Waiting. Scene AH promises no late
        // notification, so take back what was already submitted too (U-7).
        withdrawWaitingBanners()
        var dismissedChanged = false
        for row in cachedAll where row.waiting {
            attentionLedger.acknowledge(rowKey: row.rowKey, nowMs: nowMs)
            if row.waitSignal == .pending || row.waitSignal == .vendor || row.skill == "pending" {
                dismissedChanged = dismissedPendingKeys.insert(row.rowKey).inserted || dismissedChanged
            }
        }
        attentionLedger.save()
        if dismissedChanged { persistDismissedPendingKeys() }
        AttentionIO.clearAll()
        refresh(reason: "clearWaiting")
    }

    /// Live Waiting-none session — needs Attention Reach, not a fake Waiting chip.
    func isWaitingNoneNeedsReach(_ row: AgentRow) -> Bool {
        !row.waiting
            && row.liveProcess
            && row.agent.waitingSource == .none
    }

    /// Open Waiting signals focused on this Waiting-none agent (0.94 Proof).
    func openWaitingReach(for row: AgentRow) {
        openSettings(focusWaitingSignals: true)
    }

    /// The row that has been blocked longest, if any.
    ///
    /// Rows arrive sorted oldest-wait-first, so this is the top of the list —
    /// but the lookup does not rely on that, because a caller reaching for
    /// "the most urgent thing" should not silently depend on sort order.
    var oldestWait: AgentRow? {
        Self.oldestWaitRow(in: cachedAll)
    }

    nonisolated static func oldestWaitRow(in rows: [AgentRow]) -> AgentRow? {
        let waiting = rows.filter(\.waiting)
        return waiting
            .filter { $0.waitSinceMs > 0 }
            .min { $0.waitSinceMs < $1.waitSinceMs }
            ?? waiting.first
    }

    nonisolated static func firstWaitingRow(in rows: [AgentRow]) -> AgentRow? {
        rows.first(where: \.waiting)
    }

    /// Focus the longest-outstanding wait. One step from "something needs me"
    /// to the waiting row (and best Focus handle when one exists).
    func focusOldestWait() {
        guard let row = oldestWait else { return }
        DebugLog.write("jump to oldest wait \(DebugLog.key(row.rowKey))")
        focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
    }

    /// "12m ago" for a row's last activity, or "no activity yet".

    /// Support Health Focus fact — observation-only when nothing is clickable.
    func supportFocusDetail(_ health: AgentSupportHealth) -> String {
        if let tier = health.focusTier {
            switch tier {
            case .warp: return tr(.supportFocusWarp)
            case .hostWorkspace(let kind):
                return String(format: tr(.supportFocusHostWorkspace), kind.displayName)
            case .hostApp(let kind):
                return String(format: tr(.supportFocusHost), kind.displayName)
            case .tty: return tr(.supportFocusTTY)
            }
        }
        if health.focusTTYNeedsOptIn {
            return tr(.supportFocusTTYNeedsOptIn)
        }
        return tr(.supportFocusNone)
    }

    /// Thin vs deep observation — never let a cache/none Agent look session-deep.
    /// Rich cache (goal + workspace/activity) stays Limited but says so honestly.
    /// Waiting-none still exposes harvest depth so ZCode/Trae cannot hide behind
    /// “Waiting unavailable” alone (0.70 Contract Honesty).
    func supportDepthDetail(_ health: AgentSupportHealth) -> String {
        let harvest: String
        switch health.agent.harvestSource {
        case .bestEffortCache:
            let rich = health.hasGoal && (health.hasWorkspace || health.hasActivity)
            harvest = rich ? tr(.supportDepthCachePartial) : tr(.supportDepthCacheThin)
        case .structuredSession:
            harvest = tr(.supportDepthSession)
        }
        if health.agent.waitingSource == .none {
            return "\(tr(.supportDepthWaitingNone)) · \(harvest)"
        }
        return harvest
    }

    func dismissWaiting(_ row: AgentRow) {
        // A vendor-reported wait (18.0) is dismissed the same soft way: the
        // vendor will keep reporting it until the session moves.
        let isHarvestPending = row.waitSignal == .pending || row.waitSignal == .vendor || row.skill == "pending"
        // 0.95: pure harvest soft-dismiss must not write agent-wide Attention
        // done (empty session clears every wait for that agent).
        if row.waitSignal == .hooks {
            AttentionIO.appendDone(agent: row.agent, session: row.doneSession)
        } else if !isHarvestPending, !row.doneSession.isEmpty {
            AttentionIO.appendDone(agent: row.agent, session: row.doneSession)
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        attentionLedger.acknowledge(rowKey: row.rowKey, nowMs: nowMs)
        attentionLedger.save()
        pendingWaitingNotifications.removeValue(forKey: row.rowKey)
        if isHarvestPending {
            dismissedPendingKeys.insert(row.rowKey)
            persistDismissedPendingKeys()
        }
        refresh(reason: "dismissWaiting")
    }

    func rowActionNotice(_ row: AgentRow) -> String? {
        rowActionNotices[row.rowKey]
    }

    /// Say what happened, briefly. Long enough to read, short enough that it
    /// never settles in and becomes row furniture.
    func noteRowAction(_ rowKey: String, _ message: String) {
        rowActionNotices[rowKey] = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            guard let self, self.rowActionNotices[rowKey] == message else { return }
            self.rowActionNotices.removeValue(forKey: rowKey)
        }
    }

    func primaryAction(_ row: AgentRow) {
        guard row.canFocusTerminal else { return }
        focusTerminal(row)
    }

    /// The focus handle was derived by the scan that produced this row, and a
    /// window can close between then and the click. When nothing was reached,
    /// say so and rescan: the next row either carries a handle that works or
    /// stops offering one.
    func focusTerminal(_ row: AgentRow) {
        if row.yourTurn { markTurnSeen(row) }
        guard !TerminalFocus.focus(row: row) else { return }
        noteRowAction(row.rowKey, tr(.focusFailed))
        refresh(reason: "focus-failed")
    }

    /// 16.0: the finished session that has waited longest for a look.
    var oldestTurn: AgentRow? {
        cachedAll.filter(\.yourTurn).min { $0.turnSinceMs < $1.turnSinceMs }
    }

    /// Blocked first, then "your turn" — the order of Conductor's "next
    /// needing attention", with the stakes kept apart.
    func focusNextTurn() {
        guard let row = oldestTurn else { return }
        DebugLog.write("jump to turn \(DebugLog.key(row.rowKey))")
        focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
    }

    /// Looking at a finished session is what "your turn" was asking for. A
    /// session-scoped `done` in the attention file is the record — it
    /// survives a restart, and it is the same line a new prompt would write.
    func markTurnSeen(_ row: AgentRow) {
        guard row.yourTurn, !row.doneSession.isEmpty else { return }
        AttentionIO.appendDone(agent: row.agent, session: row.doneSession)
        refresh(reason: "turn-seen")
    }

    func focusFirstWaiting() {
        if let row = Self.firstWaitingRow(in: cachedAll) ?? Self.firstWaitingRow(in: snapshot.rows) {
            focusAgent(idRaw: row.agent.rawValue, session: row.sessionID, rowKey: row.rowKey)
            return
        }
        requestTrayReveal()
    }

    /// Resolve a notify / hotkey / jump target, attempt best Focus, and always
    /// keep tray row identity for Waiting (Go-Look Closure). Focus success must
    /// not abandon the row that raised the interruption.
    func focusAgent(idRaw: String, session: String = "", rowKey: String = "") {
        let row = resolveFocusRow(idRaw: idRaw, session: session, rowKey: rowKey)
        if let row {
            let didFocus = row.canFocusTerminal && TerminalFocus.focus(row: row)
            if row.yourTurn { markTurnSeen(row) }
            if row.waiting || !didFocus {
                requestTrayReveal(rowKey: row.rowKey)
            }
            return
        }
        if !rowKey.isEmpty {
            // Stale notify identity: still open the tray so the user is not stranded.
            requestTrayReveal(rowKey: rowKey)
            return
        }
        focusFirstWaiting()
    }

    /// Prefer exact `rowKey`, then session, then first waiting/live row for agent.
    private func resolveFocusRow(idRaw: String, session: String, rowKey: String) -> AgentRow? {
        Self.focusTarget(in: cachedAll, idRaw: idRaw, session: session, rowKey: rowKey)
    }

    /// The session match stays inside the named agent and takes a prefix
    /// only when exactly one row fits — the same rule the builder applies to
    /// attention ids, so a truncated id (or another agent's session that
    /// happens to share a prefix) cannot send a banner click to the wrong
    /// row.
    nonisolated static func focusTarget(
        in rows: [AgentRow], idRaw: String, session: String, rowKey: String
    ) -> AgentRow? {
        if !rowKey.isEmpty, let row = rows.first(where: { $0.rowKey == rowKey }) {
            return row
        }
        let agent = ActivityHarvest.mapAgent(idRaw)?.surfaceID
        if !session.isEmpty {
            let sameAgent = rows.filter { !$0.sessionID.isEmpty && (agent == nil || $0.agent == agent) }
            if let exact = sameAgent.first(where: { $0.sessionID == session }) { return exact }
            let prefixed = sameAgent.filter {
                session.hasPrefix($0.sessionID) || $0.sessionID.hasPrefix(session)
            }
            if prefixed.count == 1 { return prefixed[0] }
        }
        guard let id = agent else { return nil }
        let own = rows.filter { $0.agent == id }
        return firstWaitingRow(in: own) ?? own.first
    }
}

// MARK: - 22.0 · the banner's audit

extension StatusStore {
    /// Records a banner outcome per row on its active ledger event; writes
    /// the ledger only when an outcome actually changed.
    func recordDelivery(_ outcomes: [String: String], nowMs: Int64) {
        var changed = false
        for (key, outcome) in outcomes where attentionLedger.markDelivery(rowKey: key, outcome: outcome, nowMs: nowMs) {
            changed = true
        }
        if changed { attentionLedger.save() }
    }

    /// The person clicked the banner for this row.
    func recordBannerClick(rowKey: String) {
        guard !rowKey.isEmpty else { return }
        if attentionLedger.markClicked(rowKey: rowKey, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) {
            attentionLedger.save()
        }
    }
}
