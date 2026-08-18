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
    static func matchRespondInbound(
        _ inbound: [RespondSpool.InboundRequest],
        rows: [AgentRow]
    ) -> [String: RespondSpool.InboundRequest] {
        var byRowKey: [String: RespondSpool.InboundRequest] = [:]
        for candidate in inbound {
            let request = candidate.request
            guard !request.host.isEmpty else { continue }
            let match = rows.first { row in
                guard row.observationSource == .remote else { return false }
                guard row.agent == request.agent, row.host == request.host else { return false }
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
        let written = RespondSpool.writeVerdict(verdict)
        DebugLog.write(
            "respond verdict allow=\(allow) host=\(inbound.request.host) written=\(written)"
        )
        if written {
            respondVerdictSentRowKeys.insert(row.rowKey)
        } else {
            noteRowAction(row.rowKey, tr(.respondWriteFailed))
        }
    }
}
