import Foundation

/// Respond (scene AR) — deliver the user's own decision to a remote
/// permission request. See docs/respond-protocol.md for the file protocol and
/// AGENTS.md for the invariant this must never cross: no judgment transfer,
/// no blind approve, and every failure falls open to the vendor's own prompt.
extension StatusStore {
    /// Match inbound full requests to rows. Called on the main thread after
    /// every applyScan with spool contents read on the scan queue.
    ///
    /// A request only ever attaches to a REMOTE row of the same host and
    /// agent: local rows never hold (the vendor prompt is already in front of
    /// the user), so offering an answer on one would promise something the
    /// hook will not collect.
    func refreshRespondInbound(_ inbound: [RespondSpool.InboundRequest]) {
        let byRowKey = Self.matchRespondInbound(inbound, rows: snapshot.rows)
        if byRowKey != respondInboundByRowKey {
            respondInboundByRowKey = byRowKey
        }
        // A verdict note only makes sense while its request is still around.
        respondVerdictSentRowKeys = respondVerdictSentRowKeys.filter {
            byRowKey[$0] != nil
        }
    }

    /// Pure matcher, so the attachment rules can be pinned by tests without
    /// seeding a snapshot.
    ///
    /// The two kinds never cross. A request read out of the local tree only
    /// attaches to a row this Mac is actually observing, and a request that
    /// arrived from a partner Mac only attaches to a remote row of that host —
    /// otherwise a verdict would go back to a hook that is not the one holding.
    static func matchRespondInbound(
        _ inbound: [RespondSpool.InboundRequest],
        rows: [AgentRow]
    ) -> [String: RespondSpool.InboundRequest] {
        var byRowKey: [String: RespondSpool.InboundRequest] = [:]
        for candidate in inbound {
            let request = candidate.request
            guard !request.host.isEmpty else { continue }
            let match = rows.first { row in
                if candidate.isLocal {
                    guard row.observationSource != .remote else { return false }
                } else {
                    guard row.observationSource == .remote else { return false }
                    guard row.host == request.host else { return false }
                }
                guard row.agent == request.agent else { return false }
                if !request.session.isEmpty, !row.sessionID.isEmpty {
                    return row.sessionID == request.session
                }
                return true
            }
            guard let row = match else { continue }
            // Prefer the newest request when two attach to the same row.
            if let existing = byRowKey[row.rowKey],
               existing.request.receivedAtMs >= request.receivedAtMs {
                continue
            }
            byRowKey[row.rowKey] = candidate
        }
        return byRowKey
    }

    func respondRequest(for row: AgentRow) -> RespondSpool.InboundRequest? {
        respondInboundByRowKey[row.rowKey]
    }

    func respondVerdictSent(_ row: AgentRow) -> Bool {
        respondVerdictSentRowKeys.contains(row.rowKey)
    }

    /// Deny is always safe: refusing something you have not fully read cannot
    /// be regretted the way approving it can.
    func respondDeny(_ row: AgentRow) {
        writeRespondVerdict(row, allow: false)
    }

    /// Deny straight off the banner, where the interruption actually arrived.
    ///
    /// Keyed by row rather than by an `AgentRow` because the notification only
    /// ever carried the key. A request that has since expired or been claimed
    /// simply finds nothing to answer, which `writeRespondVerdict` already
    /// reports honestly.
    func respondDeny(rowKey: String) {
        guard let row = allRowsForDisplay.first(where: { $0.rowKey == rowKey }) else { return }
        respondDeny(row)
    }

    /// Is there a full request attached to this row right now? Decides whether
    /// the banner is allowed to offer Deny at all.
    func canRespondFromBanner(_ row: AgentRow) -> Bool {
        respondInboundByRowKey[row.rowKey] != nil && !respondVerdictSentRowKeys.contains(row.rowKey)
    }

    /// Allow goes through the model's own gate: `decide(allow: true)` returns
    /// nil for a truncated or empty request, and this method reports failure
    /// rather than pretending.
    func respondAllow(_ row: AgentRow) {
        writeRespondVerdict(row, allow: true)
    }

    func openRespond(_ row: AgentRow) {
        AgentDetailWindowController.shared.show(store: self, row: row)
    }

    /// Every exit from here is visible.
    ///
    /// Refusal and a failed write used to leave through `debug.log` alone, so
    /// pressing Deny — the button this product promises is always available,
    /// because refusing something you have not fully read is the safe move —
    /// looked exactly like pressing a button that does nothing. Failure is
    /// still fail-open: the remote agent falls back to its own prompt, which
    /// is what the sentence says.
    private func writeRespondVerdict(_ row: AgentRow, allow: Bool) {
        guard let inbound = respondInboundByRowKey[row.rowKey] else {
            noteRowAction(row.rowKey, tr(.respondRequestGone))
            return
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var decisions = RespondDecisionStore()
        guard let verdict = decisions.decide(inbound.request, allow: allow, nowMs: nowMs) else {
            DebugLog.write("respond refuse allow=\(allow) key=\(row.rowKey) canOfferAllow=false")
            noteRowAction(row.rowKey, tr(.respondRefused))
            return
        }
        let written = RespondSpool.writeVerdict(verdict, local: inbound.isLocal)
        DebugLog.write(
            "respond verdict allow=\(allow) host=\(inbound.request.host) "
                + "local=\(inbound.isLocal) written=\(written)"
        )
        if written {
            respondVerdictSentRowKeys.insert(row.rowKey)
        } else {
            noteRowAction(row.rowKey, tr(.respondWriteFailed))
        }
    }
}
