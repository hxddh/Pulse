import Foundation
import AppKit

/// 4.0-γ file split — Look continuity — what changed while the tray was closed.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    func trayWillAppear() {
        traySessionToken &+= 1
        // Store-owned, and just as much "last time's rummaging" as the folds.
        if showAllAgents {
            showAllAgents = false
            applyRowWindow()
        }
    }

    /// Tray panel appeared — probe faster while the user is looking at it.
    func trayDidAppear() {
        trayOpen = true
        // 0.96: keep the close fingerprint until the opening scan finishes.
        // Diffing `cachedAll` here used the last background tick, so sleep/lock
        // changes landed in the list but not in the while-away notice.
        if trayClosedAt != nil {
            lookContinuityPendingClosedAt = trayClosedAt
        }
        rescheduleTimer()
        if previewFixtureActive {
            applyPendingLookContinuity()
        } else {
            refresh(reason: "trayOpen")
        }
    }

    func trayDidDisappear() {
        trayOpen = false
        trayClosedAt = Date()
        trayCloseFingerprint = captureLookFingerprint(at: trayClosedAt ?? Date())
        lookContinuityPendingClosedAt = nil
        rescheduleTimer()
    }

    /// Apply Look Closure against the rows from the opening scan (0.96).
    func applyPendingLookContinuity() {
        guard let closed = lookContinuityPendingClosedAt else { return }
        lookContinuityPendingClosedAt = nil
        missedWhileAway = waitHistory.filter { $0.resolvedAt > closed }.count
        if let prior = trayCloseFingerprint {
            applyLookContinuity(prior: prior, closedAt: closed)
            return
        }
        lookMovedWhileAway = 0
        lookNewWaitsWhileAway = 0
        let ended = waitHistory.filter { $0.resolvedAt > closed }
        lookContinuityItems = ended.map { wait in
            let label = wait.title.isEmpty
                ? wait.agent.displayName
                : "\(wait.agent.displayName) · \(wait.title)"
            let revealable = cachedAll.contains(where: { $0.rowKey == wait.rowKey })
            return LookDeltaItem(
                kind: .endedWait,
                rowKey: wait.rowKey,
                label: label,
                revealable: revealable
            )
        }
        lookMovedRowKeys = []
        rebuildLookContinuityNotice()
    }

    /// Test seam: seed resolved-wait history for Look Closure assertions.
    func seedWaitHistory(_ items: [ResolvedWait]) {
        waitHistory = items
    }

    /// Acknowledge the "while you were away" line (clears named notice + row marks).
    func clearMissedWhileAway() {
        missedWhileAway = 0
        lookMovedWhileAway = 0
        lookNewWaitsWhileAway = 0
        lookContinuityNotice = ""
        lookContinuityItems = []
        lookMovedRowKeys = []
    }

    /// Look Closure (0.93): reveal the highest-priority named row, then ack.
    func activateLookContinuity() {
        let key = lookContinuityPrimaryRevealKey
        clearMissedWhileAway()
        if let key, !key.isEmpty {
            requestTrayReveal(rowKey: key)
        }
    }

    /// First revealable Look Closure row — new wait → ended (if still present) → moved.
    var lookContinuityPrimaryRevealKey: String? {
        lookContinuityItems.first(where: \.revealable)?.rowKey
    }

    /// Short row mark while the Look Closure notice is still up.
    func lookMarkedWhileAway(_ row: AgentRow) -> Bool {
        lookMovedRowKeys.contains(row.rowKey) && !row.waiting
    }

    /// Snapshot of live tray rows for Look Continuity / Closure.
    func captureLookFingerprint(at date: Date = Date()) -> TrayLookFingerprint {
        let snaps = cachedAll.map { row -> TrayLookFingerprint.RowSnap in
            TrayLookFingerprint.RowSnap(
                rowKey: row.rowKey,
                agentRaw: row.agent.rawValue,
                label: lookRowLabel(row),
                waiting: row.waiting,
                waitKind: row.waitKind,
                phase: row.phase,
                tool: row.tool,
                task: row.task,
                harvestMs: row.harvestMs,
                activityChangedMs: row.activityChangedMs,
                changeTag: lookChangeTag(row.activityChange),
                tokensIn: row.tokensIn,
                tokensOut: row.tokensOut,
                progressDone: row.progressDone,
                waitSinceMs: row.waitSinceMs
            )
        }
        return TrayLookFingerprint(closedAt: date, rows: snaps)
    }

    private func lookRowLabel(_ row: AgentRow) -> String {
        if let task = row.usefulTask, !task.isEmpty {
            let short = task.count > 28 ? String(task.prefix(27)) + "…" : task
            return "\(row.agent.displayName) · \(short)"
        }
        return row.agent.displayName
    }

    private func lookChangeTag(_ change: AgentActivityChange?) -> String {
        guard let change else { return "" }
        switch change {
        case .errors(let n): return "errors:\(n)"
        case .files(let n): return "files:\(n)"
        case .progress(let d, let t): return "progress:\(d)/\(t)"
        case .modelCall: return "model"
        case .toolChanged: return "tool"
        case .phaseChanged: return "phase"
        case .taskChanged: return "task"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    /// Compare close fingerprint to current rows — named Look Closure events (0.93).
    func applyLookContinuity(prior: TrayLookFingerprint, closedAt: Date) {
        let now = captureLookFingerprint(at: Date())
        let keyDelta = Self.lookContinuityKeyDelta(prior: prior, current: now)
        let liveByKey = Self.byRowKey(cachedAll)
        var items: [LookDeltaItem] = []

        // Priority: new waits → ended waits → moved sessions.
        for key in keyDelta.newWaitKeys {
            let label: String
            let revealable: Bool
            if let row = liveByKey[key] {
                label = lookRowLabel(row)
                revealable = true
            } else if let snap = now.rows.first(where: { $0.rowKey == key }) {
                label = snap.label.isEmpty ? snap.agentRaw : snap.label
                revealable = false
            } else {
                label = key
                revealable = false
            }
            items.append(LookDeltaItem(kind: .newWait, rowKey: key, label: label, revealable: revealable))
        }

        let ended = waitHistory.filter { $0.resolvedAt > closedAt }
        let endedKeys = Set(ended.map(\.rowKey))
        let newWaitSet = Set(keyDelta.newWaitKeys)
        lookNewWaitsWhileAway = keyDelta.newWaitKeys.count
        lookMovedWhileAway = keyDelta.movedKeys.filter {
            !endedKeys.contains($0) && !newWaitSet.contains($0)
        }.count
        missedWhileAway = ended.count

        for wait in ended {
            // Same row lighting a new wait outranks the ended history item.
            if newWaitSet.contains(wait.rowKey) { continue }
            let label = wait.title.isEmpty
                ? wait.agent.displayName
                : "\(wait.agent.displayName) · \(wait.title)"
            let revealable = liveByKey[wait.rowKey] != nil
            items.append(LookDeltaItem(
                kind: .endedWait,
                rowKey: wait.rowKey,
                label: label,
                revealable: revealable
            ))
        }

        for key in keyDelta.movedKeys {
            if endedKeys.contains(key) || newWaitSet.contains(key) { continue }
            let label: String
            let revealable: Bool
            if let row = liveByKey[key] {
                label = lookRowLabel(row)
                revealable = true
            } else if let snap = now.rows.first(where: { $0.rowKey == key }) {
                label = snap.label.isEmpty ? snap.agentRaw : snap.label
                revealable = false
            } else {
                continue
            }
            items.append(LookDeltaItem(kind: .moved, rowKey: key, label: label, revealable: revealable))
        }

        lookContinuityItems = items
        lookMovedRowKeys = Set(
            items.compactMap { item -> String? in
                guard item.revealable else { return nil }
                switch item.kind {
                case .newWait, .moved: return item.rowKey
                case .endedWait: return nil
                }
            }
        )
        rebuildLookContinuityNotice()
    }

    /// Key-level Look Continuity diff — only fingerprint fields; never invents Waiting.
    static func lookContinuityKeyDelta(
        prior: TrayLookFingerprint,
        current: TrayLookFingerprint
    ) -> (movedKeys: [String], newWaitKeys: [String]) {
        let priorByKey = Dictionary(prior.rows.map { ($0.rowKey, $0) }, uniquingKeysWith: { first, _ in first })
        var movedKeys: [String] = []
        var newWaitKeys: [String] = []
        for snap in current.rows {
            guard let old = priorByKey[snap.rowKey] else {
                if snap.waiting {
                    newWaitKeys.append(snap.rowKey)
                } else if snap.harvestMs > 0 || snap.activityChangedMs > 0 {
                    movedKeys.append(snap.rowKey)
                }
                continue
            }
            if snap.waiting, !old.waiting {
                newWaitKeys.append(snap.rowKey)
                continue
            }
            // 0.96: a new wait generation on the same row (waitSinceMs moved)
            // is a new wait, not a silent continuation.
            if snap.waiting, old.waiting,
               snap.waitSinceMs > 0, old.waitSinceMs > 0,
               snap.waitSinceMs != old.waitSinceMs {
                newWaitKeys.append(snap.rowKey)
                continue
            }
            let changed = snap.phase != old.phase
                || snap.tool != old.tool
                || snap.task != old.task
                || snap.changeTag != old.changeTag
                || snap.harvestMs != old.harvestMs
                || snap.activityChangedMs != old.activityChangedMs
                || snap.tokensIn != old.tokensIn
                || snap.tokensOut != old.tokensOut
                || snap.progressDone != old.progressDone
                || snap.waitKind != old.waitKind
            if changed { movedKeys.append(snap.rowKey) }
        }
        return (movedKeys, newWaitKeys)
    }

    /// Compatibility wrapper used by older tests — counts only.
    static func lookContinuityDelta(
        prior: TrayLookFingerprint,
        current: TrayLookFingerprint
    ) -> (moved: Int, newWaits: Int) {
        let keys = lookContinuityKeyDelta(prior: prior, current: current)
        return (keys.movedKeys.count, keys.newWaitKeys.count)
    }

    private func rebuildLookContinuityNotice() {
        // Prefer named Look Closure copy (0.93); fall back to counts if empty.
        if !lookContinuityItems.isEmpty {
            lookContinuityNotice = formatLookContinuityNotice(lookContinuityItems)
            return
        }
        var parts: [String] = []
        if missedWhileAway > 0 {
            parts.append(String(format: tr(.whileAway), missedWhileAway))
        }
        if lookNewWaitsWhileAway > 0 {
            parts.append(String(format: tr(.whileAwayNewWaits), lookNewWaitsWhileAway))
        }
        if lookMovedWhileAway > 0 {
            parts.append(String(format: tr(.whileAwayMoved), lookMovedWhileAway))
        }
        lookContinuityNotice = parts.joined(separator: " · ")
    }

    /// Named notice: up to 3 events + "+N". Priority already encoded in items order.
    func formatLookContinuityNotice(_ items: [LookDeltaItem], limit: Int = 3) -> String {
        guard !items.isEmpty else { return "" }
        let head = items.prefix(limit).map { item -> String in
            switch item.kind {
            case .newWait:
                return String(format: tr(.whileAwayNamedNew), item.label)
            case .endedWait:
                return String(format: tr(.whileAwayNamedEnded), item.label)
            case .moved:
                return String(format: tr(.whileAwayNamedMoved), item.label)
            }
        }
        var text = head.joined(separator: " · ")
        let overflow = items.count - limit
        if overflow > 0 {
            text += " · " + String(format: tr(.whileAwayMore), overflow)
        }
        return text
    }
}
